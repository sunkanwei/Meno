use std::net::{Ipv4Addr, Shutdown, SocketAddr, SocketAddrV4, TcpStream};
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::HWND;

use crate::audio_session::{AudioSession, AudioStatus};
use crate::channel_health::{ChannelHealth, HealthAction};
use crate::discovery;
use crate::file_transfer::WorkerEvent as FileWorkerEvent;
use crate::mouse_session::{self, SessionEvent};
use crate::protocol::{
    CAPABILITY_FILE_CLIPBOARD, CAPABILITY_MAC_MICROPHONE, CAPABILITY_PNG_CLIPBOARD,
    CAPABILITY_TEXT_CLIPBOARD, CAPABILITY_WINDOWS_ONLINE_NOTIFICATION, Capabilities, Frame,
    FrameDecoder, Hello, MAX_IMAGE_SIZE, MAX_TEXT_SIZE, MessageKind, clipboard_hello, parse_hello,
};

const FIRST_DISCOVERY_DELAY: Duration = Duration::from_secs(2);
const SECOND_DISCOVERY_DELAY: Duration = Duration::from_secs(5);
const MAX_DISCOVERY_DELAY: Duration = Duration::from_secs(10);
const RECONNECT_DELAY: Duration = Duration::from_secs(1);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
const WRITE_TIMEOUT: Duration = Duration::from_secs(2);
const WORKER_EVENT_CAPACITY: usize = 4;
const NETWORK_COMMAND_CAPACITY: usize = 32;
const MAX_CONNECT_CANDIDATES: usize = 4;

pub enum NetworkCommand {
    Clipboard(Frame),
    FileFrame { connection_id: u64, frame: Frame },
    ProtocolViolation { connection_id: u64 },
    Pause(bool),
    Rediscover,
    Stop,
}

pub enum NetworkEvent {
    Searching,
    Connected { name: String, address: String },
    AudioStatus(AudioStatus),
    Clipboard(Frame),
    Error(String),
}

pub(crate) enum WorkerEvent {
    Command(NetworkCommand),
    // The clipboard reader thread is the only socket still reporting frames
    // here; the mouse session owns its socket end to end.
    Socket {
        connection_id: u64,
        result: Result<Vec<Frame>, String>,
    },
    Mouse {
        connection_id: u64,
        event: SessionEvent,
    },
    Audio {
        connection_id: u64,
        status: AudioStatus,
    },
}

pub fn spawn(hwnd: HWND, file_events: SyncSender<FileWorkerEvent>) -> SyncSender<NetworkCommand> {
    let (command_sender, command_receiver) = mpsc::sync_channel(NETWORK_COMMAND_CAPACITY);
    let hwnd_value = hwnd.0 as usize;
    thread::spawn(move || {
        let (event_sender, event_receiver) = mpsc::sync_channel(WORKER_EVENT_CAPACITY);
        let command_event_sender = event_sender.clone();
        thread::spawn(move || {
            while let Ok(command) = command_receiver.recv() {
                if command_event_sender
                    .send(WorkerEvent::Command(command))
                    .is_err()
                {
                    return;
                }
            }
            let _ = command_event_sender.send(WorkerEvent::Command(NetworkCommand::Stop));
        });
        worker(
            HWND(hwnd_value as *mut _),
            event_receiver,
            event_sender,
            file_events,
        );
    });
    command_sender
}

