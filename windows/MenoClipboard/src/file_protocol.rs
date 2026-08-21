pub const TRANSFER_ID_SIZE: usize = 16;
pub const MAX_TOP_LEVEL: usize = 128;
pub const MAX_ENTRIES: usize = 20_000;
pub const MAX_DEPTH: usize = 64;
pub const MAX_LOGICAL_BYTES: u64 = 50 * 1_024 * 1_024 * 1_024;
pub const MAX_OFFER_PAYLOAD: usize = 16 * 1_048_576;
pub const MAX_NAME_BYTES: usize = 1_024;
pub const MAX_CHUNK_DATA: usize = 524_288;
pub const UNKNOWN_MILLIS: i64 = i64::MIN;

pub const RESULT_OK: u8 = 0;
pub const RESULT_BAD_MANIFEST: u8 = 1;
pub const RESULT_NO_SPACE: u8 = 2;
pub const RESULT_WRITE_FAILED: u8 = 3;
pub const RESULT_CLIPBOARD_FAILED: u8 = 4;
pub const RESULT_SUPERSEDED: u8 = 5;

pub const CANCEL_LOCAL_CLIPBOARD: u8 = 1;
pub const CANCEL_SOURCE_CHANGED: u8 = 2;
pub const CANCEL_READ_FAILED: u8 = 3;
pub const CANCEL_SUPERSEDED: u8 = 4;
pub const CANCEL_TIMEOUT: u8 = 5;

const KIND_DIRECTORY: u8 = 1;
const KIND_FILE: u8 = 2;
pub const FLAG_HIDDEN: u8 = 1;
const PARENT_TOP: u32 = u32::MAX;

pub type TransferId = [u8; TRANSFER_ID_SIZE];

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OfferEntry {
    pub directory: bool,
    pub hidden: bool,
    pub parent: Option<u32>,
    pub name: String,
    pub size: u64,
    pub modified_millis: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Offer {
    pub transfer_id: TransferId,
    pub total_file_bytes: u64,
    pub entries: Vec<OfferEntry>,
}

// Structurally malformed bytes (bad lengths, truncation, trailing data) are
// protocol violations; semantically illegal manifests are reported with
// fileResult 1 so the connection survives a buggy but framed peer.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OfferError {
    Malformed,
    Illegal(&'static str),
}

pub fn checked_logical_bytes(total: u64, additional: u64) -> Option<u64> {
    total
        .checked_add(additional)
        .filter(|total| *total <= MAX_LOGICAL_BYTES)
}

pub fn new_transfer_id() -> TransferId {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());
    let mut id = [0_u8; TRANSFER_ID_SIZE];
    let low = (nanos as u64) ^ COUNTER.fetch_add(1, Ordering::Relaxed).rotate_left(17);
    // The constant tag in the high half also guarantees a non-zero id.
    let high =
        ((nanos >> 64) as u64) ^ (u64::from(std::process::id()) << 32) ^ 0x4D45_4E4F_4649_4C45;
    id[..8].copy_from_slice(&low.to_be_bytes());
    id[8..].copy_from_slice(&high.to_be_bytes());
    id
}

pub fn transfer_id_hex(id: &TransferId) -> String {
    let mut hex = String::with_capacity(32);
    for byte in id {
        hex.push_str(&format!("{byte:02x}"));
    }
    hex
}

fn read_transfer_id(payload: &[u8]) -> Result<TransferId, OfferError> {
    if payload.len() < TRANSFER_ID_SIZE {
        return Err(OfferError::Malformed);
    }
    let id: TransferId = payload[..TRANSFER_ID_SIZE].try_into().unwrap();
    if id.iter().all(|byte| *byte == 0) {
        return Err(OfferError::Malformed);
    }
    Ok(id)
}

fn exact_payload(payload: &[u8], size: usize) -> Result<TransferId, OfferError> {
    if payload.len() != size {
        return Err(OfferError::Malformed);
    }
    read_transfer_id(payload)
}

