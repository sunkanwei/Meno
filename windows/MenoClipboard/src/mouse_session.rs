use std::collections::VecDeque;
use std::ffi::OsString;
use std::io;
use std::net::{Shutdown, TcpStream};
use std::os::windows::ffi::OsStringExt;
use std::os::windows::io::AsRawSocket;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, SyncSender, TrySendError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::HANDLE;
use windows::Win32::NetworkManagement::QoS::{
    QOS_NON_ADAPTIVE_FLOW, QOS_VERSION, QOSAddSocketToFlow, QOSCloseHandle, QOSCreateHandle,
    QOSRemoveSocketFromFlow, QOSTrafficTypeControl,
};
use windows::Win32::Networking::WinSock::{
    AF_INET, FIONREAD, IN_ADDR, IN_ADDR_0, SOCKADDR, SOCKADDR_IN, SOCKET, ioctlsocket,
};
use windows::Win32::System::SystemInformation::GetSystemDirectoryW;
use windows::Win32::System::Threading::{
    CREATE_NO_WINDOW, GetCurrentThread, SetThreadPriority, THREAD_PRIORITY_ABOVE_NORMAL,
};

use crate::connection::{ChannelHealth, WorkerEvent};
use crate::diagnostics::{
    self, DRIVER_STATUS_AVAILABLE, DRIVER_STATUS_UNAVAILABLE, DiagnosticEventKind, DiagnosticField,
    DiagnosticReason, DiagnosticRecord, DiagnosticState, DiagnosticTransport,
};
use crate::display_contract::DisplayContract;
use crate::mouse_control::{MouseControl, ReleaseOutcome, ReleaseVerdict, release_verdict};
use crate::mouse_input::{InputOutcome, LeaveInfo, MouseInputController};
use crate::protocol::{
    CAPABILITY_DIRECTIONAL_MOUSE_HANDOFF, CAPABILITY_KEYBOARD_STATE, CAPABILITY_MOUSE_CONTROL,
    CAPABILITY_REMOTE_DIAGNOSTICS, CAPABILITY_REMOTE_SHUTDOWN, Frame, FrameDecoder, MessageKind,
    MouseEntryEdge, MouseMoveSample, control_only, control_payload, decode_mouse_move,
    directional_mouse_enter, keyboard_state_message, mouse_button, mouse_enter, mouse_hello,
    mouse_leave_payload, mouse_unavailable_hello, mouse_wheel, parse_hello,
};

// Small confirmations that cannot be written promptly mean the session is
// already unhealthy; retrying stale control frames would be worse.
const MOUSE_WRITE_TIMEOUT: Duration = Duration::from_millis(100);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
const IDLE_BEFORE_PING: Duration = Duration::from_secs(30);
const PONG_TIMEOUT: Duration = Duration::from_secs(10);
// A single read+process round is bounded so a flooded socket cannot starve
// the lease, the health deadlines or the stop signal.
const MAX_ROUND_BYTES: usize = 256 * 1024;
const METRICS_INTERVAL: Duration = Duration::from_secs(1);
// Movement batches normally arrive every 8-16 ms; a longer hole while
// movement was flowing is a genuine stall worth its own log line.
const GAP_LOG_THRESHOLD: Duration = Duration::from_millis(32);
const CANARY_PERIOD: Duration = Duration::from_millis(5);
const CANARY_TICKS_KEPT: usize = 256;
const READINESS_POLL_INTERVAL: Duration = Duration::from_millis(100);
const COORDINATOR_NOTIFY_TIMEOUT: Duration = Duration::from_millis(100);
const MOUSE_OUTBOUND_CAPACITY: usize = 512;

// Low-frequency lifecycle reports to the coordinator; per-frame mouse traffic
// never crosses this channel.
pub enum SessionEvent {
    Ready {
        mouse: bool,
        keyboard: bool,
        directional_mouse_handoff: bool,
        remote_shutdown: bool,
        remote_diagnostics: bool,
        driver_abi: u16,
        display: Option<DisplayContract>,
    },
    Exited,
}

enum OutboundCommand {
    Control {
        frame: Frame,
        completed: SyncSender<io::Result<()>>,
    },
    Diagnostic {
        record: Arc<DiagnosticRecord>,
        replayed: bool,
    },
    Stop,
}

struct MouseSender {
    commands: SyncSender<OutboundCommand>,
}

impl MouseSender {
    fn start(mut stream: TcpStream) -> (Arc<Self>, JoinHandle<()>) {
        let (commands, receiver) = mpsc::sync_channel(MOUSE_OUTBOUND_CAPACITY);
        let sender = Arc::new(Self { commands });
        let handle = thread::spawn(move || {
            while let Ok(command) = receiver.recv() {
                match command {
                    OutboundCommand::Control { frame, completed } => {
                        let _ = completed.send(frame.write_to(&mut stream));
                    }
                    OutboundCommand::Diagnostic { record, replayed } => {
                        if Frame::new(MessageKind::DiagnosticEvent, record.payload(replayed))
                            .write_to(&mut stream)
                            .is_err()
                        {
                            crate::logging::debug(
                                "diagnostic frame write failed; control writer remains active",
                            );
                        }
                    }
                    OutboundCommand::Stop => break,
                }
            }
        });
        (sender, handle)
    }

    fn stop(&self) {
        let _ = self.commands.send(OutboundCommand::Stop);
    }
}

impl DiagnosticTransport for MouseSender {
    fn try_send_diagnostic(&self, record: Arc<DiagnosticRecord>, replayed: bool) -> bool {
        self.commands
            .try_send(OutboundCommand::Diagnostic { record, replayed })
            .is_ok()
    }

    fn send_control(&self, frame: Frame) -> io::Result<()> {
        let (completed, wait) = mpsc::sync_channel(1);
        self.commands
            .send(OutboundCommand::Control { frame, completed })
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "mouse writer stopped"))?;
        wait.recv()
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "mouse writer stopped"))?
    }
}

struct SessionDiagnostics {
    connection_id: u64,
    writer: Arc<MouseSender>,
    active: bool,
    state: DiagnosticState,
}

impl SessionDiagnostics {
    fn new(connection_id: u64, writer: Arc<MouseSender>) -> Self {
        Self {
            connection_id,
            writer,
            active: false,
            state: DiagnosticState::Local,
        }
    }

    fn ready(&mut self, negotiated: bool, mut fields: Vec<DiagnosticField>) {
        fields.insert(0, DiagnosticField::StateAfter(DiagnosticState::Local as u8));
        fields.insert(0, DiagnosticField::StateBefore(self.state as u8));
        if negotiated {
            let transport: Arc<dyn DiagnosticTransport> = self.writer.clone();
            self.active = diagnostics::attach(self.connection_id, transport, fields);
        } else {
            diagnostics::record(DiagnosticEventKind::ConnectionReady, 0, fields);
        }
        self.state = DiagnosticState::Local;
    }

    fn record_transition(
        &mut self,
        kind: DiagnosticEventKind,
        control_id: u64,
        after: DiagnosticState,
        reason: Option<DiagnosticReason>,
        fields: Vec<DiagnosticField>,
    ) {
        if let Some(record) = self.prepare_transition(kind, control_id, after, reason, fields) {
            diagnostics::submit(record);
        }
    }

