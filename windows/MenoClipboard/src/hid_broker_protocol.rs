use std::io::{self, Read, Write};

pub(crate) const OP_QUERY: u8 = 1;
pub(crate) const OP_WRITE: u8 = 2;
pub(crate) const STATUS_OK: u8 = 0;
pub(crate) const STATUS_ERROR: u8 = 1;
pub(crate) const STATUS_READY: u8 = 2;
pub(crate) const READY_SEQUENCE: u64 = u64::MAX;
pub(crate) const MAX_PAYLOAD: usize = 512;

const PROTOCOL_VERSION: u8 = 1;
const HEADER_SIZE: usize = 12;

#[derive(Debug, Eq, PartialEq)]
pub(crate) struct BrokerFrame {
    pub(crate) code: u8,
    pub(crate) sequence: u64,
    pub(crate) payload: Vec<u8>,
}

pub(crate) fn write_frame(
    output: &mut impl Write,
    code: u8,
    sequence: u64,
    payload: &[u8],
) -> io::Result<()> {
    if payload.len() > MAX_PAYLOAD || payload.len() > u16::MAX as usize {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "HID broker payload is too large",
        ));
    }
    let mut header = [0_u8; HEADER_SIZE];
    header[0] = PROTOCOL_VERSION;
    header[1] = code;
    header[2..4].copy_from_slice(&(payload.len() as u16).to_le_bytes());
    header[4..12].copy_from_slice(&sequence.to_le_bytes());
    output.write_all(&header)?;
    output.write_all(payload)
}

pub(crate) fn read_frame(input: &mut impl Read) -> io::Result<BrokerFrame> {
    let mut header = [0_u8; HEADER_SIZE];
    input.read_exact(&mut header)?;
    if header[0] != PROTOCOL_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "HID broker protocol version mismatch",
        ));
    }
    let length = u16::from_le_bytes([header[2], header[3]]) as usize;
    if length > MAX_PAYLOAD {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "HID broker payload exceeds the protocol limit",
        ));
    }
    let mut payload = vec![0_u8; length];
    input.read_exact(&mut payload)?;
    let sequence = u64::from_le_bytes(header[4..12].try_into().unwrap());
    if sequence == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "HID broker sequence must be nonzero",
        ));
    }
    Ok(BrokerFrame {
        code: header[1],
        sequence,
        payload,
    })
}

pub(crate) fn error_payload(error: &str) -> Vec<u8> {
    let bytes = error.as_bytes();
    let mut length = bytes.len().min(MAX_PAYLOAD);
    while length > 0 && !error.is_char_boundary(length) {
        length -= 1;
    }
    bytes[..length].to_vec()
}

pub(crate) fn validate_success_payload(
    operation: u8,
    payload: &[u8],
    query_size: usize,
) -> Result<(), String> {
    let expected = match operation {
        OP_QUERY => query_size,
        OP_WRITE => std::mem::size_of::<u64>(),
        _ => return Err(format!("unsupported HID broker operation {operation}")),
    };
    if payload.len() != expected {
        return Err(format!(
            "Meno HID broker returned {} of {expected} response bytes for operation {operation}",
            payload.len()
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;

    #[test]
    fn frame_has_a_bounded_versioned_layout() {
        let mut encoded = Vec::new();
        write_frame(&mut encoded, OP_WRITE, 0x0102_0304_0506_0708, &[9, 8, 7]).unwrap();
        assert_eq!(
            &encoded[..HEADER_SIZE],
            &[1, 2, 3, 0, 8, 7, 6, 5, 4, 3, 2, 1]
        );
        assert_eq!(
            read_frame(&mut Cursor::new(encoded)).unwrap(),
            BrokerFrame {
                code: OP_WRITE,
                sequence: 0x0102_0304_0506_0708,
                payload: vec![9, 8, 7],
            }
        );
    }

    #[test]
    fn oversized_and_zero_sequence_frames_are_rejected_before_use() {
        let mut oversized = [0_u8; HEADER_SIZE];
        oversized[0] = PROTOCOL_VERSION;
        oversized[2..4].copy_from_slice(&u16::MAX.to_le_bytes());
        assert_eq!(
            read_frame(&mut Cursor::new(oversized)).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );

        let mut zero_sequence = [0_u8; HEADER_SIZE];
        zero_sequence[0] = PROTOCOL_VERSION;
        assert_eq!(
            read_frame(&mut Cursor::new(zero_sequence))
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn response_lengths_and_utf8_errors_stay_bounded() {
        assert!(validate_success_payload(OP_QUERY, &[0; 88], 88).is_ok());
        assert!(validate_success_payload(OP_WRITE, &[0; 8], 88).is_ok());
        assert!(validate_success_payload(OP_QUERY, &[0; 87], 88).is_err());
        assert!(validate_success_payload(OP_WRITE, &[], 88).is_err());
        assert!(validate_success_payload(99, &[], 88).is_err());

        let payload = error_payload(&"错".repeat(MAX_PAYLOAD));
        assert!(payload.len() <= MAX_PAYLOAD);
        assert!(std::str::from_utf8(&payload).is_ok());
    }
}