fn worker(
    hwnd: HWND,
    receiver: Receiver<WorkerEvent>,
    sender: SyncSender<WorkerEvent>,
    file_events: SyncSender<FileWorkerEvent>,
) {
    let mut paused = false;
    let mut discovery_delay = FIRST_DISCOVERY_DELAY;
    let mut connection_id = 0_u64;
    let mut windows_online_sent = false;

    loop {
        if paused {
            match wait_while_paused(&receiver, &file_events) {
                IdleExit::Retry => {
                    paused = false;
                    discovery_delay = FIRST_DISCOVERY_DELAY;
                    post(hwnd, NetworkEvent::Searching);
                }
                IdleExit::Pause => continue,
                IdleExit::Stop => return,
            }
        }

        post(hwnd, NetworkEvent::Searching);
        let companions = match discovery::discover() {
            Ok(companions) if !companions.is_empty() => companions,
            Ok(_) => {
                match wait_before_retry(&receiver, &file_events, discovery_delay) {
                    IdleExit::Retry => {}
                    IdleExit::Pause => paused = true,
                    IdleExit::Stop => return,
                }
                discovery_delay = next_discovery_delay(discovery_delay);
                continue;
            }
            Err(error) => {
                post(hwnd, NetworkEvent::Error(error));
                match wait_before_retry(&receiver, &file_events, discovery_delay) {
                    IdleExit::Retry => {}
                    IdleExit::Pause => paused = true,
                    IdleExit::Stop => return,
                }
                discovery_delay = next_discovery_delay(discovery_delay);
                continue;
            }
        };

        let connected = companions
            .into_iter()
            .take(MAX_CONNECT_CANDIDATES)
            .find_map(|companion| {
                connect_channels(
                    companion.address,
                    companion.offer.clipboard_port,
                    companion.offer.mouse_port,
                )
                .map(|streams| (companion, streams))
            });
        let Some((companion, (clipboard_stream, mouse_stream))) = connected else {
            match wait_before_retry(&receiver, &file_events, discovery_delay) {
                IdleExit::Retry => {}
                IdleExit::Pause => paused = true,
                IdleExit::Stop => return,
            }
            discovery_delay = next_discovery_delay(discovery_delay);
            continue;
        };

        connection_id = connection_id.wrapping_add(1);
        discovery_delay = FIRST_DISCOVERY_DELAY;
        match run_connection(
            hwnd,
            clipboard_stream,
            mouse_stream,
            companion.address,
            connection_id,
            &receiver,
            &sender,
            &file_events,
            &mut windows_online_sent,
        ) {
            ConnectionExit::Stop => return,
            ConnectionExit::Pause => paused = true,
            // A failed session must not spin: backoff bounds the reconnect
            // rate, while Rediscover/Pause commands still take effect at once.
            ConnectionExit::Reconnect => {
                match wait_before_retry(&receiver, &file_events, RECONNECT_DELAY) {
                    IdleExit::Retry => {}
                    IdleExit::Pause => paused = true,
                    IdleExit::Stop => return,
                }
            }
        }
    }
}

fn connect_channels(
    address: Ipv4Addr,
    clipboard_port: u16,
    mouse_port: u16,
) -> Option<(TcpStream, Option<TcpStream>)> {
    let clipboard_address = SocketAddr::V4(SocketAddrV4::new(address, clipboard_port));
    let mouse_address = SocketAddr::V4(SocketAddrV4::new(address, mouse_port));
    let clipboard_stream = TcpStream::connect_timeout(&clipboard_address, CONNECT_TIMEOUT).ok()?;
    let mouse_stream = TcpStream::connect_timeout(&mouse_address, CONNECT_TIMEOUT)
        .map_err(|error| {
            crate::logging::error(&format!(
                "mouse connection unavailable before Ready: endpoint={mouse_address} error={error}"
            ));
        })
        .ok();
    Some((clipboard_stream, mouse_stream))
}

enum IdleExit {
    Retry,
    Pause,
    Stop,
}

fn wait_while_paused(
    receiver: &Receiver<WorkerEvent>,
    file_events: &SyncSender<FileWorkerEvent>,
) -> IdleExit {
    loop {
        match receiver.recv() {
            Ok(WorkerEvent::Command(NetworkCommand::Pause(false)))
            | Ok(WorkerEvent::Command(NetworkCommand::Rediscover)) => return IdleExit::Retry,
            Ok(WorkerEvent::Command(NetworkCommand::Stop)) | Err(_) => return IdleExit::Stop,
            Ok(WorkerEvent::Command(NetworkCommand::FileFrame {
                connection_id,
                frame,
            })) => {
                notify_write_failed(file_events, connection_id, frame.message_id);
            }
            Ok(_) => {}
        }
    }
}

