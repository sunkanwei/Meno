use std::net::{Ipv4Addr, Shutdown, SocketAddr, SocketAddrV4, TcpStream};
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::HWND;

use crate::audio_session::{AudioSession, AudioStatus};
use crate::discovery;
use crate::display_contract::DisplayContract;
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
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
const IDLE_BEFORE_PING: Duration = Duration::from_secs(30);
const PONG_TIMEOUT: Duration = Duration::from_secs(10);
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
            Ok(WorkerEvent::Command(NetworkCommand::Clipboard(frame))) => {
                crate::logging::debug(&format!(
                    "clipboard send dropped: not connected (kind={:?} bytes={})",
                    frame.kind,
                    frame.payload.len()
                ));
            }
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

pub(crate) struct ChannelHealth {
    pub(crate) ready: bool,
    pub(crate) connected_at: Instant,
    pub(crate) last_activity: Instant,
    pub(crate) ping_sent: Option<Instant>,
}

impl ChannelHealth {
    pub(crate) fn new() -> Self {
        let now = Instant::now();
        Self {
            ready: false,
            connected_at: now,
            last_activity: now,
            ping_sent: None,
        }
    }

    pub(crate) fn deadline(&self) -> Instant {
        if !self.ready {
            self.connected_at + HANDSHAKE_TIMEOUT
        } else if let Some(sent) = self.ping_sent {
            sent + PONG_TIMEOUT
        } else {
            self.last_activity + IDLE_BEFORE_PING
        }
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

    let mut clipboard_health = ChannelHealth::new();
    let mut clipboard_capabilities = Capabilities::empty();
    let mut mouse_handshake = mouse_session.is_none();
    let mut mouse_ready = false;
    let mut mouse_keyboard = false;
    let mut directional_mouse_handoff = false;
    let mut remote_shutdown = false;
    let mut remote_diagnostics = false;
    let mut mouse_driver_abi = 0_u16;
    let mut mouse_display = None;
    let mut remote_name = String::new();
    let mut connected_reported = false;
    let mut negotiated_reported = false;
    let mut audio_negotiated = false;
    let mut audio_session: Option<AudioSession> = None;
    let exit = 'connected: loop {
        let wait = clipboard_health
            .deadline()
            .saturating_duration_since(Instant::now());
        match receiver.recv_timeout(wait) {
            Ok(WorkerEvent::Command(NetworkCommand::Clipboard(frame)))
                if clipboard_health.ready =>
            {
                // Only content types confirmed in Ready may be sent.
                let negotiated = match frame.kind {
                    MessageKind::Text => clipboard_capabilities.contains(CAPABILITY_TEXT_CLIPBOARD),
                    MessageKind::Png => clipboard_capabilities.contains(CAPABILITY_PNG_CLIPBOARD),
                    _ => false,
                };
                if negotiated {
                    if frame.write_to(&mut clipboard_stream).is_err() {
                        break 'connected ConnectionExit::Reconnect;
                    }
                    clipboard_health.last_activity = Instant::now();
                } else {
                    crate::logging::debug(&format!(
                        "clipboard send dropped: kind={:?} was not negotiated",
                        frame.kind
                    ));
                }
            }
            Ok(WorkerEvent::Command(NetworkCommand::Clipboard(frame))) => {
                crate::logging::debug(&format!(
                    "clipboard send dropped: handshake pending (kind={:?} bytes={})",
                    frame.kind,
                    frame.payload.len()
                ));
            }
            // File frames keep the single-writer rule: the coordinator writes
            // them serially on the same socket and reports completion so the
            // file worker can wait for the peer's Ack with real backpressure.
            Ok(WorkerEvent::Command(NetworkCommand::FileFrame {
                connection_id: command_connection_id,
                frame,
            })) => {
                let message_id = frame.message_id;
                let writable = clipboard_health.ready
                    && command_connection_id == connection_id
                    && frame.kind.is_file_transfer()
                    && clipboard_capabilities.contains(CAPABILITY_FILE_CLIPBOARD);
                let ok = writable && frame.write_to(&mut clipboard_stream).is_ok();
                if ok {
                    clipboard_health.last_activity = Instant::now();
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
                clipboard_health.last_activity = Instant::now();

                for frame in frames {
                    match frame.kind {
                        MessageKind::Ready => {
                            if clipboard_health.ready {
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
                            clipboard_capabilities = negotiated;
                            clipboard_health.ready = true;
                            clipboard_health.last_activity = Instant::now();
                            remote_name = crate::peer_name::normalize(&hello.name);
                            match negotiated_audio_port(&hello) {
                                Err(()) => crate::logging::error(
                                    "audio protocol error: control Ready must contain capability 8 and audioPort together",
                                ),
                                Ok(None) => {}
                                Ok(Some(port)) => {
                                    let endpoint = SocketAddr::V4(SocketAddrV4::new(address, port));
                                    let audio_sender = sender.clone();
                                    audio_negotiated = true;
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
                                                Err(TrySendError::Full(_)) => {
                                                    crate::logging::debug(
                                                        "audio status dropped: connection worker queue is full",
                                                    );
                                                    false
                                                }
                                                Err(TrySendError::Disconnected(_)) => false,
                                            }
                                        },
                                    ));
                                }
                            }
                            if clipboard_capabilities.contains(CAPABILITY_FILE_CLIPBOARD)
                                && !send_file_event(
                                    file_events,
                                    FileWorkerEvent::Link { connection_id },
                                )
                            {
                                break 'connected ConnectionExit::Reconnect;
                            }
                            match send_windows_online_if_needed(
                                &mut clipboard_stream,
                                clipboard_capabilities,
                                windows_online_sent,
                            ) {
                                Ok(true) => {
                                    clipboard_health.last_activity = Instant::now();
                                    crate::logging::info("Windows online notification sent");
                                }
                                Ok(false) => {}
                                Err(_) => break 'connected ConnectionExit::Reconnect,
                            }
                            connected_reported = report_connected(
                                hwnd,
                                &address_text,
                                &remote_name,
                                clipboard_health.ready,
                                connected_reported,
                            );
                            negotiated_reported = report_negotiated(
                                clipboard_health.ready,
                                mouse_handshake,
                                mouse_ready,
                                &clipboard_capabilities,
                                mouse_keyboard,
                                directional_mouse_handoff,
                                remote_shutdown,
                                remote_diagnostics,
                                mouse_driver_abi,
                                mouse_display.as_ref(),
                                audio_negotiated,
                                negotiated_reported,
                            );
                        }
                        MessageKind::Text => {
                            if !clipboard_health.ready
                                || !clipboard_capabilities.contains(CAPABILITY_TEXT_CLIPBOARD)
                                || frame.payload.len() > MAX_TEXT_SIZE
                                || std::str::from_utf8(&frame.payload).is_err()
                            {
                                break 'connected ConnectionExit::Reconnect;
                            }
                            post(hwnd, NetworkEvent::Clipboard(frame));
                        }
                        MessageKind::Png => {
                            if !clipboard_health.ready
                                || !clipboard_capabilities.contains(CAPABILITY_PNG_CLIPBOARD)
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
                            clipboard_health.last_activity = Instant::now();
                        }
                        MessageKind::Pong if frame.payload.is_empty() => {
                            clipboard_health.ping_sent = None;
                        }
                        kind if kind.is_file_transfer() => {
                            if !clipboard_health.ready
                                || !clipboard_capabilities.contains(CAPABILITY_FILE_CLIPBOARD)
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
                    remote_diagnostics: negotiated_remote_diagnostics,
                    driver_abi,
                    display,
                } => {
                    if mouse_handshake {
                        break 'connected ConnectionExit::Reconnect;
                    }
                    mouse_handshake = true;
                    mouse_ready = mouse;
                    mouse_keyboard = keyboard;
                    directional_mouse_handoff = negotiated_directional_mouse_handoff;
                    remote_shutdown = negotiated_remote_shutdown;
                    remote_diagnostics = negotiated_remote_diagnostics;
                    mouse_driver_abi = driver_abi;
                    mouse_display = display;
                    connected_reported = report_connected(
                        hwnd,
                        &address_text,
                        &remote_name,
                        clipboard_health.ready,
                        connected_reported,
                    );
                    negotiated_reported = report_negotiated(
                        clipboard_health.ready,
                        mouse_handshake,
                        mouse_ready,
                        &clipboard_capabilities,
                        mouse_keyboard,
                        directional_mouse_handoff,
                        remote_shutdown,
                        remote_diagnostics,
                        mouse_driver_abi,
                        mouse_display.as_ref(),
                        audio_negotiated,
                        negotiated_reported,
                    );
                }
                SessionEvent::Exited => {
                    if mouse_exit_requires_reconnect(&mut mouse_handshake) {
                        break 'connected ConnectionExit::Reconnect;
                    }
                    crate::logging::error("mouse session unavailable before Ready");
                    mouse_ready = false;
                    connected_reported = report_connected(
                        hwnd,
                        &address_text,
                        &remote_name,
                        clipboard_health.ready,
                        connected_reported,
                    );
                    negotiated_reported = report_negotiated(
                        clipboard_health.ready,
                        mouse_handshake,
                        mouse_ready,
                        &clipboard_capabilities,
                        mouse_keyboard,
                        directional_mouse_handoff,
                        remote_shutdown,
                        remote_diagnostics,
                        mouse_driver_abi,
                        mouse_display.as_ref(),
                        audio_negotiated,
                        negotiated_reported,
                    );
                }
            },
            Ok(WorkerEvent::Audio {
                connection_id: event_connection_id,
                status,
            }) if event_connection_id == connection_id => {
                post(hwnd, NetworkEvent::AudioStatus(status));
            }
            Err(RecvTimeoutError::Timeout) => {
                if service_health(&mut clipboard_stream, &mut clipboard_health).is_err() {
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

fn mouse_exit_requires_reconnect(mouse_handshake: &mut bool) -> bool {
    let reconnect = *mouse_handshake;
    *mouse_handshake = true;
    reconnect
}

fn should_report_connected(clipboard_ready: bool, already_reported: bool) -> bool {
    clipboard_ready && !already_reported
}

fn report_connected(
    hwnd: HWND,
    address: &str,
    remote_name: &str,
    clipboard_ready: bool,
    already_reported: bool,
) -> bool {
    if !should_report_connected(clipboard_ready, already_reported) {
        return already_reported;
    }
    post(
        hwnd,
        NetworkEvent::Connected {
            name: if remote_name.is_empty() {
                "Mac".to_string()
            } else {
                remote_name.to_string()
            },
            address: address.to_string(),
        },
    );
    true
}

#[allow(clippy::too_many_arguments)]
fn report_negotiated(
    clipboard_ready: bool,
    mouse_handshake: bool,
    mouse_ready: bool,
    clipboard_capabilities: &Capabilities,
    mouse_keyboard: bool,
    directional_mouse_handoff: bool,
    remote_shutdown: bool,
    remote_diagnostics: bool,
    mouse_driver_abi: u16,
    mouse_display: Option<&DisplayContract>,
    audio_negotiated: bool,
    already_reported: bool,
) -> bool {
    if already_reported || !clipboard_ready || !mouse_handshake {
        return already_reported;
    }
    let display_id = mouse_display.map_or("none", |display| display.monitor_id.as_str());
    let display_device = mouse_display.map_or("none", |display| display.device_name.as_str());
    let screen = mouse_display.map_or_else(
        || "none".to_string(),
        |display| format!("{}x{}", display.screen_width, display.screen_height),
    );
    let content_capabilities = clipboard_capabilities.intersect(Capabilities::from_slice(&[
        CAPABILITY_TEXT_CLIPBOARD,
        CAPABILITY_PNG_CLIPBOARD,
        CAPABILITY_FILE_CLIPBOARD,
    ]));
    crate::logging::info(&format!(
        "Negotiated MENO capabilities: content={} text={} png={} file={} microphone={} windowsOnline={} mouse={} keyboard={} directionalMouseHandoff={} shutdown={} remoteDiagnostics={} driver_abi={} screen={screen} display_id={display_id} display_device={display_device} injection={}",
        !content_capabilities.is_empty(),
        clipboard_capabilities.contains(CAPABILITY_TEXT_CLIPBOARD),
        clipboard_capabilities.contains(CAPABILITY_PNG_CLIPBOARD),
        clipboard_capabilities.contains(CAPABILITY_FILE_CLIPBOARD),
        audio_negotiated,
        clipboard_capabilities.contains(CAPABILITY_WINDOWS_ONLINE_NOTIFICATION),
        mouse_ready,
        mouse_keyboard,
        directional_mouse_handoff,
        remote_shutdown,
        remote_diagnostics,
        mouse_driver_abi,
        if mouse_ready {
            "primary-display"
        } else {
            "none"
        },
    ));
    true
}

fn configure_stream(stream: &TcpStream) -> std::io::Result<()> {
    stream.set_nodelay(true)?;
    stream.set_read_timeout(None)?;
    stream.set_write_timeout(Some(WRITE_TIMEOUT))
}

pub(crate) fn service_health(stream: &mut TcpStream, health: &mut ChannelHealth) -> Result<(), ()> {
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
        Frame::new(MessageKind::Ping, Vec::new())
            .write_to(stream)
            .map_err(|_| ())?;
        health.ping_sent = Some(now);
    }
    Ok(())
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
        let mut before_ready = false;
        assert!(!mouse_exit_requires_reconnect(&mut before_ready));
        assert!(before_ready);
        assert!(should_report_connected(true, false));

        let mut after_ready = true;
        assert!(mouse_exit_requires_reconnect(&mut after_ready));
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