    fn record_snapshot(
        &self,
        kind: DiagnosticEventKind,
        control_id: u64,
        before: DiagnosticState,
        after: DiagnosticState,
        reason: DiagnosticReason,
    ) {
        diagnostics::record(
            kind,
            control_id,
            vec![
                DiagnosticField::StateBefore(before as u8),
                DiagnosticField::StateAfter(after as u8),
                DiagnosticField::Reason(reason as u16),
            ],
        );
    }

    fn prepare_transition(
        &mut self,
        kind: DiagnosticEventKind,
        control_id: u64,
        after: DiagnosticState,
        reason: Option<DiagnosticReason>,
        mut fields: Vec<DiagnosticField>,
    ) -> Option<Arc<DiagnosticRecord>> {
        let before = self.state;
        self.state = after;
        if let Some(reason) = reason {
            fields.insert(0, DiagnosticField::Reason(reason as u16));
        }
        fields.insert(0, DiagnosticField::StateAfter(after as u8));
        fields.insert(0, DiagnosticField::StateBefore(before as u8));
        diagnostics::prepare(kind, control_id, fields)
    }

    fn send_after_record(
        &self,
        record: Option<Arc<DiagnosticRecord>>,
        frame: Frame,
    ) -> io::Result<()> {
        let Some(record) = record else {
            return self.writer.send_control(frame);
        };
        if !self.active {
            diagnostics::submit(record);
            return self.writer.send_control(frame);
        }
        let transport: Arc<dyn DiagnosticTransport> = self.writer.clone();
        diagnostics::record_before_control(
            self.connection_id,
            record.clone(),
            transport,
            frame.clone(),
        )
        .unwrap_or_else(|| {
            diagnostics::submit(record);
            self.writer.send_control(frame)
        })
    }

    fn close(&mut self, control_id: u64, reason: DiagnosticReason) {
        let fields = vec![
            DiagnosticField::StateBefore(self.state as u8),
            DiagnosticField::StateAfter(DiagnosticState::Local as u8),
            DiagnosticField::Reason(reason as u16),
        ];
        self.state = DiagnosticState::Local;
        if self.active {
            diagnostics::close(self.connection_id, control_id, fields);
            self.active = false;
        } else {
            diagnostics::record(DiagnosticEventKind::ConnectionClosed, control_id, fields);
        }
    }
}

// The stop signal wakes the session thread through an atomic flag plus a
// read-side socket shutdown; it never travels through an input queue.
pub struct StopSignal {
    requested: AtomicBool,
    confirm_release: AtomicBool,
}

impl StopSignal {
    pub fn new() -> Self {
        Self {
            requested: AtomicBool::new(false),
            confirm_release: AtomicBool::new(false),
        }
    }

    pub fn request(&self, confirm_release: bool) {
        self.confirm_release
            .store(confirm_release, Ordering::SeqCst);
        self.requested.store(true, Ordering::SeqCst);
    }

    pub(crate) fn requested(&self) -> bool {
        self.requested.load(Ordering::SeqCst)
    }

    fn confirm_release(&self) -> bool {
        self.confirm_release.load(Ordering::SeqCst)
    }
}

pub fn spawn(
    stream: TcpStream,
    connection_id: u64,
    computer_name: String,
    events: SyncSender<WorkerEvent>,
    stop: Arc<StopSignal>,
) -> JoinHandle<()> {
    thread::spawn(move || run(stream, connection_id, computer_name, events, stop))
}

fn notify(events: &SyncSender<WorkerEvent>, connection_id: u64, event: SessionEvent) -> bool {
    let deadline = Instant::now() + COORDINATOR_NOTIFY_TIMEOUT;
    let mut pending = WorkerEvent::Mouse {
        connection_id,
        event,
    };
    loop {
        match events.try_send(pending) {
            Ok(()) => return true,
            Err(TrySendError::Disconnected(_)) => return false,
            Err(TrySendError::Full(event)) => {
                if Instant::now() >= deadline {
                    crate::logging::error("mouse coordinator queue remained full");
                    return false;
                }
                pending = event;
                thread::sleep(Duration::from_millis(1));
            }
        }
    }
}