fn notify_write_failed(
    file_events: &SyncSender<FileWorkerEvent>,
    connection_id: u64,
    message_id: u64,
) {
    let _ = send_file_event(
        file_events,
        FileWorkerEvent::Written {
            connection_id,
            message_id,
            ok: false,
        },
    );
}

fn send_file_event(sender: &SyncSender<FileWorkerEvent>, event: FileWorkerEvent) -> bool {
    match sender.try_send(event) {
        Ok(()) => true,
        Err(TrySendError::Full(_)) => {
            crate::logging::error("file worker overload: bounded event queue is full");
            false
        }
        Err(TrySendError::Disconnected(_)) => false,
    }
}

fn wait_before_retry(
    receiver: &Receiver<WorkerEvent>,
    file_events: &SyncSender<FileWorkerEvent>,
    delay: Duration,
) -> IdleExit {
    let deadline = Instant::now() + delay;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match receiver.recv_timeout(remaining) {
            Ok(WorkerEvent::Command(NetworkCommand::Pause(true))) => return IdleExit::Pause,
            Ok(WorkerEvent::Command(NetworkCommand::Rediscover))
            | Ok(WorkerEvent::Command(NetworkCommand::Pause(false))) => return IdleExit::Retry,
            Ok(WorkerEvent::Command(NetworkCommand::Stop))
            | Err(RecvTimeoutError::Disconnected) => return IdleExit::Stop,
            Ok(WorkerEvent::Command(NetworkCommand::Clipboard(_))) => {}
            Ok(WorkerEvent::Command(NetworkCommand::FileFrame {
                connection_id,
                frame,
            })) => {
                notify_write_failed(file_events, connection_id, frame.message_id);
            }
            Err(RecvTimeoutError::Timeout) => return IdleExit::Retry,
            Ok(_) => {}
        }
    }
}

fn next_discovery_delay(current: Duration) -> Duration {
    if current < SECOND_DISCOVERY_DELAY {
        SECOND_DISCOVERY_DELAY
    } else {
        MAX_DISCOVERY_DELAY
    }
}

enum ConnectionExit {
    Reconnect,
    Pause,
    Stop,
}

struct ConnectionState {
    clipboard: ChannelHealth,
    clipboard_capabilities: Capabilities,
    mouse_handshake: bool,
    mouse_ready: bool,
    mouse_keyboard: bool,
    directional_mouse_handoff: bool,
    remote_shutdown: bool,
    mouse_driver_abi: u16,
    remote_name: String,
    connected_reported: bool,
    negotiated_reported: bool,
    audio_negotiated: bool,
}

impl ConnectionState {
    fn new(mouse_channel_missing: bool) -> Self {
        Self {
            clipboard: ChannelHealth::new(),
            clipboard_capabilities: Capabilities::empty(),
            mouse_handshake: mouse_channel_missing,
            mouse_ready: false,
            mouse_keyboard: false,
            directional_mouse_handoff: false,
            remote_shutdown: false,
            mouse_driver_abi: 0,
            remote_name: String::new(),
            connected_reported: false,
            negotiated_reported: false,
            audio_negotiated: false,
        }
    }

    fn mouse_exited(&mut self) -> bool {
        let reconnect = self.mouse_handshake;
        self.mouse_handshake = true;
        self.mouse_ready = false;
        reconnect
    }
}

