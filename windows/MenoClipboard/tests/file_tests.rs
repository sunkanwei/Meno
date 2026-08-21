#![allow(dead_code)]

#[path = "../src/file_cache.rs"]
mod file_cache;
#[path = "../src/file_clipboard.rs"]
mod file_clipboard;
#[path = "../src/file_manifest.rs"]
mod file_manifest;
#[path = "../src/file_protocol.rs"]
mod file_protocol;
#[path = "../src/file_transfer.rs"]
mod file_transfer;
#[path = "../src/logging.rs"]
mod logging;
#[path = "../src/protocol.rs"]
mod protocol;
#[path = "../src/transfer_cache.rs"]
mod transfer_cache;

use std::cell::RefCell;
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock, mpsc};
use std::thread;
use std::time::{Duration, UNIX_EPOCH};

use file_protocol::{Offer, OfferEntry, OfferError};
use protocol::{Frame, MessageKind};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, HWND_MESSAGE, MSG,
    PostMessageW, PostQuitMessage, RegisterClassW, WM_CLOSE, WM_DESTROY, WNDCLASSW, WS_OVERLAPPED,
};
use windows::core::{PCWSTR, w};

// Stubs for the crate-root items file_transfer.rs imports from main.rs and
// connection.rs, shaped exactly like the production definitions.
pub const WM_FILE_CLIPBOARD_REQUEST: u32 = 0x8000 + 3;

pub enum FileUiRequest {
    Publish {
        paths: Vec<PathBuf>,
        result: mpsc::Sender<Result<(), String>>,
    },
    Referenced {
        result: mpsc::Sender<Result<Vec<PathBuf>, String>>,
    },
}

static UI_REQUEST_ID: AtomicU64 = AtomicU64::new(0);
static UI_REQUESTS: OnceLock<Mutex<VecDeque<(u64, usize, FileUiRequest)>>> = OnceLock::new();
static UI_CONFIGS: OnceLock<Mutex<HashMap<usize, TestUiConfig>>> = OnceLock::new();

#[derive(Clone)]
struct TestUiConfig {
    referenced: Result<Vec<PathBuf>, String>,
    publish_ok: bool,
}

pub fn post_file_ui_request(hwnd: HWND, request: FileUiRequest) -> bool {
    let id = UI_REQUEST_ID.fetch_add(1, Ordering::Relaxed);
    let requests = UI_REQUESTS.get_or_init(|| Mutex::new(VecDeque::new()));
    requests
        .lock()
        .unwrap()
        .push_back((id, hwnd.0 as usize, request));
    let posted =
        unsafe { PostMessageW(Some(hwnd), WM_FILE_CLIPBOARD_REQUEST, WPARAM(0), LPARAM(0)) };
    if posted.is_err() {
        requests.lock().unwrap().retain(|entry| entry.0 != id);
        false
    } else {
        true
    }
}

mod connection {
    use crate::protocol::Frame;

    #[derive(Debug)]
    pub enum NetworkCommand {
        FileFrame { connection_id: u64, frame: Frame },
        ProtocolViolation { connection_id: u64 },
    }
}

fn sample_transfer_id() -> [u8; 16] {
    [
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E,
        0x0F,
    ]
}

fn sample_offer() -> Offer {
    Offer {
        transfer_id: sample_transfer_id(),
        total_file_bytes: 2,
        entries: vec![
            OfferEntry {
                directory: true,
                hidden: false,
                parent: None,
                name: "A".to_string(),
                size: 0,
                modified_millis: file_protocol::UNKNOWN_MILLIS,
            },
            OfferEntry {
                directory: false,
                hidden: true,
                parent: Some(0),
                name: "x.txt".to_string(),
                size: 2,
                modified_millis: 1000,
            },
        ],
    }
}

#[test]
fn file_offer_matches_fixed_wire_bytes() {
    let payload = file_protocol::encode_offer(&sample_offer()).unwrap();
    let frame = Frame {
        kind: MessageKind::FileOffer,
        message_id: 0x0102_0304_0506_0708,
        payload,
    };

    let expected: &[u8] = &[
        0x4D, 0x45, 0x4E, 0x4F, 0x12, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x00, 0x00, 0x00, 0x52, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
        0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x02, 0x01, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01, 0x41, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x78, 0x2E, 0x74, 0x78, 0x74, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8,
    ];
    assert_eq!(frame.encoded().unwrap(), expected);

    let decoded = file_protocol::decode_offer(&expected[protocol::HEADER_SIZE..]).unwrap();
    assert_eq!(decoded, sample_offer());
}

#[test]
fn file_chunk_and_ack_match_fixed_wire_bytes() {
    let id = sample_transfer_id();
    let chunk = file_protocol::encode_chunk(&id, 1, 0, &[0x41, 0x42]);
    assert_eq!(
        chunk,
        vec![
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
            0x0E, 0x0F, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x41, 0x42,
        ]
    );
    let (chunk_id, entry, offset, data) = file_protocol::decode_chunk(&chunk).unwrap();
    assert_eq!((chunk_id, entry, offset), (id, 1, 0));
    assert_eq!(data, [0x41, 0x42]);

    let ack = file_protocol::encode_ack(&id, 1, 2);
    assert_eq!(
        ack,
        vec![
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
            0x0E, 0x0F, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
        ]
    );
    assert_eq!(file_protocol::decode_ack(&ack).unwrap(), (id, 1, 2));
}

#[test]
fn small_payloads_have_exact_lengths() {
    let id = sample_transfer_id();
    assert!(file_protocol::decode_accept(&id).unwrap() == id);
    assert!(file_protocol::decode_complete(&id).unwrap() == id);
    assert!(file_protocol::decode_accept(&id[..15]).is_err());
    assert!(file_protocol::decode_accept(&[&id[..], &[0]].concat()).is_err());
    assert_eq!(
        file_protocol::decode_result(&file_protocol::encode_result(&id, 5)).unwrap(),
        (id, 5)
    );
    assert_eq!(
        file_protocol::decode_cancel(&file_protocol::encode_cancel(&id, 4)).unwrap(),
        (id, 4)
    );
    assert!(file_protocol::decode_result(&id).is_err());
    assert!(file_protocol::decode_cancel(&[&id[..], &[1, 2]].concat()).is_err());
    assert!(file_protocol::decode_ack(&id).is_err());
}

#[test]
fn zero_transfer_id_is_rejected_everywhere() {
    let zero = [0_u8; 16];
    assert!(file_protocol::decode_accept(&zero).is_err());
    let mut chunk = file_protocol::encode_chunk(&sample_transfer_id(), 0, 0, &[1]);
    chunk[..16].copy_from_slice(&zero);
    assert!(file_protocol::decode_chunk(&chunk).is_err());
}

#[test]
fn chunk_data_bounds_are_enforced() {
    let id = sample_transfer_id();
    let empty = file_protocol::encode_chunk(&id, 0, 0, &[]);
    assert!(file_protocol::decode_chunk(&empty).is_err());
    let maximal =
        file_protocol::encode_chunk(&id, 0, 0, &vec![7_u8; file_protocol::MAX_CHUNK_DATA]);
    assert_eq!(
        file_protocol::decode_chunk(&maximal).unwrap().3.len(),
        file_protocol::MAX_CHUNK_DATA
    );
    let mut oversized = file_protocol::encode_chunk(&id, 0, 0, &[1]);
    oversized.extend_from_slice(&vec![0_u8; file_protocol::MAX_CHUNK_DATA]);
    assert!(file_protocol::decode_chunk(&oversized).is_err());
}

fn offer_payload(entries: Vec<OfferEntry>) -> Vec<u8> {
    let total = entries
        .iter()
        .filter(|entry| !entry.directory)
        .map(|entry| entry.size)
        .sum();
    file_protocol::encode_offer(&Offer {
        transfer_id: sample_transfer_id(),
        total_file_bytes: total,
        entries,
    })
    .unwrap()
}

// The validating encoder refuses illegal manifests, but the decoder must
// reject them too; this raw builder bypasses encoder-side validation.
fn raw_offer_payload(entries: &[OfferEntry]) -> Vec<u8> {
    let total: u64 = entries
        .iter()
        .filter(|entry| !entry.directory)
        .map(|entry| entry.size)
        .sum();
    raw_offer_payload_with_total(entries, total)
}

