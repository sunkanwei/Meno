use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::file_protocol::{MAX_ENTRIES, MAX_LOGICAL_BYTES, TransferId, transfer_id_hex};

pub const SPACE_MARGIN: u64 = 1_024 * 1_024 * 1_024;
pub const RETENTION: Duration = Duration::from_secs(24 * 60 * 60);
pub const PARTIAL_METADATA: &str = ".meno-partial";
pub const COMPLETED_METADATA: &str = ".meno-completed";
const COMPLETED_TEMP: &str = ".meno-completed.tmp";
const METADATA_HEADER: &str = "MENO-FILE-CACHE-1";
const MAX_METADATA_BYTES: u64 = 256;
const FILE_ATTRIBUTE_REPARSE_BITS: u32 = 0x400;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompletedMetadata {
    pub transfer_id: TransferId,
    pub logical_bytes: u64,
    pub entry_count: usize,
    pub completed_millis: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CacheRecord {
    pub name: String,
    pub logical_bytes: u64,
    pub entry_count: usize,
    pub completed_millis: u64,
    pub referenced: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CapacityPlan {
    pub evict: Vec<String>,
    pub fits: bool,
}

pub fn is_transfer_directory_name(name: &str) -> bool {
    name.len() == 32 && name.bytes().all(|byte| byte.is_ascii_hexdigit())
}

pub fn is_referenced(directory: &Path, referenced: &[PathBuf]) -> bool {
    referenced.iter().any(|path| path.starts_with(directory))
}

pub fn required_free(incoming_logical_bytes: u64) -> Option<u64> {
    (incoming_logical_bytes <= MAX_LOGICAL_BYTES)
        .then_some(incoming_logical_bytes)?
        .checked_add(SPACE_MARGIN)
}

pub fn is_expired(completed_millis: u64, now_millis: u64) -> bool {
    now_millis.saturating_sub(completed_millis) > RETENTION.as_millis() as u64
}

pub fn plan_capacity(
    records: &[CacheRecord],
    incoming_logical_bytes: u64,
    incoming_entries: usize,
    available_bytes: u64,
) -> CapacityPlan {
    let Some(required_free) = required_free(incoming_logical_bytes) else {
        return CapacityPlan {
            evict: Vec::new(),
            fits: false,
        };
    };
    if incoming_entries == 0 || incoming_entries > MAX_ENTRIES {
        return CapacityPlan {
            evict: Vec::new(),
            fits: false,
        };
    }

    let Some(mut total_bytes) = records.iter().try_fold(0_u64, |total, record| {
        total.checked_add(record.logical_bytes)
    }) else {
        return CapacityPlan {
            evict: Vec::new(),
            fits: false,
        };
    };
    let Some(mut total_entries) = records.iter().try_fold(0_usize, |total, record| {
        total.checked_add(record.entry_count)
    }) else {
        return CapacityPlan {
            evict: Vec::new(),
            fits: false,
        };
    };
    let mut free = available_bytes;
    let fits = |bytes: u64, entries: usize, available: u64| {
        bytes
            .checked_add(incoming_logical_bytes)
            .is_some_and(|total| total <= MAX_LOGICAL_BYTES)
            && entries
                .checked_add(incoming_entries)
                .is_some_and(|total| total <= MAX_ENTRIES)
            && available >= required_free
    };
    if fits(total_bytes, total_entries, free) {
        return CapacityPlan {
            evict: Vec::new(),
            fits: true,
        };
    }

    let mut candidates: Vec<&CacheRecord> =
        records.iter().filter(|record| !record.referenced).collect();
    candidates.sort_by(|left, right| {
        left.completed_millis
            .cmp(&right.completed_millis)
            .then_with(|| left.name.cmp(&right.name))
    });
    let mut evict = Vec::new();
    for record in candidates {
        total_bytes = total_bytes.saturating_sub(record.logical_bytes);
        total_entries = total_entries.saturating_sub(record.entry_count);
        free = free.saturating_add(record.logical_bytes);
        evict.push(record.name.clone());
        if fits(total_bytes, total_entries, free) {
            return CapacityPlan { evict, fits: true };
        }
    }
    CapacityPlan { evict, fits: false }
}

fn metadata_text(
    transfer_id: &TransferId,
    logical_bytes: u64,
    entry_count: usize,
    completed_millis: u64,
) -> String {
    format!(
        "{METADATA_HEADER}\n{}\n{logical_bytes}\n{entry_count}\n{completed_millis}\n",
        transfer_id_hex(transfer_id)
    )
}

fn write_new(path: &Path, contents: &[u8]) -> Result<(), String> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|error| format!("metadata create failed: {error}"))?;
    file.write_all(contents)
        .map_err(|error| format!("metadata write failed: {error}"))?;
    file.sync_all()
        .map_err(|error| format!("metadata flush failed: {error}"))
}

