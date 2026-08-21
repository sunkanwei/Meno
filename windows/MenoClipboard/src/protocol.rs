use std::io::{self, Read, Write};
use std::net::TcpStream;

pub const MAGIC: [u8; 4] = *b"MENO";
pub const DISCOVERY_PORT: u16 = 45_891;
pub const HEADER_SIZE: usize = 20;
pub const MAX_NAME_SIZE: usize = 256;
pub const MAX_HELLO_SIZE: usize = 512;
pub const MAX_TEXT_SIZE: usize = 1_048_576;
pub const MAX_IMAGE_SIZE: usize = 33_554_432;
pub const MAX_MOUSE_MOVE_BATCH: usize = 16;
pub const MAX_KEYBOARD_KEYS: usize = 6;
pub const CONTROL_ID_SIZE: usize = 8;
pub const MOUSE_ENTER_PAYLOAD_SIZE: usize = CONTROL_ID_SIZE + 2;
pub const DIRECTIONAL_MOUSE_ENTER_PAYLOAD_SIZE: usize = MOUSE_ENTER_PAYLOAD_SIZE + 1;
pub const MOUSE_BUTTON_PAYLOAD_SIZE: usize = CONTROL_ID_SIZE + 2;
pub const MOUSE_WHEEL_PAYLOAD_SIZE: usize = CONTROL_ID_SIZE + 4;
pub const KEYBOARD_STATE_PAYLOAD_SIZE: usize = 8;
pub const KEYBOARD_STATE_MESSAGE_SIZE: usize = CONTROL_ID_SIZE + KEYBOARD_STATE_PAYLOAD_SIZE;

pub const CAPABILITY_TEXT_CLIPBOARD: u16 = 1;
pub const CAPABILITY_PNG_CLIPBOARD: u16 = 2;
pub const CAPABILITY_MOUSE_CONTROL: u16 = 3;
pub const CAPABILITY_KEYBOARD_STATE: u16 = 4;
pub const CAPABILITY_FILE_CLIPBOARD: u16 = 5;
pub const CAPABILITY_REMOTE_SHUTDOWN: u16 = 6;
pub const CAPABILITY_MAC_MICROPHONE: u16 = 8;
pub const CAPABILITY_DIRECTIONAL_MOUSE_HANDOFF: u16 = 9;
pub const CAPABILITY_WINDOWS_ONLINE_NOTIFICATION: u16 = 10;
pub const CAPABILITY_REMOTE_DIAGNOSTICS: u16 = 11;

const FIELD_NAME: u8 = 1;
const FIELD_CAPABILITIES: u8 = 2;
const FIELD_DRIVER_ABI: u8 = 3;
const FIELD_SCREEN_WIDTH: u8 = 4;
const FIELD_SCREEN_HEIGHT: u8 = 5;
const FIELD_AUDIO_PORT: u8 = 6;
const MAX_CAPABILITIES_BYTES: usize = 128;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum MessageKind {
    Hello = 1,
    Ready = 2,
    Text = 3,
    Png = 4,
    Ping = 5,
    Pong = 6,
    MouseEnter = 7,
    MouseMove = 8,
    MouseButton = 9,
    MouseWheel = 10,
    MouseReleaseAll = 11,
    MouseLeave = 12,
    MouseDriverUnavailable = 13,
    KeyboardState = 14,
    MouseAcquired = 15,
    MouseReleased = 16,
    MouseControlHeartbeat = 17,
    FileOffer = 18,
    FileAccept = 19,
    FileChunk = 20,
    FileComplete = 21,
    FileResult = 22,
    FileCancel = 23,
    FileAck = 24,
    ShutdownRequest = 25,
    MicrophonePcm = 28,
    DirectionalMouseEnter = 29,
    WindowsOnline = 30,
    DiagnosticEvent = 31,
}

impl MessageKind {
    pub fn is_file_transfer(self) -> bool {
        (MessageKind::FileOffer as u8..=MessageKind::FileAck as u8).contains(&(self as u8))
    }
}