fn raw_offer_payload_with_total(entries: &[OfferEntry], total: u64) -> Vec<u8> {
    let mut payload = Vec::new();
    payload.extend_from_slice(&sample_transfer_id());
    payload.extend_from_slice(&(entries.len() as u32).to_be_bytes());
    payload.extend_from_slice(&total.to_be_bytes());
    for entry in entries {
        payload.push(if entry.directory { 1 } else { 2 });
        payload.push(if entry.hidden { 1 } else { 0 });
        payload.extend_from_slice(&entry.parent.unwrap_or(u32::MAX).to_be_bytes());
        payload.extend_from_slice(&(entry.name.len() as u16).to_be_bytes());
        payload.extend_from_slice(entry.name.as_bytes());
        payload.extend_from_slice(&entry.size.to_be_bytes());
        payload.extend_from_slice(&entry.modified_millis.to_be_bytes());
    }
    payload
}

fn file_entry(name: &str, parent: Option<u32>, size: u64) -> OfferEntry {
    OfferEntry {
        directory: false,
        hidden: false,
        parent,
        name: name.to_string(),
        size,
        modified_millis: 0,
    }
}

fn dir_entry(name: &str, parent: Option<u32>) -> OfferEntry {
    OfferEntry {
        directory: true,
        hidden: false,
        parent,
        name: name.to_string(),
        size: 0,
        modified_millis: 0,
    }
}

#[test]
fn offer_rejects_bad_structure_and_content() {
    // A lone file is the minimal valid offer.
    assert!(file_protocol::decode_offer(&offer_payload(vec![file_entry("a", None, 1)])).is_ok());

    // Parent must be an earlier directory. Raw bytes bypass encoder checks.
    assert!(matches!(
        file_protocol::decode_offer(&raw_offer_payload(&[
            dir_entry("d", None),
            file_entry("a", Some(1), 1),
        ])),
        Err(OfferError::Illegal(_))
    ));
    assert!(matches!(
        file_protocol::decode_offer(&raw_offer_payload(&[
            file_entry("a", None, 1),
            file_entry("b", Some(0), 1),
        ])),
        Err(OfferError::Illegal(_))
    ));
    assert!(matches!(
        file_protocol::decode_offer(&raw_offer_payload(&[file_entry("a", Some(0), 1)])),
        Err(OfferError::Illegal(_))
    ));

    // Top-level entries have depth 1; exactly MAX_DEPTH is legal.
    let mut deep = vec![dir_entry("d0", None)];
    for level in 1..file_protocol::MAX_DEPTH {
        deep.push(dir_entry(&format!("d{level}"), Some((level - 1) as u32)));
    }
    assert!(file_protocol::decode_offer(&offer_payload(deep)).is_ok());
    let mut too_deep = vec![dir_entry("d0", None)];
    for level in 1..=file_protocol::MAX_DEPTH {
        too_deep.push(dir_entry(&format!("d{level}"), Some((level - 1) as u32)));
    }
    assert!(matches!(
        file_protocol::decode_offer(&raw_offer_payload(&too_deep)),
        Err(OfferError::Illegal(_))
    ));

    // Name rules.
    for name in ["", "a\0b", "a/b", ".", ".."] {
        let payload = raw_offer_payload(&[file_entry(name, None, 1)]);
        assert!(
            matches!(
                file_protocol::decode_offer(&payload),
                Err(OfferError::Illegal(_))
            ),
            "name {name:?} must be rejected"
        );
    }
    // A backslash stays legal on the wire.
    assert!(file_protocol::decode_offer(&offer_payload(vec![file_entry("a\\b", None, 1)])).is_ok());

    // Oversized name.
    let long_name = "a".repeat(file_protocol::MAX_NAME_BYTES + 1);
    let mut raw = Vec::new();
    raw.extend_from_slice(&sample_transfer_id());
    raw.extend_from_slice(&1_u32.to_be_bytes());
    raw.extend_from_slice(&1_u64.to_be_bytes());
    raw.push(2);
    raw.push(0);
    raw.extend_from_slice(&u32::MAX.to_be_bytes());
    raw.extend_from_slice(&((file_protocol::MAX_NAME_BYTES + 1) as u16).to_be_bytes());
    raw.extend_from_slice(long_name.as_bytes());
    raw.extend_from_slice(&1_u64.to_be_bytes());
    raw.extend_from_slice(&0_i64.to_be_bytes());
    assert!(matches!(
        file_protocol::decode_offer(&raw),
        Err(OfferError::Illegal(_))
    ));

    // Directory must declare zero size.
    assert!(matches!(
        file_protocol::decode_offer(&{
            let mut payload = offer_payload(vec![dir_entry("d", None)]);
            let size_offset = 16 + 4 + 8 + 1 + 1 + 4 + 2 + 1;
            payload[size_offset..size_offset + 8].copy_from_slice(&9_u64.to_be_bytes());
            payload
        }),
        Err(OfferError::Illegal(_))
    ));

    // Declared total must match the sum, without overflow.
    let mut payload = offer_payload(vec![file_entry("a", None, 1)]);
    payload[20..28].copy_from_slice(&2_u64.to_be_bytes());
    assert!(matches!(
        file_protocol::decode_offer(&payload),
        Err(OfferError::Illegal(_))
    ));
    let mut overflow = Vec::new();
    overflow.extend_from_slice(&sample_transfer_id());
    overflow.extend_from_slice(&2_u32.to_be_bytes());
    overflow.extend_from_slice(&u64::MAX.to_be_bytes());
    for name in ["a", "b"] {
        overflow.push(2);
        overflow.push(0);
        overflow.extend_from_slice(&u32::MAX.to_be_bytes());
        overflow.extend_from_slice(&1_u16.to_be_bytes());
        overflow.extend_from_slice(name.as_bytes());
        overflow.extend_from_slice(&u64::MAX.to_be_bytes());
        overflow.extend_from_slice(&0_i64.to_be_bytes());
    }
    assert!(matches!(
        file_protocol::decode_offer(&overflow),
        Err(OfferError::Illegal(_))
    ));

    // Entry count limits.
    assert!(matches!(
        file_protocol::decode_offer(&raw_offer_payload(&[])),
        Err(OfferError::Illegal(_))
    ));
    let top: Vec<OfferEntry> = (0..=file_protocol::MAX_TOP_LEVEL)
        .map(|index| file_entry(&format!("f{index}"), None, 0))
        .collect();
    assert!(matches!(
        file_protocol::decode_offer(&raw_offer_payload(&top)),
        Err(OfferError::Illegal(_))
    ));
}

#[test]
fn file_limits_and_message_numbers_are_fixed() {
    assert_eq!(file_protocol::MAX_ENTRIES, 20_000);
    assert_eq!(file_protocol::MAX_TOP_LEVEL, 128);
    assert_eq!(file_protocol::MAX_DEPTH, 64);
    assert_eq!(file_protocol::MAX_LOGICAL_BYTES, 50 * 1_024 * 1_024 * 1_024);
    assert_eq!(file_protocol::MAX_NAME_BYTES, 1_024);
    assert_eq!(file_protocol::MAX_OFFER_PAYLOAD, 16 * 1_024 * 1_024);
    assert_eq!(file_protocol::MAX_CHUNK_DATA, 512 * 1_024);
    assert_eq!(file_cache::SPACE_MARGIN, 1_024 * 1_024 * 1_024);
    assert_eq!(file_cache::RETENTION, Duration::from_secs(24 * 60 * 60));
    assert_eq!(MessageKind::FileOffer as u8, 18);
    assert_eq!(MessageKind::FileAccept as u8, 19);
    assert_eq!(MessageKind::FileChunk as u8, 20);
    assert_eq!(MessageKind::FileComplete as u8, 21);
    assert_eq!(MessageKind::FileResult as u8, 22);
    assert_eq!(MessageKind::FileCancel as u8, 23);
    assert_eq!(MessageKind::FileAck as u8, 24);
}

