use std::thread;
use std::time::Duration;

use arboard::{Clipboard, Error as ClipboardError, ImageData};
use windows::Win32::System::DataExchange::GetClipboardSequenceNumber;

use crate::connection::NetworkCommand;
use crate::protocol::{Frame, MAX_TEXT_SIZE, MessageKind};
use crate::{image_codec, logging, with_state};

pub(crate) const CLIPBOARD_RETRY_COUNT: usize = 5;
pub(crate) const CLIPBOARD_RETRY_DELAY: Duration = Duration::from_millis(20);

pub(crate) enum LocalClipboard {
    Frame(Frame),
    Image(ImageData<'static>),
}

pub(crate) fn read_local_clipboard() -> Result<Option<LocalClipboard>, ClipboardError> {
    let mut clipboard = Clipboard::new()?;
    match clipboard.get_image() {
        Ok(image) => {
            let expected = match image_codec::checked_rgba_bytes(image.width, image.height) {
                Ok(expected) => expected,
                Err(error) => {
                    let _ = error;
                    return Ok(None);
                }
            };
            if image.bytes.len() != expected {
                logging::error("Clipboard image skipped: RGBA length does not match dimensions");
                return Ok(None);
            }
            return Ok(Some(LocalClipboard::Image(image.to_owned_img())));
        }
        Err(ClipboardError::ContentNotAvailable) => {}
        Err(error) => return Err(error),
    }
    let text = clipboard.get_text()?;
    let payload = text.into_bytes();
    if payload.len() > MAX_TEXT_SIZE {
        return Ok(None);
    }
    Ok(Some(LocalClipboard::Frame(Frame::new(
        MessageKind::Text,
        payload,
    ))))
}

pub(crate) fn apply_remote_clipboard(
    _kind: MessageKind,
    _bytes: usize,
    mut apply: impl FnMut(&mut Clipboard) -> Result<(), ClipboardError>,
) {
    for attempt in 0..CLIPBOARD_RETRY_COUNT {
        let result = Clipboard::new().and_then(|mut clipboard| apply(&mut clipboard));
        match result {
            Ok(()) => {
                let sequence = unsafe { GetClipboardSequenceNumber() };
                let _ = with_state(|state| state.ignored_sequence = Some(sequence));
                return;
            }
            Err(ClipboardError::ClipboardOccupied) if attempt + 1 < CLIPBOARD_RETRY_COUNT => {
                thread::sleep(CLIPBOARD_RETRY_DELAY);
            }
            Err(ClipboardError::ClipboardOccupied) => {
                logging::error("Remote clipboard apply failed: occupied through all retries");
                return;
            }
            Err(error) => {
                logging::error(&format!("Remote clipboard apply failed: {error}"));
                return;
            }
        }
    }
}

pub(crate) fn send_clipboard(frame: Frame) {
    let _ = with_state(|state| state.network.try_send(NetworkCommand::Clipboard(frame)));
}