fn run(
    mut stream: TcpStream,
    connection_id: u64,
    computer_name: String,
    events: SyncSender<WorkerEvent>,
    stop: Arc<StopSignal>,
) {
    elevate_priority("mouse session");
    // The QoS flow rides on the socket lifetime; failure is recorded once and
    // the session continues without it.
    let qos = QosFlow::establish(&stream);
    let mut input = MouseInputController::new();
    if let Some(error) = input.driver_error() {
        crate::logging::error(error);
    }
    let display_contract = match DisplayContract::current() {
        Ok(display) => Some(display),
        Err(error) => {
            crate::logging::error(&format!("mouse readiness unavailable: {error}"));
            None
        }
    };
    let mut local_mouse_ready = input.driver_available() && display_contract.is_some();
    let driver_abi = if local_mouse_ready {
        input.driver_abi()
    } else {
        0
    };
    let hello = match display_contract.as_ref().filter(|_| local_mouse_ready) {
        Some(display) => {
            crate::logging::info(&format!(
                "mouse readiness: display_id={} display_device={} primary=true screen={}x{} injection=primary-display driver_abi={driver_abi}",
                display.monitor_id,
                display.device_name,
                display.screen_width,
                display.screen_height,
            ));
            mouse_hello(
                &computer_name,
                driver_abi,
                display.screen_width,
                display.screen_height,
            )
            .expect("validated mouse readiness produces a Hello")
        }
        None => mouse_unavailable_hello(&computer_name),
    };
    let writer_stream = if stream.set_nodelay(true).is_ok()
        && stream.set_write_timeout(Some(MOUSE_WRITE_TIMEOUT)).is_ok()
    {
        stream.try_clone().ok()
    } else {
        None
    };
    let Some(writer_stream) = writer_stream else {
        let _ = stream.shutdown(Shutdown::Both);
        let _ = notify(&events, connection_id, SessionEvent::Exited);
        return;
    };
    let (writer, writer_handle) = MouseSender::start(writer_stream);
    if writer
        .send_control(Frame::new(MessageKind::Hello, hello))
        .is_err()
    {
        writer.stop();
        let _ = writer_handle.join();
        let _ = stream.shutdown(Shutdown::Both);
        let _ = notify(&events, connection_id, SessionEvent::Exited);
        return;
    }
    let mut session_diagnostics = SessionDiagnostics::new(connection_id, writer.clone());
    if !local_mouse_ready {
        session_diagnostics.record_transition(
            DiagnosticEventKind::DriverUnavailable,
            0,
            DiagnosticState::Local,
            Some(DiagnosticReason::DriverFailure),
            vec![DiagnosticField::DriverStatus(DRIVER_STATUS_UNAVAILABLE)],
        );
    }

    let mut health = ChannelHealth::new();
    let mut control = MouseControl::new();
    let mut stale_log = StaleLogLimiter::new();
    let mut metrics = MouseMetrics::new();
    let mut decoder = FrameDecoder::new();
    let mut mouse_negotiated = false;
    let mut keyboard_negotiated = false;
    let mut directional_mouse_handoff_negotiated = false;
    let mut remote_shutdown_negotiated = false;
    let mut remote_diagnostics_negotiated = false;
    let mut failed = false;
    let mut exit_reason = "connection-closed";
    let mut next_readiness_check = Instant::now() + READINESS_POLL_INTERVAL;
    let clock = Instant::now();
    let (canary, canary_handle) = SchedulerCanary::start(clock);
    let mut previous_samples = 0_u64;

    'session: loop {
        if stop.requested() {
            break;
        }
        let mut deadline = health.deadline();
        if let Some(lease) = control.lease_deadline() {
            deadline = deadline.min(lease);
        }
        if local_mouse_ready {
            deadline = deadline.min(next_readiness_check);
        }
        let now = Instant::now();
        if deadline <= now {
            // Expired deadlines are handled before any further reading.
            if service_mouse_health(&writer, &mut health).is_err() {
                failed = true;
                break;
            }
            if let Some(expired) = control.expire_lease(now) {
                session_diagnostics.record_transition(
                    DiagnosticEventKind::HeartbeatExpired,
                    expired,
                    DiagnosticState::Releasing,
                    Some(DiagnosticReason::HeartbeatExpired),
                    Vec::new(),
                );
                if finish_and_confirm(
                    &mut input,
                    &writer,
                    &mut session_diagnostics,
                    expired,
                    "lease-expired",
                    None,
                    None,
                )
                .is_err()
                {
                    failed = true;
                    break;
                }
                health.last_activity = Instant::now();
            }
            if local_mouse_ready && now >= next_readiness_check {
                if let Err(error) = input.ensure_driver_available() {
                    crate::logging::error(&format!("mouse readiness revoked: {error}"));
                    if !keep_session_after_driver_unavailable(driver_unavailable(
                        &mut input,
                        &mut control,
                        &writer,
                        &mut session_diagnostics,
                    )) {
                        failed = true;
                        break;
                    }
                    local_mouse_ready = false;
                    health.last_activity = Instant::now();
                    continue;
                }
                let display = display_contract
                    .as_ref()
                    .expect("local mouse readiness has a display contract");
                if let Err(error) = display.ensure_current() {
                    crate::logging::error(&format!("mouse readiness revoked: {error}"));
                    exit_reason = "display-contract-invalid";
                    failed = true;
                    break;
                }
                next_readiness_check = now + READINESS_POLL_INTERVAL;
            }
            continue;
        }
        if stream.set_read_timeout(Some(deadline - now)).is_err() {
            failed = true;
            break;
        }
        let wait_started = Instant::now();
        let first_read = decoder.read_available(&mut stream);
        let wait = wait_started.elapsed();
        let mut frames = match first_read {
            Ok(frames) => frames,
            Err(_) => {
                if stop.requested() {
                    break;
                }
                failed = true;
                break;
            }
        };
        if frames.is_empty() {
            // Read timeout: the deadlines are evaluated at the loop top.
            continue;
        }
        health.last_activity = Instant::now();
        // Drain whatever already arrived so one stall cannot replay history.
        let mut drained = 0_usize;
        loop {
            let pending = match readable_bytes(&stream) {
                Ok(pending) => pending,
                Err(_) => {
                    if stop.requested() {
                        break 'session;
                    }
                    failed = true;
                    break 'session;
                }
            };
            if pending == 0 || drained >= MAX_ROUND_BYTES {
                break;
            }
            drained += pending as usize;
            match decoder.read_available(&mut stream) {
                Ok(more) => frames.extend(more),
                Err(_) => {
                    if stop.requested() {
                        break 'session;
                    }
                    failed = true;
                    break 'session;
                }
            }
        }
        metrics.record_round(&frames, wait, previous_samples > 0);
        let round_samples = metrics.last_round_samples();
        let process_started = Instant::now();
        if !process_frames(
            frames,
            &writer,
            &mut input,
            &mut control,
            &mut stale_log,
            &mut metrics,
            &mut health,
            &mut mouse_negotiated,
            &mut keyboard_negotiated,
            &mut directional_mouse_handoff_negotiated,
            &mut remote_shutdown_negotiated,
            &mut remote_diagnostics_negotiated,
            &mut session_diagnostics,
            &events,
            connection_id,
            driver_abi,
            display_contract.as_ref(),
        ) {
            failed = true;
            break;
        }
        if input.driver_error().is_some() {
            local_mouse_ready = false;
        }
        let process_elapsed = process_started.elapsed();
        metrics.record_processing(process_elapsed);
        if wait >= GAP_LOG_THRESHOLD
            && previous_samples > 0
            && round_samples >= 4
            && crate::logging::verbose()
        {
            // A stall while movement was flowing, ending in a real movement
            // burst: the canary answers whether this scheduling class was
            // starved or the data had not arrived when the gap ended.
            let end_ms = clock.elapsed().as_millis() as u64;
            let start_ms = end_ms.saturating_sub(wait.as_millis() as u64);
            let canary_max = canary.max_overshoot_between(start_ms, end_ms);
            crate::logging::debug(&format!(
                "mouse gap: wait_us={} canary_max_us={:?} catchup_samples={} proc_us={} hid_queue={}",
                wait.as_micros(),
                canary_max,
                round_samples,
                process_elapsed.as_micros(),
                input.queue_depth()
            ));
        }
        previous_samples = round_samples;
        metrics.maybe_log(&mut input, &control, &canary);
        if stop.requested() {
            break;
        }
    }

    let confirm = stop.requested() && stop.confirm_release() && !failed;
    let closing_control_id = control.clear();
    if let Some(control_id) = closing_control_id {
        if confirm {
            let _ = finish_and_confirm(
                &mut input,
                &writer,
                &mut session_diagnostics,
                control_id,
                "pause",
                None,
                None,
            );
        } else {
            let report = input.release_teardown();
            crate::logging::info(&format!(
                "mouse release: controlID={control_id} reason={exit_reason} reset_ok={} barrier_us={} stable_samples={} second_reset={} sent=none",
                report.reset_ok, report.barrier_us, report.stable_samples, report.second_reset
            ));
        }
        crate::cursor_hider::hide();
    } else {
        let _ = input.finish_remote();
    }
    session_diagnostics.close(
        if confirm {
            0
        } else {
            closing_control_id.unwrap_or(0)
        },
        if stop.requested() {
            DiagnosticReason::ProcessExit
        } else {
            DiagnosticReason::ConnectionClosed
        },
    );
    writer.stop();
    let _ = writer_handle.join();
    let _ = stream.shutdown(Shutdown::Both);
    drop(qos);
    canary.stop();
    let _ = canary_handle.join();
    let _ = notify(&events, connection_id, SessionEvent::Exited);
}

