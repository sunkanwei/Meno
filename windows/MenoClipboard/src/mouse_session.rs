use std::io;
use std::net::{Shutdown, TcpStream};
use std::os::windows::io::AsRawSocket;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, SyncSender, TrySendError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use windows::Win32::Networking::WinSock::{FIONREAD, SOCKET, ioctlsocket};
use windows::Win32::System::Threading::{
    GetCurrentThread, SetThreadPriority, THREAD_PRIORITY_ABOVE_NORMAL,
};

use crate::connection::{ChannelHealth, WorkerEvent};
use crate::display_contract::DisplayContract;
use crate::mouse_control::{MouseControl, ReleaseOutcome, ReleaseVerdict, release_verdict};
use crate::mouse_input::{InputOutcome, LeaveInfo, MouseInputController};
use crate::protocol::{
    CAPABILITY_DIRECTIONAL_MOUSE_HANDOFF, CAPABILITY_KEYBOARD_STATE, CAPABILITY_MOUSE_CONTROL,
    CAPABILITY_REMOTE_SHUTDOWN, Frame, FrameDecoder, MessageKind, MouseEntryEdge, MouseMoveSample,
    control_only, control_payload, decode_mouse_move, directional_mouse_enter,
    keyboard_state_message, mouse_button, mouse_enter, mouse_hello, mouse_leave_payload,
    mouse_unavailable_hello, mouse_wheel, parse_hello,
};
use crate::qos_flow::QosFlow;
use crate::remote_shutdown::{handle_remote_shutdown, start_remote_shutdown};

// Small confirmations that cannot be written promptly mean the session is
// already unhealthy; retrying stale control frames would be worse.
const MOUSE_WRITE_TIMEOUT: Duration = Duration::from_millis(100);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
const IDLE_BEFORE_PING: Duration = Duration::from_secs(30);
const PONG_TIMEOUT: Duration = Duration::from_secs(10);
// A single read+process round is bounded so a flooded socket cannot starve
// the lease, the health deadlines or the stop signal.
const MAX_ROUND_BYTES: usize = 256 * 1024;
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
        driver_abi: u16,
    },
    Exited,
}

enum OutboundCommand {
    Control {
        frame: Frame,
        completed: SyncSender<io::Result<()>>,
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

impl MouseSender {
    fn send_control(&self, frame: Frame) -> io::Result<()> {
        let (completed, wait) = mpsc::sync_channel(1);
        self.commands
            .send(OutboundCommand::Control { frame, completed })
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "mouse writer stopped"))?;
        wait.recv()
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "mouse writer stopped"))?
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
        Some(display) => mouse_hello(
            &computer_name,
            driver_abi,
            display.screen_width,
            display.screen_height,
        )
        .expect("validated mouse readiness produces a Hello"),
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
    let mut health = ChannelHealth::new();
    let mut control = MouseControl::new();
    let mut decoder = FrameDecoder::new();
    let mut mouse_negotiated = false;
    let mut keyboard_negotiated = false;
    let mut directional_mouse_handoff_negotiated = false;
    let mut remote_shutdown_negotiated = false;
    let mut failed = false;
    let mut exit_reason = "connection-closed";
    let mut next_readiness_check = Instant::now() + READINESS_POLL_INTERVAL;

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
                if finish_and_confirm(&mut input, &writer, expired, "lease-expired", None).is_err()
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
        let first_read = decoder.read_available(&mut stream);
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
        if !process_frames(
            frames,
            &writer,
            &mut input,
            &mut control,
            &mut health,
            &mut mouse_negotiated,
            &mut keyboard_negotiated,
            &mut directional_mouse_handoff_negotiated,
            &mut remote_shutdown_negotiated,
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
        if stop.requested() {
            break;
        }
    }

    let confirm = stop.requested() && stop.confirm_release() && !failed;
    let closing_control_id = control.clear();
    if let Some(control_id) = closing_control_id {
        if confirm {
            let _ = finish_and_confirm(&mut input, &writer, control_id, "pause", None);
        } else {
            let _ = input.release_teardown();
            crate::logging::info(&format!(
                "mouse control local: controlID={control_id} reason={exit_reason}"
            ));
        }
        crate::cursor_hider::hide();
    } else {
        let _ = input.finish_remote();
    }
    writer.stop();
    let _ = writer_handle.join();
    let _ = stream.shutdown(Shutdown::Both);
    drop(qos);
    let _ = notify(&events, connection_id, SessionEvent::Exited);
}

#[allow(clippy::too_many_arguments)]
fn process_frames(
    frames: Vec<Frame>,
    writer: &Arc<MouseSender>,
    input: &mut MouseInputController,
    control: &mut MouseControl,
    health: &mut ChannelHealth,
    mouse_negotiated: &mut bool,
    keyboard_negotiated: &mut bool,
    directional_mouse_handoff_negotiated: &mut bool,
    remote_shutdown_negotiated: &mut bool,
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
            }
            continue;
        }
        if !flush_group(&mut group, writer, input, control, health) {
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
                health.ready = true;
                health.last_activity = Instant::now();
                if !notify(
                    events,
                    connection_id,
                    SessionEvent::Ready {
                        mouse: *mouse_negotiated,
                        keyboard: *keyboard_negotiated,
                        directional_mouse_handoff: *directional_mouse_handoff_negotiated,
                        remote_shutdown: *remote_shutdown_negotiated,
                        driver_abi: if *mouse_negotiated { driver_abi } else { 0 },
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
                    health,
                    display,
                    control_id,
                    normalized_y,
                    MouseEntryEdge::Left,
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
                    health,
                    display,
                    control_id,
                    normalized_y,
                    entry_edge,
                ) {
                    return false;
                }
            }
            MessageKind::MouseButton if health.ready && *mouse_negotiated => {
                let Ok((control_id, button, down)) = mouse_button(&frame.payload) else {
                    return false;
                };
                if !control.accept(control_id, Instant::now()) {
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
                    health,
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
                    continue;
                }
                if !handle_outcome(
                    input.wheel(lines),
                    writer,
                    input,
                    control,
                    health,
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
                        if finish_and_confirm(input, writer, control_id, "release-all", None)
                            .is_err()
                        {
                            return false;
                        }
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
                    ReleaseOutcome::Stale => {}
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
                    continue;
                }
                if !handle_outcome(
                    input.keyboard(&state),
                    writer,
                    input,
                    control,
                    health,
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
                let _ = control.accept(control_id, Instant::now());
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
            // Kind 31 is reserved. It is never negotiated and cannot enter
            // the normal mouse-control path.
            MessageKind::DiagnosticEvent => return false,
            _ => return false,
        }
    }
    flush_group(&mut group, writer, input, control, health)
}

