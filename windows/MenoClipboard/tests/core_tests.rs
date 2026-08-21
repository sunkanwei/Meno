#![allow(dead_code)]

#[path = "../src/core_modules.rs"]
mod core_modules;

use core_modules::{
    bounded_queue, discovery, display_contract, hid_broker_protocol, image_codec, logging,
    mouse_control, peer_name, protocol, virtual_hid,
};

use std::borrow::Cow;
use std::time::{Duration, Instant};

#[test]
fn runtime_log_generation_is_limited_to_128_kib() {
    assert_eq!(logging::MAX_LOG_BYTES, 128 * 1024);
}

use arboard::ImageData;
use mouse_control::{MouseControl, ReleaseOutcome};
use protocol::{Frame, FrameDecoder, MAX_IMAGE_SIZE, MessageKind, MouseEntryEdge, MouseMoveSample};

#[test]
fn bounded_queue_limits_items_bytes_and_wakeups() {
    use bounded_queue::{BoundedQueue, PushResult};

    let mut queue = BoundedQueue::new(2, 10);
    assert_eq!(queue.push("one", 4), PushResult::Queued { wake: true });
    assert_eq!(queue.push("two", 6), PushResult::Queued { wake: false });
    assert_eq!(queue.push("three", 1), PushResult::Full);
    let stats = queue.stats();
    assert_eq!(
        (stats.items, stats.bytes, stats.high_items, stats.high_bytes),
        (2, 10, 2, 10)
    );
    assert_eq!(stats.rejected, 1);

    let (batch, more) = queue.take_batch(1);
    assert_eq!(batch, vec!["one"]);
    assert!(more);
    assert_eq!(queue.push("three", 1), PushResult::Queued { wake: false });
    let (batch, more) = queue.take_batch(8);
    assert_eq!(batch, vec!["two", "three"]);
    assert!(!more);
    assert_eq!(queue.push("four", 1), PushResult::Queued { wake: true });
}

#[test]
fn bounded_queue_latest_replaces_stale_state() {
    use bounded_queue::{BoundedQueue, PushResult};

    let mut queue = BoundedQueue::new(2, 8);
    assert_eq!(queue.push("status", 4), PushResult::Queued { wake: true });
    assert_eq!(
        queue.push_latest("new", 3, |value| *value != "status"),
        PushResult::Queued { wake: false }
    );
    assert_eq!(
        queue.push_latest("latest", 4, |value| *value != "status"),
        PushResult::Replaced { wake: false }
    );
    let (batch, more) = queue.take_batch(8);
    assert_eq!(batch, vec!["status", "latest"]);
    assert!(!more);
    assert_eq!(queue.stats().replaced, 1);
}

#[test]
fn bounded_queue_rejection_preserves_the_previous_latest_item() {
    use bounded_queue::{BoundedQueue, PushResult};

    let mut queue = BoundedQueue::new(2, 8);
    assert_eq!(queue.push("old", 4), PushResult::Queued { wake: true });
    assert_eq!(
        queue.push_latest("oversized", 9, |_| true),
        PushResult::Full
    );
    let (batch, more) = queue.take_batch(8);
    assert_eq!(batch, vec!["old"]);
    assert!(!more);
    assert_eq!(queue.stats().replaced, 0);
    assert_eq!(queue.stats().rejected, 1);
}

#[test]
fn discovery_broadcast_supports_static_and_apipa_networks() {
    use std::net::Ipv4Addr;

    assert_eq!(
        discovery::broadcast_address(Ipv4Addr::new(192, 168, 50, 10), 24),
        Some(Ipv4Addr::new(192, 168, 50, 255))
    );
    assert_eq!(
        discovery::broadcast_address(Ipv4Addr::new(169, 254, 7, 9), 16),
        Some(Ipv4Addr::new(169, 254, 255, 255))
    );
    assert_eq!(
        discovery::broadcast_address(Ipv4Addr::new(10, 0, 0, 8), 32),
        None
    );
    assert_eq!(
        discovery::broadcast_address(Ipv4Addr::new(10, 0, 0, 8), 0),
        None
    );
}

#[test]
fn peer_name_is_safe_for_single_line_display_and_logs() {
    assert_eq!(
        peer_name::normalize("  Mac\r\nINFO forged\tname  "),
        "Mac INFO forged name"
    );
    assert_eq!(peer_name::normalize("\0\n\t"), "Mac");
    assert_eq!(peer_name::normalize(&"界".repeat(100)).chars().count(), 80);
}

fn move_sample(dx: i16) -> MouseMoveSample {
    MouseMoveSample { dx, dy: 0 }
}

fn move_sample_xy(dx: i16, dy: i16) -> MouseMoveSample {
    MouseMoveSample { dx, dy }
}

#[test]
fn log_repeat_folding_suppresses_and_summarizes() {
    use logging::FoldDecision;
    let start = Instant::now();
    let mut repeat = None;

    let FoldDecision::Write { summary } =
        logging::fold(&mut repeat, logging::Level::Info, "stuck", start)
    else {
        panic!("first message must be written");
    };
    assert_eq!(summary, None);

    for step in 1..=3 {
        assert!(matches!(
            logging::fold(
                &mut repeat,
                logging::Level::Info,
                "stuck",
                start + Duration::from_secs(step)
            ),
            FoldDecision::Suppress
        ));
    }

    let FoldDecision::Write { summary } = logging::fold(
        &mut repeat,
        logging::Level::Info,
        "different",
        start + Duration::from_secs(4),
    ) else {
        panic!("a new message must be written");
    };
    assert_eq!(
        summary.as_deref(),
        Some("(previous message repeated 3 times)")
    );
}

#[test]
fn log_repeat_folding_relogs_after_the_window() {
    use logging::FoldDecision;
    let start = Instant::now();
    let mut repeat = None;

    logging::fold(&mut repeat, logging::Level::Error, "stuck", start);
    assert!(matches!(
        logging::fold(
            &mut repeat,
            logging::Level::Error,
            "stuck",
            start + Duration::from_secs(30)
        ),
        FoldDecision::Suppress
    ));

    let FoldDecision::Write { summary } = logging::fold(
        &mut repeat,
        logging::Level::Error,
        "stuck",
        start + Duration::from_secs(61),
    ) else {
        panic!("a repeat past the relog window must be written");
    };
    assert_eq!(
        summary.as_deref(),
        Some("(previous message repeated 1 time)")
    );

    let FoldDecision::Write { summary } = logging::fold(
        &mut repeat,
        logging::Level::Error,
        "stuck",
        start + Duration::from_secs(122),
    ) else {
        panic!("an uninterrupted repeat past the window must be written");
    };
    assert_eq!(summary, None);
}

#[test]
fn log_repeat_folding_keeps_levels_separate() {
    use logging::FoldDecision;
    let start = Instant::now();
    let mut repeat = None;

    logging::fold(&mut repeat, logging::Level::Info, "same text", start);
    let FoldDecision::Write { summary } = logging::fold(
        &mut repeat,
        logging::Level::Error,
        "same text",
        start + Duration::from_secs(1),
    ) else {
        panic!("the same text at another level must not fold");
    };
    assert_eq!(summary, None);
}

#[test]
fn embedded_cursor_files_have_valid_headers() {
    let directory = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("assets/cursors");
    let mut cur_count = 0;
    let mut ani_count = 0;
    for entry in std::fs::read_dir(&directory).unwrap() {
        let path = entry.unwrap().path();
        let bytes = std::fs::read(&path).unwrap();
        match path.extension().and_then(|extension| extension.to_str()) {
            Some("cur") => {
                cur_count += 1;
                assert_eq!(&bytes[0..4], &[0, 0, 2, 0], "{}", path.display());
            }
            Some("ani") => {
                ani_count += 1;
                assert_eq!(&bytes[0..4], b"RIFF", "{}", path.display());
                assert_eq!(&bytes[8..12], b"ACON", "{}", path.display());
            }
            _ => {}
        }
    }
    assert_eq!((cur_count, ani_count), (19, 2));
}