impl TryFrom<u8> for MessageKind {
    type Error = io::Error;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Hello),
            2 => Ok(Self::Ready),
            3 => Ok(Self::Text),
            4 => Ok(Self::Png),
            5 => Ok(Self::Ping),
            6 => Ok(Self::Pong),
            7 => Ok(Self::MouseEnter),
            8 => Ok(Self::MouseMove),
            9 => Ok(Self::MouseButton),
            10 => Ok(Self::MouseWheel),
            11 => Ok(Self::MouseReleaseAll),
            12 => Ok(Self::MouseLeave),
            13 => Ok(Self::MouseDriverUnavailable),
            14 => Ok(Self::KeyboardState),
            15 => Ok(Self::MouseAcquired),
            16 => Ok(Self::MouseReleased),
            17 => Ok(Self::MouseControlHeartbeat),
            18 => Ok(Self::FileOffer),
            19 => Ok(Self::FileAccept),
            20 => Ok(Self::FileChunk),
            21 => Ok(Self::FileComplete),
            22 => Ok(Self::FileResult),
            23 => Ok(Self::FileCancel),
            24 => Ok(Self::FileAck),
            25 => Ok(Self::ShutdownRequest),
            28 => Ok(Self::MicrophonePcm),
            29 => Ok(Self::DirectionalMouseEnter),
            30 => Ok(Self::WindowsOnline),
            31 => Ok(Self::DiagnosticEvent),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unknown message type",
            )),
        }
    }
}

#[derive(Clone, Debug)]
pub struct Frame {
    pub kind: MessageKind,
    pub message_id: u64,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn new(kind: MessageKind, payload: Vec<u8>) -> Self {
        Self {
            kind,
            message_id: next_message_id(),
            payload,
        }
    }

    pub fn write_to(&self, stream: &mut TcpStream) -> io::Result<()> {
        let encoded = self.encoded()?;
        stream.write_all(&encoded)
    }

    pub fn encoded(&self) -> io::Result<Vec<u8>> {
        let length = u32::try_from(self.payload.len())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "payload too large"))?;
        let mut output = Vec::with_capacity(HEADER_SIZE + self.payload.len());
        output.extend_from_slice(&MAGIC);
        output.push(self.kind as u8);
        output.extend_from_slice(&[0, 0, 0]);
        output.extend_from_slice(&self.message_id.to_be_bytes());
        output.extend_from_slice(&length.to_be_bytes());
        output.extend_from_slice(&self.payload);
        Ok(output)
    }
}

pub struct FrameDecoder {
    buffer: Vec<u8>,
}

impl FrameDecoder {
    pub fn new() -> Self {
        Self { buffer: Vec::new() }
    }

    pub fn read_available(&mut self, stream: &mut TcpStream) -> io::Result<Vec<Frame>> {
        let mut chunk = [0_u8; 65_536];
        match stream.read(&mut chunk) {
            Ok(0) => Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "connection closed",
            )),
            Ok(length) => self.append(&chunk[..length]),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                Ok(Vec::new())
            }
            Err(error) => Err(error),
        }
    }

    pub(crate) fn append(&mut self, data: &[u8]) -> io::Result<Vec<Frame>> {
        self.buffer.extend_from_slice(data);
        let mut frames = Vec::new();
        loop {
            if self.buffer.len() < HEADER_SIZE {
                break;
            }
            if self.buffer[0..4] != MAGIC
                || self.buffer[5] != 0
                || self.buffer[6] != 0
                || self.buffer[7] != 0
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "invalid frame header",
                ));
            }
            let message_id = u64::from_be_bytes(self.buffer[8..16].try_into().unwrap());
            let payload_length =
                u32::from_be_bytes(self.buffer[16..20].try_into().unwrap()) as usize;
            if payload_length > MAX_IMAGE_SIZE {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "payload too large",
                ));
            }
            let frame_length = HEADER_SIZE + payload_length;
            if self.buffer.len() < frame_length {
                break;
            }
            // Unknown kinds belong to future extensions: skip them by their
            // declared length instead of dropping the connection.
            if let Ok(kind) = MessageKind::try_from(self.buffer[4]) {
                frames.push(Frame {
                    kind,
                    message_id,
                    payload: self.buffer[HEADER_SIZE..frame_length].to_vec(),
                });
            }
            self.buffer.drain(..frame_length);
        }
        Ok(frames)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DiscoveryOffer {
    pub clipboard_port: u16,
    pub mouse_port: u16,
}