#[allow(clippy::too_many_arguments)]
fn handle_enter(
    writer: &Arc<MouseSender>,
    input: &mut MouseInputController,
    control: &mut MouseControl,
    health: &mut ChannelHealth,
    display: Option<&DisplayContract>,
    control_id: u64,
    normalized_y: u16,
    entry_edge: MouseEntryEdge,
) -> bool {
    if !input.driver_available() {
        return keep_session_after_driver_unavailable(driver_unavailable(input, control, writer));
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
                "mouse control local: controlID={replaced} reason=replaced"
            ));
            report.reset_ok && report.stable
        } else {
            input.finish_remote().is_ok()
        };
        if !teardown_ok {
            return driver_unavailable(input, control, writer).is_ok();
        }
        if let Err(error) = input.begin_session(
            normalized_y,
            entry_edge,
            display.screen_width,
            display.screen_height,
        ) {
            crate::logging::error(&format!("Mouse session begin failed: {error}"));
            return keep_session_after_driver_unavailable(driver_unavailable(
                input, control, writer,
            ));
        }
    }
    crate::logging::info(&format!("mouse control remote: controlID={control_id}"));
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
    health.last_activity = Instant::now();
    true
}

// Submits the collapsed final position of a movement group; an edge trigger
// completes the return immediately and the group's remainder never replays.
fn flush_group(
    group: &mut Vec<MouseMoveSample>,
    writer: &Arc<MouseSender>,
    input: &mut MouseInputController,
    control: &mut MouseControl,
    health: &mut ChannelHealth,
) -> bool {
    if group.is_empty() {
        return true;
    }
    let samples = std::mem::take(group);
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
        health,
        control_id,
        "move-edge",
    )
}

fn handle_outcome(
    outcome: Result<InputOutcome, String>,
    writer: &Arc<MouseSender>,
    input: &mut MouseInputController,
    control: &mut MouseControl,
    health: &mut ChannelHealth,
    control_id: u64,
    reason: &'static str,
) -> bool {
    match outcome {
        Ok(InputOutcome::Applied) => true,
        Ok(InputOutcome::Leaving(info)) => {
            if handle_leaving(input, control, writer, control_id, reason, info).is_err() {
                return false;
            }
            health.last_activity = Instant::now();
            true
        }
        Ok(InputOutcome::DriverFailed) => {
            keep_session_after_driver_unavailable(driver_unavailable(input, control, writer))
        }
        Err(_) => false,
    }
}

fn driver_unavailable(
    input: &mut MouseInputController,
    control: &mut MouseControl,
    writer: &Arc<MouseSender>,
) -> std::io::Result<()> {
    let control_id = control.clear();
    let _ = input.release_teardown();
    if let Some(control_id) = control_id {
        crate::logging::error(&format!("mouse driver unavailable: controlID={control_id}"));
    }
    let result = writer.send_control(Frame::new(MessageKind::MouseDriverUnavailable, Vec::new()));
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
    control_id: u64,
    reason: &'static str,
    leave: Option<LeaveInfo>,
) -> std::io::Result<()> {
    let report = input.release_teardown();
    let verdict = release_verdict(report.reset_ok && report.stable, leave.is_some());
    let result = match verdict {
        ReleaseVerdict::ConfirmLeave => {
            let info = leave
                .as_ref()
                .expect("leave info present for a leave verdict");
            writer.send_control(Frame::new(
                MessageKind::MouseLeave,
                mouse_leave_payload(control_id, info.normalized_y).to_vec(),
            ))
        }
        ReleaseVerdict::ConfirmReleased => writer.send_control(Frame::new(
            MessageKind::MouseReleased,
            control_payload(control_id).to_vec(),
        )),
        ReleaseVerdict::DriverUnavailable => {
            writer.send_control(Frame::new(MessageKind::MouseDriverUnavailable, Vec::new()))
        }
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
        &format!("mouse control local: controlID={control_id} reason={reason}"),
    );
    crate::cursor_hider::hide();
    result
}

fn handle_leaving(
    input: &mut MouseInputController,
    control: &mut MouseControl,
    writer: &Arc<MouseSender>,
    control_id: u64,
    reason: &'static str,
    info: LeaveInfo,
) -> std::io::Result<()> {
    if !control.leave(control_id) {
        return Ok(());
    }
    finish_and_confirm(input, writer, control_id, reason, Some(info))
}

fn elevate_priority(_thread_name: &str) {
    // Above normal only: never high, time-critical or realtime.
    let _ = unsafe { SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL) };
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delivered_driver_unavailable_keeps_the_session_open() {
        assert!(keep_session_after_driver_unavailable(Ok(())));
        assert!(!keep_session_after_driver_unavailable(Err(io::Error::new(
            io::ErrorKind::BrokenPipe,
            "test failure"
        ))));
    }
}