// The coordinator owns discovery, the clipboard link and the unified
// lifecycle; the mouse session thread owns everything on the mouse channel.
#[allow(clippy::too_many_arguments)]
fn run_connection(
    hwnd: HWND,
    mut clipboard_stream: TcpStream,
    mouse_stream: Option<TcpStream>,
    address: Ipv4Addr,
    connection_id: u64,
    receiver: &Receiver<WorkerEvent>,
    sender: &SyncSender<WorkerEvent>,
    file_events: &SyncSender<FileWorkerEvent>,
    windows_online_sent: &mut bool,
) -> ConnectionExit {
    if configure_stream(&clipboard_stream).is_err() {
        return ConnectionExit::Reconnect;
    }
    let computer_name = computer_name();
    let address_text = address.to_string();
    if Frame::new(MessageKind::Hello, clipboard_hello(&computer_name))
        .write_to(&mut clipboard_stream)
        .is_err()
    {
        return ConnectionExit::Reconnect;
    }

    let Ok(clipboard_reader_stream) = clipboard_stream.try_clone() else {
        return ConnectionExit::Reconnect;
    };
    let stop = Arc::new(mouse_session::StopSignal::new());
    let clipboard_reader = spawn_reader(
        clipboard_reader_stream,
        connection_id,
        sender.clone(),
        stop.clone(),
    );
    // The coordinator keeps a cloned mouse handle solely to wake the session
    // thread by shutting down its read side; all mouse I/O stays there.
    let (mouse_wakeup, mouse_session) = match mouse_stream {
        Some(mouse_stream) => match mouse_stream.try_clone() {
            Ok(wakeup) => (
                Some(wakeup),
                Some(mouse_session::spawn(
                    mouse_stream,
                    connection_id,
                    computer_name.clone(),
                    sender.clone(),
                    stop.clone(),
                )),
            ),
            Err(error) => {
                crate::logging::error(&format!(
                    "mouse connection unavailable before Ready: clone failed: {error}"
                ));
                (None, None)
            }
        },
        None => (None, None),
    };

    let mut state = ConnectionState::new(mouse_session.is_none());
    let mut audio_session: Option<AudioSession> = None;
    let exit = 'connected: loop {
        let wait = state
            .clipboard
            .deadline()
            .saturating_duration_since(Instant::now());
        match receiver.recv_timeout(wait) {
            Ok(WorkerEvent::Command(NetworkCommand::Clipboard(frame))) if state.clipboard.ready => {
                // Only content types confirmed in Ready may be sent.
                let negotiated = match frame.kind {
                    MessageKind::Text => state
                        .clipboard_capabilities
                        .contains(CAPABILITY_TEXT_CLIPBOARD),
                    MessageKind::Png => state
                        .clipboard_capabilities
                        .contains(CAPABILITY_PNG_CLIPBOARD),
                    _ => false,
                };
                if negotiated {
                    if frame.write_to(&mut clipboard_stream).is_err() {
                        break 'connected ConnectionExit::Reconnect;
                    }
                    state.clipboard.last_activity = Instant::now();
                }
            }
            Ok(WorkerEvent::Command(NetworkCommand::Clipboard(_))) => {}
            // File frames keep the single-writer rule: the coordinator writes
            // them serially on the same socket and reports completion so the
            // file worker can wait for the peer's Ack with real backpressure.
            Ok(WorkerEvent::Command(NetworkCommand::FileFrame {
                connection_id: command_connection_id,
                frame,
            })) => {
                let message_id = frame.message_id;
                let writable = state.clipboard.ready
                    && command_connection_id == connection_id
                    && frame.kind.is_file_transfer()
                    && state
                        .clipboard_capabilities
                        .contains(CAPABILITY_FILE_CLIPBOARD);
                let ok = writable && frame.write_to(&mut clipboard_stream).is_ok();
                if ok {
                    state.clipboard.last_activity = Instant::now();
                }
                if !send_file_event(
                    file_events,
                    FileWorkerEvent::Written {
                        connection_id: command_connection_id,
                        message_id,
                        ok,
                    },
                ) {
                    break 'connected ConnectionExit::Reconnect;
                }
                if writable && !ok {
                    break 'connected ConnectionExit::Reconnect;
                }
            }
            Ok(WorkerEvent::Command(NetworkCommand::ProtocolViolation {
                connection_id: command_connection_id,
            })) => {
                if command_connection_id == connection_id {
                    crate::logging::error(
                        "file transfer protocol violation: reconnecting clipboard channel",
                    );
                    break 'connected ConnectionExit::Reconnect;
                }
            }
            Ok(WorkerEvent::Command(NetworkCommand::Pause(true))) => {
                break 'connected ConnectionExit::Pause;
            }
            Ok(WorkerEvent::Command(NetworkCommand::Rediscover)) => {
                break 'connected ConnectionExit::Reconnect;
            }
            Ok(WorkerEvent::Command(NetworkCommand::Stop))
            | Err(RecvTimeoutError::Disconnected) => {
                break 'connected ConnectionExit::Stop;
            }
            Ok(WorkerEvent::Socket {
                connection_id: event_connection_id,
                result,
            }) if event_connection_id == connection_id => {
                let Ok(frames) = result else {
                    break 'connected ConnectionExit::Reconnect;
                };
                state.clipboard.last_activity = Instant::now();

                for frame in frames {
                    match frame.kind {
                        MessageKind::Ready => {
                            if state.clipboard.ready {
                                break 'connected ConnectionExit::Reconnect;
                            }
                            let Ok(hello) = parse_hello(&frame.payload) else {
                                break 'connected ConnectionExit::Reconnect;
                            };
                            let negotiated =
                                hello.capabilities.intersect(Capabilities::from_slice(&[
                                    CAPABILITY_TEXT_CLIPBOARD,
                                    CAPABILITY_PNG_CLIPBOARD,
                                    CAPABILITY_FILE_CLIPBOARD,
                                    CAPABILITY_WINDOWS_ONLINE_NOTIFICATION,
                                ]));
                            state.clipboard_capabilities = negotiated;
                            state.clipboard.ready = true;
                            state.clipboard.last_activity = Instant::now();
                            state.remote_name = crate::peer_name::normalize(&hello.name);
                            match negotiated_audio_port(&hello) {
                                Err(()) => crate::logging::error(
                                    "audio protocol error: control Ready must contain capability 8 and audioPort together",
                                ),
                                Ok(None) => {}
                                Ok(Some(port)) => {
                                    let endpoint = SocketAddr::V4(SocketAddrV4::new(address, port));
                                    let audio_sender = sender.clone();
                                    state.audio_negotiated = true;
                                    audio_session = Some(AudioSession::spawn(
                                        endpoint,
                                        connection_id,
                                        computer_name.clone(),
                                        move |status| {
                                            let event = WorkerEvent::Audio {
                                                connection_id,
                                                status,
                                            };
                                            match audio_sender.try_send(event) {
                                                Ok(()) => true,
                                                Err(TrySendError::Full(_)) => false,
                                                Err(TrySendError::Disconnected(_)) => false,
                                            }
                                        },
                                    ));
                                }
                            }
                            if state
                                .clipboard_capabilities
                                .contains(CAPABILITY_FILE_CLIPBOARD)
                                && !send_file_event(
                                    file_events,
                                    FileWorkerEvent::Link { connection_id },
                                )
                            {
                                break 'connected ConnectionExit::Reconnect;
                            }
                            match send_windows_online_if_needed(
                                &mut clipboard_stream,
                                state.clipboard_capabilities,
                                windows_online_sent,
                            ) {
                                Ok(true) => {
                                    state.clipboard.last_activity = Instant::now();
                                }
                                Ok(false) => {}
                                Err(_) => break 'connected ConnectionExit::Reconnect,
                            }
                            report_connection(hwnd, &address_text, &mut state);
                        }
                        MessageKind::Text => {
                            if !state.clipboard.ready
                                || !state
                                    .clipboard_capabilities
                                    .contains(CAPABILITY_TEXT_CLIPBOARD)
                                || frame.payload.len() > MAX_TEXT_SIZE
                                || std::str::from_utf8(&frame.payload).is_err()
                            {
                                break 'connected ConnectionExit::Reconnect;
                            }
                            post(hwnd, NetworkEvent::Clipboard(frame));
                        }
                        MessageKind::Png => {
                            if !state.clipboard.ready
                                || !state
                                    .clipboard_capabilities
                                    .contains(CAPABILITY_PNG_CLIPBOARD)
                                || frame.payload.len() > MAX_IMAGE_SIZE
                            {
                                break 'connected ConnectionExit::Reconnect;
                            }
                            post(hwnd, NetworkEvent::Clipboard(frame));
                        }
                        MessageKind::Ping if frame.payload.is_empty() => {
                            if Frame::new(MessageKind::Pong, Vec::new())
                                .write_to(&mut clipboard_stream)
                                .is_err()
                            {
                                break 'connected ConnectionExit::Reconnect;
                            }
                            state.clipboard.last_activity = Instant::now();
                        }
                        MessageKind::Pong if frame.payload.is_empty() => {
                            state.clipboard.ping_sent = None;
                        }
                        kind if kind.is_file_transfer() => {
                            if !state.clipboard.ready
                                || !state
                                    .clipboard_capabilities
                                    .contains(CAPABILITY_FILE_CLIPBOARD)
                            {
                                break 'connected ConnectionExit::Reconnect;
                            }
                            if !send_file_event(
                                file_events,
                                FileWorkerEvent::Frame {
                                    connection_id,
                                    frame,
                                },
                            ) {
                                break 'connected ConnectionExit::Reconnect;
                            }
                        }
                        MessageKind::ShutdownRequest => {
                            break 'connected ConnectionExit::Reconnect;
                        }
                        _ => break 'connected ConnectionExit::Reconnect,
                    }
                }
            }
            Ok(WorkerEvent::Mouse {
                connection_id: event_connection_id,
                event,
            }) if event_connection_id == connection_id => match event {
                SessionEvent::Ready {
                    mouse,
                    keyboard,
                    directional_mouse_handoff: negotiated_directional_mouse_handoff,
                    remote_shutdown: negotiated_remote_shutdown,
                    driver_abi,
                } => {
                    if state.mouse_handshake {
                        break 'connected ConnectionExit::Reconnect;
                    }
                    state.mouse_handshake = true;
                    state.mouse_ready = mouse;
                    state.mouse_keyboard = keyboard;
                    state.directional_mouse_handoff = negotiated_directional_mouse_handoff;
                    state.remote_shutdown = negotiated_remote_shutdown;
                    state.mouse_driver_abi = driver_abi;
                    report_connection(hwnd, &address_text, &mut state);
                }
                SessionEvent::Exited => {
                    if state.mouse_exited() {
                        break 'connected ConnectionExit::Reconnect;
                    }
                    crate::logging::error("mouse session unavailable before Ready");
                    report_connection(hwnd, &address_text, &mut state);
                }
            },
            Ok(WorkerEvent::Audio {
                connection_id: event_connection_id,
                status,
            }) if event_connection_id == connection_id => {
                post(hwnd, NetworkEvent::AudioStatus(status));
            }
            Err(RecvTimeoutError::Timeout) => {
                if service_health(&mut clipboard_stream, &mut state.clipboard).is_err() {
                    break 'connected ConnectionExit::Reconnect;
                }
            }
            Ok(_) => {}
        }
    };

    // Unified teardown: both channels of one session close together, and the
    // mouse thread always finishes its release before a new session begins.
    let _ = send_file_event(file_events, FileWorkerEvent::Closed { connection_id });
    if let Some(audio_session) = audio_session {
        audio_session.stop();
    }
    stop.request(matches!(exit, ConnectionExit::Pause));
    if let Some(mouse_wakeup) = mouse_wakeup {
        let _ = mouse_wakeup.shutdown(Shutdown::Read);
    }
    let _ = clipboard_stream.shutdown(Shutdown::Both);
    let _ = clipboard_reader.join();
    if let Some(mouse_session) = mouse_session {
        let _ = mouse_session.join();
    }
    exit
}