#[test]
fn frame_encoding_matches_wire_format() {
    let frame = Frame {
        kind: MessageKind::Ping,
        message_id: 0x0102_0304_0506_0708,
        payload: Vec::new(),
    };

    assert_eq!(
        frame.encoded().unwrap(),
        vec![
            0x4D, 0x45, 0x4E, 0x4F, 0x05, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
            0x07, 0x08, 0x00, 0x00, 0x00, 0x00,
        ]
    );
}

#[test]
fn remote_shutdown_frame_matches_fixed_wire_bytes() {
    let frame = Frame {
        kind: MessageKind::ShutdownRequest,
        message_id: 0x0102_0304_0506_0708,
        payload: Vec::new(),
    };

    assert_eq!(
        frame.encoded().unwrap(),
        vec![
            0x4D, 0x45, 0x4E, 0x4F, 0x19, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
            0x07, 0x08, 0x00, 0x00, 0x00, 0x00,
        ]
    );
}

#[test]
fn windows_online_frame_matches_fixed_wire_bytes() {
    let frame = Frame {
        kind: MessageKind::WindowsOnline,
        message_id: 0x0102_0304_0506_0708,
        payload: Vec::new(),
    };

    assert_eq!(
        frame.encoded().unwrap(),
        vec![
            0x4D, 0x45, 0x4E, 0x4F, 0x1E, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
            0x07, 0x08, 0x00, 0x00, 0x00, 0x00,
        ]
    );
}

#[test]
fn decoder_handles_split_and_consecutive_frames() {
    let first = Frame {
        kind: MessageKind::Ping,
        message_id: 1,
        payload: Vec::new(),
    }
    .encoded()
    .unwrap();
    let second = Frame {
        kind: MessageKind::Text,
        message_id: 2,
        payload: "你好".as_bytes().to_vec(),
    }
    .encoded()
    .unwrap();
    let combined = [first, second].concat();
    let mut decoder = FrameDecoder::new();

    assert!(decoder.append(&combined[..7]).unwrap().is_empty());
    let frames = decoder.append(&combined[7..]).unwrap();

    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0].kind, MessageKind::Ping);
    assert_eq!(frames[0].message_id, 1);
    assert!(frames[0].payload.is_empty());
    assert_eq!(frames[1].kind, MessageKind::Text);
    assert_eq!(frames[1].message_id, 2);
    assert_eq!(frames[1].payload, "你好".as_bytes());
}

#[test]
fn decoder_rejects_invalid_header_and_oversized_payload() {
    let mut invalid = Frame {
        kind: MessageKind::Ping,
        message_id: 1,
        payload: Vec::new(),
    }
    .encoded()
    .unwrap();
    invalid[5] = 1;
    assert_eq!(
        FrameDecoder::new().append(&invalid).unwrap_err().kind(),
        std::io::ErrorKind::InvalidData
    );

    let mut oversized = vec![0_u8; protocol::HEADER_SIZE];
    oversized[0..4].copy_from_slice(&protocol::MAGIC);
    oversized[4] = MessageKind::Png as u8;
    oversized[16..20].copy_from_slice(&((MAX_IMAGE_SIZE + 1) as u32).to_be_bytes());
    assert_eq!(
        FrameDecoder::new().append(&oversized).unwrap_err().kind(),
        std::io::ErrorKind::InvalidData
    );
}

#[test]
fn decoder_skips_unknown_message_kinds_without_disconnecting() {
    let mut unknown = Vec::new();
    unknown.extend_from_slice(&protocol::MAGIC);
    unknown.push(200);
    unknown.extend_from_slice(&[0, 0, 0]);
    unknown.extend_from_slice(&9_u64.to_be_bytes());
    unknown.extend_from_slice(&3_u32.to_be_bytes());
    unknown.extend_from_slice(&[1, 2, 3]);
    let ping = Frame {
        kind: MessageKind::Ping,
        message_id: 1,
        payload: Vec::new(),
    }
    .encoded()
    .unwrap();

    let mut decoder = FrameDecoder::new();
    let frames = decoder.append(&[unknown.clone(), ping].concat()).unwrap();
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].kind, MessageKind::Ping);

    let mut split_decoder = FrameDecoder::new();
    assert!(split_decoder.append(&unknown[..22]).unwrap().is_empty());
    assert!(split_decoder.append(&unknown[22..]).unwrap().is_empty());
}

#[test]
fn extended_message_kinds_decode() {
    assert_eq!(
        MessageKind::try_from(15).unwrap(),
        MessageKind::MouseAcquired
    );
    assert_eq!(
        MessageKind::try_from(16).unwrap(),
        MessageKind::MouseReleased
    );
    assert_eq!(
        MessageKind::try_from(17).unwrap(),
        MessageKind::MouseControlHeartbeat
    );
    assert_eq!(MessageKind::try_from(18).unwrap(), MessageKind::FileOffer);
    assert_eq!(MessageKind::try_from(24).unwrap(), MessageKind::FileAck);
    assert_eq!(
        MessageKind::try_from(25).unwrap(),
        MessageKind::ShutdownRequest
    );
    assert_eq!(
        MessageKind::try_from(28).unwrap(),
        MessageKind::MicrophonePcm
    );
    assert_eq!(
        MessageKind::try_from(29).unwrap(),
        MessageKind::DirectionalMouseEnter
    );
    assert_eq!(MessageKind::DirectionalMouseEnter as u8, 0x1D);
    assert_eq!(
        MessageKind::try_from(30).unwrap(),
        MessageKind::WindowsOnline
    );
    assert_eq!(MessageKind::WindowsOnline as u8, 0x1E);
    assert_eq!(
        MessageKind::try_from(31).unwrap(),
        MessageKind::DiagnosticEvent
    );
    assert_eq!(MessageKind::DiagnosticEvent as u8, 0x1F);
    assert!(MessageKind::try_from(26).is_err());
    assert!(MessageKind::try_from(27).is_err());
}

#[test]
fn microphone_pcm_frame_uses_fixed_meno_header_bytes() {
    let encoded = Frame {
        kind: MessageKind::MicrophonePcm,
        message_id: 1,
        payload: vec![0; 1_920],
    }
    .encoded()
    .unwrap();
    assert_eq!(
        &encoded[..protocol::HEADER_SIZE],
        &[
            0x4D, 0x45, 0x4E, 0x4F, 0x1C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x07, 0x80,
        ]
    );
}

#[test]
fn directional_mouse_enter_frame_uses_fixed_meno_header_bytes() {
    let encoded = Frame {
        kind: MessageKind::DirectionalMouseEnter,
        message_id: 0x0102_0304_0506_0708,
        payload: vec![1, 2, 3, 4, 5, 6, 7, 8, 0x12, 0x34, 2],
    }
    .encoded()
    .unwrap();
    assert_eq!(
        &encoded[..protocol::HEADER_SIZE],
        &[
            0x4D, 0x45, 0x4E, 0x4F, 0x1D, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
            0x07, 0x08, 0x00, 0x00, 0x00, 0x0B,
        ]
    );
}

#[test]
fn discovery_request_uses_fixed_meno_bytes() {
    assert_eq!(
        protocol::discovery_packet(1, 0, 0),
        [0x4D, 0x45, 0x4E, 0x4F, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]
    );
}

#[test]
fn discovery_offer_rejects_invalid_packets_and_port_zero() {
    assert_eq!(
        protocol::parse_offer(&protocol::discovery_packet(2, 45_891, 45_892)),
        Some(protocol::DiscoveryOffer {
            clipboard_port: 45_891,
            mouse_port: 45_892,
        })
    );
    assert_eq!(
        protocol::parse_offer(&protocol::discovery_packet(2, 0, 45_892)),
        None
    );
    assert_eq!(
        protocol::parse_offer(&protocol::discovery_packet(1, 45_891, 45_892)),
        None
    );
    let mut reserved = protocol::discovery_packet(2, 45_891, 45_892);
    reserved[5] = 1;
    assert_eq!(protocol::parse_offer(&reserved), None);
}