pub fn discovery_packet(kind: u8, clipboard_port: u16, mouse_port: u16) -> [u8; 10] {
    let mut packet = [0_u8; 10];
    packet[0..4].copy_from_slice(&MAGIC);
    packet[4] = kind;
    packet[6..8].copy_from_slice(&clipboard_port.to_be_bytes());
    packet[8..10].copy_from_slice(&mouse_port.to_be_bytes());
    packet
}

pub fn parse_offer(packet: &[u8]) -> Option<DiscoveryOffer> {
    if packet.len() != 10 || packet[0..4] != MAGIC || packet[4] != 2 || packet[5] != 0 {
        return None;
    }
    let clipboard_port = u16::from_be_bytes([packet[6], packet[7]]);
    let mouse_port = u16::from_be_bytes([packet[8], packet[9]]);
    (clipboard_port != 0 && mouse_port != 0).then_some(DiscoveryOffer {
        clipboard_port,
        mouse_port,
    })
}

pub fn utf8_payload(value: &str, maximum_size: usize) -> Vec<u8> {
    let mut payload = Vec::new();
    for character in value.chars() {
        let mut encoded = [0_u8; 4];
        let bytes = character.encode_utf8(&mut encoded).as_bytes();
        if payload.len() + bytes.len() > maximum_size {
            break;
        }
        payload.extend_from_slice(bytes);
    }
    payload
}

// Capability numbers are the only feature negotiation mechanism; unknown
// numbers are ignored so peers with different feature sets still connect.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Capabilities(u32);

impl Capabilities {
    pub fn empty() -> Self {
        Self::default()
    }

    pub fn from_slice(capabilities: &[u16]) -> Self {
        let mut result = Self::empty();
        for &capability in capabilities {
            result.insert(capability);
        }
        result
    }

    pub fn contains(self, capability: u16) -> bool {
        capability < 32 && self.0 & (1_u32 << capability) != 0
    }

    pub fn insert(&mut self, capability: u16) {
        if capability < 32 {
            self.0 |= 1_u32 << capability;
        }
    }

    pub fn intersect(self, other: Self) -> Self {
        Self(self.0 & other.0)
    }

    pub fn is_empty(self) -> bool {
        self.0 == 0
    }