fn negotiated_audio_port(hello: &Hello) -> Result<Option<u16>, ()> {
    match (
        hello.capabilities.contains(CAPABILITY_MAC_MICROPHONE),
        hello.audio_port,
    ) {
        (true, Some(port)) => Ok(Some(port)),
        (false, None) => Ok(None),
        _ => Err(()),
    }
}

fn send_windows_online_if_needed(
    stream: &mut TcpStream,
    negotiated: Capabilities,
    sent: &mut bool,
) -> std::io::Result<bool> {
    if *sent || !negotiated.contains(CAPABILITY_WINDOWS_ONLINE_NOTIFICATION) {
        return Ok(false);
    }
    Frame::new(MessageKind::WindowsOnline, Vec::new()).write_to(stream)?;
    *sent = true;
    Ok(true)
}

fn report_connection(hwnd: HWND, address: &str, state: &mut ConnectionState) {
    if state.clipboard.ready && !state.connected_reported {
        post(
            hwnd,
            NetworkEvent::Connected {
                name: if state.remote_name.is_empty() {
                    "Mac".to_string()
                } else {
                    state.remote_name.clone()
                },
                address: address.to_string(),
            },
        );
        state.connected_reported = true;
    }
    if state.negotiated_reported || !state.clipboard.ready || !state.mouse_handshake {
        return;
    }
    let content_capabilities = state
        .clipboard_capabilities
        .intersect(Capabilities::from_slice(&[
            CAPABILITY_TEXT_CLIPBOARD,
            CAPABILITY_PNG_CLIPBOARD,
            CAPABILITY_FILE_CLIPBOARD,
        ]));
    crate::logging::info(&format!(
        "Negotiated MENO capabilities: content={} text={} png={} file={} microphone={} windowsOnline={} mouse={} keyboard={} directionalMouseHandoff={} shutdown={} driver_abi={}",
        !content_capabilities.is_empty(),
        state
            .clipboard_capabilities
            .contains(CAPABILITY_TEXT_CLIPBOARD),
        state
            .clipboard_capabilities
            .contains(CAPABILITY_PNG_CLIPBOARD),
        state
            .clipboard_capabilities
            .contains(CAPABILITY_FILE_CLIPBOARD),
        state.audio_negotiated,
        state
            .clipboard_capabilities
            .contains(CAPABILITY_WINDOWS_ONLINE_NOTIFICATION),
        state.mouse_ready,
        state.mouse_keyboard,
        state.directional_mouse_handoff,
        state.remote_shutdown,
        state.mouse_driver_abi,
    ));
    state.negotiated_reported = true;
}