#[test]
fn logical_byte_limit_is_shared_by_encode_decode_and_manifest_accounting() {
    let limit = file_protocol::MAX_LOGICAL_BYTES;
    let accepted = Offer {
        transfer_id: sample_transfer_id(),
        total_file_bytes: limit,
        entries: vec![file_entry("large.bin", None, limit)],
    };
    let payload = file_protocol::encode_offer(&accepted).unwrap();
    assert_eq!(file_protocol::decode_offer(&payload).unwrap(), accepted);

    let oversized = Offer {
        transfer_id: sample_transfer_id(),
        total_file_bytes: limit + 1,
        entries: vec![file_entry("large.bin", None, limit + 1)],
    };
    assert!(matches!(
        file_protocol::encode_offer(&oversized),
        Err(OfferError::Illegal(_))
    ));
    let raw = raw_offer_payload_with_total(&oversized.entries, oversized.total_file_bytes);
    assert!(matches!(
        file_protocol::decode_offer(&raw),
        Err(OfferError::Illegal(_))
    ));

    assert_eq!(file_protocol::checked_logical_bytes(0, limit), Some(limit));
    assert_eq!(file_protocol::checked_logical_bytes(limit, 0), Some(limit));
    assert_eq!(file_protocol::checked_logical_bytes(limit, 1), None);
    assert_eq!(file_protocol::checked_logical_bytes(u64::MAX, 1), None);
}

#[test]
fn encode_and_decode_share_entry_top_level_and_depth_limits() {
    let mut maximal_entries = Vec::with_capacity(file_protocol::MAX_ENTRIES);
    maximal_entries.push(dir_entry("root", None));
    maximal_entries.extend(
        (1..file_protocol::MAX_ENTRIES).map(|index| file_entry(&format!("f{index}"), Some(0), 0)),
    );
    let maximal = Offer {
        transfer_id: sample_transfer_id(),
        total_file_bytes: 0,
        entries: maximal_entries.clone(),
    };
    let encoded = file_protocol::encode_offer(&maximal).unwrap();
    assert_eq!(file_protocol::decode_offer(&encoded).unwrap(), maximal);

    maximal_entries.push(file_entry("one-too-many", Some(0), 0));
    let oversized = Offer {
        transfer_id: sample_transfer_id(),
        total_file_bytes: 0,
        entries: maximal_entries,
    };
    assert!(matches!(
        file_protocol::encode_offer(&oversized),
        Err(OfferError::Illegal(_))
    ));
    assert!(matches!(
        file_protocol::decode_offer(&raw_offer_payload(&oversized.entries)),
        Err(OfferError::Illegal(_))
    ));

    let too_many_roots: Vec<_> = (0..=file_protocol::MAX_TOP_LEVEL)
        .map(|index| file_entry(&format!("root{index}"), None, 0))
        .collect();
    assert!(matches!(
        file_protocol::encode_offer(&Offer {
            transfer_id: sample_transfer_id(),
            total_file_bytes: 0,
            entries: too_many_roots,
        }),
        Err(OfferError::Illegal(_))
    ));

    let mut too_deep = vec![dir_entry("d0", None)];
    for depth in 1..=file_protocol::MAX_DEPTH {
        too_deep.push(dir_entry(&format!("d{depth}"), Some((depth - 1) as u32)));
    }
    assert!(matches!(
        file_protocol::encode_offer(&Offer {
            transfer_id: sample_transfer_id(),
            total_file_bytes: 0,
            entries: too_deep,
        }),
        Err(OfferError::Illegal(_))
    ));
}

#[test]
fn offer_rejects_malformed_framing() {
    assert!(matches!(
        file_protocol::decode_offer(&vec![0_u8; file_protocol::MAX_OFFER_PAYLOAD + 1]),
        Err(OfferError::Malformed)
    ));
    let payload = offer_payload(vec![file_entry("a", None, 1)]);
    assert!(matches!(
        file_protocol::decode_offer(&payload[..payload.len() - 1]),
        Err(OfferError::Malformed)
    ));
    let mut extra = payload.clone();
    extra.push(0);
    assert!(matches!(
        file_protocol::decode_offer(&extra),
        Err(OfferError::Malformed)
    ));
    let mut bad_id = payload.clone();
    bad_id[..16].copy_from_slice(&[0_u8; 16]);
    assert!(matches!(
        file_protocol::decode_offer(&bad_id),
        Err(OfferError::Malformed)
    ));
    // Invalid UTF-8 in a name.
    let mut bad_utf8 = payload.clone();
    let name_offset = 16 + 4 + 8 + 1 + 1 + 4 + 2;
    bad_utf8[name_offset] = 0xFF;
    assert!(matches!(
        file_protocol::decode_offer(&bad_utf8),
        Err(OfferError::Illegal(_))
    ));
}

#[test]
fn zero_byte_file_offer_round_trips() {
    let offer = Offer {
        transfer_id: sample_transfer_id(),
        total_file_bytes: 0,
        entries: vec![
            dir_entry("empty-dir", None),
            file_entry("zero.bin", None, 0),
        ],
    };
    let payload = file_protocol::encode_offer(&offer).unwrap();
    assert_eq!(file_protocol::decode_offer(&payload).unwrap(), offer);
}

// ----- receive-side name mapping -----

#[test]
fn name_mapping_replaces_illegal_characters() {
    assert_eq!(
        file_manifest::map_component("a<b:c\"d/e\\f|g?h*i", 255),
        "a_b_c_d_e_f_g_h_i"
    );
    assert_eq!(
        file_manifest::map_component("with\u{0001}control", 255),
        "with_control"
    );
    assert_eq!(
        file_manifest::map_component("trailing. . ", 255),
        "trailing"
    );
    assert_eq!(file_manifest::map_component("...", 255), "_");
    assert_eq!(file_manifest::map_component("ok.txt", 255), "ok.txt");
}

#[test]
fn name_mapping_covers_every_reserved_name() {
    for name in [
        "CON",
        "con",
        "PRN",
        "AUX",
        "NUL",
        "CLOCK$",
        "CONIN$",
        "CONOUT$",
        "COM1",
        "com9",
        "LPT1",
        "lpt9",
        "COM\u{00B9}",
        "COM\u{00B2}",
        "com\u{00B3}",
        "LPT\u{00B9}",
        "LPT\u{00B2}",
        "lpt\u{00B3}",
    ] {
        let mapped = file_manifest::map_component(name, 255);
        assert!(
            !file_manifest::conflict_key(&mapped).eq(&file_manifest::conflict_key(name))
                || mapped.ends_with('_'),
            "{name} must be renamed, got {mapped}"
        );
    }
    assert_eq!(file_manifest::map_component("CON.txt", 255), "CON_.txt");
    assert_eq!(
        file_manifest::map_component("console.txt", 255),
        "console.txt"
    );
    assert_eq!(file_manifest::map_component("COM10", 255), "COM10");
}

#[test]
fn name_truncation_keeps_extension_and_surrogates() {
    let long_stem = format!("{}.txt", "中".repeat(300));
    let mapped = file_manifest::map_component(&long_stem, 255);
    assert!(mapped.encode_utf16().count() <= 255);
    assert!(mapped.ends_with(".txt"));

    // An emoji (surrogate pair) must never be split at the boundary.
    let emoji_name = format!("{}.bin", "\u{1F600}".repeat(200));
    let mapped = file_manifest::map_component(&emoji_name, 255);
    assert!(mapped.encode_utf16().count() <= 255);
    assert!(!mapped.ends_with('\u{FFFD}'));
    assert!(mapped.ends_with(".bin"));

    let no_extension = file_manifest::map_component(&"a".repeat(300), 10);
    assert_eq!(no_extension.encode_utf16().count(), 10);
}

#[test]
fn conflict_keys_merge_case_and_normalization() {
    let composed = "Ä.txt";
    let decomposed = "A\u{0308}.txt";
    assert_eq!(
        file_manifest::conflict_key(composed),
        file_manifest::conflict_key(decomposed)
    );
    assert_eq!(
        file_manifest::conflict_key("REPORT.PDF"),
        file_manifest::conflict_key("report.pdf")
    );
}