#[test]
fn utf8_truncation_never_splits_a_character() {
    let payload = protocol::utf8_payload("ab😀中", 7);

    assert_eq!(payload.len(), 6);
    assert_eq!(String::from_utf8(payload).unwrap(), "ab😀");
}

#[test]
fn mouse_hello_matches_fixed_tlv_bytes() {
    assert_eq!(
        protocol::mouse_hello("Win", 4, 3840, 2160).unwrap(),
        vec![
            0x01, 0x00, 0x03, 0x57, 0x69, 0x6E, 0x02, 0x00, 0x08, 0x00, 0x03, 0x00, 0x04, 0x00,
            0x06, 0x00, 0x09, 0x03, 0x00, 0x02, 0x00, 0x04, 0x04, 0x00, 0x04, 0x00, 0x00, 0x0F,
            0x00, 0x05, 0x00, 0x04, 0x00, 0x00, 0x08, 0x70,
        ]
    );
}

#[test]
fn directional_mouse_handoff_capability_is_fixed_big_endian_nine() {
    assert_eq!(protocol::CAPABILITY_DIRECTIONAL_MOUSE_HANDOFF, 9);
    let payload = protocol::mouse_hello("Win", 4, 3840, 2160).unwrap();
    assert_eq!(&payload[15..17], &[0x00, 0x09]);
}

#[test]
fn windows_online_notification_capability_is_fixed_big_endian_ten() {
    assert_eq!(protocol::CAPABILITY_WINDOWS_ONLINE_NOTIFICATION, 10);
    let payload = protocol::clipboard_hello("Win");
    assert_eq!(&payload[17..19], &[0x00, 0x0A]);
}

#[test]
fn remote_diagnostics_capability_eleven_is_reserved_and_not_advertised() {
    assert_eq!(protocol::CAPABILITY_REMOTE_DIAGNOSTICS, 11);
    let hello =
        protocol::parse_hello(&protocol::mouse_hello("Win", 4, 3840, 2160).unwrap()).unwrap();
    assert!(
        !hello
            .capabilities
            .contains(protocol::CAPABILITY_REMOTE_DIAGNOSTICS)
    );
    let peer_hello = protocol::parse_hello(&[0x02, 0x00, 0x02, 0x00, 0x0B]).unwrap();
    assert!(peer_hello.capabilities.is_empty());
}

#[test]
fn mouse_hello_requires_driver_and_valid_primary_screen() {
    assert!(protocol::mouse_hello("Win", 0, 3840, 2160).is_err());
    assert!(protocol::mouse_hello("Win", 4, 0, 2160).is_err());
    assert!(protocol::mouse_hello("Win", 4, 1, 2160).is_err());
    assert!(protocol::mouse_hello("Win", 4, 3840, 0).is_err());
    assert!(protocol::mouse_hello("Win", 4, i32::MAX as u32 + 1, 2160).is_err());

    let with_driver =
        protocol::parse_hello(&protocol::mouse_hello("Win", 4, 3840, 2160).unwrap()).unwrap();
    assert!(
        with_driver
            .capabilities
            .contains(protocol::CAPABILITY_KEYBOARD_STATE)
    );
    assert!(
        with_driver
            .capabilities
            .contains(protocol::CAPABILITY_REMOTE_SHUTDOWN)
    );
    assert!(
        with_driver
            .capabilities
            .contains(protocol::CAPABILITY_DIRECTIONAL_MOUSE_HANDOFF)
    );
    assert_eq!(with_driver.driver_abi, Some(4));
    assert_eq!(with_driver.screen_width, Some(3840));
    assert_eq!(with_driver.screen_height, Some(2160));
}

#[test]
fn unavailable_mouse_hello_offers_shutdown_only() {
    let payload = protocol::mouse_unavailable_hello("Win");
    assert_eq!(
        payload,
        vec![
            0x01, 0x00, 0x03, 0x57, 0x69, 0x6E, 0x02, 0x00, 0x02, 0x00, 0x06,
        ]
    );
    let hello = protocol::parse_hello(&payload).unwrap();
    assert!(
        !hello
            .capabilities
            .contains(protocol::CAPABILITY_MOUSE_CONTROL)
    );
    assert!(
        !hello
            .capabilities
            .contains(protocol::CAPABILITY_KEYBOARD_STATE)
    );
    assert!(
        hello
            .capabilities
            .contains(protocol::CAPABILITY_REMOTE_SHUTDOWN)
    );
    assert!(
        !hello
            .capabilities
            .contains(protocol::CAPABILITY_REMOTE_DIAGNOSTICS)
    );
    assert_eq!(hello.driver_abi, None);
    assert_eq!(hello.screen_width, None);
    assert_eq!(hello.screen_height, None);
}

#[test]
fn clipboard_hello_offers_text_png_and_files() {
    let hello = protocol::parse_hello(&protocol::clipboard_hello("Win")).unwrap();
    assert_eq!(hello.name, "Win");
    assert!(
        hello
            .capabilities
            .contains(protocol::CAPABILITY_TEXT_CLIPBOARD)
    );
    assert!(
        hello
            .capabilities
            .contains(protocol::CAPABILITY_PNG_CLIPBOARD)
    );
    assert!(
        hello
            .capabilities
            .contains(protocol::CAPABILITY_FILE_CLIPBOARD)
    );
    assert!(
        hello
            .capabilities
            .contains(protocol::CAPABILITY_MAC_MICROPHONE)
    );
    assert!(
        hello
            .capabilities
            .contains(protocol::CAPABILITY_WINDOWS_ONLINE_NOTIFICATION)
    );
    assert!(
        !hello
            .capabilities
            .contains(protocol::CAPABILITY_MOUSE_CONTROL)
    );
    assert!(
        !hello
            .capabilities
            .contains(protocol::CAPABILITY_KEYBOARD_STATE)
    );
    assert!(
        !hello
            .capabilities
            .contains(protocol::CAPABILITY_REMOTE_SHUTDOWN)
    );
    assert_eq!(hello.driver_abi, None);
    assert_eq!(hello.screen_width, None);
    assert_eq!(hello.screen_height, None);
}

#[test]
fn clipboard_hello_capabilities_match_fixed_tlv_bytes() {
    let payload = protocol::clipboard_hello("Win");

    assert_eq!(
        payload,
        vec![
            0x01, 0x00, 0x03, 0x57, 0x69, 0x6E, 0x02, 0x00, 0x0A, 0x00, 0x01, 0x00, 0x02, 0x00,
            0x05, 0x00, 0x08, 0x00, 0x0A,
        ]
    );
}

#[test]
fn audio_hello_only_offers_microphone_and_has_fixed_tlv_bytes() {
    let payload = protocol::audio_hello("Win");
    assert_eq!(
        payload,
        vec![
            0x01, 0x00, 0x03, 0x57, 0x69, 0x6E, 0x02, 0x00, 0x02, 0x00, 0x08,
        ]
    );
    let hello = protocol::parse_hello(&payload).unwrap();
    assert_eq!(
        hello.capabilities,
        protocol::Capabilities::from_slice(&[protocol::CAPABILITY_MAC_MICROPHONE])
    );
    assert_eq!(hello.audio_port, None);
}

#[test]
fn hello_limits_total_size_without_splitting_characters() {
    let name = "中".repeat(200);
    let payload = protocol::mouse_hello(&name, 4, 3840, 2160).unwrap();

    assert!(payload.len() <= protocol::MAX_HELLO_SIZE);
    let hello = protocol::parse_hello(&payload).unwrap();
    assert!(hello.name.len() <= protocol::MAX_NAME_SIZE);
    assert_eq!(hello.name.chars().count(), 85);
    assert!(hello.name.chars().all(|character| character == '中'));
}