    fn sorted(self) -> Vec<u16> {
        (0..32)
            .filter(|&capability| self.contains(capability))
            .collect()
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Hello {
    pub name: String,
    pub capabilities: Capabilities,
    pub driver_abi: Option<u16>,
    pub screen_width: Option<u32>,
    pub screen_height: Option<u32>,
    pub audio_port: Option<u16>,
}

pub fn clipboard_hello(name: &str) -> Vec<u8> {
    hello_payload(
        name,
        Capabilities::from_slice(&[
            CAPABILITY_TEXT_CLIPBOARD,
            CAPABILITY_PNG_CLIPBOARD,
            CAPABILITY_FILE_CLIPBOARD,
            CAPABILITY_MAC_MICROPHONE,
            CAPABILITY_WINDOWS_ONLINE_NOTIFICATION,
        ]),
        None,
        None,
    )
}

pub fn audio_hello(name: &str) -> Vec<u8> {
    hello_payload(
        name,
        Capabilities::from_slice(&[CAPABILITY_MAC_MICROPHONE]),
        None,
        None,
    )
}

pub fn mouse_hello(
    name: &str,
    driver_abi: u16,
    screen_width: u32,
    screen_height: u32,
) -> Result<Vec<u8>, String> {
    if driver_abi == 0 {
        return Err("mouse readiness requires a non-zero driver ABI".to_string());
    }
    if screen_width < 2
        || screen_height == 0
        || screen_width > i32::MAX as u32
        || screen_height > i32::MAX as u32
    {
        return Err("mouse readiness requires a valid primary display size".to_string());
    }
    let mut capabilities = Capabilities::from_slice(&[CAPABILITY_MOUSE_CONTROL]);
    capabilities.insert(CAPABILITY_KEYBOARD_STATE);
    capabilities.insert(CAPABILITY_REMOTE_SHUTDOWN);
    capabilities.insert(CAPABILITY_DIRECTIONAL_MOUSE_HANDOFF);
    capabilities.insert(CAPABILITY_REMOTE_DIAGNOSTICS);
    Ok(hello_payload(
        name,
        capabilities,
        Some(driver_abi),
        Some((screen_width, screen_height)),
    ))
}

pub fn mouse_unavailable_hello(name: &str) -> Vec<u8> {
    hello_payload(
        name,
        Capabilities::from_slice(&[CAPABILITY_REMOTE_SHUTDOWN, CAPABILITY_REMOTE_DIAGNOSTICS]),
        None,
        None,
    )
}

fn hello_payload(
    name: &str,
    capabilities: Capabilities,
    driver_abi: Option<u16>,
    screen: Option<(u32, u32)>,
) -> Vec<u8> {
    let mut tail = Vec::new();
    let mut capability_value = Vec::new();
    for capability in capabilities.sorted() {
        capability_value.extend_from_slice(&capability.to_be_bytes());
    }
    push_field(&mut tail, FIELD_CAPABILITIES, &capability_value);
    if let Some(driver_abi) = driver_abi {
        push_field(&mut tail, FIELD_DRIVER_ABI, &driver_abi.to_be_bytes());
    }
    if let Some((width, height)) = screen {
        push_field(&mut tail, FIELD_SCREEN_WIDTH, &width.to_be_bytes());
        push_field(&mut tail, FIELD_SCREEN_HEIGHT, &height.to_be_bytes());
    }
    let name_budget = MAX_HELLO_SIZE
        .saturating_sub(tail.len() + 3)
        .min(MAX_NAME_SIZE);
    let name_value = utf8_payload(name, name_budget);
    let mut payload = Vec::with_capacity(3 + name_value.len() + tail.len());
    push_field(&mut payload, FIELD_NAME, &name_value);
    payload.extend_from_slice(&tail);
    payload
}

fn push_field(output: &mut Vec<u8>, field: u8, value: &[u8]) {
    output.push(field);
    output.extend_from_slice(&(value.len() as u16).to_be_bytes());
    output.extend_from_slice(value);
}

// Unknown fields and capabilities are skipped; duplicated known fields and
// malformed values reject the handshake because the peer is not Meno.
pub fn parse_hello(payload: &[u8]) -> Result<Hello, String> {
    if payload.len() > MAX_HELLO_SIZE {
        return Err("hello payload too large".to_string());
    }
    let mut hello = Hello::default();
    let mut seen_fields = 0_u32;
    let mut offset = 0;
    while offset < payload.len() {
        if payload.len() - offset < 3 {
            return Err("truncated hello field".to_string());
        }
        let field = payload[offset];
        let length = u16::from_be_bytes([payload[offset + 1], payload[offset + 2]]) as usize;
        let end = offset + 3 + length;
        if end > payload.len() {
            return Err("truncated hello field value".to_string());
        }
        let value = &payload[offset + 3..end];
        match field {
            FIELD_NAME => {
                reject_duplicate_field(&mut seen_fields, field)?;
                if length > MAX_NAME_SIZE {
                    return Err("invalid hello name".to_string());
                }
                hello.name = String::from_utf8(value.to_vec())
                    .map_err(|_| "invalid hello name".to_string())?;
            }
            FIELD_CAPABILITIES => {
                reject_duplicate_field(&mut seen_fields, field)?;
                if !length.is_multiple_of(2) || length > MAX_CAPABILITIES_BYTES {
                    return Err("invalid hello capabilities".to_string());
                }
                for chunk in value.chunks_exact(2) {
                    let capability = u16::from_be_bytes([chunk[0], chunk[1]]);
                    if matches!(
                        capability,
                        CAPABILITY_TEXT_CLIPBOARD
                            | CAPABILITY_PNG_CLIPBOARD
                            | CAPABILITY_MOUSE_CONTROL
                            | CAPABILITY_KEYBOARD_STATE
                            | CAPABILITY_FILE_CLIPBOARD
                            | CAPABILITY_REMOTE_SHUTDOWN
                            | CAPABILITY_MAC_MICROPHONE
                            | CAPABILITY_DIRECTIONAL_MOUSE_HANDOFF
                            | CAPABILITY_WINDOWS_ONLINE_NOTIFICATION
                            | CAPABILITY_REMOTE_DIAGNOSTICS
                    ) {
                        hello.capabilities.insert(capability);
                    }
                }
            }
            FIELD_DRIVER_ABI => {
                reject_duplicate_field(&mut seen_fields, field)?;
                if length != 2 {
                    return Err("invalid hello driver ABI".to_string());
                }
                hello.driver_abi = Some(u16::from_be_bytes([value[0], value[1]]));
            }
            FIELD_SCREEN_WIDTH => {
                reject_duplicate_field(&mut seen_fields, field)?;
                if length != 4 {
                    return Err("invalid hello screen width".to_string());
                }
                hello.screen_width = Some(u32::from_be_bytes(value.try_into().unwrap()));
            }
            FIELD_SCREEN_HEIGHT => {
                reject_duplicate_field(&mut seen_fields, field)?;
                if length != 4 {
                    return Err("invalid hello screen height".to_string());
                }
                hello.screen_height = Some(u32::from_be_bytes(value.try_into().unwrap()));
            }
            FIELD_AUDIO_PORT => {
                reject_duplicate_field(&mut seen_fields, field)?;
                if length != 2 {
                    return Err("invalid hello audio port".to_string());
                }
                let audio_port = u16::from_be_bytes([value[0], value[1]]);
                if audio_port == 0 {
                    return Err("invalid hello audio port".to_string());
                }
                hello.audio_port = Some(audio_port);
            }
            _ => {}
        }
        offset = end;
    }
    Ok(hello)
}

fn reject_duplicate_field(seen_fields: &mut u32, field: u8) -> Result<(), String> {
    let mask = 1_u32 << field;
    if *seen_fields & mask != 0 {
        return Err(format!("duplicate hello field {field}"));
    }
    *seen_fields |= mask;
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MouseMoveSample {
    pub dx: i16,
    pub dy: i16,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum MouseEntryEdge {
    Left = 1,
    Right = 2,
}

impl MouseEntryEdge {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Right => "right",
        }
    }
}

impl TryFrom<u8> for MouseEntryEdge {
    type Error = String;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Left),
            2 => Ok(Self::Right),
            _ => Err("invalid mouse entry edge".to_string()),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KeyboardState {
    pub modifiers: u8,
    pub keys: Vec<u8>,
}

pub fn control_header(payload: &[u8]) -> Result<u64, String> {
    if payload.len() < CONTROL_ID_SIZE {
        return Err("invalid mouse control header".to_string());
    }
    let control_id = u64::from_be_bytes(payload[..CONTROL_ID_SIZE].try_into().unwrap());
    if control_id == 0 {
        return Err("invalid mouse control id".to_string());
    }
    Ok(control_id)
}

pub fn control_payload(control_id: u64) -> [u8; CONTROL_ID_SIZE] {
    control_id.to_be_bytes()
}

pub fn control_only(payload: &[u8]) -> Result<u64, String> {
    if payload.len() != CONTROL_ID_SIZE {
        return Err("invalid mouse control payload".to_string());
    }
    control_header(payload)
}

pub fn mouse_enter(payload: &[u8]) -> Result<(u64, u16), String> {
    if payload.len() != MOUSE_ENTER_PAYLOAD_SIZE {
        return Err("invalid mouse enter payload".to_string());
    }
    let control_id = control_header(payload)?;
    let normalized_y = u16::from_be_bytes([payload[8], payload[9]]);
    Ok((control_id, normalized_y))
}

pub fn directional_mouse_enter(
    payload: &[u8],
    negotiated: bool,
) -> Result<(u64, u16, MouseEntryEdge), String> {
    if !negotiated {
        return Err("directional mouse handoff was not negotiated".to_string());
    }
    if payload.len() != DIRECTIONAL_MOUSE_ENTER_PAYLOAD_SIZE {
        return Err("invalid directional mouse enter payload".to_string());
    }
    let control_id = control_header(payload)?;
    let normalized_y = u16::from_be_bytes([payload[8], payload[9]]);
    let entry_edge = MouseEntryEdge::try_from(payload[10])?;
    Ok((control_id, normalized_y, entry_edge))
}

pub fn mouse_button(payload: &[u8]) -> Result<(u64, u8, bool), String> {
    if payload.len() != MOUSE_BUTTON_PAYLOAD_SIZE {
        return Err("invalid mouse button payload".to_string());
    }
    let control_id = control_header(payload)?;
    let button = payload[8];
    let down = payload[9];
    if !(1..=3).contains(&button) || down > 1 {
        return Err("invalid mouse button payload".to_string());
    }
    Ok((control_id, button, down == 1))
}

pub fn mouse_wheel(payload: &[u8]) -> Result<(u64, i32), String> {
    if payload.len() != MOUSE_WHEEL_PAYLOAD_SIZE {
        return Err("invalid mouse wheel payload".to_string());
    }
    let control_id = control_header(payload)?;
    let lines = i32::from_be_bytes(payload[8..12].try_into().unwrap());
    Ok((control_id, lines))
}

pub fn decode_mouse_move(payload: &[u8]) -> Result<(u64, Vec<MouseMoveSample>), String> {
    if payload.len() < CONTROL_ID_SIZE + 1 {
        return Err("invalid mouse move batch".to_string());
    }
    let count = payload[CONTROL_ID_SIZE] as usize;
    if count == 0
        || count > MAX_MOUSE_MOVE_BATCH
        || payload.len() != CONTROL_ID_SIZE + 1 + count * 4
    {
        return Err("invalid mouse move batch".to_string());
    }
    let control_id = control_header(payload)?;
    let samples = payload[CONTROL_ID_SIZE + 1..]
        .chunks_exact(4)
        .map(|bytes| MouseMoveSample {
            dx: i16::from_be_bytes([bytes[0], bytes[1]]),
            dy: i16::from_be_bytes([bytes[2], bytes[3]]),
        })
        .collect();
    Ok((control_id, samples))
}

pub fn keyboard_state_message(payload: &[u8]) -> Result<(u64, KeyboardState), String> {
    if payload.len() != KEYBOARD_STATE_MESSAGE_SIZE {
        return Err("invalid keyboard state message".to_string());
    }
    let control_id = control_header(payload)?;
    let state = decode_keyboard_state(&payload[CONTROL_ID_SIZE..])?;
    Ok((control_id, state))
}

pub fn mouse_leave_payload(control_id: u64, normalized_y: u16) -> [u8; MOUSE_ENTER_PAYLOAD_SIZE] {
    let mut payload = [0_u8; MOUSE_ENTER_PAYLOAD_SIZE];
    payload[..CONTROL_ID_SIZE].copy_from_slice(&control_id.to_be_bytes());
    payload[8..10].copy_from_slice(&normalized_y.to_be_bytes());
    payload
}

pub fn decode_keyboard_state(payload: &[u8]) -> Result<KeyboardState, String> {
    if payload.len() != KEYBOARD_STATE_PAYLOAD_SIZE {
        return Err("invalid keyboard state".to_string());
    }
    let key_count = payload[1] as usize;
    if key_count > MAX_KEYBOARD_KEYS || payload[2 + key_count..].iter().any(|key| *key != 0) {
        return Err("invalid keyboard state".to_string());
    }
    let mut keys = payload[2..2 + key_count].to_vec();
    keys.sort_unstable();
    if keys
        .iter()
        .enumerate()
        .any(|(index, key)| !(0x04..0xE0).contains(key) || (index > 0 && keys[index - 1] == *key))
    {
        return Err("invalid keyboard state".to_string());
    }
    Ok(KeyboardState {
        modifiers: payload[0],
        keys,
    })
}

fn next_message_id() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos() as u64);
    seed ^ COUNTER.fetch_add(1, Ordering::Relaxed)
}