pub fn encode_offer(offer: &Offer) -> Result<Vec<u8>, OfferError> {
    if offer.entries.is_empty() || offer.entries.len() > MAX_ENTRIES {
        return Err(OfferError::Illegal("entry count out of range"));
    }
    let mut total = 0_u64;
    let mut size = TRANSFER_ID_SIZE + 4 + 8;
    let mut depths = Vec::with_capacity(offer.entries.len());
    let mut top_level = 0_usize;
    for (index, entry) in offer.entries.iter().enumerate() {
        if entry.name.is_empty() || entry.name.len() > MAX_NAME_BYTES {
            return Err(OfferError::Illegal("name length out of range"));
        }
        if entry.name.bytes().any(|byte| byte == 0 || byte == b'/')
            || entry.name == "."
            || entry.name == ".."
        {
            return Err(OfferError::Illegal("name contains forbidden content"));
        }
        if entry.directory && entry.size != 0 {
            return Err(OfferError::Illegal("directory must declare zero size"));
        }
        let depth = match entry.parent {
            None => {
                top_level += 1;
                if top_level > MAX_TOP_LEVEL {
                    return Err(OfferError::Illegal("too many top-level entries"));
                }
                1
            }
            Some(parent) => {
                let parent = parent as usize;
                if parent >= index {
                    return Err(OfferError::Illegal("parent index must precede the entry"));
                }
                if !offer.entries[parent].directory {
                    return Err(OfferError::Illegal("parent entry must be a directory"));
                }
                depths[parent] + 1
            }
        };
        if depth > MAX_DEPTH {
            return Err(OfferError::Illegal("depth limit exceeded"));
        }
        depths.push(depth);
        if !entry.directory {
            total = checked_logical_bytes(total, entry.size)
                .ok_or(OfferError::Illegal("total file bytes exceed fixed limit"))?;
        }
        size = size
            .checked_add(1 + 1 + 4 + 2 + entry.name.len() + 8 + 8)
            .ok_or(OfferError::Illegal("offer size overflow"))?;
    }
    if total != offer.total_file_bytes || size > MAX_OFFER_PAYLOAD {
        return Err(OfferError::Illegal("offer exceeds fixed limits"));
    }
    let mut payload = Vec::with_capacity(size);
    payload.extend_from_slice(&offer.transfer_id);
    payload.extend_from_slice(&(offer.entries.len() as u32).to_be_bytes());
    payload.extend_from_slice(&offer.total_file_bytes.to_be_bytes());
    for entry in &offer.entries {
        payload.push(if entry.directory {
            KIND_DIRECTORY
        } else {
            KIND_FILE
        });
        payload.push(if entry.hidden { FLAG_HIDDEN } else { 0 });
        payload.extend_from_slice(&entry.parent.unwrap_or(PARENT_TOP).to_be_bytes());
        payload.extend_from_slice(&(entry.name.len() as u16).to_be_bytes());
        payload.extend_from_slice(entry.name.as_bytes());
        payload.extend_from_slice(&entry.size.to_be_bytes());
        payload.extend_from_slice(&entry.modified_millis.to_be_bytes());
    }
    Ok(payload)
}

pub fn decode_offer(payload: &[u8]) -> Result<Offer, OfferError> {
    if payload.len() > MAX_OFFER_PAYLOAD || payload.len() < TRANSFER_ID_SIZE + 4 + 8 {
        return Err(OfferError::Malformed);
    }
    let transfer_id = read_transfer_id(payload)?;
    let mut cursor = TRANSFER_ID_SIZE;
    let mut take = |count: usize| -> Result<&[u8], OfferError> {
        let end = cursor.checked_add(count).ok_or(OfferError::Malformed)?;
        let slice = payload.get(cursor..end).ok_or(OfferError::Malformed)?;
        cursor = end;
        Ok(slice)
    };
    let entry_count = u32::from_be_bytes(take(4)?.try_into().unwrap()) as usize;
    if entry_count == 0 || entry_count > MAX_ENTRIES {
        return Err(OfferError::Illegal("entry count out of range"));
    }
    let declared_total = u64::from_be_bytes(take(8)?.try_into().unwrap());
    if declared_total > MAX_LOGICAL_BYTES {
        return Err(OfferError::Illegal("total file bytes exceed fixed limit"));
    }
    let mut entries: Vec<OfferEntry> = Vec::with_capacity(entry_count.min(4_096));
    let mut depths: Vec<usize> = Vec::with_capacity(entry_count.min(4_096));
    let mut top_level = 0_usize;
    let mut total = 0_u64;
    for index in 0..entry_count {
        let kind = take(1)?[0];
        let flags = take(1)?[0];
        let parent_raw = u32::from_be_bytes(take(4)?.try_into().unwrap());
        let name_length = u16::from_be_bytes(take(2)?.try_into().unwrap()) as usize;
        if name_length == 0 || name_length > MAX_NAME_BYTES {
            return Err(OfferError::Illegal("name length out of range"));
        }
        let name_bytes = take(name_length)?;
        let name =
            std::str::from_utf8(name_bytes).map_err(|_| OfferError::Illegal("name not UTF-8"))?;
        if name.bytes().any(|byte| byte == 0 || byte == b'/') || name == "." || name == ".." {
            return Err(OfferError::Illegal("name contains forbidden content"));
        }
        let size = u64::from_be_bytes(take(8)?.try_into().unwrap());
        let modified_millis = i64::from_be_bytes(take(8)?.try_into().unwrap());
        let directory = match kind {
            KIND_DIRECTORY => true,
            KIND_FILE => false,
            _ => return Err(OfferError::Illegal("unknown entry kind")),
        };
        if directory && size != 0 {
            return Err(OfferError::Illegal("directory must declare zero size"));
        }
        let parent = if parent_raw == PARENT_TOP {
            top_level += 1;
            if top_level > MAX_TOP_LEVEL {
                return Err(OfferError::Illegal("too many top-level entries"));
            }
            None
        } else {
            let parent_index = parent_raw as usize;
            if parent_index >= index {
                return Err(OfferError::Illegal("parent index must precede the entry"));
            }
            if !entries[parent_index].directory {
                return Err(OfferError::Illegal("parent entry must be a directory"));
            }
            Some(parent_raw)
        };
        let depth = match parent {
            None => 1,
            Some(parent) => depths[parent as usize] + 1,
        };
        if depth > MAX_DEPTH {
            return Err(OfferError::Illegal("depth limit exceeded"));
        }
        depths.push(depth);
        if !directory {
            total = checked_logical_bytes(total, size)
                .ok_or(OfferError::Illegal("total file bytes exceed fixed limit"))?;
        }
        entries.push(OfferEntry {
            directory,
            hidden: flags & FLAG_HIDDEN != 0,
            parent,
            name: name.to_string(),
            size,
            modified_millis,
        });
    }
    if cursor != payload.len() {
        return Err(OfferError::Malformed);
    }
    if total != declared_total {
        return Err(OfferError::Illegal("total file bytes mismatch"));
    }
    Ok(Offer {
        transfer_id,
        total_file_bytes: declared_total,
        entries,
    })
}