#[allow(clippy::too_many_arguments)]
fn process_frames(
    frames: Vec<Frame>,
    writer: &Arc<MouseSender>,
    input: &mut MouseInputController,
    control: &mut MouseControl,
    stale_log: &mut StaleLogLimiter,
    metrics: &mut MouseMetrics,
    health: &mut ChannelHealth,
    mouse_negotiated: &mut bool,
    keyboard_negotiated: &mut bool,
    directional_mouse_handoff_negotiated: &mut bool,
    remote_shutdown_negotiated: &mut bool,
    remote_diagnostics_negotiated: &mut bool,
    session_diagnostics: &mut SessionDiagnostics,
    events: &SyncSender<WorkerEvent>,
    connection_id: u64,
    driver_abi: u16,
    display: Option<&DisplayContract>,
) -> bool {
    // Contiguous MouseMove frames form one movement group; every other frame
    // is a boundary that flushes the group before being handled.
    let mut group: Vec<MouseMoveSample> = Vec::new();
    for frame in frames {
        if frame.kind == MessageKind::MouseMove && health.ready && *mouse_negotiated {
            let Ok((control_id, samples)) = decode_mouse_move(&frame.payload) else {
                return false;
            };
            if control.accept(control_id, Instant::now()) {
                group.extend_from_slice(&samples);
            } else {
                // A stale move carries no state: skip it without breaking
                // the current movement group.
                stale_log.log("MouseMove", control_id, control.active_control_id());
            }
            continue;
        }
        if !flush_group(
            &mut group,
            writer,
            input,
            control,
            metrics,
            health,
            session_diagnostics,
        ) {
            return false;
        }
        match frame.kind {
            MessageKind::Ready => {
                if health.ready {
                    return false;
                }
                let Ok(hello) = parse_hello(&frame.payload) else {
                    return false;
                };
                *mouse_negotiated = driver_abi != 0
                    && display.is_some()
                    && hello.capabilities.contains(CAPABILITY_MOUSE_CONTROL);
                *keyboard_negotiated =
                    *mouse_negotiated && hello.capabilities.contains(CAPABILITY_KEYBOARD_STATE);
                *directional_mouse_handoff_negotiated = *mouse_negotiated
                    && hello
                        .capabilities
                        .contains(CAPABILITY_DIRECTIONAL_MOUSE_HANDOFF);
                *remote_shutdown_negotiated =
                    hello.capabilities.contains(CAPABILITY_REMOTE_SHUTDOWN);
                *remote_diagnostics_negotiated =
                    hello.capabilities.contains(CAPABILITY_REMOTE_DIAGNOSTICS);
                health.ready = true;
                health.last_activity = Instant::now();
                let mut diagnostic_fields =
                    vec![DiagnosticField::DriverStatus(if *mouse_negotiated {
                        DRIVER_STATUS_AVAILABLE
                    } else {
                        DRIVER_STATUS_UNAVAILABLE
                    })];
                if let Some(bounds) = diagnostics::virtual_desktop_bounds() {
                    diagnostic_fields.push(DiagnosticField::VirtualDesktopBounds(bounds));
                }
                if let Some(display) = display {
                    diagnostic_fields.push(DiagnosticField::MonitorBounds(
                        diagnostics::DiagnosticBounds {
                            x: 0,
                            y: 0,
                            width: display.screen_width as i32,
                            height: display.screen_height as i32,
                        },
                    ));
                }
                session_diagnostics.ready(*remote_diagnostics_negotiated, diagnostic_fields);
                if !notify(
                    events,
                    connection_id,
                    SessionEvent::Ready {
                        mouse: *mouse_negotiated,
                        keyboard: *keyboard_negotiated,
                        directional_mouse_handoff: *directional_mouse_handoff_negotiated,
                        remote_shutdown: *remote_shutdown_negotiated,
                        remote_diagnostics: *remote_diagnostics_negotiated,
                        driver_abi: if *mouse_negotiated { driver_abi } else { 0 },
                        display: if *mouse_negotiated {
                            display.cloned()
                        } else {
                            None
                        },
                    },
                ) {
                    return false;
                }
            }
            MessageKind::MouseEnter if health.ready && *mouse_negotiated => {
                let Ok((control_id, normalized_y)) = mouse_enter(&frame.payload) else {
                    return false;
                };
                if !handle_enter(
                    writer,
                    input,
                    control,
                    metrics,
                    health,
                    session_diagnostics,
                    display,
                    control_id,
                    normalized_y,
                    MouseEntryEdge::Left,
                    false,
                ) {
                    return false;
                }
            }
            MessageKind::DirectionalMouseEnter if health.ready && *mouse_negotiated => {
                let Ok((control_id, normalized_y, entry_edge)) =
                    directional_mouse_enter(&frame.payload, *directional_mouse_handoff_negotiated)
                else {
                    return false;
                };
                if !handle_enter(
                    writer,
                    input,
                    control,
                    metrics,
                    health,
                    session_diagnostics,
                    display,
                    control_id,
                    normalized_y,
                    entry_edge,
                    true,
                ) {
                    return false;
                }
            }
            MessageKind::MouseButton if health.ready && *mouse_negotiated => {
                let Ok((control_id, button, down)) = mouse_button(&frame.payload) else {
                    return false;
                };
                if !control.accept(control_id, Instant::now()) {
                    stale_log.log("MouseButton", control_id, control.active_control_id());
                    continue;
                }
                let Some(entry_edge) = control.active_entry_edge() else {
                    return false;
                };
                if !handle_outcome(
                    input.button(button, down, entry_edge),
                    writer,
                    input,
                    control,
                    metrics,
                    health,
                    session_diagnostics,
                    control_id,
                    "button-up-edge",
                ) {
                    return false;
                }
            }
            MessageKind::MouseWheel if health.ready && *mouse_negotiated => {
                let Ok((control_id, lines)) = mouse_wheel(&frame.payload) else {
                    return false;
                };
                if !control.accept(control_id, Instant::now()) {
                    stale_log.log("MouseWheel", control_id, control.active_control_id());
                    continue;
                }
                if !handle_outcome(
                    input.wheel(lines),
                    writer,
                    input,
                    control,
                    metrics,
                    health,
                    session_diagnostics,
                    control_id,
                    "wheel-edge",
                ) {
                    return false;
                }
            }
            MessageKind::MouseReleaseAll if health.ready && *mouse_negotiated => {
                let Ok(control_id) = control_only(&frame.payload) else {
                    return false;
                };
                match control.release_all(control_id) {
                    ReleaseOutcome::Released(control_id) => {
                        if finish_and_confirm(
                            input,
                            writer,
                            session_diagnostics,
                            control_id,
                            "release-all",
                            None,
                            None,
                        )
                        .is_err()
                        {
                            return false;
                        }
                        metrics.record_release();
                        health.last_activity = Instant::now();
                    }
                    ReleaseOutcome::ReAck(control_id) => {
                        if writer
                            .send_control(Frame::new(
                                MessageKind::MouseReleased,
                                control_payload(control_id).to_vec(),
                            ))
                            .is_err()
                        {
                            return false;
                        }
                        health.last_activity = Instant::now();
                    }
                    ReleaseOutcome::Stale => {
                        stale_log.log("MouseReleaseAll", control_id, control.active_control_id());
                    }
                }
            }
            MessageKind::KeyboardState if health.ready && *mouse_negotiated => {
                // A peer without negotiated capability 4 may race with a
                // capability change. Ignore the frame without parsing or
                // injecting it, while keeping mouse control available.
                if !*keyboard_negotiated {
                    continue;
                }
                let Ok((control_id, state)) = keyboard_state_message(&frame.payload) else {
                    return false;
                };
                if !control.accept(control_id, Instant::now()) {
                    stale_log.log("KeyboardState", control_id, control.active_control_id());
                    continue;
                }
                if !handle_outcome(
                    input.keyboard(&state),
                    writer,
                    input,
                    control,
                    metrics,
                    health,
                    session_diagnostics,
                    control_id,
                    "keyboard-edge",
                ) {
                    return false;
                }
            }
            MessageKind::MouseControlHeartbeat if health.ready && *mouse_negotiated => {
                let Ok(control_id) = control_only(&frame.payload) else {
                    return false;
                };
                if !control.accept(control_id, Instant::now()) {
                    stale_log.log(
                        "MouseControlHeartbeat",
                        control_id,
                        control.active_control_id(),
                    );
                }
            }
            MessageKind::ShutdownRequest => {
                if !handle_remote_shutdown(
                    health.ready,
                    *remote_shutdown_negotiated,
                    &frame.payload,
                    start_remote_shutdown,
                ) {
                    return false;
                }
                health.last_activity = Instant::now();
            }
            MessageKind::Ping if frame.payload.is_empty() => {
                if writer
                    .send_control(Frame::new(MessageKind::Pong, Vec::new()))
                    .is_err()
                {
                    return false;
                }
                health.last_activity = Instant::now();
            }
            MessageKind::Pong if frame.payload.is_empty() => {
                health.ping_sent = None;
            }
            _ => return false,
        }
    }
    flush_group(
        &mut group,
        writer,
        input,
        control,
        metrics,
        health,
        session_diagnostics,
    )
}

