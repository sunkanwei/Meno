use std::collections::VecDeque;
use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, SyncSender, TrySendError};
use std::sync::{Arc, OnceLock};
use std::thread;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, SM_CXSCREEN, SM_CXVIRTUALSCREEN, SM_CYSCREEN, SM_CYVIRTUALSCREEN,
    SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};
use windows::core::GUID;

use crate::protocol::Frame;

pub const MAX_DIAGNOSTIC_PAYLOAD: usize = 2_048;
pub const DIAGNOSTIC_CACHE_CAPACITY: usize = 256;
pub const MAX_RECENT_MOTION_SAMPLES: usize = 16;

const DIAGNOSTIC_HEADER_SIZE: usize = 26;
const DIAGNOSTIC_COMMAND_CAPACITY: usize = 512;
const FLAG_REPLAYED: u8 = 1;

const FIELD_STATE_BEFORE: u8 = 1;
const FIELD_STATE_AFTER: u8 = 2;
const FIELD_REASON: u8 = 3;
const FIELD_CURSOR_X: u8 = 4;
const FIELD_CURSOR_Y: u8 = 5;
const FIELD_DELTA_X: u8 = 6;
const FIELD_DELTA_Y: u8 = 7;
const FIELD_BOUNDARY: u8 = 8;
const FIELD_THRESHOLD: u8 = 9;
const FIELD_DRIVER_STATUS: u8 = 10;
const FIELD_QUEUE_DEPTH: u8 = 11;
const FIELD_PROCESS_RUN_ID: u8 = 12;
const FIELD_EXECUTABLE_VERSION: u8 = 13;
const FIELD_BUILD_ID: u8 = 14;
const FIELD_VIRTUAL_DESKTOP_BOUNDS: u8 = 15;
const FIELD_MONITOR_BOUNDS: u8 = 16;
const FIELD_INPUT_SOURCE: u8 = 17;
const FIELD_RECENT_MOTION_SAMPLES: u8 = 18;

pub const DRIVER_STATUS_UNAVAILABLE: u8 = 0;
pub const DRIVER_STATUS_AVAILABLE: u8 = 1;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum DiagnosticEventKind {
    ProcessStarted = 1,
    ConnectionReady = 2,
    ControlEnterReceived = 3,
    ControlAcquired = 4,
    LeaveDecision = 5,
    ControlReleased = 6,
    HeartbeatExpired = 7,
    DriverUnavailable = 8,
    ConnectionClosed = 9,
    ReplayComplete = 10,
}

impl TryFrom<u8> for DiagnosticEventKind {
    type Error = ();

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::ProcessStarted),
            2 => Ok(Self::ConnectionReady),
            3 => Ok(Self::ControlEnterReceived),
            4 => Ok(Self::ControlAcquired),
            5 => Ok(Self::LeaveDecision),
            6 => Ok(Self::ControlReleased),
            7 => Ok(Self::HeartbeatExpired),
            8 => Ok(Self::DriverUnavailable),
            9 => Ok(Self::ConnectionClosed),
            10 => Ok(Self::ReplayComplete),
            _ => Err(()),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum DiagnosticState {
    Unknown = 0,
    Local = 1,
    Acquiring = 2,
    Remote = 3,
    Releasing = 4,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u16)]