pub fn write_partial(
    directory: &Path,
    transfer_id: &TransferId,
    logical_bytes: u64,
    entry_count: usize,
) -> Result<(), String> {
    if logical_bytes > MAX_LOGICAL_BYTES || entry_count == 0 || entry_count > MAX_ENTRIES {
        return Err("partial metadata values exceed fixed limits".to_string());
    }
    write_new(
        &directory.join(PARTIAL_METADATA),
        metadata_text(transfer_id, logical_bytes, entry_count, 0).as_bytes(),
    )
}

pub fn mark_completed(
    directory: &Path,
    transfer_id: &TransferId,
    logical_bytes: u64,
    entry_count: usize,
) -> Result<CompletedMetadata, String> {
    if logical_bytes > MAX_LOGICAL_BYTES || entry_count == 0 || entry_count > MAX_ENTRIES {
        return Err("completed metadata values exceed fixed limits".to_string());
    }
    let completed_millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u128::from(u64::MAX)) as u64;
    let completed_millis = completed_millis.max(1);
    let temporary = directory.join(COMPLETED_TEMP);
    write_new(
        &temporary,
        metadata_text(transfer_id, logical_bytes, entry_count, completed_millis).as_bytes(),
    )?;
    fs::rename(&temporary, directory.join(COMPLETED_METADATA))
        .map_err(|error| format!("completed metadata publish failed: {error}"))?;
    let _ = fs::remove_file(directory.join(PARTIAL_METADATA));
    Ok(CompletedMetadata {
        transfer_id: *transfer_id,
        logical_bytes,
        entry_count,
        completed_millis,
    })
}

pub fn load_completed(directory_name: &str, directory: &Path) -> Result<CompletedMetadata, String> {
    if !is_transfer_directory_name(directory_name) {
        return Err("cache directory name is invalid".to_string());
    }
    let path = directory.join(COMPLETED_METADATA);
    let metadata = fs::symlink_metadata(&path)
        .map_err(|error| format!("completed metadata unavailable: {error}"))?;
    if !metadata.is_file()
        || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_BITS != 0
        || metadata.len() > MAX_METADATA_BYTES
    {
        return Err("completed metadata file is invalid".to_string());
    }
    let mut bytes = Vec::with_capacity(MAX_METADATA_BYTES as usize);
    fs::File::open(&path)
        .map_err(|error| format!("metadata open failed: {error}"))?
        .take(MAX_METADATA_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("metadata read failed: {error}"))?;
    if bytes.len() as u64 > MAX_METADATA_BYTES {
        return Err("completed metadata file is too large".to_string());
    }
    let text = std::str::from_utf8(&bytes).map_err(|_| "metadata is not UTF-8".to_string())?;
    let mut lines = text.lines();
    if lines.next() != Some(METADATA_HEADER) {
        return Err("metadata header is invalid".to_string());
    }
    let id_hex = lines
        .next()
        .ok_or_else(|| "metadata transfer ID is missing".to_string())?;
    if !is_transfer_directory_name(id_hex) || !id_hex.eq_ignore_ascii_case(directory_name) {
        return Err("metadata transfer ID does not match its directory".to_string());
    }
    let logical_bytes = lines
        .next()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value <= MAX_LOGICAL_BYTES)
        .ok_or_else(|| "metadata logical byte count is invalid".to_string())?;
    let entry_count = lines
        .next()
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|value| (1..=MAX_ENTRIES).contains(value))
        .ok_or_else(|| "metadata entry count is invalid".to_string())?;
    let completed_millis = lines
        .next()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value != 0)
        .ok_or_else(|| "metadata completion time is invalid".to_string())?;
    if lines.next().is_some() {
        return Err("metadata has trailing fields".to_string());
    }
    let mut transfer_id = [0_u8; 16];
    for (index, pair) in id_hex.as_bytes().chunks_exact(2).enumerate() {
        transfer_id[index] = (hex_nibble(pair[0])? << 4) | hex_nibble(pair[1])?;
    }
    Ok(CompletedMetadata {
        transfer_id,
        logical_bytes,
        entry_count,
        completed_millis,
    })
}

fn hex_nibble(byte: u8) -> Result<u8, String> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        b'A'..=b'F' => Ok(byte - b'A' + 10),
        _ => Err("metadata transfer ID is not hexadecimal".to_string()),
    }
}