#[allow(clippy::too_many_arguments)]
fn handle_enter(
    writer: &Arc<MouseSender>,
    input: &mut MouseInputController,
    control: &mut MouseControl,
    metrics: &mut MouseMetrics,
    health: &mut ChannelHealth,
    session_diagnostics: &mut SessionDiagnostics,
    display: Option<&DisplayContract>,
    control_id: u64,
    normalized_y: u16,
    entry_edge: MouseEntryEdge,
    directional: bool,
) -> bool {
    let enter_started = Instant::now();
    session_diagnostics.record_transition(
        DiagnosticEventKind::ControlEnterReceived,
        control_id,
        DiagnosticState::Acquiring,
        None,
        vec![DiagnosticField::Boundary(entry_edge as u8)],
    );
    if !input.driver_available() {
        return keep_session_after_driver_unavailable(driver_unavailable(
            input,
            control,
            writer,
            session_diagnostics,
        ));
    }
    let Some(display) = display else {
        return false;
    };
    if let Err(error) = display.ensure_current() {
        crate::logging::error(&format!("mouse acquire rejected: {error}"));
        return false;
    }
    let entered = match control.enter(control_id, entry_edge, Instant::now()) {
        Ok(entered) => entered,
        Err(error) => {
            crate::logging::error(&format!("mouse acquire rejected: {error}"));
            return false;
        }
    };
    if !entered.already_active {
        let teardown_ok = if let Some(replaced) = entered.replaced {
            let report = input.release_teardown();
            crate::logging::info(&format!(
                "mouse release: controlID={replaced} reason=replaced reset_ok={} barrier_us={} stable_samples={} second_reset={} sent=none",
                report.reset_ok, report.barrier_us, report.stable_samples, report.second_reset
            ));
            let succeeded = report.reset_ok && report.stable;
            if succeeded {
                session_diagnostics.record_snapshot(
                    DiagnosticEventKind::ControlReleased,
                    replaced,
                    DiagnosticState::Remote,
                    DiagnosticState::Acquiring,
                    DiagnosticReason::StaleControl,
                );
            }
            succeeded
        } else {
            input.finish_remote().is_ok()
        };
        if !teardown_ok {
            return driver_unavailable(input, control, writer, session_diagnostics).is_ok();
        }
        if let Err(error) = input.begin_session(
            normalized_y,
            entry_edge,
            display.screen_width,
            display.screen_height,
        ) {
            crate::logging::error(&format!("Mouse session begin failed: {error}"));
            return keep_session_after_driver_unavailable(driver_unavailable(
                input,
                control,
                writer,
                session_diagnostics,
            ));
        }
    }
    crate::logging::info(&format!(
        "mouse acquire: controlID={control_id} entryEdge={} directional={directional}",
        entry_edge.as_str()
    ));
    crate::cursor_hider::show();
    if writer
        .send_control(Frame::new(
            MessageKind::MouseAcquired,
            control_payload(control_id).to_vec(),
        ))
        .is_err()
    {
        return false;
    }
    session_diagnostics.record_transition(
        DiagnosticEventKind::ControlAcquired,
        control_id,
        DiagnosticState::Remote,
        None,
        vec![
            DiagnosticField::Boundary(entry_edge as u8),
            DiagnosticField::DriverStatus(DRIVER_STATUS_AVAILABLE),
        ],
    );
    metrics.record_enter(enter_started.elapsed());
    health.last_activity = Instant::now();
    true
}

fn handle_remote_shutdown(
    ready: bool,
    negotiated: bool,
    payload: &[u8],
    start: impl FnOnce(),
) -> bool {
    if !ready || !negotiated || !payload.is_empty() {
        return false;
    }
    start();
    true
}

fn start_remote_shutdown() {
    start_remote_shutdown_with(system_directory, |command| command.spawn().map(drop));
}

fn start_remote_shutdown_with(
    resolve_system_directory: impl FnOnce() -> io::Result<PathBuf>,
    spawn: impl FnOnce(&mut Command) -> io::Result<()>,
) {
    let result = resolve_system_directory().and_then(|directory| {
        let mut command = shutdown_command(&directory);
        spawn(&mut command)
    });
    match result {
        Ok(()) => crate::logging::info("remote shutdown command started"),
        Err(error) => {
            crate::logging::error(&format!("remote shutdown launch failed: {error}"));
        }
    }
}

fn shutdown_command(system_directory: &Path) -> Command {
    let mut command = Command::new(system_directory.join("shutdown.exe"));
    command.args(["/p", "/f", "/d", "p:0:0"]);
    command.creation_flags(CREATE_NO_WINDOW.0);
    command
}

fn system_directory() -> io::Result<PathBuf> {
    let mut buffer = [0_u16; 32_768];
    let length = unsafe { GetSystemDirectoryW(Some(&mut buffer)) } as usize;
    if length == 0 {
        return Err(io::Error::last_os_error());
    }
    if length >= buffer.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Windows system directory is too long",
        ));
    }
    Ok(PathBuf::from(OsString::from_wide(&buffer[..length])))
}

// Submits the collapsed final position of a movement group; an edge trigger
// completes the return immediately and the group's remainder never replays.
fn flush_group(
    group: &mut Vec<MouseMoveSample>,
    writer: &Arc<MouseSender>,
    input: &mut MouseInputController,
    control: &mut MouseControl,
    metrics: &mut MouseMetrics,
    health: &mut ChannelHealth,
    session_diagnostics: &mut SessionDiagnostics,
) -> bool {
    if group.is_empty() {
        return true;
    }
    let samples = std::mem::take(group);
    metrics.record_group(samples.len());
    // A non-empty group was accepted against the active session, so it exists.
    let Some(control_id) = control.active_control_id() else {
        return true;
    };
    let Some(entry_edge) = control.active_entry_edge() else {
        return false;
    };
    handle_outcome(
        input.submit_move(&samples, entry_edge),
        writer,
        input,
        control,
        metrics,
        health,
        session_diagnostics,
        control_id,
        "move-edge",
    )
}