pub enum DiagnosticReason {
    CrossedReturnEdge = 1,
    ReleaseRequest = 2,
    HeartbeatExpired = 3,
    ConnectionClosed = 4,
    DriverFailure = 5,
    LocalInputOverride = 6,
    ProcessExit = 7,
    StaleControl = 8,
    InvalidState = 9,
    Unknown = 10,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DiagnosticBounds {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DiagnosticMotionSample {
    pub age_micros: u32,
    pub cursor_x: i32,
    pub cursor_y: i32,
    pub delta_x: i16,
    pub delta_y: i16,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DiagnosticField {
    StateBefore(u8),
    StateAfter(u8),
    Reason(u16),
    CursorX(i32),
    CursorY(i32),
    DeltaX(i32),
    DeltaY(i32),
    Boundary(u8),
    Threshold(i32),
    DriverStatus(u8),
    QueueDepth(u16),
    ProcessRunId([u8; 16]),
    ExecutableVersion(String),
    BuildId(String),
    VirtualDesktopBounds(DiagnosticBounds),
    MonitorBounds(DiagnosticBounds),
    InputSource(u8),
    RecentMotionSamples(Vec<DiagnosticMotionSample>),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DiagnosticEvent {
    pub kind: DiagnosticEventKind,
    pub flags: u8,
    pub source_sequence: u64,
    pub source_uptime_micros: u64,
    pub control_id: u64,
    pub fields: Vec<DiagnosticField>,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct DiagnosticIdentity {
    pub process_run_id: [u8; 16],
    pub source_sequence: u64,
}

impl DiagnosticEvent {
    pub fn identity(&self) -> Option<DiagnosticIdentity> {
        self.fields.iter().find_map(|field| match field {
            DiagnosticField::ProcessRunId(process_run_id) => Some(DiagnosticIdentity {
                process_run_id: *process_run_id,
                source_sequence: self.source_sequence,
            }),
            _ => None,
        })
    }
}

pub fn encode_diagnostic_event(event: &DiagnosticEvent) -> Result<Vec<u8>, String> {
    if event.flags & !FLAG_REPLAYED != 0 {
        return Err("diagnostic flags contain reserved bits".to_string());
    }
    let mut output = Vec::with_capacity(256);
    output.push(event.kind as u8);
    output.push(event.flags);
    output.extend_from_slice(&event.source_sequence.to_be_bytes());
    output.extend_from_slice(&event.source_uptime_micros.to_be_bytes());
    output.extend_from_slice(&event.control_id.to_be_bytes());
    for field in &event.fields {
        let (field_id, value) = encode_field(field)?;
        let length =
            u16::try_from(value.len()).map_err(|_| "diagnostic field is too large".to_string())?;
        if output.len() + 3 + value.len() > MAX_DIAGNOSTIC_PAYLOAD {
            return Err("diagnostic payload is too large".to_string());
        }
        output.push(field_id);
        output.extend_from_slice(&length.to_be_bytes());
        output.extend_from_slice(&value);
    }
    Ok(output)
}

pub fn decode_diagnostic_event(payload: &[u8]) -> Result<Option<DiagnosticEvent>, String> {
    if payload.len() > MAX_DIAGNOSTIC_PAYLOAD {
        return Err("diagnostic payload is too large".to_string());
    }
    if payload.len() < DIAGNOSTIC_HEADER_SIZE {
        return Err("diagnostic payload is truncated".to_string());
    }
    let flags = payload[1];
    if flags & !FLAG_REPLAYED != 0 {
        return Err("diagnostic flags contain reserved bits".to_string());
    }
    let Ok(kind) = DiagnosticEventKind::try_from(payload[0]) else {
        return Ok(None);
    };
    let source_sequence = u64::from_be_bytes(payload[2..10].try_into().unwrap());
    let source_uptime_micros = u64::from_be_bytes(payload[10..18].try_into().unwrap());
    let control_id = u64::from_be_bytes(payload[18..26].try_into().unwrap());
    let mut fields = Vec::new();
    let mut offset = DIAGNOSTIC_HEADER_SIZE;
    while offset < payload.len() {
        if payload.len() - offset < 3 {
            return Err("diagnostic field is truncated".to_string());
        }
        let field_id = payload[offset];
        let length = u16::from_be_bytes([payload[offset + 1], payload[offset + 2]]) as usize;
        let end = offset + 3 + length;
        if end > payload.len() {
            return Err("diagnostic field value is truncated".to_string());
        }
        if let Some(field) = decode_field(field_id, &payload[offset + 3..end])? {
            fields.push(field);
        }
        offset = end;
    }
    Ok(Some(DiagnosticEvent {
        kind,
        flags,
        source_sequence,
        source_uptime_micros,
        control_id,
        fields,
    }))
}

fn encode_field(field: &DiagnosticField) -> Result<(u8, Vec<u8>), String> {
    let encoded = match field {
        DiagnosticField::StateBefore(value) => (FIELD_STATE_BEFORE, vec![*value]),
        DiagnosticField::StateAfter(value) => (FIELD_STATE_AFTER, vec![*value]),
        DiagnosticField::Reason(value) => (FIELD_REASON, value.to_be_bytes().to_vec()),
        DiagnosticField::CursorX(value) => (FIELD_CURSOR_X, value.to_be_bytes().to_vec()),
        DiagnosticField::CursorY(value) => (FIELD_CURSOR_Y, value.to_be_bytes().to_vec()),
        DiagnosticField::DeltaX(value) => (FIELD_DELTA_X, value.to_be_bytes().to_vec()),
        DiagnosticField::DeltaY(value) => (FIELD_DELTA_Y, value.to_be_bytes().to_vec()),
        DiagnosticField::Boundary(value) => (FIELD_BOUNDARY, vec![*value]),
        DiagnosticField::Threshold(value) => (FIELD_THRESHOLD, value.to_be_bytes().to_vec()),
        DiagnosticField::DriverStatus(value) => (FIELD_DRIVER_STATUS, vec![*value]),
        DiagnosticField::QueueDepth(value) => (FIELD_QUEUE_DEPTH, value.to_be_bytes().to_vec()),
        DiagnosticField::ProcessRunId(value) => (FIELD_PROCESS_RUN_ID, value.to_vec()),
        DiagnosticField::ExecutableVersion(value) => {
            if value.len() > 64 {
                return Err("diagnostic executable version is too large".to_string());
            }
            (FIELD_EXECUTABLE_VERSION, value.as_bytes().to_vec())
        }
        DiagnosticField::BuildId(value) => {
            if value.len() > 64 {
                return Err("diagnostic build id is too large".to_string());
            }
            (FIELD_BUILD_ID, value.as_bytes().to_vec())
        }
        DiagnosticField::VirtualDesktopBounds(value) => {
            (FIELD_VIRTUAL_DESKTOP_BOUNDS, encode_bounds(*value))
        }
        DiagnosticField::MonitorBounds(value) => (FIELD_MONITOR_BOUNDS, encode_bounds(*value)),
        DiagnosticField::InputSource(value) => (FIELD_INPUT_SOURCE, vec![*value]),
        DiagnosticField::RecentMotionSamples(samples) => {
            if samples.len() > MAX_RECENT_MOTION_SAMPLES {
                return Err("diagnostic motion history is too large".to_string());
            }
            let mut value = Vec::with_capacity(samples.len() * 16);
            for sample in samples {
                value.extend_from_slice(&sample.age_micros.to_be_bytes());
                value.extend_from_slice(&sample.cursor_x.to_be_bytes());
                value.extend_from_slice(&sample.cursor_y.to_be_bytes());
                value.extend_from_slice(&sample.delta_x.to_be_bytes());
                value.extend_from_slice(&sample.delta_y.to_be_bytes());
            }
            (FIELD_RECENT_MOTION_SAMPLES, value)
        }
    };
    Ok(encoded)
}

fn decode_field(field_id: u8, value: &[u8]) -> Result<Option<DiagnosticField>, String> {
    let invalid = || Err(format!("invalid diagnostic field {field_id}"));
    let field = match field_id {
        FIELD_STATE_BEFORE if value.len() == 1 => DiagnosticField::StateBefore(value[0]),
        FIELD_STATE_AFTER if value.len() == 1 => DiagnosticField::StateAfter(value[0]),
        FIELD_REASON if value.len() == 2 => {
            DiagnosticField::Reason(u16::from_be_bytes(value.try_into().unwrap()))
        }
        FIELD_CURSOR_X if value.len() == 4 => {
            DiagnosticField::CursorX(i32::from_be_bytes(value.try_into().unwrap()))
        }
        FIELD_CURSOR_Y if value.len() == 4 => {
            DiagnosticField::CursorY(i32::from_be_bytes(value.try_into().unwrap()))
        }
        FIELD_DELTA_X if value.len() == 4 => {
            DiagnosticField::DeltaX(i32::from_be_bytes(value.try_into().unwrap()))
        }
        FIELD_DELTA_Y if value.len() == 4 => {
            DiagnosticField::DeltaY(i32::from_be_bytes(value.try_into().unwrap()))
        }
        FIELD_BOUNDARY if value.len() == 1 => DiagnosticField::Boundary(value[0]),
        FIELD_THRESHOLD if value.len() == 4 => {
            DiagnosticField::Threshold(i32::from_be_bytes(value.try_into().unwrap()))
        }
        FIELD_DRIVER_STATUS if value.len() == 1 => DiagnosticField::DriverStatus(value[0]),
        FIELD_QUEUE_DEPTH if value.len() == 2 => {
            DiagnosticField::QueueDepth(u16::from_be_bytes(value.try_into().unwrap()))
        }
        FIELD_PROCESS_RUN_ID if value.len() == 16 => {
            DiagnosticField::ProcessRunId(value.try_into().unwrap())
        }
        FIELD_EXECUTABLE_VERSION if value.len() <= 64 => DiagnosticField::ExecutableVersion(
            std::str::from_utf8(value)
                .map_err(|_| "invalid diagnostic executable version".to_string())?
                .to_string(),
        ),
        FIELD_BUILD_ID if value.len() <= 64 => DiagnosticField::BuildId(
            std::str::from_utf8(value)
                .map_err(|_| "invalid diagnostic build id".to_string())?
                .to_string(),
        ),
        FIELD_VIRTUAL_DESKTOP_BOUNDS if value.len() == 16 => {
            DiagnosticField::VirtualDesktopBounds(decode_bounds(value))
        }
        FIELD_MONITOR_BOUNDS if value.len() == 16 => {
            DiagnosticField::MonitorBounds(decode_bounds(value))
        }
        FIELD_INPUT_SOURCE if value.len() == 1 => DiagnosticField::InputSource(value[0]),
        FIELD_RECENT_MOTION_SAMPLES
            if value.len().is_multiple_of(16) && value.len() / 16 <= MAX_RECENT_MOTION_SAMPLES =>
        {
            DiagnosticField::RecentMotionSamples(
                value
                    .chunks_exact(16)
                    .map(|sample| DiagnosticMotionSample {
                        age_micros: u32::from_be_bytes(sample[0..4].try_into().unwrap()),
                        cursor_x: i32::from_be_bytes(sample[4..8].try_into().unwrap()),
                        cursor_y: i32::from_be_bytes(sample[8..12].try_into().unwrap()),
                        delta_x: i16::from_be_bytes(sample[12..14].try_into().unwrap()),
                        delta_y: i16::from_be_bytes(sample[14..16].try_into().unwrap()),
                    })
                    .collect(),
            )
        }
        1..=18 => return invalid(),
        _ => return Ok(None),
    };
    Ok(Some(field))
}

fn encode_bounds(bounds: DiagnosticBounds) -> Vec<u8> {
    let mut output = Vec::with_capacity(16);
    output.extend_from_slice(&bounds.x.to_be_bytes());
    output.extend_from_slice(&bounds.y.to_be_bytes());
    output.extend_from_slice(&bounds.width.to_be_bytes());
    output.extend_from_slice(&bounds.height.to_be_bytes());
    output
}

fn decode_bounds(value: &[u8]) -> DiagnosticBounds {
    DiagnosticBounds {
        x: i32::from_be_bytes(value[0..4].try_into().unwrap()),
        y: i32::from_be_bytes(value[4..8].try_into().unwrap()),
        width: i32::from_be_bytes(value[8..12].try_into().unwrap()),
        height: i32::from_be_bytes(value[12..16].try_into().unwrap()),
    }
}

#[derive(Debug)]
pub struct DiagnosticRecord {
    event: DiagnosticEvent,
    payload: Vec<u8>,
}

impl DiagnosticRecord {
    pub fn event(&self) -> &DiagnosticEvent {
        &self.event
    }

    pub fn payload(&self, replayed: bool) -> Vec<u8> {
        let mut payload = self.payload.clone();
        if replayed {
            payload[1] |= FLAG_REPLAYED;
        }
        payload
    }
}

struct DiagnosticSource {
    process_run_id: [u8; 16],
    started: Instant,
    next_sequence: AtomicU64,
}

impl DiagnosticSource {
    fn new() -> Self {
        Self {
            process_run_id: process_run_id(),
            started: Instant::now(),
            next_sequence: AtomicU64::new(1),
        }
    }

    fn prepare(
        &self,
        kind: DiagnosticEventKind,
        control_id: u64,
        mut fields: Vec<DiagnosticField>,
    ) -> Result<Arc<DiagnosticRecord>, String> {
        fields.insert(
            0,
            DiagnosticField::BuildId(
                option_env!("MENO_BUILD_ID")
                    .unwrap_or(env!("CARGO_PKG_VERSION"))
                    .to_string(),
            ),
        );
        fields.insert(
            0,
            DiagnosticField::ExecutableVersion(env!("CARGO_PKG_VERSION").to_string()),
        );
        fields.insert(0, DiagnosticField::ProcessRunId(self.process_run_id));
        let event = DiagnosticEvent {
            kind,
            flags: 0,
            source_sequence: self.next_sequence.fetch_add(1, Ordering::Relaxed),
            source_uptime_micros: self.started.elapsed().as_micros().min(u64::MAX as u128) as u64,
            control_id,
            fields,
        };
        let payload = encode_diagnostic_event(&event)?;
        Ok(Arc::new(DiagnosticRecord { event, payload }))
    }
}

fn process_run_id() -> [u8; 16] {
    if let Ok(guid) = GUID::new() {
        return guid.to_u128().to_be_bytes();
    }
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());
    let mut bytes = (nanos ^ (u128::from(std::process::id()) << 64)).to_be_bytes();
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    bytes
}

pub trait DiagnosticTransport: Send + Sync {
    fn try_send_diagnostic(&self, record: Arc<DiagnosticRecord>, replayed: bool) -> bool;
    fn send_control(&self, frame: Frame) -> io::Result<()>;
}

struct ConnectionTransport {
    connection_id: u64,
    transport: Arc<dyn DiagnosticTransport>,
}

struct DiagnosticStore {
    cache: VecDeque<Arc<DiagnosticRecord>>,
    connection: Option<ConnectionTransport>,
}

impl DiagnosticStore {
    fn new() -> Self {
        Self {
            cache: VecDeque::with_capacity(DIAGNOSTIC_CACHE_CAPACITY),
            connection: None,
        }
    }

    fn cache(&mut self, record: Arc<DiagnosticRecord>) {
        if self.cache.len() == DIAGNOSTIC_CACHE_CAPACITY {
            self.cache.pop_front();
        }
        self.cache.push_back(record);
    }

    fn record(&mut self, record: Arc<DiagnosticRecord>) {
        self.cache(record.clone());
        if let Some(connection) = &self.connection
            && !connection.transport.try_send_diagnostic(record, false)
        {
            crate::logging::debug("diagnostic event dropped: outbound queue is full");
        }
    }

    fn attach(
        &mut self,
        negotiated: bool,
        connection_id: u64,
        transport: Arc<dyn DiagnosticTransport>,
        replay_complete: Arc<DiagnosticRecord>,
        connection_ready: Arc<DiagnosticRecord>,
    ) {
        if !negotiated {
            return;
        }
        self.connection = None;
        for record in &self.cache {
            if !transport.try_send_diagnostic(record.clone(), true) {
                crate::logging::debug("diagnostic replay truncated: outbound queue is full");
                break;
            }
        }
        let _ = transport.try_send_diagnostic(replay_complete, false);
        self.connection = Some(ConnectionTransport {
            connection_id,
            transport,
        });
        self.record(connection_ready);
    }

    fn close(&mut self, connection_id: u64, record: Arc<DiagnosticRecord>) {
        self.record(record);
        if self
            .connection
            .as_ref()
            .is_some_and(|connection| connection.connection_id == connection_id)
        {
            self.connection = None;
        }
    }

    fn record_then_control(
        &mut self,
        connection_id: u64,
        record: Arc<DiagnosticRecord>,
        transport: Arc<dyn DiagnosticTransport>,
        frame: Frame,
    ) -> io::Result<()> {
        self.cache(record.clone());
        if self
            .connection
            .as_ref()
            .is_some_and(|connection| connection.connection_id == connection_id)
        {
            let _ = transport.try_send_diagnostic(record, false);
        }
        transport.send_control(frame)
    }
}

enum DiagnosticCommand {
    Record(Arc<DiagnosticRecord>),
    Attach {
        connection_id: u64,
        transport: Arc<dyn DiagnosticTransport>,
        replay_complete: Arc<DiagnosticRecord>,
        connection_ready: Arc<DiagnosticRecord>,
    },
    Close {
        connection_id: u64,
        record: Arc<DiagnosticRecord>,
        completed: SyncSender<()>,
    },
    RecordThenControl {
        connection_id: u64,
        record: Arc<DiagnosticRecord>,
        transport: Arc<dyn DiagnosticTransport>,
        frame: Frame,
        completed: SyncSender<io::Result<()>>,
    },
}

struct DiagnosticHub {
    source: Arc<DiagnosticSource>,
    commands: SyncSender<DiagnosticCommand>,
}

static HUB: OnceLock<DiagnosticHub> = OnceLock::new();

pub fn initialize() {
    if HUB.get().is_some() {
        return;
    }
    let source = Arc::new(DiagnosticSource::new());
    let (commands, receiver) = mpsc::sync_channel(DIAGNOSTIC_COMMAND_CAPACITY);
    thread::spawn(move || {
        let mut store = DiagnosticStore::new();
        while let Ok(command) = receiver.recv() {
            match command {
                DiagnosticCommand::Record(record) => store.record(record),
                DiagnosticCommand::Attach {
                    connection_id,
                    transport,
                    replay_complete,
                    connection_ready,
                } => store.attach(
                    true,
                    connection_id,
                    transport,
                    replay_complete,
                    connection_ready,
                ),
                DiagnosticCommand::Close {
                    connection_id,
                    record,
                    completed,
                } => {
                    store.close(connection_id, record);
                    let _ = completed.send(());
                }
                DiagnosticCommand::RecordThenControl {
                    connection_id,
                    record,
                    transport,
                    frame,
                    completed,
                } => {
                    let result = store.record_then_control(connection_id, record, transport, frame);
                    let _ = completed.send(result);
                }
            }
        }
    });
    if HUB.set(DiagnosticHub { source, commands }).is_err() {
        return;
    }
    let mut fields = vec![
        DiagnosticField::StateBefore(DiagnosticState::Unknown as u8),
        DiagnosticField::StateAfter(DiagnosticState::Local as u8),
    ];
    if let Some(bounds) = virtual_desktop_bounds() {
        fields.push(DiagnosticField::VirtualDesktopBounds(bounds));
    }
    if let Some(bounds) = primary_monitor_bounds() {
        fields.push(DiagnosticField::MonitorBounds(bounds));
    }
    record(DiagnosticEventKind::ProcessStarted, 0, fields);
}

pub fn prepare(
    kind: DiagnosticEventKind,
    control_id: u64,
    fields: Vec<DiagnosticField>,
) -> Option<Arc<DiagnosticRecord>> {
    let hub = HUB.get()?;
    match hub.source.prepare(kind, control_id, fields) {
        Ok(record) => Some(record),
        Err(error) => {
            crate::logging::error(&format!("diagnostic event encoding failed: {error}"));
            None
        }
    }
}

pub fn record(kind: DiagnosticEventKind, control_id: u64, fields: Vec<DiagnosticField>) -> bool {
    let Some(record) = prepare(kind, control_id, fields) else {
        return false;
    };
    submit(record)
}

pub fn submit(record: Arc<DiagnosticRecord>) -> bool {
    let Some(hub) = HUB.get() else {
        return false;
    };
    match hub.commands.try_send(DiagnosticCommand::Record(record)) {
        Ok(()) => true,
        Err(TrySendError::Full(_)) => {
            crate::logging::debug("diagnostic event dropped: cache queue is full");
            false
        }
        Err(TrySendError::Disconnected(_)) => false,
    }
}

pub fn attach(
    connection_id: u64,
    transport: Arc<dyn DiagnosticTransport>,
    connection_fields: Vec<DiagnosticField>,
) -> bool {
    let Some(replay_complete) = prepare(DiagnosticEventKind::ReplayComplete, 0, Vec::new()) else {
        return false;
    };
    let Some(connection_ready) =
        prepare(DiagnosticEventKind::ConnectionReady, 0, connection_fields)
    else {
        return false;
    };
    let Some(hub) = HUB.get() else {
        return false;
    };
    match hub.commands.try_send(DiagnosticCommand::Attach {
        connection_id,
        transport,
        replay_complete,
        connection_ready,
    }) {
        Ok(()) => true,
        Err(TrySendError::Full(_)) => {
            crate::logging::debug("diagnostic replay skipped: cache queue is full");
            false
        }
        Err(TrySendError::Disconnected(_)) => false,
    }
}

pub fn close(connection_id: u64, control_id: u64, fields: Vec<DiagnosticField>) {
    let Some(record) = prepare(DiagnosticEventKind::ConnectionClosed, control_id, fields) else {
        return;
    };
    let Some(hub) = HUB.get() else {
        return;
    };
    let (completed, wait) = mpsc::sync_channel(1);
    match hub.commands.try_send(DiagnosticCommand::Close {
        connection_id,
        record: record.clone(),
        completed,
    }) {
        Ok(()) => {
            let _ = wait.recv();
        }
        Err(TrySendError::Full(_)) => {
            let _ = submit(record);
        }
        Err(TrySendError::Disconnected(_)) => {}
    }
}

pub fn record_before_control(
    connection_id: u64,
    record: Arc<DiagnosticRecord>,
    transport: Arc<dyn DiagnosticTransport>,
    frame: Frame,
) -> Option<io::Result<()>> {
    let hub = HUB.get()?;
    let (completed, wait) = mpsc::sync_channel(1);
    match hub.commands.try_send(DiagnosticCommand::RecordThenControl {
        connection_id,
        record,
        transport,
        frame,
        completed,
    }) {
        Ok(()) => Some(wait.recv().unwrap_or_else(|_| {
            Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "diagnostic worker stopped before control write",
            ))
        })),
        Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => None,
    }
}

pub fn virtual_desktop_bounds() -> Option<DiagnosticBounds> {
    let bounds = DiagnosticBounds {
        x: unsafe { GetSystemMetrics(SM_XVIRTUALSCREEN) },
        y: unsafe { GetSystemMetrics(SM_YVIRTUALSCREEN) },
        width: unsafe { GetSystemMetrics(SM_CXVIRTUALSCREEN) },
        height: unsafe { GetSystemMetrics(SM_CYVIRTUALSCREEN) },
    };
    (bounds.width > 0 && bounds.height > 0).then_some(bounds)
}

pub fn primary_monitor_bounds() -> Option<DiagnosticBounds> {
    let bounds = DiagnosticBounds {
        x: 0,
        y: 0,
        width: unsafe { GetSystemMetrics(SM_CXSCREEN) },
        height: unsafe { GetSystemMetrics(SM_CYSCREEN) },
    };
    (bounds.width > 0 && bounds.height > 0).then_some(bounds)
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicBool, Ordering};

    use crate::protocol::{Frame, MessageKind};

    use super::*;

    #[derive(Clone, Debug, Eq, PartialEq)]
    enum Sent {
        Diagnostic {
            kind: DiagnosticEventKind,
            sequence: u64,
            replayed: bool,
        },
        Control(MessageKind),
    }

    struct FakeTransport {
        sent: Mutex<Vec<Sent>>,
        fail_diagnostic: AtomicBool,
    }

    impl FakeTransport {
        fn new() -> Self {
            Self {
                sent: Mutex::new(Vec::new()),
                fail_diagnostic: AtomicBool::new(false),
            }
        }

        fn take(&self) -> Vec<Sent> {
            std::mem::take(&mut *self.sent.lock().unwrap())
        }
    }

    impl DiagnosticTransport for FakeTransport {
        fn try_send_diagnostic(&self, record: Arc<DiagnosticRecord>, replayed: bool) -> bool {
            if self.fail_diagnostic.load(Ordering::Relaxed) {
                return false;
            }
            self.sent.lock().unwrap().push(Sent::Diagnostic {
                kind: record.event().kind,
                sequence: record.event().source_sequence,
                replayed,
            });
            true
        }

        fn send_control(&self, frame: Frame) -> io::Result<()> {
            self.sent.lock().unwrap().push(Sent::Control(frame.kind));
            Ok(())
        }
    }

    fn prepared(source: &DiagnosticSource, kind: DiagnosticEventKind) -> Arc<DiagnosticRecord> {
        source.prepare(kind, 0, Vec::new()).unwrap()
    }

    #[test]
    fn old_peer_without_negotiation_receives_no_diagnostics() {
        let source = DiagnosticSource::new();
        let transport = Arc::new(FakeTransport::new());
        let mut store = DiagnosticStore::new();
        store.attach(
            false,
            1,
            transport.clone(),
            prepared(&source, DiagnosticEventKind::ReplayComplete),
            prepared(&source, DiagnosticEventKind::ConnectionReady),
        );

        store.record(prepared(&source, DiagnosticEventKind::ControlEnterReceived));

        assert!(transport.take().is_empty());
        assert_eq!(store.cache.len(), 1);
    }

    #[test]
    fn cache_is_bounded_and_replay_preserves_sequence_with_flag() {
        let source = DiagnosticSource::new();
        let mut store = DiagnosticStore::new();
        for _ in 0..300 {
            store.record(prepared(&source, DiagnosticEventKind::ControlReleased));
        }
        assert_eq!(store.cache.len(), DIAGNOSTIC_CACHE_CAPACITY);
        assert_eq!(store.cache.front().unwrap().event().source_sequence, 45);
        assert_eq!(store.cache.back().unwrap().event().source_sequence, 300);

        let transport = Arc::new(FakeTransport::new());
        store.attach(
            true,
            7,
            transport.clone(),
            prepared(&source, DiagnosticEventKind::ReplayComplete),
            prepared(&source, DiagnosticEventKind::ConnectionReady),
        );
        let sent = transport.take();
        let replayed = sent
            .iter()
            .filter(|item| matches!(item, Sent::Diagnostic { replayed: true, .. }))
            .count();
        assert_eq!(replayed, DIAGNOSTIC_CACHE_CAPACITY);
        assert_eq!(
            sent.first(),
            Some(&Sent::Diagnostic {
                kind: DiagnosticEventKind::ControlReleased,
                sequence: 45,
                replayed: true,
            })
        );
        assert!(sent.iter().any(|item| {
            matches!(
                item,
                Sent::Diagnostic {
                    kind: DiagnosticEventKind::ReplayComplete,
                    replayed: false,
                    ..
                }
            )
        }));

        let replay_payload = store.cache.front().unwrap().payload(true);
        let decoded = decode_diagnostic_event(&replay_payload).unwrap().unwrap();
        assert_eq!(decoded.flags, FLAG_REPLAYED);
        assert_eq!(decoded.source_sequence, 46);
    }

    #[test]
    fn leave_decision_is_queued_before_mouse_leave() {
        let source = DiagnosticSource::new();
        let transport = Arc::new(FakeTransport::new());
        let mut store = DiagnosticStore::new();
        store.attach(
            true,
            9,
            transport.clone(),
            prepared(&source, DiagnosticEventKind::ReplayComplete),
            prepared(&source, DiagnosticEventKind::ConnectionReady),
        );
        transport.take();

        store
            .record_then_control(
                9,
                prepared(&source, DiagnosticEventKind::LeaveDecision),
                transport.clone(),
                Frame::new(MessageKind::MouseLeave, Vec::new()),
            )
            .unwrap();

        let sent = transport.take();
        assert!(matches!(
            sent.as_slice(),
            [
                Sent::Diagnostic {
                    kind: DiagnosticEventKind::LeaveDecision,
                    replayed: false,
                    ..
                },
                Sent::Control(MessageKind::MouseLeave)
            ]
        ));
    }

    #[test]
    fn diagnostic_send_failure_does_not_block_control_release() {
        let source = DiagnosticSource::new();
        let transport = Arc::new(FakeTransport::new());
        let mut store = DiagnosticStore::new();
        store.attach(
            true,
            11,
            transport.clone(),
            prepared(&source, DiagnosticEventKind::ReplayComplete),
            prepared(&source, DiagnosticEventKind::ConnectionReady),
        );
        transport.take();
        transport.fail_diagnostic.store(true, Ordering::Relaxed);

        assert!(
            store
                .record_then_control(
                    11,
                    prepared(&source, DiagnosticEventKind::LeaveDecision),
                    transport.clone(),
                    Frame::new(MessageKind::MouseLeave, Vec::new()),
                )
                .is_ok()
        );
        assert_eq!(
            transport.take(),
            vec![Sent::Control(MessageKind::MouseLeave)]
        );
    }

    #[test]
    fn repeated_replay_has_the_same_deduplication_identity() {
        let source = DiagnosticSource::new();
        let record = prepared(&source, DiagnosticEventKind::ControlReleased);
        let live = decode_diagnostic_event(&record.payload(false))
            .unwrap()
            .unwrap()
            .identity()
            .unwrap();
        let replayed = decode_diagnostic_event(&record.payload(true))
            .unwrap()
            .unwrap()
            .identity()
            .unwrap();
        let mut seen = HashSet::new();
        assert!(seen.insert(live));
        assert!(!seen.insert(replayed));
    }
}