#[test]
fn conflict_resolution_numbers_stably() {
    let entries = vec![
        file_entry("a<b.txt", None, 1),
        file_entry("a>b.txt", None, 1),
        file_entry("A_B.TXT", None, 1),
        file_entry("unique.txt", None, 1),
    ];
    let rels = file_manifest::map_receive_names(&entries, 255);
    let names: Vec<String> = rels
        .iter()
        .map(|rel| rel.to_string_lossy().into_owned())
        .collect();
    assert_eq!(names[0], "a_b.txt");
    assert_eq!(names[1], "a_b (2).txt");
    assert_eq!(names[2], "A_B (3).TXT");
    assert_eq!(names[3], "unique.txt");
}

#[test]
fn conflict_suffix_fits_the_component_limit() {
    let long_name = "中".repeat(300);
    let entries = vec![
        file_entry(&long_name, None, 1),
        file_entry(&long_name, None, 1),
    ];
    let rels = file_manifest::map_receive_names(&entries, 255);
    let first = rels[0].to_string_lossy().into_owned();
    let second = rels[1].to_string_lossy().into_owned();
    assert!(first.encode_utf16().count() <= 255);
    assert!(second.encode_utf16().count() <= 255);
    assert!(second.contains(" (2)"));
    assert_ne!(
        file_manifest::conflict_key(&first),
        file_manifest::conflict_key(&second)
    );
}

#[test]
fn twenty_thousand_identical_names_map_uniquely_and_stably() {
    let entries = vec![file_entry("same.txt", None, 0); file_protocol::MAX_ENTRIES];
    let first = file_manifest::map_receive_names(&entries, 255);
    let second = file_manifest::map_receive_names(&entries, 255);
    assert_eq!(first, second);
    assert_eq!(first[0], PathBuf::from("same.txt"));
    assert_eq!(first[1], PathBuf::from("same (2).txt"));
    assert_eq!(
        first.last().unwrap(),
        &PathBuf::from(format!("same ({}).txt", file_protocol::MAX_ENTRIES))
    );
    let unique: HashSet<String> = first
        .iter()
        .map(|path| file_manifest::conflict_key(&path.to_string_lossy()))
        .collect();
    assert_eq!(unique.len(), file_protocol::MAX_ENTRIES);
    assert!(
        first
            .iter()
            .all(|path| path.as_os_str().encode_wide().count() <= 255)
    );
}

#[test]
fn cache_capacity_counts_bytes_entries_and_evicts_oldest_unreferenced() {
    let gib = 1_024_u64 * 1_024 * 1_024;
    let records = vec![
        file_cache::CacheRecord {
            name: "referenced".to_string(),
            logical_bytes: 5 * gib,
            entry_count: 1_000,
            completed_millis: 1,
            referenced: true,
        },
        file_cache::CacheRecord {
            name: "newer".to_string(),
            logical_bytes: 15 * gib,
            entry_count: 8_000,
            completed_millis: 3,
            referenced: false,
        },
        file_cache::CacheRecord {
            name: "oldest".to_string(),
            logical_bytes: 30 * gib,
            entry_count: 10_000,
            completed_millis: 2,
            referenced: false,
        },
    ];
    let available = file_cache::required_free(gib).unwrap();
    let plan = file_cache::plan_capacity(&records, gib, 2_000, available);
    assert!(plan.fits);
    assert_eq!(plan.evict, ["oldest"]);

    let all_referenced = [file_cache::CacheRecord {
        name: "protected".to_string(),
        logical_bytes: file_protocol::MAX_LOGICAL_BYTES,
        entry_count: file_protocol::MAX_ENTRIES,
        completed_millis: 1,
        referenced: true,
    }];
    let refused =
        file_cache::plan_capacity(&all_referenced, 0, 1, file_cache::required_free(0).unwrap());
    assert!(!refused.fits);
    assert!(refused.evict.is_empty());

    let zero_byte_entries = [file_cache::CacheRecord {
        name: "zero-byte-files".to_string(),
        logical_bytes: 0,
        entry_count: file_protocol::MAX_ENTRIES - 1,
        completed_millis: 1,
        referenced: true,
    }];
    assert!(
        !file_cache::plan_capacity(
            &zero_byte_entries,
            0,
            2,
            file_cache::required_free(0).unwrap(),
        )
        .fits
    );
}

#[test]
fn cache_disk_budget_handles_exact_boundary_shortfall_and_overflow() {
    let incoming = 123_u64;
    let required = file_cache::required_free(incoming).unwrap();
    assert!(file_cache::plan_capacity(&[], incoming, 1, required).fits);
    assert!(!file_cache::plan_capacity(&[], incoming, 1, required - 1).fits);
    assert_eq!(file_cache::required_free(u64::MAX), None);
}

#[test]
fn cache_metadata_distinguishes_partial_completed_corrupt_and_legacy_roots() {
    let tree = TempTree::new("cache-metadata");
    let id = [0xAB_u8; 16];
    let name = file_protocol::transfer_id_hex(&id);
    let directory = tree.path(&name);
    fs::create_dir_all(&directory).unwrap();

    file_cache::write_partial(&directory, &id, 42, 3).unwrap();
    assert!(file_cache::load_completed(&name, &directory).is_err());
    assert!(directory.join(file_cache::PARTIAL_METADATA).is_file());

    let completed = file_cache::mark_completed(&directory, &id, 42, 3).unwrap();
    assert_eq!(completed.transfer_id, id);
    assert_eq!(completed.logical_bytes, 42);
    assert_eq!(completed.entry_count, 3);
    assert!(completed.completed_millis > 0);
    assert!(!directory.join(file_cache::PARTIAL_METADATA).exists());
    assert_eq!(
        file_cache::load_completed(&name, &directory).unwrap(),
        completed
    );

    let other_name = file_protocol::transfer_id_hex(&[0xCD_u8; 16]);
    assert!(file_cache::load_completed(&other_name, &directory).is_err());
    fs::write(directory.join(file_cache::COMPLETED_METADATA), b"corrupt").unwrap();
    assert!(file_cache::load_completed(&name, &directory).is_err());

    let legacy = tree.path("00112233445566778899aabbccddeeff");
    fs::create_dir_all(&legacy).unwrap();
    assert!(file_cache::load_completed("00112233445566778899aabbccddeeff", &legacy).is_err());
}

#[test]
fn cache_reference_and_retention_rules_are_conservative() {
    let root = PathBuf::from(r"C:\cache\00112233445566778899aabbccddeeff");
    assert!(file_cache::is_referenced(
        &root,
        &[root.join("folder").join("file.txt")]
    ));
    assert!(!file_cache::is_referenced(
        &root,
        &[PathBuf::from(r"C:\cache\another")]
    ));
    let retention = file_cache::RETENTION.as_millis() as u64;
    assert!(!file_cache::is_expired(1_000, 1_000 + retention));
    assert!(file_cache::is_expired(1_000, 1_001 + retention));
}

// ----- CF_HDROP byte layout and ownership -----

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().collect()
}

#[test]
fn dropfiles_blob_matches_shell_layout() {
    let paths = [wide("C:\\a.txt"), wide("D:\\中 文")];
    let blob = file_clipboard::dropfiles_blob(&paths);

    let mut expected = Vec::new();
    expected.extend_from_slice(&20_u32.to_le_bytes());
    expected.extend_from_slice(&0_i32.to_le_bytes());
    expected.extend_from_slice(&0_i32.to_le_bytes());
    expected.extend_from_slice(&0_i32.to_le_bytes());
    expected.extend_from_slice(&1_i32.to_le_bytes());
    for path in &paths {
        for unit in path {
            expected.extend_from_slice(&unit.to_le_bytes());
        }
        expected.extend_from_slice(&0_u16.to_le_bytes());
    }
    expected.extend_from_slice(&0_u16.to_le_bytes());
    assert_eq!(blob, expected);
    assert_eq!(file_clipboard::DROPEFFECT_COPY, 1);
}

struct MockOps {
    log: RefCell<Vec<&'static str>>,
    handles: RefCell<Vec<windows::Win32::Foundation::HGLOBAL>>,
    fail_effect: bool,
    fail_hdrop: bool,
}

impl file_clipboard::ClipboardOps for MockOps {
    fn open(&self) -> Result<(), file_clipboard::ClipboardFailure> {
        self.log.borrow_mut().push("open");
        Ok(())
    }

    fn empty(&self) -> Result<(), file_clipboard::ClipboardFailure> {
        self.log.borrow_mut().push("empty");
        Ok(())
    }