#[allow(clippy::too_many_arguments)]
fn handle_outcome(
    outcome: Result<InputOutcome, String>,
    writer: &Arc<MouseSender>,
    input: &mut MouseInputController,
    control: &mut MouseControl,
    metrics: &mut MouseMetrics,
    health: &mut ChannelHealth,
    session_diagnostics: &mut SessionDiagnostics,
    control_id: u64,
    reason: &'static str,
) -> bool {
    match outcome {
        Ok(InputOutcome::Applied) => true,
        Ok(InputOutcome::Leaving(info)) => {
            if handle_leaving(
                input,
                control,
                writer,
                session_diagnostics,
                control_id,
                reason,
                info,
            )
            .is_err()
            {
                return false;
            }
            metrics.record_release();
            health.last_activity = Instant::now();
            true
        }
        Ok(InputOutcome::DriverFailed) => keep_session_after_driver_unavailable(
            driver_unavailable(input, control, writer, session_diagnostics),
        ),
        Err(_) => false,
    }
}

fn driver_unavailable(
    input: &mut MouseInputController,
    control: &mut MouseControl,
    _writer: &Arc<MouseSender>,
    session_diagnostics: &mut SessionDiagnostics,
) -> std::io::Result<()> {
    let control_id = control.clear();
    let report = input.release_teardown();
    if let Some(control_id) = control_id {
        crate::logging::error(&format!(
            "mouse release: controlID={control_id} reason=driver-failed reset_ok={} barrier_us={} stable_samples={} second_reset={} sent=MouseDriverUnavailable",
            report.reset_ok, report.barrier_us, report.stable_samples, report.second_reset
        ));
    }
    let record = session_diagnostics.prepare_transition(
        DiagnosticEventKind::DriverUnavailable,
        control_id.unwrap_or(0),
        DiagnosticState::Local,
        Some(DiagnosticReason::DriverFailure),
        vec![
            DiagnosticField::DriverStatus(DRIVER_STATUS_UNAVAILABLE),
            DiagnosticField::QueueDepth(u16::try_from(input.queue_depth()).unwrap_or(u16::MAX)),
        ],
    );
    let result = session_diagnostics.send_after_record(
        record,
        Frame::new(MessageKind::MouseDriverUnavailable, Vec::new()),
    );
    crate::cursor_hider::hide();
    result
}

fn keep_session_after_driver_unavailable(notification: std::io::Result<()>) -> bool {
    notification.is_ok()
}

// Unified release transaction: the caller transitions the state machine
// first, then this helper tears down the HID state, waits for the Windows
// input pipeline to settle, and only then confirms the release on the wire.
fn finish_and_confirm(
    input: &mut MouseInputController,
    writer: &Arc<MouseSender>,
    session_diagnostics: &mut SessionDiagnostics,
    control_id: u64,
    reason: &'static str,
    leave: Option<LeaveInfo>,
    leave_decision: Option<Arc<DiagnosticRecord>>,
) -> std::io::Result<()> {
    let report = input.release_teardown();
    let verdict = release_verdict(report.reset_ok && report.stable, leave.is_some());
    let edge = leave.as_ref().map_or_else(String::new, |info| {
        format!(
            " entryEdge={} boundary={} prevX={} dx={} proposedX={} condition={} batch={}/{} queue={}",
            info.entry_edge.as_str(),
            info.boundary,
            info.previous_x,
            info.dx,
            info.proposed_x,
            info.condition,
            info.injected,
            info.total,
            info.queue_depth
        )
    });
    let (sent, result) = match verdict {
        ReleaseVerdict::ConfirmLeave => {
            let info = leave
                .as_ref()
                .expect("leave info present for a leave verdict");
            (
                "MouseLeave",
                session_diagnostics.send_after_record(
                    leave_decision,
                    Frame::new(
                        MessageKind::MouseLeave,
                        mouse_leave_payload(control_id, info.normalized_y).to_vec(),
                    ),
                ),
            )
        }
        ReleaseVerdict::ConfirmReleased => (
            "MouseReleased",
            writer.send_control(Frame::new(
                MessageKind::MouseReleased,
                control_payload(control_id).to_vec(),
            )),
        ),
        ReleaseVerdict::DriverUnavailable => (
            "MouseDriverUnavailable",
            session_diagnostics.send_after_record(
                leave_decision,
                Frame::new(MessageKind::MouseDriverUnavailable, Vec::new()),
            ),
        ),
    };
    // A failed teardown means the local input pipeline state is unknown, so
    // the peer never receives a release confirmation; that is an error.
    let level = if matches!(verdict, ReleaseVerdict::DriverUnavailable) {
        crate::logging::Level::Error
    } else {
        crate::logging::Level::Info
    };
    crate::logging::log(
        level,
        &format!(
            "mouse release: controlID={control_id} reason={reason} reset_ok={} barrier_us={} stable_samples={} second_reset={} sent={sent}{edge}",
            report.reset_ok, report.barrier_us, report.stable_samples, report.second_reset
        ),
    );
    crate::cursor_hider::hide();
    if matches!(verdict, ReleaseVerdict::DriverUnavailable) {
        session_diagnostics.record_transition(
            DiagnosticEventKind::DriverUnavailable,
            control_id,
            DiagnosticState::Local,
            Some(DiagnosticReason::DriverFailure),
            vec![DiagnosticField::DriverStatus(DRIVER_STATUS_UNAVAILABLE)],
        );
    } else {
        session_diagnostics.record_transition(
            DiagnosticEventKind::ControlReleased,
            control_id,
            DiagnosticState::Local,
            Some(release_reason(reason)),
            Vec::new(),
        );
    }
    result
}

fn handle_leaving(
    input: &mut MouseInputController,
    control: &mut MouseControl,
    writer: &Arc<MouseSender>,
    session_diagnostics: &mut SessionDiagnostics,
    control_id: u64,
    reason: &'static str,
    info: LeaveInfo,
) -> std::io::Result<()> {
    if !control.leave(control_id) {
        crate::logging::debug(&format!(
            "MouseLeave duplicate suppressed: controlID={control_id}"
        ));
        return Ok(());
    }
    let mut fields = vec![
        DiagnosticField::CursorX(info.cursor_x),
        DiagnosticField::CursorY(info.cursor_y),
        DiagnosticField::DeltaX(i32::from(info.dx)),
        DiagnosticField::DeltaY(i32::from(info.dy)),
        DiagnosticField::Boundary(info.entry_edge as u8),
        DiagnosticField::Threshold(info.boundary),
        DiagnosticField::DriverStatus(DRIVER_STATUS_AVAILABLE),
        DiagnosticField::QueueDepth(u16::try_from(info.queue_depth).unwrap_or(u16::MAX)),
        DiagnosticField::InputSource(1),
        DiagnosticField::RecentMotionSamples(info.recent_motion_samples.clone()),
    ];
    if let Some(bounds) = diagnostics::virtual_desktop_bounds() {
        fields.push(DiagnosticField::VirtualDesktopBounds(bounds));
    }
    if let Some(bounds) = diagnostics::primary_monitor_bounds() {
        fields.push(DiagnosticField::MonitorBounds(bounds));
    }
    let decision = session_diagnostics.prepare_transition(
        DiagnosticEventKind::LeaveDecision,
        control_id,
        DiagnosticState::Releasing,
        Some(DiagnosticReason::CrossedReturnEdge),
        fields,
    );
    finish_and_confirm(
        input,
        writer,
        session_diagnostics,
        control_id,
        reason,
        Some(info),
        decision,
    )
}