#[test]
fn philips_monitor_identity_is_derived_from_pnp_vendor_id() {
    assert_eq!(
        display_contract::philips_monitor_id(
            r"\\?\DISPLAY#PHLC26F#5&1958ed0d&0&UID8453#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}"
        ),
        Some(r"DISPLAY\PHLC26F".to_string())
    );
    assert_eq!(
        display_contract::philips_monitor_id(r"MONITOR\PHL1234\INSTANCE"),
        Some(r"DISPLAY\PHL1234".to_string())
    );
    assert_eq!(
        display_contract::philips_monitor_id(r"\\?\DISPLAY#VSC1234#INSTANCE"),
        None
    );
}

#[test]
fn hello_ignores_unknown_fields_and_capabilities() {
    let mut payload = vec![1, 0, 1, 0x57];
    payload.extend_from_slice(&[2, 0, 12, 0, 1, 0, 6, 0, 7, 0, 8, 0, 10, 0, 99]);
    payload.extend_from_slice(&[200, 0, 2, 0xAA, 0xBB]);

    let hello = protocol::parse_hello(&payload).unwrap();

    assert_eq!(hello.name, "W");
    assert!(
        hello
            .capabilities
            .contains(protocol::CAPABILITY_TEXT_CLIPBOARD)
    );
    assert!(
        hello
            .capabilities
            .contains(protocol::CAPABILITY_REMOTE_SHUTDOWN)
    );
    assert!(
        hello
            .capabilities
            .contains(protocol::CAPABILITY_MAC_MICROPHONE)
    );
    assert!(
        hello
            .capabilities
            .contains(protocol::CAPABILITY_WINDOWS_ONLINE_NOTIFICATION)
    );
    assert!(!hello.capabilities.contains(7));
    assert!(!hello.capabilities.contains(99));
}

#[test]
fn hello_rejects_duplicate_known_fields() {
    let mut payload = vec![1, 0, 1, 0x57];
    payload.extend_from_slice(&[1, 0, 1, 0x58]);
    assert!(protocol::parse_hello(&payload).is_err());

    let mut payload = vec![1, 0, 1, 0x57];
    payload.extend_from_slice(&[200, 0, 1, 1, 200, 0, 1, 2]);
    assert!(protocol::parse_hello(&payload).is_ok());

    let payload = [6, 0, 2, 0xBE, 0xEF, 6, 0, 2, 0xBE, 0xF0];
    assert!(protocol::parse_hello(&payload).is_err());
}

#[test]
fn hello_audio_port_is_unique_nonzero_big_endian_u16() {
    let hello = protocol::parse_hello(&[6, 0, 2, 0xBE, 0xEF]).unwrap();
    assert_eq!(hello.audio_port, Some(0xBEEF));
    assert!(protocol::parse_hello(&[6, 0, 2, 0, 0]).is_err());
    assert!(protocol::parse_hello(&[6, 0, 1, 1]).is_err());
    assert!(protocol::parse_hello(&[6, 0, 3, 0, 1, 2]).is_err());
}

#[test]
fn hello_rejects_malformed_lengths_and_oversized_payloads() {
    assert!(protocol::parse_hello(&[1, 0]).is_err());
    assert!(protocol::parse_hello(&[1, 0, 5, 0x57]).is_err());

    let mut long_name = vec![1, 1, 1];
    long_name.extend(std::iter::repeat_n(b'a', 257));
    assert!(protocol::parse_hello(&long_name).is_err());

    assert!(protocol::parse_hello(&[2, 0, 3, 0, 1, 0]).is_err());
    assert!(protocol::parse_hello(&[3, 0, 3, 0, 0, 4]).is_err());
    assert!(protocol::parse_hello(&[4, 0, 2, 0, 4]).is_err());

    let mut oversized = vec![1, 1, 0];
    oversized.extend(std::iter::repeat_n(b'a', 256));
    oversized.extend_from_slice(&[2, 0, 4, 0, 1, 0, 2]);
    oversized.extend_from_slice(&[200, 0, 250]);
    oversized.extend(std::iter::repeat_n(0, 250));
    assert!(oversized.len() > protocol::MAX_HELLO_SIZE);
    assert!(protocol::parse_hello(&oversized).is_err());
}

#[test]
fn capability_intersection_keeps_only_shared_capabilities() {
    let local = protocol::Capabilities::from_slice(&[
        protocol::CAPABILITY_TEXT_CLIPBOARD,
        protocol::CAPABILITY_PNG_CLIPBOARD,
    ]);
    let remote = protocol::Capabilities::from_slice(&[
        protocol::CAPABILITY_PNG_CLIPBOARD,
        protocol::CAPABILITY_MOUSE_CONTROL,
    ]);

    let negotiated = local.intersect(remote);

    assert!(!negotiated.contains(protocol::CAPABILITY_TEXT_CLIPBOARD));
    assert!(negotiated.contains(protocol::CAPABILITY_PNG_CLIPBOARD));
    assert!(!negotiated.contains(protocol::CAPABILITY_MOUSE_CONTROL));
    assert!(
        local
            .intersect(protocol::Capabilities::from_slice(&[
                protocol::CAPABILITY_KEYBOARD_STATE
            ]))
            .is_empty()
    );
}

#[test]
fn control_payload_is_big_endian_and_round_trips() {
    let payload = protocol::control_payload(0x0102_0304_0506_0708);

    assert_eq!(payload, [1, 2, 3, 4, 5, 6, 7, 8]);
    assert_eq!(
        protocol::control_header(&payload).unwrap(),
        0x0102_0304_0506_0708
    );
}

#[test]
fn control_header_rejects_zero_id_and_short_payload() {
    assert!(protocol::control_header(&[0, 0, 0, 0, 0, 0, 0, 0]).is_err());
    assert!(protocol::control_header(&[0, 0, 0, 0, 0, 0, 1]).is_err());
}

#[test]
fn mouse_enter_matches_fixed_wire_bytes() {
    assert_eq!(MessageKind::MouseEnter as u8, 7);
    let payload = [1, 2, 3, 4, 5, 6, 7, 8, 0xCA, 0xFE];

    let (control_id, normalized_y) = protocol::mouse_enter(&payload).unwrap();

    assert_eq!(control_id, 0x0102_0304_0506_0708);
    assert_eq!(normalized_y, 0xCAFE);
    assert_eq!(mouse_control::entry_position(MouseEntryEdge::Left, 2193), 1);
}

#[test]
fn mouse_enter_rejects_wrong_length() {
    assert!(protocol::mouse_enter(&protocol::control_payload(1)).is_err());
    assert!(protocol::mouse_enter(&[1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 2]).is_err());
}

#[test]
fn directional_mouse_enter_matches_fixed_wire_bytes() {
    let payload = [1, 2, 3, 4, 5, 6, 7, 8, 0x12, 0x34, 2];

    let (control_id, normalized_y, entry_edge) =
        protocol::directional_mouse_enter(&payload, true).unwrap();

    assert_eq!(control_id, 0x0102_0304_0506_0708);
    assert_eq!(normalized_y, 0x1234);
    assert_eq!(entry_edge, MouseEntryEdge::Right);
}

#[test]
fn directional_mouse_enter_requires_exact_length_valid_edge_and_negotiation() {
    let valid = [1, 2, 3, 4, 5, 6, 7, 8, 0x12, 0x34, 1];
    assert!(protocol::directional_mouse_enter(&valid[..10], true).is_err());
    assert!(
        protocol::directional_mouse_enter(&[1, 2, 3, 4, 5, 6, 7, 8, 0x12, 0x34, 1, 0], true,)
            .is_err()
    );
    for entry_edge in [0, 3, u8::MAX] {
        let mut invalid = valid;
        invalid[10] = entry_edge;
        assert!(protocol::directional_mouse_enter(&invalid, true).is_err());
    }
    let mut zero_control_id = valid;
    zero_control_id[..8].fill(0);
    assert!(protocol::directional_mouse_enter(&zero_control_id, true).is_err());
    assert!(protocol::directional_mouse_enter(&valid, false).is_err());
}