pub fn encode_id_only(transfer_id: &TransferId) -> Vec<u8> {
    transfer_id.to_vec()
}

pub fn decode_accept(payload: &[u8]) -> Result<TransferId, OfferError> {
    exact_payload(payload, TRANSFER_ID_SIZE)
}

pub fn decode_complete(payload: &[u8]) -> Result<TransferId, OfferError> {
    exact_payload(payload, TRANSFER_ID_SIZE)
}

pub fn encode_result(transfer_id: &TransferId, status: u8) -> Vec<u8> {
    let mut payload = transfer_id.to_vec();
    payload.push(status);
    payload
}

pub fn decode_result(payload: &[u8]) -> Result<(TransferId, u8), OfferError> {
    let id = exact_payload(payload, TRANSFER_ID_SIZE + 1)?;
    Ok((id, payload[TRANSFER_ID_SIZE]))
}

pub fn encode_cancel(transfer_id: &TransferId, reason: u8) -> Vec<u8> {
    encode_result(transfer_id, reason)
}

pub fn decode_cancel(payload: &[u8]) -> Result<(TransferId, u8), OfferError> {
    decode_result(payload)
}

pub fn encode_chunk(transfer_id: &TransferId, entry: u32, offset: u64, data: &[u8]) -> Vec<u8> {
    let mut payload = Vec::with_capacity(TRANSFER_ID_SIZE + 4 + 8 + data.len());
    payload.extend_from_slice(transfer_id);
    payload.extend_from_slice(&entry.to_be_bytes());
    payload.extend_from_slice(&offset.to_be_bytes());
    payload.extend_from_slice(data);
    payload
}

pub fn decode_chunk(payload: &[u8]) -> Result<(TransferId, u32, u64, &[u8]), OfferError> {
    if payload.len() < TRANSFER_ID_SIZE + 4 + 8 + 1
        || payload.len() > TRANSFER_ID_SIZE + 4 + 8 + MAX_CHUNK_DATA
    {
        return Err(OfferError::Malformed);
    }
    let transfer_id = read_transfer_id(payload)?;
    let entry = u32::from_be_bytes(
        payload[TRANSFER_ID_SIZE..TRANSFER_ID_SIZE + 4]
            .try_into()
            .unwrap(),
    );
    let offset = u64::from_be_bytes(
        payload[TRANSFER_ID_SIZE + 4..TRANSFER_ID_SIZE + 12]
            .try_into()
            .unwrap(),
    );
    Ok((
        transfer_id,
        entry,
        offset,
        &payload[TRANSFER_ID_SIZE + 12..],
    ))
}

pub fn encode_ack(transfer_id: &TransferId, entry: u32, next_offset: u64) -> Vec<u8> {
    let mut payload = Vec::with_capacity(TRANSFER_ID_SIZE + 4 + 8);
    payload.extend_from_slice(transfer_id);
    payload.extend_from_slice(&entry.to_be_bytes());
    payload.extend_from_slice(&next_offset.to_be_bytes());
    payload
}

pub fn decode_ack(payload: &[u8]) -> Result<(TransferId, u32, u64), OfferError> {
    let id = exact_payload(payload, TRANSFER_ID_SIZE + 4 + 8)?;
    let entry = u32::from_be_bytes(
        payload[TRANSFER_ID_SIZE..TRANSFER_ID_SIZE + 4]
            .try_into()
            .unwrap(),
    );
    let next_offset = u64::from_be_bytes(
        payload[TRANSFER_ID_SIZE + 4..TRANSFER_ID_SIZE + 12]
            .try_into()
            .unwrap(),
    );
    Ok((id, entry, next_offset))
}