fn release_reason(reason: &str) -> DiagnosticReason {
    match reason {
        "release-all" => DiagnosticReason::ReleaseRequest,
        "lease-expired" => DiagnosticReason::HeartbeatExpired,
        "pause" => DiagnosticReason::ProcessExit,
        "move-edge" | "button-up-edge" => DiagnosticReason::CrossedReturnEdge,
        _ => DiagnosticReason::Unknown,
    }
}

struct StaleLogLimiter {
    last: Option<Instant>,
}

impl StaleLogLimiter {
    fn new() -> Self {
        Self { last: None }
    }

    fn log(&mut self, kind: &str, control_id: u64, active: Option<u64>) {
        let now = Instant::now();
        if self
            .last
            .is_none_or(|previous| now.duration_since(previous) >= Duration::from_secs(1))
        {
            crate::logging::debug(&format!(
                "stale mouse message ignored: kind={kind} controlID={control_id} active={active:?}"
            ));
            self.last = Some(now);
        }
    }
}

// A same-priority 5 ms ticker. If it wakes late, the whole scheduling class
// is starved (so the mouse thread is too); if it is on time while a network
// gap appears, the data simply had not arrived when the gap ended.
struct SchedulerCanary {
    stop: AtomicBool,
    clock: Instant,
    ticks: Mutex<VecDeque<(u64, u32)>>,
    window_max_overshoot_us: AtomicU64,
}

impl SchedulerCanary {
    fn start(clock: Instant) -> (Arc<Self>, JoinHandle<()>) {
        let canary = Arc::new(Self {
            stop: AtomicBool::new(false),
            clock,
            ticks: Mutex::new(VecDeque::with_capacity(CANARY_TICKS_KEPT)),
            window_max_overshoot_us: AtomicU64::new(0),
        });
        let worker = canary.clone();
        let handle = thread::spawn(move || worker.run());
        (canary, handle)
    }

    fn run(&self) {
        elevate_priority("scheduler canary");
        let mut next = self.clock + CANARY_PERIOD;
        while !self.stop.load(Ordering::Relaxed) {
            let now = Instant::now();
            if next > now {
                thread::sleep(next - now);
            }
            let woke = Instant::now();
            let overshoot = woke.saturating_duration_since(next);
            next = if woke >= next {
                woke + CANARY_PERIOD
            } else {
                next + CANARY_PERIOD
            };
            let at_ms = woke.duration_since(self.clock).as_millis() as u64;
            let overshoot_us = overshoot.as_micros() as u32;
            {
                let mut ticks = self
                    .ticks
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                if ticks.len() == CANARY_TICKS_KEPT {
                    ticks.pop_front();
                }
                ticks.push_back((at_ms, overshoot_us));
            }
            self.window_max_overshoot_us
                .fetch_max(u64::from(overshoot_us), Ordering::Relaxed);
        }
    }

    fn max_overshoot_between(&self, start_ms: u64, end_ms: u64) -> Option<u32> {
        let ticks = self
            .ticks
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        ticks
            .iter()
            .filter(|(at, _)| *at >= start_ms && *at <= end_ms)
            .map(|(_, overshoot)| *overshoot)
            .max()
    }

    fn take_window_max(&self) -> u64 {
        self.window_max_overshoot_us.swap(0, Ordering::Relaxed)
    }

    fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

fn elevate_priority(thread_name: &str) {
    // Above normal only: never high, time-critical or realtime.
    if unsafe { SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL) }.is_err() {
        crate::logging::info(&format!(
            "{thread_name} thread stays at normal priority (set failed)"
        ));
    }
}

fn service_mouse_health(writer: &Arc<MouseSender>, health: &mut ChannelHealth) -> Result<(), ()> {
    let now = Instant::now();
    if !health.ready {
        return (now < health.connected_at + HANDSHAKE_TIMEOUT)
            .then_some(())
            .ok_or(());
    }
    if let Some(sent) = health.ping_sent {
        return (now < sent + PONG_TIMEOUT).then_some(()).ok_or(());
    }
    if now >= health.last_activity + IDLE_BEFORE_PING {
        writer
            .send_control(Frame::new(MessageKind::Ping, Vec::new()))
            .map_err(|_| ())?;
        health.ping_sent = Some(now);
    }
    Ok(())
}

fn readable_bytes(stream: &TcpStream) -> std::io::Result<u32> {
    let mut available = 0_u32;
    let result = unsafe {
        ioctlsocket(
            SOCKET(stream.as_raw_socket() as usize),
            FIONREAD,
            &raw mut available,
        )
    };
    if result == 0 {
        Ok(available)
    } else {
        Err(std::io::Error::last_os_error())
    }
}

struct QosFlow {
    handle: HANDLE,
    flow_id: u32,
}

impl QosFlow {
    fn establish(stream: &TcpStream) -> Option<Self> {
        let peer = match stream.peer_addr() {
            Ok(peer) => peer,
            Err(_) => return None,
        };
        let std::net::SocketAddr::V4(peer) = peer else {
            return None;
        };
        let mut handle = HANDLE::default();
        let mut version = QOS_VERSION {
            MajorVersion: 1,
            MinorVersion: 0,
        };
        if unsafe { QOSCreateHandle(&raw mut version, &raw mut handle) } == false {
            crate::logging::info("qWAVE unavailable; mouse socket keeps default traffic class");
            return None;
        }
        let address = SOCKADDR_IN {
            sin_family: AF_INET,
            sin_port: peer.port().to_be(),
            sin_addr: IN_ADDR {
                S_un: IN_ADDR_0 {
                    S_addr: u32::from_ne_bytes(peer.ip().octets()),
                },
            },
            sin_zero: [0; 8],
        };
        let mut flow_id = 0_u32;
        let added = unsafe {
            QOSAddSocketToFlow(
                handle,
                SOCKET(stream.as_raw_socket() as usize),
                Some((&raw const address).cast::<SOCKADDR>()),
                QOSTrafficTypeControl,
                Some(QOS_NON_ADAPTIVE_FLOW),
                &raw mut flow_id,
            )
        };
        if added == false {
            crate::logging::info("qWAVE flow rejected; mouse socket keeps default traffic class");
            let _ = unsafe { QOSCloseHandle(handle) };
            return None;
        }
        Some(Self { handle, flow_id })
    }
}

impl Drop for QosFlow {
    fn drop(&mut self) {
        unsafe {
            let _ = QOSRemoveSocketFromFlow(self.handle, None, self.flow_id, None);
            let _ = QOSCloseHandle(self.handle);
        }
    }
}

struct MouseMetrics {
    window_start: Instant,
    rounds: u64,
    bytes: u64,
    frames: u64,
    samples: u64,
    last_round_samples: u64,
    groups: u64,
    group_max_samples: usize,
    wait_max_us: u128,
    wait_active_max_us: u128,
    wait_over_8ms: u64,
    wait_over_16ms: u64,
    wait_over_50ms: u64,
    process_max_us: u128,
    process_over_8ms: u64,
    process_over_16ms: u64,
    process_over_50ms: u64,
    enters: u64,
    enter_max_us: u128,
    releases: u64,
}