fn configure_stream(stream: &TcpStream) -> std::io::Result<()> {
    stream.set_nodelay(true)?;
    stream.set_read_timeout(None)?;
    stream.set_write_timeout(Some(WRITE_TIMEOUT))
}

pub(crate) fn service_health(stream: &mut TcpStream, health: &mut ChannelHealth) -> Result<(), ()> {
    let now = Instant::now();
    match health.action(now) {
        HealthAction::Wait => Ok(()),
        HealthAction::SendPing => {
            Frame::new(MessageKind::Ping, Vec::new())
                .write_to(stream)
                .map_err(|_| ())?;
            health.ping_sent = Some(now);
            Ok(())
        }
        HealthAction::TimedOut => Err(()),
    }
}

fn spawn_reader(
    stream: TcpStream,
    connection_id: u64,
    sender: SyncSender<WorkerEvent>,
    stop: Arc<mouse_session::StopSignal>,
) -> JoinHandle<()> {
    thread::spawn(move || read_socket(stream, connection_id, sender, stop))
}

fn read_socket(
    mut stream: TcpStream,
    connection_id: u64,
    sender: SyncSender<WorkerEvent>,
    stop: Arc<mouse_session::StopSignal>,
) {
    let mut decoder = FrameDecoder::new();
    loop {
        match decoder.read_available(&mut stream) {
            Ok(frames) if frames.is_empty() => {}
            Ok(frames) => {
                if !send_reader_event(
                    &sender,
                    &stop,
                    WorkerEvent::Socket {
                        connection_id,
                        result: Ok(frames),
                    },
                ) {
                    return;
                }
            }
            Err(error) => {
                let _ = send_reader_event(
                    &sender,
                    &stop,
                    WorkerEvent::Socket {
                        connection_id,
                        result: Err(error.to_string()),
                    },
                );
                return;
            }
        }
    }
}