#[test]
fn mouse_move_accepts_one_to_sixteen_samples_in_order() {
    for count in [1_usize, 16] {
        let mut payload = protocol::control_payload(7).to_vec();
        payload.push(count as u8);
        for index in 0..count {
            payload.extend_from_slice(&(index as i16).to_be_bytes());
            payload.extend_from_slice(&(-(index as i16)).to_be_bytes());
        }

        let (control_id, samples) = protocol::decode_mouse_move(&payload).unwrap();

        assert_eq!(control_id, 7);
        assert_eq!(samples.len(), count);
        assert_eq!(samples[count - 1].dx, (count - 1) as i16);
        assert_eq!(samples[count - 1].dy, -((count - 1) as i16));
    }
}

#[test]
fn mouse_move_matches_fixed_wire_bytes() {
    let payload = [1, 2, 3, 4, 5, 6, 7, 8, 1, 0xFF, 0xFE, 0, 3];

    let (control_id, samples) = protocol::decode_mouse_move(&payload).unwrap();

    assert_eq!(control_id, 0x0102_0304_0506_0708);
    assert_eq!(samples, [MouseMoveSample { dx: -2, dy: 3 }]);
}

#[test]
fn mouse_move_rejects_bad_count_length_and_zero_id() {
    let mut zero_count = protocol::control_payload(1).to_vec();
    zero_count.push(0);
    assert!(protocol::decode_mouse_move(&zero_count).is_err());

    let mut too_many = protocol::control_payload(1).to_vec();
    too_many.push(17);
    too_many.extend(std::iter::repeat_n(0_u8, 17 * 4));
    assert!(protocol::decode_mouse_move(&too_many).is_err());

    let mut short = protocol::control_payload(1).to_vec();
    short.push(1);
    short.extend_from_slice(&[0, 1, 0]);
    assert!(protocol::decode_mouse_move(&short).is_err());

    let zero_id = [0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1];
    assert!(protocol::decode_mouse_move(&zero_id).is_err());
}

#[test]
fn mouse_button_validates_button_and_down_flag() {
    let mut payload = protocol::control_payload(3).to_vec();
    payload.extend_from_slice(&[1, 1]);
    assert_eq!(protocol::mouse_button(&payload).unwrap(), (3, 1, true));

    let fixed = [1, 2, 3, 4, 5, 6, 7, 8, 2, 0];
    assert_eq!(
        protocol::mouse_button(&fixed).unwrap(),
        (0x0102_0304_0506_0708, 2, false)
    );

    for tail in [[0_u8, 1], [4, 1], [1, 2]] {
        let mut invalid = protocol::control_payload(3).to_vec();
        invalid.extend_from_slice(&tail);
        assert!(protocol::mouse_button(&invalid).is_err());
    }

    assert!(protocol::mouse_button(&protocol::control_payload(3)).is_err());
}

#[test]
fn mouse_wheel_matches_fixed_wire_bytes() {
    let payload = [1, 2, 3, 4, 5, 6, 7, 8, 0xFF, 0xFF, 0xFF, 0xFF];
    assert_eq!(
        protocol::mouse_wheel(&payload).unwrap(),
        (0x0102_0304_0506_0708, -1)
    );

    let mut payload = protocol::control_payload(9).to_vec();
    payload.extend_from_slice(&(-2_i32).to_be_bytes());
    assert_eq!(protocol::mouse_wheel(&payload).unwrap(), (9, -2));
    assert!(protocol::mouse_wheel(&protocol::control_payload(9)).is_err());
}

#[test]
fn keyboard_state_message_matches_fixed_wire_bytes() {
    let payload = [1, 2, 3, 4, 5, 6, 7, 8, 1, 1, 4, 0, 0, 0, 0, 0];

    let (control_id, state) = protocol::keyboard_state_message(&payload).unwrap();

    assert_eq!(control_id, 0x0102_0304_0506_0708);
    assert_eq!(state.modifiers, 1);
    assert_eq!(state.keys, [0x04]);

    let mut invalid_inner = protocol::control_payload(5).to_vec();
    invalid_inner.extend_from_slice(&[0, 2, 0x04, 0x04, 0, 0, 0, 0]);
    assert!(protocol::keyboard_state_message(&invalid_inner).is_err());

    let mut short = protocol::control_payload(5).to_vec();
    short.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0]);
    assert!(protocol::keyboard_state_message(&short).is_err());
}

#[test]
fn keyboard_state_inner_format_is_fully_validated() {
    let state =
        protocol::decode_keyboard_state(&[0b0000_0011, 3, 0x06, 0x04, 0x05, 0, 0, 0]).unwrap();

    assert_eq!(state.modifiers, 0b0000_0011);
    assert_eq!(state.keys, [0x04, 0x05, 0x06]);

    for payload in [
        vec![0, 7, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09],
        vec![0, 1, 0x04, 1, 0, 0, 0, 0],
        vec![0, 2, 0x04, 0x04, 0, 0, 0, 0],
        vec![0, 1, 0xE0, 0, 0, 0, 0, 0],
        vec![0, 1, 0x03, 0, 0, 0, 0, 0],
        vec![0, 0, 0, 0, 0, 0, 0],
    ] {
        assert!(protocol::decode_keyboard_state(&payload).is_err());
    }
}

#[test]
fn control_only_accepts_exact_header() {
    assert_eq!(
        protocol::control_only(&[1, 2, 3, 4, 5, 6, 7, 8]).unwrap(),
        0x0102_0304_0506_0708
    );
    assert!(protocol::control_only(&[1, 2, 3, 4, 5, 6, 7, 8, 0]).is_err());
    assert!(protocol::control_only(&[0, 0, 0, 0, 0, 0, 0, 0]).is_err());
}

#[test]
fn mouse_leave_payload_carries_control_id_and_big_endian_position() {
    let payload = protocol::mouse_leave_payload(0x0102_0304_0506_0708, 0x1234);

    assert_eq!(payload, [1, 2, 3, 4, 5, 6, 7, 8, 0x12, 0x34]);
}

#[test]
fn png_round_trip_preserves_rgba_pixels() {
    let source = ImageData {
        width: 2,
        height: 1,
        bytes: Cow::Owned(vec![255, 0, 0, 255, 0, 255, 0, 128]),
    };

    let png = image_codec::encode_png(source).unwrap();
    assert!(png.len() <= MAX_IMAGE_SIZE);
    let decoded = image_codec::decode_png(&png).unwrap();

    assert_eq!(decoded.width, 2);
    assert_eq!(decoded.height, 1);
    assert_eq!(decoded.bytes.as_ref(), [255, 0, 0, 255, 0, 255, 0, 128]);
}

#[test]
fn image_budget_rejects_invalid_dimensions_and_lengths() {
    assert!(image_codec::checked_rgba_bytes(0, 1).is_err());
    assert!(image_codec::checked_rgba_bytes(image_codec::MAX_IMAGE_DIMENSION + 1, 1).is_err());
    assert_eq!(
        image_codec::checked_rgba_bytes(4096, 4096).unwrap(),
        image_codec::MAX_RGBA_BYTES
    );
    assert!(image_codec::checked_rgba_bytes(4096, 4097).is_err());

    let mismatched = ImageData {
        width: 2,
        height: 1,
        bytes: Cow::Owned(vec![0; 4]),
    };
    assert!(image_codec::encode_png(mismatched).is_err());
}