impl MouseMetrics {
    fn new() -> Self {
        Self {
            window_start: Instant::now(),
            rounds: 0,
            bytes: 0,
            frames: 0,
            samples: 0,
            last_round_samples: 0,
            groups: 0,
            group_max_samples: 0,
            wait_max_us: 0,
            wait_active_max_us: 0,
            wait_over_8ms: 0,
            wait_over_16ms: 0,
            wait_over_50ms: 0,
            process_max_us: 0,
            process_over_8ms: 0,
            process_over_16ms: 0,
            process_over_50ms: 0,
            enters: 0,
            enter_max_us: 0,
            releases: 0,
        }
    }

    fn record_round(&mut self, frames: &[Frame], wait: Duration, movement_active: bool) {
        self.rounds += 1;
        self.bytes += frames
            .iter()
            .map(|frame| crate::protocol::HEADER_SIZE + frame.payload.len())
            .sum::<usize>() as u64;
        self.frames += frames.len() as u64;
        self.last_round_samples = frames
            .iter()
            .filter(|frame| frame.kind == MessageKind::MouseMove)
            .map(|frame| {
                frame
                    .payload
                    .len()
                    .saturating_sub(crate::protocol::CONTROL_ID_SIZE + 1)
                    / 4
            })
            .sum::<usize>() as u64;
        self.samples += self.last_round_samples;
        let wait_us = wait.as_micros();
        self.wait_max_us = self.wait_max_us.max(wait_us);
        if movement_active {
            // Waits measured only while movement was flowing: the true stall
            // figure, without idle heartbeat cadence mixed in.
            self.wait_active_max_us = self.wait_active_max_us.max(wait_us);
        }
        Self::bucket(
            wait_us,
            &mut self.wait_over_8ms,
            &mut self.wait_over_16ms,
            &mut self.wait_over_50ms,
        );
    }

    fn last_round_samples(&self) -> u64 {
        self.last_round_samples
    }

    fn record_processing(&mut self, elapsed: Duration) {
        let elapsed_us = elapsed.as_micros();
        self.process_max_us = self.process_max_us.max(elapsed_us);
        Self::bucket(
            elapsed_us,
            &mut self.process_over_8ms,
            &mut self.process_over_16ms,
            &mut self.process_over_50ms,
        );
    }

    fn record_group(&mut self, samples: usize) {
        self.groups += 1;
        self.group_max_samples = self.group_max_samples.max(samples);
    }

    fn record_enter(&mut self, elapsed: Duration) {
        self.enters += 1;
        self.enter_max_us = self.enter_max_us.max(elapsed.as_micros());
    }

    fn record_release(&mut self) {
        self.releases += 1;
    }

    fn bucket(micros: u128, over_8: &mut u64, over_16: &mut u64, over_50: &mut u64) {
        if micros > 8_000 {
            *over_8 += 1;
        }
        if micros > 16_000 {
            *over_16 += 1;
        }
        if micros > 50_000 {
            *over_50 += 1;
        }
    }

    // One bounded summary per interval while active. The values are snapshots
    // from the writer state, so diagnostics never call a HID API here.
    fn maybe_log(
        &mut self,
        input: &mut MouseInputController,
        control: &MouseControl,
        canary: &SchedulerCanary,
    ) {
        let now = Instant::now();
        if now.duration_since(self.window_start) < METRICS_INTERVAL {
            return;
        }
        let hid = input.take_stats();
        let canary_max_us = canary.take_window_max();
        let busy = self.samples > 0
            || self.groups > 0
            || hid.hid_calls > 0
            || self.enters > 0
            || self.releases > 0;
        // A canary overshoot beyond one display frame is an anomaly worth
        // logging even in an otherwise idle (heartbeat-only) window.
        let anomaly = canary_max_us > 16_000;
        if (busy || anomaly) && control.active_control_id().is_some() && crate::logging::verbose() {
            crate::logging::debug(&format!(
                "mouse metrics: rounds={} bytes={} frames={} samples={} groups={} group_max={} wait_max_us={} wait_active_max_us={} wait>8/16/50ms={}/{}/{} canary_max_us={} proc_max_us={} proc>8/16/50ms={}/{}/{} hid_calls={} hid_move_calls={} hid_max_us={} hid_queue_max_us={} hid_queue_high={} hid_coalesced={} hid_dropped={} hid_timeouts={} enters={} enter_max_us={} releases={}",
                self.rounds,
                self.bytes,
                self.frames,
                self.samples,
                self.groups,
                self.group_max_samples,
                self.wait_max_us,
                self.wait_active_max_us,
                self.wait_over_8ms,
                self.wait_over_16ms,
                self.wait_over_50ms,
                canary_max_us,
                self.process_max_us,
                self.process_over_8ms,
                self.process_over_16ms,
                self.process_over_50ms,
                hid.hid_calls,
                hid.hid_move_calls,
                hid.hid_max_us,
                hid.hid_queue_max_us,
                hid.hid_queue_high,
                hid.hid_coalesced_moves,
                hid.hid_dropped_moves,
                hid.hid_timeouts,
                self.enters,
                self.enter_max_us,
                self.releases,
            ));
        }
        *self = Self::new();
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use super::*;

    #[test]
    fn remote_shutdown_requires_ready_negotiated_empty_request() {
        for (ready, negotiated, payload) in [
            (false, true, &[][..]),
            (true, false, &[][..]),
            (true, true, &[1][..]),
        ] {
            let calls = Cell::new(0);
            assert!(!handle_remote_shutdown(ready, negotiated, payload, || {
                calls.set(calls.get() + 1)
            }));
            assert_eq!(calls.get(), 0);
        }

        let calls = Cell::new(0);
        assert!(handle_remote_shutdown(true, true, &[], || {
            calls.set(calls.get() + 1);
        }));
        assert_eq!(calls.get(), 1);
    }

    #[test]
    fn remote_shutdown_command_uses_system_executable_and_fixed_arguments() {
        let command = shutdown_command(Path::new(r"C:\Windows\System32"));
        assert_eq!(
            command.get_program(),
            Path::new(r"C:\Windows\System32\shutdown.exe")
        );
        assert_eq!(
            command.get_args().collect::<Vec<_>>(),
            ["/p", "/f", "/d", "p:0:0"].map(std::ffi::OsStr::new)
        );
    }

    #[test]
    fn remote_shutdown_launch_failure_is_consumed_without_retry() {
        let calls = Cell::new(0);
        start_remote_shutdown_with(
            || Ok(PathBuf::from(r"C:\Windows\System32")),
            |_| {
                calls.set(calls.get() + 1);
                Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "test failure",
                ))
            },
        );
        assert_eq!(calls.get(), 1);
    }

    #[test]
    fn remote_shutdown_directory_failure_skips_process_launch() {
        let calls = Cell::new(0);
        start_remote_shutdown_with(
            || Err(io::Error::new(io::ErrorKind::NotFound, "test failure")),
            |_| {
                calls.set(calls.get() + 1);
                Ok(())
            },
        );
        assert_eq!(calls.get(), 0);
    }

    #[test]
    fn system_shutdown_executable_exists() {
        assert!(system_directory().unwrap().join("shutdown.exe").is_file());
    }

    #[test]
    fn delivered_driver_unavailable_keeps_the_session_open() {
        assert!(keep_session_after_driver_unavailable(Ok(())));
        assert!(!keep_session_after_driver_unavailable(Err(io::Error::new(
            io::ErrorKind::BrokenPipe,
            "test failure"
        ))));
    }
}