    fn set(
        &self,
        format: u32,
        handle: windows::Win32::Foundation::HGLOBAL,
    ) -> Result<(), file_clipboard::ClipboardFailure> {
        self.handles.borrow_mut().push(handle);
        if format == file_clipboard::CF_HDROP {
            self.log.borrow_mut().push("set-hdrop");
            if self.fail_hdrop {
                return Err(file_clipboard::ClipboardFailure::Failed(
                    "hdrop".to_string(),
                ));
            }
        } else {
            self.log.borrow_mut().push("set-effect");
            if self.fail_effect {
                return Err(file_clipboard::ClipboardFailure::Failed(
                    "effect".to_string(),
                ));
            }
        }
        Ok(())
    }

    fn close(&self) {
        self.log.borrow_mut().push("close");
    }
}

fn global_valid(handle: windows::Win32::Foundation::HGLOBAL) -> bool {
    (unsafe { windows::Win32::System::Memory::GlobalSize(handle) }) != 0
}

fn free_all(handles: &[windows::Win32::Foundation::HGLOBAL]) {
    for handle in handles {
        if global_valid(*handle) {
            let _ = unsafe { windows::Win32::Foundation::GlobalFree(Some(*handle)) };
        }
    }
}

#[test]
fn publish_writes_hdrop_before_copy_effect() {
    let ops = MockOps {
        log: RefCell::new(Vec::new()),
        handles: RefCell::new(Vec::new()),
        fail_effect: false,
        fail_hdrop: false,
    };
    file_clipboard::publish_with(&ops, 0xC000, &[wide("C:\\a.txt")]).unwrap();
    assert_eq!(
        ops.log.borrow().as_slice(),
        ["open", "empty", "set-hdrop", "set-effect", "close"]
    );
    // Ownership moved to the system: nothing may be freed by the publisher.
    let handles = ops.handles.borrow();
    assert!(handles.iter().all(|handle| global_valid(*handle)));
    free_all(&handles);
}

#[test]
fn publish_effect_failure_leaves_no_half_written_clipboard() {
    let ops = MockOps {
        log: RefCell::new(Vec::new()),
        handles: RefCell::new(Vec::new()),
        fail_effect: true,
        fail_hdrop: false,
    };
    let result = file_clipboard::publish_with(&ops, 0xC000, &[wide("C:\\a.txt")]);
    assert!(result.is_err());
    assert_eq!(
        ops.log.borrow().as_slice(),
        ["open", "empty", "set-hdrop", "set-effect", "empty", "close"]
    );
    // The system released CF_HDROP through the second empty; the DropEffect
    // handle was still ours and had to be freed by the publisher.
    let handles = ops.handles.borrow();
    assert_eq!(handles.len(), 2);
    assert!(global_valid(handles[0]));
    assert!(!global_valid(handles[1]));
    free_all(&handles);
}

#[test]
fn publish_hdrop_failure_frees_both_handles() {
    let ops = MockOps {
        log: RefCell::new(Vec::new()),
        handles: RefCell::new(Vec::new()),
        fail_effect: false,
        fail_hdrop: true,
    };
    let result = file_clipboard::publish_with(&ops, 0xC000, &[wide("C:\\a.txt")]);
    assert!(result.is_err());
    assert_eq!(
        ops.log.borrow().as_slice(),
        ["open", "empty", "set-hdrop", "close"]
    );
    let handles = ops.handles.borrow();
    assert_eq!(handles.len(), 1);
    assert!(!global_valid(handles[0]));
}

// ----- enumeration over a real temp tree -----

struct TempTree(PathBuf);

impl TempTree {
    fn new(name: &str) -> Self {
        let root = std::env::temp_dir().join(format!("meno-test-{}-{}", name, std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        Self(root)
    }

    fn path(&self, relative: &str) -> PathBuf {
        self.0.join(relative)
    }
}

impl Drop for TempTree {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(file_manifest::io_path(&self.0));
    }
}

#[test]
fn enumeration_builds_ordered_manifest_with_metadata() {
    let tree = TempTree::new("enumerate");
    fs::create_dir_all(tree.path("dir/sub")).unwrap();
    fs::create_dir_all(tree.path("empty-dir")).unwrap();
    fs::write(tree.path("dir/b.txt"), b"bb").unwrap();
    fs::write(tree.path("dir/中.txt"), b"c").unwrap();
    fs::write(tree.path("dir/sub/😀.txt"), b"").unwrap();
    fs::write(tree.path("z last.txt"), b"zzz").unwrap();
    let hidden = tree.path("dir/.hidden");
    fs::write(&hidden, b"h").unwrap();
    let wide_path: Vec<u16> = std::os::windows::ffi::OsStrExt::encode_wide(hidden.as_os_str())
        .chain(std::iter::once(0))
        .collect();
    unsafe {
        windows::Win32::Storage::FileSystem::SetFileAttributesW(
            windows::core::PCWSTR(wide_path.as_ptr()),
            windows::Win32::Storage::FileSystem::FILE_ATTRIBUTE_HIDDEN,
        )
        .unwrap();
    }

    let manifest = file_manifest::enumerate(&[
        tree.path("dir"),
        tree.path("empty-dir"),
        tree.path("z last.txt"),
    ])
    .unwrap();

    let names: Vec<&str> = manifest
        .entries
        .iter()
        .map(|entry| entry.name.as_str())
        .collect();
    assert_eq!(
        names,
        [
            "dir",
            ".hidden",
            "b.txt",
            "sub",
            "😀.txt",
            "中.txt",
            "empty-dir",
            "z last.txt"
        ]
    );
    let dir = &manifest.entries[0];
    assert!(dir.directory && dir.parent.is_none());
    let hidden_entry = &manifest.entries[1];
    assert!(hidden_entry.hidden);
    assert_eq!(hidden_entry.parent, Some(0));
    assert_eq!(hidden_entry.size, 1);
    let sub = &manifest.entries[3];
    assert!(sub.directory && sub.parent == Some(0));
    let emoji = &manifest.entries[4];
    assert_eq!(emoji.parent, Some(3));
    assert_eq!(emoji.size, 0);
    assert_eq!(manifest.total_file_bytes, 2 + 1 + 1 + 3);
    assert!(
        manifest
            .entries
            .iter()
            .all(|entry| entry.modified_millis > 0)
    );
    assert!(file_manifest::unchanged(&manifest.entries[2]));
    assert!(
        manifest
            .entries
            .iter()
            .all(|entry| entry.directory == entry.path.is_none())
    );
}

#[test]
fn enumeration_detects_source_changes() {
    let tree = TempTree::new("changed");
    fs::write(tree.path("a.txt"), b"one").unwrap();
    let manifest = file_manifest::enumerate(&[tree.path("a.txt")]).unwrap();
    assert!(file_manifest::unchanged(&manifest.entries[0]));
    std::thread::sleep(std::time::Duration::from_millis(20));
    fs::write(tree.path("a.txt"), b"two!").unwrap();
    assert!(!file_manifest::unchanged(&manifest.entries[0]));
}

#[test]
fn enumeration_rejects_junctions_and_missing_paths() {
    let tree = TempTree::new("links");
    fs::create_dir_all(tree.path("real")).unwrap();
    fs::write(tree.path("real/a.txt"), b"a").unwrap();
    let junction = tree.path("link");
    let status = std::process::Command::new("cmd")
        .args([
            "/c",
            "mklink",
            "/J",
            &junction.to_string_lossy(),
            &tree.path("real").to_string_lossy(),
        ])
        .output()
        .unwrap();
    assert!(status.status.success());
    assert!(file_manifest::enumerate(&[junction]).is_err());
    assert!(file_manifest::enumerate(&[tree.path("missing")]).is_err());
}

#[test]
fn enumeration_rejects_too_many_top_level_items() {
    let tree = TempTree::new("limits");
    fs::write(tree.path("a.txt"), b"a").unwrap();
    let paths = vec![tree.path("a.txt"); file_protocol::MAX_TOP_LEVEL + 1];
    assert!(file_manifest::enumerate(&paths).is_err());
}

// ----- file transfer worker state machine -----

static UI_CLASS_COUNTER: AtomicU32 = AtomicU32::new(0);

unsafe extern "system" fn test_ui_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_FILE_CLIPBOARD_REQUEST {
        let requests = UI_REQUESTS.get_or_init(|| Mutex::new(VecDeque::new()));
        loop {
            let request = {
                let mut requests = requests.lock().unwrap();
                requests
                    .iter()
                    .position(|entry| entry.1 == hwnd.0 as usize)
                    .and_then(|index| requests.remove(index))
                    .map(|entry| entry.2)
            };
            let Some(request) = request else {
                break;
            };
            let config = UI_CONFIGS
                .get_or_init(|| Mutex::new(HashMap::new()))
                .lock()
                .unwrap()
                .get(&(hwnd.0 as usize))
                .cloned()
                .unwrap_or(TestUiConfig {
                    referenced: Ok(Vec::new()),
                    publish_ok: true,
                });
            match request {
                FileUiRequest::Publish { result, .. } => {
                    let response = if config.publish_ok {
                        Ok(())
                    } else {
                        Err("injected clipboard failure".to_string())
                    };
                    let _ = result.send(response);
                }
                FileUiRequest::Referenced { result } => {
                    let _ = result.send(config.referenced);
                }
            };
        }
        return LRESULT(0);
    }
    if message == WM_DESTROY {
        unsafe { PostQuitMessage(0) };
        return LRESULT(0);
    }
    unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
}