#[test]
fn png_header_over_dimension_limit_is_rejected_before_output_allocation() {
    fn crc32(bytes: &[u8]) -> u32 {
        let mut crc = u32::MAX;
        for &byte in bytes {
            crc ^= u32::from(byte);
            for _ in 0..8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & 0_u32.wrapping_sub(crc & 1));
            }
        }
        !crc
    }

    let mut png = image_codec::encode_png(ImageData {
        width: 1,
        height: 1,
        bytes: Cow::Owned(vec![0, 0, 0, 255]),
    })
    .unwrap();
    png[16..20].copy_from_slice(&((image_codec::MAX_IMAGE_DIMENSION + 1) as u32).to_be_bytes());
    let crc = crc32(&png[12..29]);
    png[29..33].copy_from_slice(&crc.to_be_bytes());

    let error = match image_codec::decode_png(&png) {
        Ok(_) => panic!("oversized PNG header was accepted"),
        Err(error) => error,
    };
    assert!(error.contains("dimensions exceed"), "{error}");
}

#[test]
fn enter_establishes_active_session_and_ack() {
    let mut control = MouseControl::new();
    let now = Instant::now();

    let outcome = control.enter(42, MouseEntryEdge::Left, now).unwrap();

    assert_eq!(outcome.control_id, 42);
    assert_eq!(outcome.replaced, None);
    assert!(!outcome.already_active);
    assert_eq!(control.active_control_id(), Some(42));
    assert_eq!(control.active_entry_edge(), Some(MouseEntryEdge::Left));
    assert_eq!(
        control.lease_deadline(),
        Some(now + mouse_control::LEASE_DURATION)
    );
}

#[test]
fn duplicate_enter_refreshes_lease_without_replacing() {
    let mut control = MouseControl::new();
    let start = Instant::now();
    control.enter(42, MouseEntryEdge::Left, start).unwrap();

    let outcome = control
        .enter(42, MouseEntryEdge::Left, start + Duration::from_millis(250))
        .unwrap();

    assert!(outcome.already_active);
    assert_eq!(outcome.replaced, None);
    assert_eq!(control.active_entry_edge(), Some(MouseEntryEdge::Left));
    assert_eq!(
        control.lease_deadline(),
        Some(start + Duration::from_millis(250) + mouse_control::LEASE_DURATION)
    );
}

#[test]
fn enter_with_new_id_replaces_old_session() {
    let mut control = MouseControl::new();
    let now = Instant::now();
    control.enter(1, MouseEntryEdge::Left, now).unwrap();

    let outcome = control.enter(2, MouseEntryEdge::Right, now).unwrap();

    assert_eq!(outcome.replaced, Some(1));
    assert!(!outcome.already_active);
    assert_eq!(control.active_control_id(), Some(2));
    assert_eq!(control.active_entry_edge(), Some(MouseEntryEdge::Right));
}

#[test]
fn duplicate_control_id_cannot_change_the_session_entry_edge() {
    let mut control = MouseControl::new();
    let now = Instant::now();
    control.enter(1, MouseEntryEdge::Right, now).unwrap();

    assert!(
        control
            .enter(1, MouseEntryEdge::Left, now + Duration::from_millis(1))
            .is_err()
    );
    assert_eq!(control.active_control_id(), Some(1));
    assert_eq!(control.active_entry_edge(), Some(MouseEntryEdge::Right));
}

#[test]
fn active_session_accepts_input_and_refreshes_lease() {
    let mut control = MouseControl::new();
    let start = Instant::now();
    control.enter(1, MouseEntryEdge::Left, start).unwrap();

    assert!(control.accept(1, start + Duration::from_millis(300)));
    assert_eq!(
        control.lease_deadline(),
        Some(start + Duration::from_millis(700))
    );
    assert_eq!(
        control.expire_lease(start + Duration::from_millis(699)),
        None
    );
    assert_eq!(
        control.expire_lease(start + Duration::from_millis(700)),
        Some(1)
    );
}

#[test]
fn stale_input_is_rejected_without_affecting_active_session() {
    let mut control = MouseControl::new();
    let start = Instant::now();
    control.enter(1, MouseEntryEdge::Left, start).unwrap();

    assert!(!control.accept(2, start));
    assert_eq!(control.active_control_id(), Some(1));
    assert!(control.accept(1, start));
}

#[test]
fn release_all_releases_and_acks() {
    let mut control = MouseControl::new();
    let start = Instant::now();
    control.enter(1, MouseEntryEdge::Left, start).unwrap();

    assert_eq!(control.release_all(1), ReleaseOutcome::Released(1));
    assert_eq!(control.active_control_id(), None);
    assert_eq!(control.active_entry_edge(), None);
    assert_eq!(control.lease_deadline(), None);
    assert!(!control.accept(1, start));
}

#[test]
fn repeated_release_all_reacks_without_reset() {
    let mut control = MouseControl::new();
    control
        .enter(1, MouseEntryEdge::Left, Instant::now())
        .unwrap();
    assert_eq!(control.release_all(1), ReleaseOutcome::Released(1));

    assert_eq!(control.release_all(1), ReleaseOutcome::ReAck(1));
    assert_eq!(control.active_control_id(), None);
    assert_eq!(control.active_entry_edge(), None);
}

#[test]
fn stale_release_all_does_not_release_new_session() {
    let mut control = MouseControl::new();
    let now = Instant::now();
    control.enter(1, MouseEntryEdge::Left, now).unwrap();
    control.release_all(1);
    control.enter(2, MouseEntryEdge::Right, now).unwrap();

    assert_eq!(control.release_all(1), ReleaseOutcome::Stale);
    assert_eq!(control.active_control_id(), Some(2));
}

#[test]
fn heartbeat_keeps_session_alive_beyond_lease() {
    let mut control = MouseControl::new();
    let start = Instant::now();
    control.enter(7, MouseEntryEdge::Left, start).unwrap();

    for step in 1..=6 {
        let now = start + Duration::from_millis(step * 100);
        assert_eq!(control.expire_lease(now), None);
        assert!(control.accept(7, now));
    }
    assert_eq!(control.active_control_id(), Some(7));
    assert_eq!(
        control.lease_deadline(),
        Some(start + Duration::from_millis(1000))
    );
}

#[test]
fn session_expires_at_lease_before_mac_fallback() {
    let mut control = MouseControl::new();
    let start = Instant::now();
    control.enter(9, MouseEntryEdge::Right, start).unwrap();

    assert_eq!(
        control.expire_lease(start + Duration::from_millis(399)),
        None
    );
    assert_eq!(
        control.expire_lease(start + Duration::from_millis(400)),
        Some(9)
    );
    assert_eq!(control.active_control_id(), None);
    assert_eq!(control.active_entry_edge(), None);
    assert_eq!(control.release_all(9), ReleaseOutcome::ReAck(9));
}

#[test]
fn leave_clears_session_and_rejects_further_input() {
    let mut control = MouseControl::new();
    let start = Instant::now();
    control.enter(3, MouseEntryEdge::Right, start).unwrap();

    assert!(control.leave(3));
    assert_eq!(control.active_control_id(), None);
    assert_eq!(control.active_entry_edge(), None);
    assert!(!control.accept(3, start));
    assert!(!control.leave(3));
    assert_eq!(control.release_all(3), ReleaseOutcome::ReAck(3));
}

#[test]
fn clear_disconnects_session_without_ack() {
    let mut control = MouseControl::new();
    control
        .enter(4, MouseEntryEdge::Right, Instant::now())
        .unwrap();

    assert_eq!(control.clear(), Some(4));
    assert_eq!(control.active_control_id(), None);
    assert_eq!(control.active_entry_edge(), None);
    assert_eq!(control.lease_deadline(), None);
}

#[test]
fn entry_positions_are_one_pixel_inside_the_selected_edge() {
    let maximum_x = 3839;
    assert_eq!(
        mouse_control::entry_position(MouseEntryEdge::Left, maximum_x),
        1
    );
    assert_eq!(
        mouse_control::entry_position(MouseEntryEdge::Right, maximum_x),
        3838
    );
}

