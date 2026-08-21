use std::io;
use std::net::{Shutdown, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::audio_output::{AudioOutput, OpenError};
use crate::protocol::{
    CAPABILITY_MAC_MICROPHONE, Capabilities, Frame, FrameDecoder, MessageKind, audio_hello,
    parse_hello,
};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
const WRITE_TIMEOUT: Duration = Duration::from_secs(2);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
const FIRST_PCM_TIMEOUT: Duration = Duration::from_secs(5);
const IDLE_BEFORE_PING: Duration = Duration::from_secs(15);
const PONG_TIMEOUT: Duration = Duration::from_secs(5);
const NETWORK_RETRY: Duration = Duration::from_secs(1);
const DEVICE_RETRY: Duration = Duration::from_secs(5);
const DEVICE_POLL: Duration = Duration::from_millis(250);
const PCM_PAYLOAD_BYTES: usize = 1_920;
const PCM_SAMPLES: usize = 960;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AudioStatus {
    Disabled,
    Connecting,
    Available,
    CableMissing,
    ConnectionError,
}

impl AudioStatus {
    pub fn label(&self) -> Option<&'static str> {
        match self {
            Self::Disabled => None,
            Self::Connecting => Some("正在连接麦克风"),
            Self::Available => Some("麦克风可用"),
            Self::CableMissing => Some("未找到 VB-CABLE"),
            Self::ConnectionError => Some("音频连接错误"),
        }
    }
}

pub struct AudioSession {
    stop: Arc<StopState>,
    thread: Option<JoinHandle<()>>,
}

impl AudioSession {
    pub fn spawn(
        endpoint: SocketAddr,
        generation: u64,
        computer_name: String,
        on_status: impl Fn(AudioStatus) -> bool + Send + 'static,
    ) -> Self {
        let stop = Arc::new(StopState::new());
        let thread_stop = stop.clone();
        let thread = thread::spawn(move || {
            run(
                endpoint,
                generation,
                computer_name,
                Box::new(on_status),
                thread_stop,
            )
        });
        Self {
            stop,
            thread: Some(thread),
        }
    }

    pub fn stop(mut self) {
        self.request_stop();
        self.join();
    }

    fn request_stop(&self) {
        self.stop.request();
    }

