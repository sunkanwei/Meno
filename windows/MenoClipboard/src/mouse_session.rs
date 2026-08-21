use std::collections::VecDeque;
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

use crate::channel_health::{ChannelHealth, HealthAction};
use crate::connection::WorkerEvent;
use crate::display_contract::DisplayContract;
use crate::mouse_input::MouseInputController;
use crate::protocol::{
    CAPABILITY_KEYBOARD_STATE, CAPABILITY_MOUSE_CONTROL, CAPABILITY_MOUSE_ROUTE_CONTRACT,
    CAPABILITY_REMOTE_SHUTDOWN, Frame, FrameDecoder, MessageKind, control_only, control_payload,
    decode_mouse_move, keyboard_state_message, mouse_button, mouse_enter_v2, mouse_hello,
    mouse_leave_payload, mouse_unavailable_hello, mouse_wheel, parse_hello,
};
use crate::qos_flow::QosFlow;
use crate::remote_input_engine::{Effect, EngineState, Event, ReleaseReason, RemoteInputEngine};
use crate::remote_shutdown::{handle_remote_shutdown, start_remote_shutdown};

const MOUSE_WRITE_TIMEOUT: Duration = Duration::from_millis(100);
const MAX_ROUND_BYTES: usize = 256 * 1024;
const READINESS_POLL_INTERVAL: Duration = Duration::from_millis(100);
const COORDINATOR_NOTIFY_TIMEOUT: Duration = Duration::from_millis(100);
const MOUSE_OUTBOUND_CAPACITY: usize = 512;