// A real message-only window answering file-UI requests without touching the
// actual system clipboard.
struct TestUi {
    hwnd: HWND,
    pump: Option<thread::JoinHandle<()>>,
}

fn start_test_ui() -> TestUi {
    start_test_ui_with(TestUiConfig {
        referenced: Ok(Vec::new()),
        publish_ok: true,
    })
}

fn start_test_ui_with(config: TestUiConfig) -> TestUi {
    let (sender, receiver) = mpsc::channel();
    let pump = thread::spawn(move || {
        let instance = HINSTANCE(unsafe { GetModuleHandleW(None) }.unwrap().0);
        let class_name: Vec<u16> = format!(
            "MenoFileTransferTestUi{}",
            UI_CLASS_COUNTER.fetch_add(1, Ordering::Relaxed)
        )
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
        let class = WNDCLASSW {
            lpfnWndProc: Some(test_ui_proc),
            hInstance: instance,
            lpszClassName: PCWSTR(class_name.as_ptr()),
            ..Default::default()
        };
        unsafe { RegisterClassW(&class) };
        let hwnd = unsafe {
            CreateWindowExW(
                Default::default(),
                PCWSTR(class_name.as_ptr()),
                w!("MenoFileTransferTestUi"),
                WS_OVERLAPPED,
                0,
                0,
                0,
                0,
                Some(HWND_MESSAGE),
                None,
                Some(instance),
                None,
            )
            .unwrap()
        };
        sender.send(hwnd.0 as usize).unwrap();
        let mut message = MSG::default();
        while unsafe { GetMessageW(&mut message, None, 0, 0) }.0 > 0 {
            unsafe { DispatchMessageW(&message) };
        }
    });
    let hwnd = HWND(receiver.recv().unwrap() as *mut _);
    UI_CONFIGS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap()
        .insert(hwnd.0 as usize, config);
    TestUi {
        hwnd,
        pump: Some(pump),
    }
}

impl Drop for TestUi {
    fn drop(&mut self) {
        let _ = unsafe { PostMessageW(Some(self.hwnd), WM_CLOSE, WPARAM(0), LPARAM(0)) };
        if let Some(pump) = self.pump.take() {
            let _ = pump.join();
        }
        UI_CONFIGS
            .get_or_init(|| Mutex::new(HashMap::new()))
            .lock()
            .unwrap()
            .remove(&(self.hwnd.0 as usize));
    }
}

fn recv_frame(
    commands: &mpsc::Receiver<connection::NetworkCommand>,
) -> (u64, MessageKind, Vec<u8>) {
    match commands.recv_timeout(Duration::from_secs(10)) {
        Ok(connection::NetworkCommand::FileFrame { frame, .. }) => {
            (frame.message_id, frame.kind, frame.payload)
        }
        other => panic!("expected a file frame, got {other:?}"),
    }
}

fn recv_violation(commands: &mpsc::Receiver<connection::NetworkCommand>, connection_id: u64) {
    match commands.recv_timeout(Duration::from_secs(10)) {
        Ok(connection::NetworkCommand::ProtocolViolation { connection_id: got }) => {
            assert_eq!(got, connection_id)
        }
        other => panic!("expected a protocol violation, got {other:?}"),
    }
}

fn assert_no_command(commands: &mpsc::Receiver<connection::NetworkCommand>) {
    assert!(commands.recv_timeout(Duration::from_millis(200)).is_err());
}

fn wait_until_removed(paths: &[&Path]) {
    for _ in 0..100 {
        if paths.iter().all(|path| !path.exists()) {
            return;
        }
        thread::sleep(Duration::from_millis(10));
    }
    let remaining: Vec<&Path> = paths.iter().copied().filter(|path| path.exists()).collect();
    panic!("cache paths were not cleaned: {remaining:?}");
}

#[test]
fn worker_startup_cleans_unreferenced_legacy_partial_and_corrupt_roots() {
    let ui = start_test_ui();
    let tree = TempTree::new("cache-startup-cleanup");
    let cache_root = tree.path("FileClipboard");
    fs::create_dir_all(&cache_root).unwrap();

    let legacy = receive_cache_dir(&cache_root, &[0x11_u8; 16]);
    fs::create_dir_all(&legacy).unwrap();

    let partial_id = [0x22_u8; 16];
    let partial = receive_cache_dir(&cache_root, &partial_id);
    fs::create_dir_all(&partial).unwrap();
    file_cache::write_partial(&partial, &partial_id, 0, 1).unwrap();

    let corrupt_id = [0x33_u8; 16];
    let corrupt = receive_cache_dir(&cache_root, &corrupt_id);
    fs::create_dir_all(&corrupt).unwrap();
    file_cache::write_partial(&corrupt, &corrupt_id, 0, 1).unwrap();
    file_cache::mark_completed(&corrupt, &corrupt_id, 0, 1).unwrap();
    fs::write(corrupt.join(file_cache::COMPLETED_METADATA), b"corrupt").unwrap();

    let (events, inbox) = mpsc::channel::<file_transfer::WorkerEvent>();
    let (network, _commands) = mpsc::sync_channel(16);
    file_transfer::spawn_at(ui.hwnd, network, inbox, cache_root);
    wait_until_removed(&[&legacy, &partial, &corrupt]);
    drop(events);
}

#[test]
fn worker_protects_referenced_legacy_cache_and_refuses_new_offer() {
    let tree = TempTree::new("cache-legacy-reference");
    let cache_root = tree.path("FileClipboard");
    fs::create_dir_all(&cache_root).unwrap();
    let legacy = receive_cache_dir(&cache_root, &[0x44_u8; 16]);
    fs::create_dir_all(&legacy).unwrap();
    let referenced_file = legacy.join("still-on-clipboard.txt");
    fs::write(&referenced_file, b"keep").unwrap();
    let ui = start_test_ui_with(TestUiConfig {
        referenced: Ok(vec![referenced_file]),
        publish_ok: true,
    });

    let id = [0x45_u8; 16];
    let offer = Offer {
        transfer_id: id,
        total_file_bytes: 0,
        entries: vec![file_entry("new.txt", None, 0)],
    };
    let (events, inbox) = mpsc::channel();
    let (network, commands) = mpsc::sync_channel(16);
    file_transfer::spawn_at(ui.hwnd, network, inbox, cache_root);
    events
        .send(file_transfer::WorkerEvent::Link { connection_id: 5 })
        .unwrap();
    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 5,
            frame: Frame::new(
                MessageKind::FileOffer,
                file_protocol::encode_offer(&offer).unwrap(),
            ),
        })
        .unwrap();
    let (_, kind, payload) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileResult);
    assert_eq!(
        file_protocol::decode_result(&payload).unwrap(),
        (id, file_protocol::RESULT_NO_SPACE)
    );
    assert!(legacy.exists());
}