    fn join(&mut self) {
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for AudioSession {
    fn drop(&mut self) {
        self.request_stop();
        self.join();
    }
}

struct StopState {
    requested: AtomicBool,
    socket: Mutex<Option<TcpStream>>,
    wait_lock: Mutex<()>,
    wake: Condvar,
}

impl StopState {
    fn new() -> Self {
        Self {
            requested: AtomicBool::new(false),
            socket: Mutex::new(None),
            wait_lock: Mutex::new(()),
            wake: Condvar::new(),
        }
    }

    fn requested(&self) -> bool {
        self.requested.load(Ordering::Acquire)
    }

    fn request(&self) {
        self.requested.store(true, Ordering::Release);
        if let Some(socket) = lock(&self.socket).take() {
            let _ = socket.shutdown(Shutdown::Both);
        }
        self.wake.notify_all();
    }

    fn register(&self, stream: &TcpStream) -> io::Result<()> {
        *lock(&self.socket) = Some(stream.try_clone()?);
        Ok(())
    }

    fn clear_socket(&self) {
        *lock(&self.socket) = None;
    }

    fn wait(&self, duration: Duration) -> bool {
        if self.requested() {
            return false;
        }
        let guard = lock(&self.wait_lock);
        let _ = self
            .wake
            .wait_timeout_while(guard, duration, |_| !self.requested())
            .unwrap_or_else(|error| error.into_inner());
        !self.requested()
    }
}

struct StatusReporter {
    last: Option<AudioStatus>,
    callback: Box<dyn Fn(AudioStatus) -> bool + Send>,
}

impl StatusReporter {
    fn set(&mut self, status: AudioStatus) {
        if self.last.as_ref() == Some(&status) {
            return;
        }
        if (self.callback)(status.clone()) {
            self.last = Some(status);
        }
    }
}

fn run(
    endpoint: SocketAddr,
    generation: u64,
    computer_name: String,
    callback: Box<dyn Fn(AudioStatus) -> bool + Send>,
    stop: Arc<StopState>,
) {
    let mut reporter = StatusReporter {
        last: None,
        callback,
    };
    let mut preferred_device_id = None;
    while !stop.requested() {
        let output = match AudioOutput::open(preferred_device_id.as_deref()) {
            Ok(output) => output,
            Err(OpenError::DeviceUnavailable(error)) => {
                crate::logging::error(&format!("audio output unavailable: {error}"));
                reporter.set(AudioStatus::CableMissing);
                if !stop.wait(DEVICE_RETRY) {
                    break;
                }
                continue;
            }
            Err(OpenError::Other(error)) => {
                crate::logging::error(&format!("audio output error: {error}"));
                reporter.set(AudioStatus::ConnectionError);
                if !stop.wait(DEVICE_RETRY) {
                    break;
                }
                continue;
            }
        };
        preferred_device_id = Some(output.device_id.clone());
        reporter.set(AudioStatus::Connecting);

        loop {
            if stop.requested() {
                break;
            }
            if let Some(error) = output.take_device_error() {
                crate::logging::error(&format!("audio device invalidated: {error}"));
                reporter.set(AudioStatus::CableMissing);
                break;
            }
            let mut stream = match TcpStream::connect_timeout(&endpoint, CONNECT_TIMEOUT) {
                Ok(stream) => stream,
                Err(error) => {
                    crate::logging::error(&format!(
                        "audio connection failed: generation={generation} endpoint={endpoint} error={error}"
                    ));
                    reporter.set(AudioStatus::ConnectionError);
                    if !stop.wait(NETWORK_RETRY) {
                        break;
                    }
                    continue;
                }
            };
            if let Err(error) = configure_stream(&stream).and_then(|()| stop.register(&stream)) {
                crate::logging::error(&format!("audio socket setup failed: {error}"));
                let _ = stream.shutdown(Shutdown::Both);
                reporter.set(AudioStatus::ConnectionError);
                if !stop.wait(NETWORK_RETRY) {
                    break;
                }
                continue;
            }
            output.clear();
            let result = run_connected(
                &mut stream,
                &computer_name,
                generation,
                &output,
                &stop,
                &mut reporter,
            );
            stop.clear_socket();
            let _ = stream.shutdown(Shutdown::Both);
            output.clear();
            match result {
                SessionEnd::Stopped => break,
                SessionEnd::Device(error) => {
                    crate::logging::error(&format!("audio device invalidated: {error}"));
                    reporter.set(AudioStatus::CableMissing);
                    break;
                }
                SessionEnd::Network(error) => {
                    crate::logging::error(&format!(
                        "audio session ended: generation={generation} endpoint={endpoint} error={error}"
                    ));
                    reporter.set(AudioStatus::ConnectionError);
                }
            }
            if !stop.wait(NETWORK_RETRY) {
                break;
            }
        }
        output.clear();
        if !stop.requested() && !stop.wait(DEVICE_RETRY) {
            break;
        }
    }
    reporter.set(AudioStatus::Disabled);
}

enum SessionEnd {
    Stopped,
    Device(String),
    Network(String),
}

fn run_connected(
    stream: &mut TcpStream,
    computer_name: &str,
    generation: u64,
    output: &AudioOutput,
    stop: &StopState,
    reporter: &mut StatusReporter,
) -> SessionEnd {
    if let Err(error) = Frame::new(MessageKind::Hello, audio_hello(computer_name)).write_to(stream)
    {
        return SessionEnd::Network(error.to_string());
    }
    let connected_at = Instant::now();
    let mut last_activity = connected_at;
    let mut ping_sent = None;
    let mut ready_at = None;
    let mut pcm_started = false;
    let mut decoder = FrameDecoder::new();
    let mut sequence = SequenceTracker::default();

    loop {
        if stop.requested() {
            return SessionEnd::Stopped;
        }
        if let Some(error) = output.take_device_error() {
            return SessionEnd::Device(error);
        }
        let now = Instant::now();
        let deadline = session_deadline(
            connected_at,
            ready_at,
            pcm_started,
            last_activity,
            ping_sent,
        );
        if now >= deadline {
            if ready_at.is_none() {
                return SessionEnd::Network("audio handshake timed out".into());
            }
            if !pcm_started {
                return SessionEnd::Network("audio PCM did not start within 5 seconds".into());
            }
            if ping_sent.is_some() {
                return SessionEnd::Network("audio Pong timed out".into());
            }
            if let Err(error) = Frame::new(MessageKind::Ping, Vec::new()).write_to(stream) {
                return SessionEnd::Network(error.to_string());
            }
            ping_sent = Some(now);
            continue;
        }
        let poll_deadline = deadline.min(now + DEVICE_POLL);
        if stream
            .set_read_timeout(Some(poll_deadline.saturating_duration_since(now)))
            .is_err()
        {
            return SessionEnd::Network("could not configure audio read timeout".into());
        }
        let frames = match decoder.read_available(stream) {
            Ok(frames) => frames,
            Err(error) => {
                if stop.requested() {
                    return SessionEnd::Stopped;
                }
                return SessionEnd::Network(error.to_string());
            }
        };
        if !frames.is_empty() {
            last_activity = Instant::now();
        }
        for frame in frames {
            if ready_at.is_none() {
                if frame.kind != MessageKind::Ready || !valid_audio_ready(&frame.payload) {
                    return SessionEnd::Network("invalid audio Ready".into());
                }
                let now = Instant::now();
                ready_at = Some(now);
                last_activity = now;
                continue;
            }
            match frame.kind {
                MessageKind::MicrophonePcm => {
                    let skipped = match sequence.accept(frame.message_id) {
                        Ok(skipped) => skipped,
                        Err(error) => return SessionEnd::Network(error),
                    };
                    if skipped != 0 {
                        crate::logging::error(&format!(
                            "audio sequence gap: generation={generation} skipped={skipped} received={}",
                            frame.message_id
                        ));
                    }
                    let samples = match decode_pcm(&frame.payload) {
                        Ok(samples) => samples,
                        Err(error) => return SessionEnd::Network(error),
                    };
                    output.push(&samples);
                    if !pcm_started {
                        pcm_started = true;
                    }
                    // Retry until the bounded UI queue accepts this transition;
                    // StatusReporter coalesces every later frame after delivery.
                    reporter.set(AudioStatus::Available);
                    if frame.message_id == u64::MAX {
                        return SessionEnd::Network("audio sequence reached UInt64 maximum".into());
                    }
                }
                MessageKind::Ping if frame.payload.is_empty() => {
                    if let Err(error) = Frame::new(MessageKind::Pong, Vec::new()).write_to(stream) {
                        return SessionEnd::Network(error.to_string());
                    }
                }
                MessageKind::Pong if frame.payload.is_empty() => {
                    ping_sent = None;
                }
                _ => return SessionEnd::Network("message is not allowed on audio channel".into()),
            }
        }
    }
}

fn session_deadline(
    connected_at: Instant,
    ready_at: Option<Instant>,
    pcm_started: bool,
    last_activity: Instant,
    ping_sent: Option<Instant>,
) -> Instant {
    match ready_at {
        None => connected_at + HANDSHAKE_TIMEOUT,
        Some(ready_at) if !pcm_started => ready_at + FIRST_PCM_TIMEOUT,
        Some(_) => ping_sent.map_or(last_activity + IDLE_BEFORE_PING, |sent| sent + PONG_TIMEOUT),
    }
}

fn valid_audio_ready(payload: &[u8]) -> bool {
    let Ok(hello) = parse_hello(payload) else {
        return false;
    };
    !hello.name.is_empty()
        && hello.capabilities == Capabilities::from_slice(&[CAPABILITY_MAC_MICROPHONE])
        && hello.audio_port.is_none()
        && hello.driver_abi.is_none()
        && hello.screen_width.is_none()
        && hello.screen_height.is_none()
}

#[derive(Default)]
struct SequenceTracker {
    last: u64,
}

impl SequenceTracker {
    fn accept(&mut self, value: u64) -> Result<u64, String> {
        if value == 0 {
            return Err("audio sequence must be non-zero".into());
        }
        if self.last == 0 {
            if value != 1 {
                return Err("first audio sequence must be one".into());
            }
            self.last = value;
            return Ok(0);
        }
        if value <= self.last {
            return Err("audio sequence repeated or moved backwards".into());
        }
        let skipped = value - self.last - 1;
        self.last = value;
        Ok(skipped)
    }
}

fn decode_pcm(payload: &[u8]) -> Result<[i16; PCM_SAMPLES], String> {
    if payload.len() != PCM_PAYLOAD_BYTES {
        return Err("microphone PCM payload must be 1920 bytes".into());
    }
    let mut samples = [0_i16; PCM_SAMPLES];
    for (sample, bytes) in samples.iter_mut().zip(payload.chunks_exact(2)) {
        *sample = i16::from_be_bytes([bytes[0], bytes[1]]);
    }
    Ok(samples)
}

fn configure_stream(stream: &TcpStream) -> io::Result<()> {
    stream.set_nodelay(true)?;
    stream.set_write_timeout(Some(WRITE_TIMEOUT))
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::CAPABILITY_TEXT_CLIPBOARD;
    use std::sync::atomic::AtomicU64;

    #[test]
    fn pcm_is_exactly_960_big_endian_i16_samples() {
        let mut payload = vec![0_u8; PCM_PAYLOAD_BYTES];
        payload[0..2].copy_from_slice(&(-32_768_i16).to_be_bytes());
        payload[2..4].copy_from_slice(&1234_i16.to_be_bytes());
        let samples = decode_pcm(&payload).unwrap();
        assert_eq!(samples[0], -32_768);
        assert_eq!(samples[1], 1234);
        assert!(decode_pcm(&payload[..PCM_PAYLOAD_BYTES - 1]).is_err());
    }

    #[test]
    fn sequence_starts_at_one_rejects_replays_and_counts_gaps() {
        for first in [0, 2] {
            assert!(SequenceTracker::default().accept(first).is_err());
        }
        let mut sequence = SequenceTracker::default();
        assert_eq!(sequence.accept(1), Ok(0));
        assert_eq!(sequence.accept(2), Ok(0));
        assert_eq!(sequence.accept(5), Ok(2));
        assert!(sequence.accept(5).is_err());
        assert!(sequence.accept(4).is_err());
    }

    #[test]
    fn deadline_requires_handshake_then_real_pcm_before_keepalive() {
        let connected_at = Instant::now();
        let ready_at = connected_at + Duration::from_secs(1);
        let last_activity = ready_at + Duration::from_secs(2);
        let ping_sent = last_activity + Duration::from_secs(3);

        assert_eq!(
            session_deadline(connected_at, None, false, last_activity, None),
            connected_at + HANDSHAKE_TIMEOUT
        );
        assert_eq!(
            session_deadline(
                connected_at,
                Some(ready_at),
                false,
                last_activity,
                Some(ping_sent)
            ),
            ready_at + FIRST_PCM_TIMEOUT
        );
        assert_eq!(
            session_deadline(connected_at, Some(ready_at), true, last_activity, None),
            last_activity + IDLE_BEFORE_PING
        );
        assert_eq!(
            session_deadline(
                connected_at,
                Some(ready_at),
                true,
                last_activity,
                Some(ping_sent)
            ),
            ping_sent + PONG_TIMEOUT
        );
    }

    #[test]
    fn audio_ready_requires_only_microphone_capability_and_no_port() {
        assert!(valid_audio_ready(&audio_hello("Mac")));

        let mut with_port = audio_hello("Mac");
        with_port.extend_from_slice(&[6, 0, 2, 0xBE, 0xEF]);
        assert!(!valid_audio_ready(&with_port));
        assert!(!valid_audio_ready(&[2, 0, 2, 0, 8]));

        let mut with_other = audio_hello("Mac");
        let capability_offset = with_other
            .windows(3)
            .position(|bytes| bytes == [2, 0, 2])
            .unwrap();
        with_other[capability_offset + 2] = 4;
        with_other.extend_from_slice(&CAPABILITY_TEXT_CLIPBOARD.to_be_bytes());
        assert!(!valid_audio_ready(&with_other));
    }

    #[test]
    fn dropped_status_is_retried_but_delivered_status_is_coalesced() {
        let attempts = Arc::new(AtomicU64::new(0));
        let counted = attempts.clone();
        let mut dropped = StatusReporter {
            last: None,
            callback: Box::new(move |_| {
                counted.fetch_add(1, Ordering::Relaxed);
                false
            }),
        };
        dropped.set(AudioStatus::CableMissing);
        dropped.set(AudioStatus::CableMissing);
        assert_eq!(attempts.load(Ordering::Relaxed), 2);

        let attempts = Arc::new(AtomicU64::new(0));
        let counted = attempts.clone();
        let mut delivered = StatusReporter {
            last: None,
            callback: Box::new(move |_| {
                counted.fetch_add(1, Ordering::Relaxed);
                true
            }),
        };
        delivered.set(AudioStatus::Available);
        delivered.set(AudioStatus::Available);
        assert_eq!(attempts.load(Ordering::Relaxed), 1);
    }
}