pub enum SessionEvent {
    Ready {
        mouse: bool,
        keyboard: bool,
        mouse_route_contract: bool,
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

    fn send_control(&self, frame: Frame) -> io::Result<()> {
        let (completed, wait) = mpsc::sync_channel(1);
        self.commands
            .send(OutboundCommand::Control { frame, completed })
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "mouse writer stopped"))?;
        wait.recv()
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "mouse writer stopped"))?
    }
}

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
    elevate_priority();
    let qos = QosFlow::establish(&stream);
    let mut input = MouseInputController::new();
    if let Some(error) = input.driver_error() {
        crate::logging::error(error);
    }
    let display_contract = DisplayContract::current()
        .map_err(|error| {
            crate::logging::error(&format!("mouse readiness unavailable: {error}"));
            error
        })
        .ok();
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
        finish_socket(stream, events, connection_id);
        return;
    };
    let (writer, writer_handle) = MouseSender::start(writer_stream);
    if writer
        .send_control(Frame::new(MessageKind::Hello, hello))
        .is_err()
    {
        writer.stop();
        let _ = writer_handle.join();
        finish_socket(stream, events, connection_id);
        return;
    }

    let mut health = ChannelHealth::new();
    let mut engine = RemoteInputEngine::new();
    let mut decoder = FrameDecoder::new();
    let mut mouse_negotiated = false;
    let mut keyboard_negotiated = false;
    let mut route_contract_negotiated = false;
    let mut remote_shutdown_negotiated = false;
    let mut failed = false;
    let mut next_readiness_check = Instant::now() + READINESS_POLL_INTERVAL;

    'session: loop {
        if stop.requested() {
            break;
        }
        let mut deadline = health.deadline();
        if let Some(lease) = engine.lease_deadline() {
            deadline = deadline.min(lease);
        }
        if local_mouse_ready {
            deadline = deadline.min(next_readiness_check);
        }
        let now = Instant::now();
        if deadline <= now {
            if service_mouse_health(&writer, &mut health).is_err() {
                failed = true;
                break;
            }
            if !execute_effects(
                engine.reduce(Event::LeaseExpired { now }),
                &mut engine,
                &mut input,
                &writer,
            ) {
                failed = true;
                break;
            }
            if local_mouse_ready && now >= next_readiness_check {
                if let Err(error) = input.ensure_driver_available() {
                    crate::logging::error(&format!("mouse readiness revoked: {error}"));
                    if let Some(key) = engine.active_key() {
                        let effects = engine.reduce(Event::Release {
                            control_id: key.control_id,
                            reason: ReleaseReason::HidFailed,
                        });
                        if !execute_effects(effects, &mut engine, &mut input, &writer) {
                            failed = true;
                            break;
                        }
                    }
                    local_mouse_ready = false;
                }
                if let Some(display) = display_contract.as_ref()
                    && let Err(error) = display.ensure_current()
                {
                    crate::logging::error(&format!("mouse display contract changed: {error}"));
                    let _ = execute_effects(
                        engine.reduce(Event::DisplayChanged),
                        &mut engine,
                        &mut input,
                        &writer,
                    );
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
        let mut frames = match decoder.read_available(&mut stream) {
            Ok(frames) => frames,
            Err(_) => {
                if !stop.requested() {
                    failed = true;
                }
                break;
            }
        };
        if frames.is_empty() {
            continue;
        }
        health.last_activity = Instant::now();
        let mut drained = 0_usize;
        loop {
            let pending = match readable_bytes(&stream) {
                Ok(pending) => pending,
                Err(_) => {
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
                    failed = true;
                    break 'session;
                }
            }
        }
        if !process_frames(
            frames,
            &writer,
            &mut input,
            &mut engine,
            &mut health,
            &mut mouse_negotiated,
            &mut keyboard_negotiated,
            &mut route_contract_negotiated,
            &mut remote_shutdown_negotiated,
            &events,
            connection_id,
            driver_abi,
            display_contract.as_ref(),
        ) {
            failed = true;
            break;
        }
        engine.observe_queue_high_water(input.queue_high_water());
    }

    if engine.active_key().is_some() {
        let reason = if stop.requested() && stop.confirm_release() {
            ReleaseReason::PeerRelease
        } else if stop.requested() {
            ReleaseReason::Stopped
        } else {
            ReleaseReason::Disconnected
        };
        if let Some(key) = engine.active_key() {
            let _ = execute_effects(
                engine.reduce(Event::Release {
                    control_id: key.control_id,
                    reason,
                }),
                &mut engine,
                &mut input,
                &writer,
            );
        }
    } else {
        input.emergency_reset();
        crate::cursor_hider::hide();
    }
    if failed && engine.state() != EngineState::Faulted {
        crate::logging::error(
            "mouse session closed after protocol, display, network, or HID failure",
        );
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
    engine: &mut RemoteInputEngine,
    health: &mut ChannelHealth,
    mouse_negotiated: &mut bool,
    keyboard_negotiated: &mut bool,
    route_contract_negotiated: &mut bool,
    remote_shutdown_negotiated: &mut bool,
    events: &SyncSender<WorkerEvent>,
    connection_id: u64,
    driver_abi: u16,
    display: Option<&DisplayContract>,
) -> bool {
    for frame in frames {
        let effects = match frame.kind {
            MessageKind::Ready => {
                if health.ready {
                    return false;
                }
                let Ok(hello) = parse_hello(&frame.payload) else {
                    return false;
                };
                *route_contract_negotiated =
                    hello.capabilities.contains(CAPABILITY_MOUSE_ROUTE_CONTRACT);
                *mouse_negotiated = driver_abi != 0
                    && display.is_some()
                    && hello.capabilities.contains(CAPABILITY_MOUSE_CONTROL)
                    && *route_contract_negotiated;
                *keyboard_negotiated =
                    *mouse_negotiated && hello.capabilities.contains(CAPABILITY_KEYBOARD_STATE);
                *remote_shutdown_negotiated =
                    hello.capabilities.contains(CAPABILITY_REMOTE_SHUTDOWN);
                health.ready = true;
                if !notify(
                    events,
                    connection_id,
                    SessionEvent::Ready {
                        mouse: *mouse_negotiated,
                        keyboard: *keyboard_negotiated,
                        mouse_route_contract: *route_contract_negotiated,
                        remote_shutdown: *remote_shutdown_negotiated,
                        driver_abi: if *mouse_negotiated { driver_abi } else { 0 },
                    },
                ) {
                    return false;
                }
                Vec::new()
            }
            MessageKind::MouseEnterV2 if health.ready && *mouse_negotiated => {
                let Ok(request) = mouse_enter_v2(&frame.payload, *route_contract_negotiated) else {
                    return false;
                };
                let Some(display) = display else {
                    return false;
                };
                if display.ensure_current().is_err() {
                    return false;
                }
                engine.reduce(Event::Enter {
                    generation: connection_id,
                    request,
                    width: display.screen_width,
                    height: display.screen_height,
                    now: Instant::now(),
                })
            }
            MessageKind::MouseMove if health.ready && *mouse_negotiated => {
                let Ok((control_id, samples)) = decode_mouse_move(&frame.payload) else {
                    return false;
                };
                engine.reduce(Event::Move {
                    control_id,
                    samples,
                    now: Instant::now(),
                })
            }
            MessageKind::MouseButton if health.ready && *mouse_negotiated => {
                let Ok((control_id, button, down)) = mouse_button(&frame.payload) else {
                    return false;
                };
                engine.reduce(Event::Button {
                    control_id,
                    button,
                    down,
                    now: Instant::now(),
                })
            }
            MessageKind::MouseWheel if health.ready && *mouse_negotiated => {
                let Ok((control_id, lines)) = mouse_wheel(&frame.payload) else {
                    return false;
                };
                engine.reduce(Event::Wheel {
                    control_id,
                    lines,
                    now: Instant::now(),
                })
            }
            MessageKind::MouseReleaseAll if health.ready && *mouse_negotiated => {
                let Ok(control_id) = control_only(&frame.payload) else {
                    return false;
                };
                engine.reduce(Event::Release {
                    control_id,
                    reason: ReleaseReason::PeerRelease,
                })
            }
            MessageKind::KeyboardState if health.ready && *mouse_negotiated => {
                if !*keyboard_negotiated {
                    Vec::new()
                } else {
                    let Ok((control_id, state)) = keyboard_state_message(&frame.payload) else {
                        return false;
                    };
                    engine.reduce(Event::Keyboard {
                        control_id,
                        state,
                        now: Instant::now(),
                    })
                }
            }
            MessageKind::MouseControlHeartbeat if health.ready && *mouse_negotiated => {
                let Ok(control_id) = control_only(&frame.payload) else {
                    return false;
                };
                engine.reduce(Event::Heartbeat {
                    control_id,
                    now: Instant::now(),
                })
            }
            MessageKind::MouseEnter | MessageKind::DirectionalMouseEnter => Vec::new(),
            MessageKind::ShutdownRequest => {
                if !handle_remote_shutdown(
                    health.ready,
                    *remote_shutdown_negotiated,
                    &frame.payload,
                    start_remote_shutdown,
                ) {
                    return false;
                }
                Vec::new()
            }
            MessageKind::Ping if frame.payload.is_empty() => {
                if writer
                    .send_control(Frame::new(MessageKind::Pong, Vec::new()))
                    .is_err()
                {
                    return false;
                }
                Vec::new()
            }
            MessageKind::Pong if frame.payload.is_empty() => {
                health.ping_sent = None;
                Vec::new()
            }
            MessageKind::DiagnosticEvent => return false,
            _ => return false,
        };
        if !execute_effects(effects, engine, input, writer) {
            return false;
        }
        health.last_activity = Instant::now();
    }
    true
}

fn execute_effects(
    initial: Vec<Effect>,
    engine: &mut RemoteInputEngine,
    input: &mut MouseInputController,
    writer: &Arc<MouseSender>,
) -> bool {
    let mut effects: VecDeque<Effect> = initial.into();
    while let Some(effect) = effects.pop_front() {
        let follow_up = match effect {
            Effect::PrepareHid {
                x,
                y,
                maximum_x,
                maximum_y,
            } => {
                let event = if input.prepare(x, y, maximum_x, maximum_y).is_ok() {
                    Event::HidAcquireSucceeded
                } else {
                    Event::HidAcquireFailed
                };
                engine.reduce(event)
            }
            Effect::Pointer {
                x,
                y,
                maximum_x,
                maximum_y,
                buttons,
                critical,
            } => {
                if let Err(error) = input.pointer(x, y, maximum_x, maximum_y, buttons, critical) {
                    crate::logging::error(&format!("mouse HID pointer submission failed: {error}"));
                    engine.reduce(if error.contains("queue is full") {
                        Event::QueueOverflow
                    } else {
                        Event::Release {
                            control_id: engine.active_key().map_or(0, |key| key.control_id),
                            reason: ReleaseReason::HidFailed,
                        }
                    })
                } else {
                    Vec::new()
                }
            }
            Effect::Wheel {
                x,
                y,
                maximum_x,
                maximum_y,
                buttons,
                lines,
            } => {
                if input
                    .wheel(x, y, maximum_x, maximum_y, buttons, lines)
                    .is_err()
                {
                    engine.reduce(Event::Release {
                        control_id: engine.active_key().map_or(0, |key| key.control_id),
                        reason: ReleaseReason::HidFailed,
                    })
                } else {
                    Vec::new()
                }
            }
            Effect::Keyboard(state) => {
                if input.keyboard(&state).is_err() {
                    engine.reduce(Event::Release {
                        control_id: engine.active_key().map_or(0, |key| key.control_id),
                        reason: ReleaseReason::HidFailed,
                    })
                } else {
                    Vec::new()
                }
            }
            Effect::Neutralize {
                x,
                y,
                maximum_x,
                maximum_y,
            } => {
                let report = input.release_teardown(x, y, maximum_x, maximum_y);
                engine.observe_queue_high_water(input.queue_high_water());
                engine.reduce(Event::ReleaseCompleted {
                    succeeded: report.reset_ok && report.stable,
                })
            }
            Effect::CursorVisible(true) => {
                crate::cursor_hider::show();
                Vec::new()
            }
            Effect::CursorVisible(false) => {
                crate::cursor_hider::hide();
                Vec::new()
            }
            Effect::SendAcquired(key) => {
                if writer
                    .send_control(Frame::new(
                        MessageKind::MouseAcquired,
                        control_payload(key.control_id).to_vec(),
                    ))
                    .is_err()
                {
                    return false;
                }
                Vec::new()
            }
            Effect::SendLeave { key, normalized_y } => {
                if writer
                    .send_control(Frame::new(
                        MessageKind::MouseLeave,
                        mouse_leave_payload(key.control_id, normalized_y).to_vec(),
                    ))
                    .is_err()
                {
                    return false;
                }
                Vec::new()
            }
            Effect::SendReleased(key) => {
                if writer
                    .send_control(Frame::new(
                        MessageKind::MouseReleased,
                        control_payload(key.control_id).to_vec(),
                    ))
                    .is_err()
                {
                    return false;
                }
                Vec::new()
            }
            Effect::SendDriverUnavailable => {
                if writer
                    .send_control(Frame::new(MessageKind::MouseDriverUnavailable, Vec::new()))
                    .is_err()
                {
                    return false;
                }
                Vec::new()
            }
            Effect::ScheduleLease(_) => Vec::new(),
            Effect::LogEnter(message) | Effect::LogEnd(message) => {
                crate::logging::info(&message);
                Vec::new()
            }
            Effect::LogEdge(message) => {
                crate::logging::info(&message);
                Vec::new()
            }
            Effect::DumpFault(entries) => {
                for entry in entries {
                    crate::logging::error(&format!("mouse route trace: {entry}"));
                }
                Vec::new()
            }
            Effect::CloseChannel => return false,
        };
        effects.extend(follow_up);
    }
    true
}

fn elevate_priority() {
    let _ = unsafe { SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL) };
}

fn service_mouse_health(writer: &Arc<MouseSender>, health: &mut ChannelHealth) -> Result<(), ()> {
    let now = Instant::now();
    match health.action(now) {
        HealthAction::Wait => Ok(()),
        HealthAction::SendPing => {
            writer
                .send_control(Frame::new(MessageKind::Ping, Vec::new()))
                .map_err(|_| ())?;
            health.ping_sent = Some(now);
            Ok(())
        }
        HealthAction::TimedOut => Err(()),
    }
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

fn finish_socket(stream: TcpStream, events: SyncSender<WorkerEvent>, connection_id: u64) {
    let _ = stream.shutdown(Shutdown::Both);
    let _ = notify(&events, connection_id, SessionEvent::Exited);
}