#[test]
fn right_entry_accepts_negative_remaining_motion_into_the_screen() {
    let maximum_x = 2193;
    let mut cursor = mouse_control::LogicalCursor::new(
        mouse_control::entry_position(MouseEntryEdge::Right, maximum_x),
        0,
        maximum_x,
        1233,
    );

    let (positions, trigger) =
        cursor.advance_batch(&[move_sample(-20)], true, MouseEntryEdge::Right);

    assert_eq!(positions, vec![(2172, 0)]);
    assert_eq!(trigger, None);
}

#[test]
fn right_edge_crossing_and_boundary_motion_trigger_leave() {
    let mut cursor = mouse_control::LogicalCursor::new(998, 0, 999, 999);
    let (positions, trigger) = cursor.advance_batch(&[move_sample(1)], true, MouseEntryEdge::Right);
    assert_eq!(positions, vec![(999, 0)]);
    let trigger = trigger.unwrap();
    assert_eq!(trigger.kind, mouse_control::EdgeTriggerKind::Crossed);
    assert_eq!(trigger.previous_x, 998);
    assert_eq!(trigger.proposed_x, 999);

    let (positions, trigger) = cursor.advance_batch(&[move_sample(1)], true, MouseEntryEdge::Right);
    assert_eq!(positions, vec![(999, 0)]);
    assert_eq!(
        trigger.unwrap().kind,
        mouse_control::EdgeTriggerKind::AtBoundary
    );
}

#[test]
fn edge_step_exactly_to_boundary_fires_immediately() {
    let mut cursor = mouse_control::LogicalCursor::new(10, 0, 999, 999);

    let (positions, trigger) =
        cursor.advance_batch(&[move_sample(-10)], true, MouseEntryEdge::Left);

    assert_eq!(positions.len(), 1);
    let trigger = trigger.unwrap();
    assert_eq!(trigger.kind, mouse_control::EdgeTriggerKind::Crossed);
    assert_eq!(trigger.previous_x, 10);
    assert_eq!(trigger.proposed_x, 0);
    assert_eq!(trigger.dx, -10);
}

#[test]
fn edge_overshoot_fires_immediately() {
    let mut cursor = mouse_control::LogicalCursor::new(10, 0, 999, 999);

    let (positions, trigger) =
        cursor.advance_batch(&[move_sample(-25)], true, MouseEntryEdge::Left);

    assert_eq!(positions.len(), 1);
    let trigger = trigger.unwrap();
    assert_eq!(trigger.kind, mouse_control::EdgeTriggerKind::Crossed);
    assert_eq!(trigger.proposed_x, -15);
}

#[test]
fn edge_at_boundary_with_negative_dx_fires_immediately() {
    let mut cursor = mouse_control::LogicalCursor::new(0, 0, 999, 999);

    let (positions, trigger) = cursor.advance_batch(&[move_sample(-1)], true, MouseEntryEdge::Left);

    assert_eq!(positions.len(), 1);
    let trigger = trigger.unwrap();
    assert_eq!(trigger.kind, mouse_control::EdgeTriggerKind::AtBoundary);
    assert_eq!(trigger.previous_x, 0);
}

#[test]
fn edge_mid_batch_cross_stops_injection_for_the_rest() {
    let mut cursor = mouse_control::LogicalCursor::new(5, 0, 999, 999);

    let (positions, trigger) = cursor.advance_batch(
        &[
            move_sample(2),
            move_sample(-3),
            move_sample(-10),
            move_sample(50),
        ],
        true,
        MouseEntryEdge::Left,
    );

    assert_eq!(positions, vec![(7, 0), (4, 0), (0, 0)]);
    let trigger = trigger.unwrap();
    assert_eq!(trigger.kind, mouse_control::EdgeTriggerKind::Crossed);
    assert_eq!(trigger.previous_x, 4);
    assert_eq!(trigger.proposed_x, -6);
    assert_eq!(trigger.dx, -10);
}

#[test]
fn edge_enter_anchor_fires_on_first_left_sample() {
    let mut cursor = mouse_control::LogicalCursor::new(1, 0, 2193, 1233);

    let (positions, trigger) = cursor.advance_batch(&[move_sample(-1)], true, MouseEntryEdge::Left);

    assert_eq!(positions.len(), 1);
    let trigger = trigger.unwrap();
    assert_eq!(trigger.previous_x, 1);
    assert_eq!(trigger.proposed_x, 0);
}

#[test]
fn edge_does_not_fire_without_crossing() {
    let mut cursor = mouse_control::LogicalCursor::new(100, 0, 999, 999);

    let (positions, trigger) = cursor.advance_batch(
        &[move_sample(-10), move_sample(5), move_sample(-20)],
        true,
        MouseEntryEdge::Left,
    );

    assert_eq!(positions.len(), 3);
    assert_eq!(trigger, None);
    assert_eq!(cursor.x(), 75);
}

#[test]
fn edge_at_boundary_ignores_zero_and_motion_away_from_entry_edge() {
    for (entry_edge, start, dx, expected_x) in [
        (MouseEntryEdge::Left, 0, 5, 5),
        (MouseEntryEdge::Right, 999, -5, 994),
    ] {
        let mut cursor = mouse_control::LogicalCursor::new(start, 0, 999, 999);

        let (positions, trigger) = cursor.advance_batch(&[move_sample(0)], true, entry_edge);
        assert!(positions.len() == 1 && trigger.is_none());
        let (positions, trigger) = cursor.advance_batch(&[move_sample(dx)], true, entry_edge);
        assert!(positions.len() == 1 && trigger.is_none());
        assert_eq!(cursor.x(), expected_x);
    }
}

#[test]
fn edge_right_clamp_keeps_walkback_exact() {
    let mut cursor = mouse_control::LogicalCursor::new(2190, 0, 2193, 1233);

    let (positions, trigger) =
        cursor.advance_batch(&[move_sample(100)], true, MouseEntryEdge::Left);
    assert!(positions.len() == 1 && trigger.is_none());
    assert_eq!(cursor.x(), 2193);
    let (positions, trigger) =
        cursor.advance_batch(&[move_sample(-2193)], true, MouseEntryEdge::Left);
    assert_eq!(positions.len(), 1);
    let trigger = trigger.unwrap();
    assert_eq!(trigger.previous_x, 2193);
    assert_eq!(trigger.proposed_x, 0);
}

#[test]
fn cursor_tracks_and_clamps_y() {
    let mut cursor = mouse_control::LogicalCursor::new(500, 500, 999, 999);

    let (positions, trigger) =
        cursor.advance_batch(&[move_sample_xy(0, 600)], true, MouseEntryEdge::Left);
    assert_eq!(positions, vec![(500, 999)]);
    assert_eq!(trigger, None);
    assert_eq!(cursor.y(), 999);
    let (positions, _) =
        cursor.advance_batch(&[move_sample_xy(0, -2000)], true, MouseEntryEdge::Left);
    assert_eq!(positions, vec![(500, 0)]);
    assert_eq!(cursor.y(), 0);
}

#[test]
fn edge_detection_is_disabled_while_dragging() {
    for (entry_edge, start, dx, expected) in [
        (MouseEntryEdge::Left, 10, -25, 0),
        (MouseEntryEdge::Right, 989, 25, 999),
    ] {
        let mut cursor = mouse_control::LogicalCursor::new(start, 0, 999, 999);

        let (positions, trigger) = cursor.advance_batch(&[move_sample(dx)], false, entry_edge);

        assert_eq!(positions.len(), 1);
        assert_eq!(trigger, None);
        assert_eq!(cursor.x(), expected);
    }
}

#[test]
fn group_final_position_matches_per_sample_clamping() {
    // Hitting the left edge and reversing inside one group must end at the
    // per-sample clamped position, not the naive summed one.
    let mut cursor = mouse_control::LogicalCursor::new(5, 7, 999, 999);
    let samples = [move_sample_xy(-10, 2), move_sample_xy(3, 1)];

    let (positions, trigger) = cursor.advance_batch(&samples, false, MouseEntryEdge::Left);

    assert_eq!(trigger, None);
    assert_eq!(positions.last(), Some(&(3, 10)));
    assert_eq!((cursor.x(), cursor.y()), (3, 10));
    let naive = 5 + samples
        .iter()
        .map(|sample| i32::from(sample.dx))
        .sum::<i32>();
    assert_eq!(naive.clamp(0, 999), 0);
}