#[test]
fn worker_preserves_cache_when_clipboard_reference_read_fails() {
    let ui = start_test_ui_with(TestUiConfig {
        referenced: Err("injected clipboard read failure".to_string()),
        publish_ok: true,
    });
    let tree = TempTree::new("cache-reference-read-failure");
    let cache_root = tree.path("FileClipboard");
    let legacy = receive_cache_dir(&cache_root, &[0x47_u8; 16]);
    fs::create_dir_all(&legacy).unwrap();

    let (events, inbox) = mpsc::channel::<file_transfer::WorkerEvent>();
    let (network, _commands) = mpsc::sync_channel(16);
    file_transfer::spawn_at(ui.hwnd, network, inbox, cache_root);
    thread::sleep(Duration::from_millis(100));
    assert!(legacy.exists());
    drop(events);
}

#[test]
fn worker_publish_failure_removes_completed_cache_root() {
    let ui = start_test_ui_with(TestUiConfig {
        referenced: Ok(Vec::new()),
        publish_ok: false,
    });
    let tree = TempTree::new("receive-publish-failure");
    let cache_root = tree.path("FileClipboard");
    let id = [0x46_u8; 16];
    let offer = Offer {
        transfer_id: id,
        total_file_bytes: 0,
        entries: vec![file_entry("empty.txt", None, 0)],
    };
    let cache = receive_cache_dir(&cache_root, &id);

    let (events, inbox) = mpsc::channel();
    let (network, commands) = mpsc::sync_channel(16);
    file_transfer::spawn_at(ui.hwnd, network, inbox, cache_root);
    events
        .send(file_transfer::WorkerEvent::Link { connection_id: 6 })
        .unwrap();
    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 6,
            frame: Frame::new(
                MessageKind::FileOffer,
                file_protocol::encode_offer(&offer).unwrap(),
            ),
        })
        .unwrap();
    let (_, kind, _) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileAccept);
    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 6,
            frame: Frame::new(
                MessageKind::FileComplete,
                file_protocol::encode_id_only(&id),
            ),
        })
        .unwrap();
    let (_, kind, payload) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileResult);
    assert_eq!(
        file_protocol::decode_result(&payload).unwrap(),
        (id, file_protocol::RESULT_CLIPBOARD_FAILED)
    );
    assert!(!cache.exists());
}

#[test]
fn worker_reports_semantic_offer_limit_without_dropping_the_link() {
    let ui = start_test_ui();
    let tree = TempTree::new("receive-semantic-limit");
    let cache_root = tree.path("FileClipboard");
    let rejected_id = sample_transfer_id();
    let rejected_entries = [file_entry(
        "too-large.bin",
        None,
        file_protocol::MAX_LOGICAL_BYTES + 1,
    )];
    let rejected_payload =
        raw_offer_payload_with_total(&rejected_entries, file_protocol::MAX_LOGICAL_BYTES + 1);

    let (events, inbox) = mpsc::channel();
    let (network, commands) = mpsc::sync_channel(16);
    file_transfer::spawn_at(ui.hwnd, network, inbox, cache_root);
    events
        .send(file_transfer::WorkerEvent::Link { connection_id: 8 })
        .unwrap();
    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 8,
            frame: Frame::new(MessageKind::FileOffer, rejected_payload),
        })
        .unwrap();
    let (_, kind, payload) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileResult);
    assert_eq!(
        file_protocol::decode_result(&payload).unwrap(),
        (rejected_id, file_protocol::RESULT_BAD_MANIFEST)
    );

    let accepted_id = [0x55_u8; 16];
    let accepted = Offer {
        transfer_id: accepted_id,
        total_file_bytes: 0,
        entries: vec![file_entry("empty.txt", None, 0)],
    };
    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 8,
            frame: Frame::new(
                MessageKind::FileOffer,
                file_protocol::encode_offer(&accepted).unwrap(),
            ),
        })
        .unwrap();
    let (_, kind, payload) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileAccept);
    assert_eq!(file_protocol::decode_accept(&payload).unwrap(), accepted_id);
}

#[test]
fn rejected_semantic_offer_does_not_cancel_an_active_receive() {
    let ui = start_test_ui();
    let tree = TempTree::new("receive-invalid-offer-during-active");
    let cache_root = tree.path("FileClipboard");
    let active_id = [0x71_u8; 16];
    let active = Offer {
        transfer_id: active_id,
        total_file_bytes: 1,
        entries: vec![file_entry("active.bin", None, 1)],
    };

    let (events, inbox) = mpsc::channel();
    let (network, commands) = mpsc::sync_channel(16);
    file_transfer::spawn_at(ui.hwnd, network, inbox, cache_root.clone());
    events
        .send(file_transfer::WorkerEvent::Link { connection_id: 12 })
        .unwrap();
    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 12,
            frame: Frame::new(
                MessageKind::FileOffer,
                file_protocol::encode_offer(&active).unwrap(),
            ),
        })
        .unwrap();
    let (_, kind, payload) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileAccept);
    assert_eq!(file_protocol::decode_accept(&payload).unwrap(), active_id);

    let rejected_id = sample_transfer_id();
    let rejected_entries = [file_entry(
        "too-large.bin",
        None,
        file_protocol::MAX_LOGICAL_BYTES + 1,
    )];
    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 12,
            frame: Frame::new(
                MessageKind::FileOffer,
                raw_offer_payload_with_total(
                    &rejected_entries,
                    file_protocol::MAX_LOGICAL_BYTES + 1,
                ),
            ),
        })
        .unwrap();
    let (_, kind, payload) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileResult);
    assert_eq!(
        file_protocol::decode_result(&payload).unwrap(),
        (rejected_id, file_protocol::RESULT_BAD_MANIFEST)
    );

    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 12,
            frame: Frame::new(
                MessageKind::FileChunk,
                file_protocol::encode_chunk(&active_id, 0, 0, b"x"),
            ),
        })
        .unwrap();
    let (_, kind, payload) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileAck);
    assert_eq!(
        file_protocol::decode_ack(&payload).unwrap(),
        (active_id, 0, 1)
    );

    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 12,
            frame: Frame::new(
                MessageKind::FileComplete,
                file_protocol::encode_id_only(&active_id),
            ),
        })
        .unwrap();
    let (_, kind, payload) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileResult);
    assert_eq!(
        file_protocol::decode_result(&payload).unwrap(),
        (active_id, file_protocol::RESULT_OK)
    );
    assert_eq!(
        fs::read(receive_cache_dir(&cache_root, &active_id).join("active.bin")).unwrap(),
        b"x"
    );
}

#[test]
fn worker_send_gates_each_chunk_on_socket_and_ack() {
    let ui = start_test_ui();
    let tree = TempTree::new("send-flow");
    let size = file_protocol::MAX_CHUNK_DATA as u64 + 100;
    fs::write(tree.path("big.bin"), vec![7_u8; size as usize]).unwrap();

    let (events, inbox) = mpsc::channel();
    let (network, commands) = mpsc::sync_channel(16);
    file_transfer::spawn_at(ui.hwnd, network, inbox, tree.path("cache"));
    events
        .send(file_transfer::WorkerEvent::Link { connection_id: 7 })
        .unwrap();
    events
        .send(file_transfer::WorkerEvent::LocalFiles(vec![
            tree.path("big.bin"),
        ]))
        .unwrap();

    let (_, kind, payload) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileOffer);
    let offer = file_protocol::decode_offer(&payload).unwrap();
    assert_eq!(offer.entries.len(), 1);
    assert_eq!(offer.entries[0].size, size);
    assert_eq!(offer.total_file_bytes, size);
    let id = offer.transfer_id;

    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 7,
            frame: Frame::new(MessageKind::FileAccept, file_protocol::encode_id_only(&id)),
        })
        .unwrap();
    let (chunk_mid, kind, payload) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileChunk);
    let (chunk_id, entry, offset, data) = file_protocol::decode_chunk(&payload).unwrap();
    assert_eq!(chunk_id, id);
    assert_eq!((entry, offset, data.len() as u64), (0, 0, 524_288));

    // The next chunk must wait for both the socket write and the peer Ack.
    assert_no_command(&commands);
    events
        .send(file_transfer::WorkerEvent::Written {
            connection_id: 7,
            message_id: chunk_mid,
            ok: true,
        })
        .unwrap();
    assert_no_command(&commands);
    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 7,
            frame: Frame::new(
                MessageKind::FileAck,
                file_protocol::encode_ack(&id, 0, 524_288),
            ),
        })
        .unwrap();

    let (chunk2_mid, kind, payload) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileChunk);
    let (_, entry, offset, data) = file_protocol::decode_chunk(&payload).unwrap();
    assert_eq!((entry, offset, data.len() as u64), (0, 524_288, 100));

    events
        .send(file_transfer::WorkerEvent::Written {
            connection_id: 7,
            message_id: chunk2_mid,
            ok: true,
        })
        .unwrap();
    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 7,
            frame: Frame::new(
                MessageKind::FileAck,
                file_protocol::encode_ack(&id, 0, size),
            ),
        })
        .unwrap();
    let (complete_mid, kind, payload) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileComplete);
    assert_eq!(file_protocol::decode_complete(&payload).unwrap(), id);

    events
        .send(file_transfer::WorkerEvent::Written {
            connection_id: 7,
            message_id: complete_mid,
            ok: true,
        })
        .unwrap();
    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 7,
            frame: Frame::new(
                MessageKind::FileResult,
                file_protocol::encode_result(&id, file_protocol::RESULT_OK),
            ),
        })
        .unwrap();
    assert_no_command(&commands);
}