fn send_reader_event(
    sender: &SyncSender<WorkerEvent>,
    stop: &mouse_session::StopSignal,
    event: WorkerEvent,
) -> bool {
    let mut pending = event;
    loop {
        if stop.requested() {
            return false;
        }
        match sender.try_send(pending) {
            Ok(()) => return true,
            Err(TrySendError::Disconnected(_)) => return false,
            Err(TrySendError::Full(event)) => {
                pending = event;
                thread::sleep(Duration::from_millis(1));
            }
        }
    }
}

fn post(hwnd: HWND, event: NetworkEvent) {
    let _ = crate::post_network_event(hwnd, event);
}

fn computer_name() -> String {
    use windows::Win32::System::WindowsProgramming::GetComputerNameW;
    use windows::core::PWSTR;

    let mut buffer = [0_u16; 256];
    let mut length = buffer.len() as u32;
    if unsafe { GetComputerNameW(Some(PWSTR(buffer.as_mut_ptr())), &mut length) }.is_ok() {
        String::from_utf16_lossy(&buffer[..length as usize])
    } else {
        "Windows".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    fn connected_streams() -> (TcpStream, TcpStream) {
        let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let address = listener.local_addr().unwrap();
        let connector = thread::spawn(move || TcpStream::connect(address).unwrap());
        let receiver = listener.accept().unwrap().0;
        (connector.join().unwrap(), receiver)
    }

    fn read_frames_to_end(mut receiver: TcpStream) -> Vec<Frame> {
        let mut bytes = Vec::new();
        receiver.read_to_end(&mut bytes).unwrap();
        FrameDecoder::new().append(&bytes).unwrap()
    }

    #[test]
    fn microphone_capability_and_audio_port_must_be_negotiated_together() {
        let none = Hello::default();
        assert_eq!(negotiated_audio_port(&none), Ok(None));

        let capability_only = Hello {
            capabilities: Capabilities::from_slice(&[CAPABILITY_MAC_MICROPHONE]),
            ..Default::default()
        };
        assert_eq!(negotiated_audio_port(&capability_only), Err(()));

        let port_only = Hello {
            audio_port: Some(48_000),
            ..Default::default()
        };
        assert_eq!(negotiated_audio_port(&port_only), Err(()));

        let paired = Hello {
            capabilities: Capabilities::from_slice(&[CAPABILITY_MAC_MICROPHONE]),
            audio_port: Some(48_000),
            ..Default::default()
        };
        assert_eq!(negotiated_audio_port(&paired), Ok(Some(48_000)));
    }

    #[test]
    fn mouse_failure_before_ready_keeps_control_but_failure_after_ready_reconnects() {
        let mut before_ready = ConnectionState::new(false);
        assert!(!before_ready.mouse_exited());
        assert!(before_ready.mouse_handshake);

        let mut after_ready = ConnectionState::new(false);
        after_ready.mouse_handshake = true;
        assert!(after_ready.mouse_exited());
    }

    #[test]
    fn windows_online_is_sent_once_after_capability_negotiation() {
        let (mut sender, receiver) = connected_streams();
        let negotiated = Capabilities::from_slice(&[CAPABILITY_WINDOWS_ONLINE_NOTIFICATION]);
        let mut sent = false;

        assert!(
            !send_windows_online_if_needed(&mut sender, Capabilities::empty(), &mut sent).unwrap()
        );
        assert!(!sent);
        assert!(send_windows_online_if_needed(&mut sender, negotiated, &mut sent).unwrap());
        assert!(sent);
        assert!(!send_windows_online_if_needed(&mut sender, negotiated, &mut sent).unwrap());
        drop(sender);

        let frames = read_frames_to_end(receiver);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].kind, MessageKind::WindowsOnline);
        assert!(frames[0].payload.is_empty());
    }

    #[test]
    fn windows_online_send_failure_remains_retryable() {
        let negotiated = Capabilities::from_slice(&[CAPABILITY_WINDOWS_ONLINE_NOTIFICATION]);
        let mut sent = false;
        let (mut failed_sender, failed_receiver) = connected_streams();
        failed_sender.shutdown(Shutdown::Write).unwrap();

        assert!(send_windows_online_if_needed(&mut failed_sender, negotiated, &mut sent).is_err());
        assert!(!sent);
        drop(failed_sender);
        drop(failed_receiver);

        let (mut retry_sender, retry_receiver) = connected_streams();
        assert!(send_windows_online_if_needed(&mut retry_sender, negotiated, &mut sent).unwrap());
        assert!(sent);
        drop(retry_sender);

        let frames = read_frames_to_end(retry_receiver);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].kind, MessageKind::WindowsOnline);
        assert!(frames[0].payload.is_empty());
    }
}