#[test]
fn group_collapse_keeps_edge_position_as_final() {
    // The first left-edge trigger inside a group stops the group there: the
    // collapsed final position is the edge position, not a later sample.
    let mut cursor = mouse_control::LogicalCursor::new(5, 0, 999, 999);

    let (positions, trigger) = cursor.advance_batch(
        &[move_sample(-3), move_sample(-10), move_sample(50)],
        true,
        MouseEntryEdge::Left,
    );

    assert!(trigger.is_some());
    assert_eq!(positions.last(), Some(&(0, 0)));
    assert_eq!(cursor.x(), 0);
}

#[test]
fn group_collapse_single_sample_unchanged() {
    let mut cursor = mouse_control::LogicalCursor::new(100, 100, 999, 999);

    let (positions, trigger) =
        cursor.advance_batch(&[move_sample_xy(-5, 9)], true, MouseEntryEdge::Left);

    assert_eq!(trigger, None);
    assert_eq!(positions.last(), Some(&(95, 109)));
}

#[test]
fn button_up_at_entry_edge_after_motion_toward_it_leaves() {
    assert!(mouse_control::should_leave_on_button_up(
        0,
        0,
        999,
        MouseEntryEdge::Left,
        true
    ));
    assert!(mouse_control::should_leave_on_button_up(
        0,
        999,
        999,
        MouseEntryEdge::Right,
        true
    ));
}

#[test]
fn button_up_does_not_leave_with_button_held_off_edge_or_without_toward_motion() {
    assert!(!mouse_control::should_leave_on_button_up(
        1,
        0,
        999,
        MouseEntryEdge::Left,
        true
    ));
    assert!(!mouse_control::should_leave_on_button_up(
        0,
        5,
        999,
        MouseEntryEdge::Left,
        true
    ));
    assert!(!mouse_control::should_leave_on_button_up(
        0,
        0,
        999,
        MouseEntryEdge::Left,
        false
    ));
    assert!(!mouse_control::should_leave_on_button_up(
        1,
        999,
        999,
        MouseEntryEdge::Right,
        true
    ));
    assert!(!mouse_control::should_leave_on_button_up(
        0,
        998,
        999,
        MouseEntryEdge::Right,
        true
    ));
}

#[test]
fn release_verdict_never_confirms_a_failed_teardown() {
    use mouse_control::ReleaseVerdict;
    assert_eq!(
        mouse_control::release_verdict(false, true),
        ReleaseVerdict::DriverUnavailable
    );
    assert_eq!(
        mouse_control::release_verdict(false, false),
        ReleaseVerdict::DriverUnavailable
    );
    assert_eq!(
        mouse_control::release_verdict(true, true),
        ReleaseVerdict::ConfirmLeave
    );
    assert_eq!(
        mouse_control::release_verdict(true, false),
        ReleaseVerdict::ConfirmReleased
    );
}

#[test]
fn barrier_reports_stable_after_required_consecutive_samples() {
    use mouse_control::BarrierPoll;
    let start = Instant::now();
    let mut barrier = mouse_control::ReleaseBarrier::new(3, Duration::from_millis(40), start);

    assert_eq!(barrier.poll((10, 10), start), BarrierPoll::Waiting);
    assert_eq!(
        barrier.poll((10, 10), start + Duration::from_millis(1)),
        BarrierPoll::Waiting
    );
    assert_eq!(
        barrier.poll((10, 10), start + Duration::from_millis(2)),
        BarrierPoll::Waiting
    );
    assert_eq!(
        barrier.poll((10, 10), start + Duration::from_millis(3)),
        BarrierPoll::Stable
    );
    assert_eq!(barrier.stable_samples(), 3);
}

#[test]
fn barrier_restarts_counting_when_position_changes() {
    use mouse_control::BarrierPoll;
    let start = Instant::now();
    let mut barrier = mouse_control::ReleaseBarrier::new(2, Duration::from_millis(40), start);

    barrier.poll((0, 0), start);
    barrier.poll((0, 0), start + Duration::from_millis(1));
    assert_eq!(
        barrier.poll((5, 0), start + Duration::from_millis(2)),
        BarrierPoll::Waiting
    );
    assert_eq!(barrier.stable_samples(), 0);
    assert_eq!(
        barrier.poll((5, 0), start + Duration::from_millis(3)),
        BarrierPoll::Waiting
    );
    assert_eq!(
        barrier.poll((5, 0), start + Duration::from_millis(4)),
        BarrierPoll::Stable
    );
}

#[test]
fn barrier_expires_when_position_never_settles() {
    use mouse_control::BarrierPoll;
    let start = Instant::now();
    let mut barrier = mouse_control::ReleaseBarrier::new(3, Duration::from_millis(40), start);

    let mut result = BarrierPoll::Waiting;
    for step in 0..50 {
        result = barrier.poll((step, 0), start + Duration::from_millis(step as u64));
        if result == BarrierPoll::Expired {
            break;
        }
    }
    assert_eq!(result, BarrierPoll::Expired);
}

#[test]
fn barrier_does_not_expire_before_the_cap() {
    use mouse_control::BarrierPoll;
    let start = Instant::now();
    let mut barrier = mouse_control::ReleaseBarrier::new(3, Duration::from_millis(40), start);

    assert_eq!(
        barrier.poll((1, 1), start + Duration::from_millis(39)),
        BarrierPoll::Waiting
    );
}

fn driver_info(version: (u16, u16, u16)) -> [u8; 88] {
    let mut info = [0_u8; 88];
    info[0..2].copy_from_slice(&virtual_hid::DRIVER_ABI.to_le_bytes());
    info[2..4].copy_from_slice(&version.0.to_le_bytes());
    info[4..6].copy_from_slice(&version.1.to_le_bytes());
    info[6..8].copy_from_slice(&version.2.to_le_bytes());
    info[8..12].copy_from_slice(&0x1FF_u32.to_le_bytes());
    info[12..14].copy_from_slice(&15_u16.to_le_bytes());
    info[16..18].copy_from_slice(&7_u16.to_le_bytes());
    info[18..20].copy_from_slice(&9_u16.to_le_bytes());
    info
}

#[test]
fn virtual_hid_requires_minimum_driver_version() {
    assert!(virtual_hid::validate_driver_info(&driver_info((2, 2, 4))).is_err());
    assert!(virtual_hid::validate_driver_info(&driver_info((2, 3, 0))).is_err());
    assert!(virtual_hid::validate_driver_info(&driver_info((2, 3, 1))).is_err());
    assert!(virtual_hid::validate_driver_info(&driver_info((2, 3, 2))).is_err());
    assert!(virtual_hid::validate_driver_info(&driver_info((2, 3, 3))).is_err());
    assert!(virtual_hid::validate_driver_info(&driver_info((2, 3, 4))).is_err());
    assert!(virtual_hid::validate_driver_info(&driver_info((2, 3, 5))).is_ok());
    assert!(virtual_hid::validate_driver_info(&driver_info((2, 4, 0))).is_ok());
}

#[test]
fn virtual_hid_requires_output_capability() {
    let mut info = driver_info((2, 3, 5));
    info[8..12].copy_from_slice(&0x17F_u32.to_le_bytes());
    assert!(virtual_hid::validate_driver_info(&info).is_err());
}

#[test]
fn virtual_hid_requires_path_diagnostics_capability() {
    let mut info = driver_info((2, 3, 5));
    info[8..12].copy_from_slice(&0xFF_u32.to_le_bytes());
    assert!(virtual_hid::validate_driver_info(&info).is_err());
}