#[test]
fn worker_send_disconnects_on_mismatched_ack() {
    let ui = start_test_ui();
    let tree = TempTree::new("send-violation");
    fs::write(tree.path("a.bin"), b"some bytes").unwrap();

    let (events, inbox) = mpsc::channel();
    let (network, commands) = mpsc::sync_channel(16);
    file_transfer::spawn_at(ui.hwnd, network, inbox, tree.path("cache"));
    events
        .send(file_transfer::WorkerEvent::Link { connection_id: 3 })
        .unwrap();
    events
        .send(file_transfer::WorkerEvent::LocalFiles(vec![
            tree.path("a.bin"),
        ]))
        .unwrap();

    let (_, kind, payload) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileOffer);
    let id = file_protocol::decode_offer(&payload).unwrap().transfer_id;
    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 3,
            frame: Frame::new(MessageKind::FileAccept, file_protocol::encode_id_only(&id)),
        })
        .unwrap();
    let (chunk_mid, kind, _) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileChunk);
    events
        .send(file_transfer::WorkerEvent::Written {
            connection_id: 3,
            message_id: chunk_mid,
            ok: true,
        })
        .unwrap();
    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 3,
            frame: Frame::new(MessageKind::FileAck, file_protocol::encode_ack(&id, 0, 1)),
        })
        .unwrap();
    recv_violation(&commands, 3);
}

fn receive_cache_dir(root: &Path, id: &[u8; 16]) -> PathBuf {
    root.join(file_protocol::transfer_id_hex(id))
}

#[test]
fn worker_receive_caches_files_and_reports_success() {
    let ui = start_test_ui();
    let tree = TempTree::new("receive-success");
    let cache_root = tree.path("FileClipboard");
    let id = [0x42_u8; 16];
    let offer = Offer {
        transfer_id: id,
        total_file_bytes: 4,
        entries: vec![
            dir_entry("d", None),
            OfferEntry {
                directory: false,
                hidden: false,
                parent: Some(0),
                name: "a.txt".to_string(),
                size: 4,
                modified_millis: 1000,
            },
            file_entry("z.bin", None, 0),
        ],
    };
    let cache = receive_cache_dir(&cache_root, &id);

    let (events, inbox) = mpsc::channel();
    let (network, commands) = mpsc::sync_channel(16);
    file_transfer::spawn_at(ui.hwnd, network, inbox, cache_root);
    events
        .send(file_transfer::WorkerEvent::Link { connection_id: 1 })
        .unwrap();
    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 1,
            frame: Frame::new(
                MessageKind::FileOffer,
                file_protocol::encode_offer(&offer).unwrap(),
            ),
        })
        .unwrap();
    let (_, kind, payload) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileAccept);
    assert_eq!(file_protocol::decode_accept(&payload).unwrap(), id);

    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 1,
            frame: Frame::new(
                MessageKind::FileChunk,
                file_protocol::encode_chunk(&id, 1, 0, &[1, 2, 3, 4]),
            ),
        })
        .unwrap();
    let (_, kind, payload) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileAck);
    assert_eq!(file_protocol::decode_ack(&payload).unwrap(), (id, 1, 4));

    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 1,
            frame: Frame::new(
                MessageKind::FileComplete,
                file_protocol::encode_id_only(&id),
            ),
        })
        .unwrap();
    let (_, kind, payload) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileResult);
    assert_eq!(
        file_protocol::decode_result(&payload).unwrap(),
        (id, file_protocol::RESULT_OK)
    );

    let cached = cache.join("d").join("a.txt");
    assert_eq!(fs::read(&cached).unwrap(), [1, 2, 3, 4]);
    assert_eq!(
        fs::metadata(&cached).unwrap().modified().unwrap(),
        UNIX_EPOCH + Duration::from_millis(1000)
    );
    assert_eq!(fs::metadata(cache.join("z.bin")).unwrap().len(), 0);
    assert!(cache.join(file_cache::COMPLETED_METADATA).is_file());
    assert!(!cache.join(file_cache::PARTIAL_METADATA).exists());
    let metadata =
        file_cache::load_completed(&file_protocol::transfer_id_hex(&id), &cache).unwrap();
    assert_eq!(metadata.logical_bytes, 4);
    assert_eq!(metadata.entry_count, 3);
}

#[test]
fn worker_receive_disconnects_on_out_of_order_chunk() {
    let ui = start_test_ui();
    let tree = TempTree::new("receive-violation");
    let cache_root = tree.path("FileClipboard");
    let id = [0x24_u8; 16];
    let offer = Offer {
        transfer_id: id,
        total_file_bytes: 10,
        entries: vec![file_entry("a.bin", None, 10)],
    };

    let (events, inbox) = mpsc::channel();
    let (network, commands) = mpsc::sync_channel(16);
    file_transfer::spawn_at(ui.hwnd, network, inbox, cache_root.clone());
    events
        .send(file_transfer::WorkerEvent::Link { connection_id: 9 })
        .unwrap();
    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 9,
            frame: Frame::new(
                MessageKind::FileOffer,
                file_protocol::encode_offer(&offer).unwrap(),
            ),
        })
        .unwrap();
    let (_, kind, _) = recv_frame(&commands);
    assert_eq!(kind, MessageKind::FileAccept);

    events
        .send(file_transfer::WorkerEvent::Frame {
            connection_id: 9,
            frame: Frame::new(
                MessageKind::FileChunk,
                file_protocol::encode_chunk(&id, 0, 3, &[1]),
            ),
        })
        .unwrap();
    recv_violation(&commands, 9);
    assert!(!receive_cache_dir(&cache_root, &id).exists());
}

#[test]
fn io_path_prefixes_absolute_paths_only() {
    let absolute = file_manifest::io_path(Path::new("C:\\some\\where"));
    assert!(absolute.as_os_str().to_string_lossy().starts_with(r"\\?\"));
    let verbatim = file_manifest::io_path(Path::new(r"\\?\C:\already"));
    assert_eq!(verbatim.as_os_str().to_string_lossy(), r"\\?\C:\already");
    let unc = file_manifest::io_path(Path::new(r"\\server\share\dir"));
    assert_eq!(
        unc.as_os_str().to_string_lossy(),
        r"\\?\UNC\server\share\dir"
    );
}

#[test]
fn enumeration_depth_limit_counts_actual_entries() {
    let tree = TempTree::new("deep");
    let mut deepest = tree.0.clone();
    for _ in 0..file_protocol::MAX_DEPTH {
        deepest = deepest.join("d");
    }
    fs::create_dir_all(file_manifest::io_path(&deepest)).unwrap();
    // MAX_DEPTH nested directories, the last one empty: exactly at the limit.
    assert!(file_manifest::enumerate(&[tree.path("d")]).is_ok());

    // A file below the last directory exceeds MAX_DEPTH and must fail.
    fs::write(file_manifest::io_path(&deepest.join("f.txt")), b"x").unwrap();
    assert!(file_manifest::enumerate(&[tree.path("d")]).is_err());
}
