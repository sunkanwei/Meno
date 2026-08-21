use std::os::windows::ffi::OsStrExt;
use std::path::PathBuf;

use windows::Win32::Foundation::{GlobalFree, HGLOBAL};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, RegisterClipboardFormatW,
    SetClipboardData,
};
use windows::Win32::System::Memory::{GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalUnlock};
use windows::Win32::UI::Shell::{DROPFILES, DragQueryFileW, HDROP};
use windows::core::w;

pub const CF_HDROP: u32 = 15;
pub const DROPEFFECT_COPY: u32 = 1;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ClipboardFailure {
    Occupied,
    Failed(String),
}

pub fn read_hdrop_paths() -> Result<Option<Vec<PathBuf>>, ClipboardFailure> {
    unsafe {
        OpenClipboard(None).map_err(|_| ClipboardFailure::Occupied)?;
        let result = (|| {
            let handle = GetClipboardData(CF_HDROP).ok()?;
            let hdrop = HDROP(handle.0.cast());
            let count = DragQueryFileW(hdrop, u32::MAX, None);
            if count == 0 {
                return None;
            }
            let mut paths = Vec::with_capacity(count as usize);
            for index in 0..count {
                let length = DragQueryFileW(hdrop, index, None);
                if length == 0 {
                    return None;
                }
                let mut buffer = vec![0_u16; length as usize + 1];
                let written = DragQueryFileW(hdrop, index, Some(&mut buffer));
                if written == 0 {
                    return None;
                }
                paths.push(PathBuf::from(String::from_utf16_lossy(
                    &buffer[..written as usize],
                )));
            }
            Some(paths)
        })();
        let _ = CloseClipboard();
        Ok(result)
    }
}

// DROPFILES: fixed header, then each absolute path as UTF-16 with a NUL, and
// one extra NUL to end the list. Only the byte layout is Shell-visible.
pub fn dropfiles_blob(paths: &[Vec<u16>]) -> Vec<u8> {
    let header = std::mem::size_of::<DROPFILES>();
    let mut bytes = Vec::new();
    bytes.extend_from_slice(&(header as u32).to_le_bytes());
    bytes.extend_from_slice(&0_i32.to_le_bytes());
    bytes.extend_from_slice(&0_i32.to_le_bytes());
    bytes.extend_from_slice(&0_i32.to_le_bytes());
    bytes.extend_from_slice(&1_i32.to_le_bytes());
    for path in paths {
        for unit in path {
            bytes.extend_from_slice(&unit.to_le_bytes());
        }
        bytes.extend_from_slice(&0_u16.to_le_bytes());
    }
    bytes.extend_from_slice(&0_u16.to_le_bytes());
    bytes
}

fn wide_path(path: &std::path::Path) -> Vec<u16> {
    path.as_os_str().encode_wide().collect()
}

pub(crate) trait ClipboardOps {
    fn open(&self) -> Result<(), ClipboardFailure>;
    fn empty(&self) -> Result<(), ClipboardFailure>;
    fn set(&self, format: u32, handle: HGLOBAL) -> Result<(), ClipboardFailure>;
    fn close(&self);
}

fn global_from_bytes(bytes: &[u8]) -> Result<HGLOBAL, ClipboardFailure> {
    unsafe {
        let handle = GlobalAlloc(GMEM_MOVEABLE, bytes.len())
            .map_err(|error| ClipboardFailure::Failed(format!("GlobalAlloc failed: {error}")))?;
        let pointer = GlobalLock(handle);
        if pointer.is_null() {
            let _ = GlobalFree(Some(handle));
            return Err(ClipboardFailure::Failed("GlobalLock failed".to_string()));
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), pointer.cast(), bytes.len());
        let _ = GlobalUnlock(handle);
        Ok(handle)
    }
}

// Ownership: a handle passed to a successful SetClipboardData belongs to the
// system; on failure it stays ours and must be freed. If CF_HDROP succeeds
// but Preferred DropEffect fails, the half-written clipboard is emptied so
// the Shell can never treat the cached paths as a move.
pub(crate) fn publish_with(
    ops: &dyn ClipboardOps,
    drop_effect_format: u32,
    paths: &[Vec<u16>],
) -> Result<(), ClipboardFailure> {
    let blob = dropfiles_blob(paths);
    let hdrop = global_from_bytes(&blob)?;
    let effect = global_from_bytes(&DROPEFFECT_COPY.to_le_bytes())?;
    let mut hdrop_owned = true;
    let mut effect_owned = true;
    let mut opened = false;
    let result = (|| {
        ops.open()?;
        opened = true;
        ops.empty()?;
        ops.set(CF_HDROP, hdrop)?;
        hdrop_owned = false;
        match ops.set(drop_effect_format, effect) {
            Ok(()) => {
                effect_owned = false;
                Ok(())
            }
            Err(error) => {
                // The system releases the already-set CF_HDROP here, so the
                // Shell never sees file paths without an explicit copy effect.
                let _ = ops.empty();
                Err(error)
            }
        }
    })();
    if opened {
        ops.close();
    }
    if hdrop_owned {
        let _ = unsafe { GlobalFree(Some(hdrop)) };
    }
    if effect_owned {
        let _ = unsafe { GlobalFree(Some(effect)) };
    }
    result
}

struct Win32ClipboardOps;

impl ClipboardOps for Win32ClipboardOps {
    fn open(&self) -> Result<(), ClipboardFailure> {
        unsafe { OpenClipboard(None) }.map_err(|_| ClipboardFailure::Occupied)
    }

    fn empty(&self) -> Result<(), ClipboardFailure> {
        unsafe { EmptyClipboard() }
            .map_err(|error| ClipboardFailure::Failed(format!("EmptyClipboard failed: {error}")))
    }

    fn set(&self, format: u32, handle: HGLOBAL) -> Result<(), ClipboardFailure> {
        unsafe {
            SetClipboardData(format, Some(windows::Win32::Foundation::HANDLE(handle.0)))
                .map(|_| ())
                .map_err(|error| {
                    ClipboardFailure::Failed(format!("SetClipboardData failed: {error}"))
                })
        }
    }

    fn close(&self) {
        let _ = unsafe { CloseClipboard() };
    }
}

fn drop_effect_format() -> u32 {
    unsafe { RegisterClipboardFormatW(w!("Preferred DropEffect")) }
}

pub fn write_hdrop(paths: &[PathBuf]) -> Result<(), ClipboardFailure> {
    let format = drop_effect_format();
    if format == 0 {
        return Err(ClipboardFailure::Failed(
            "RegisterClipboardFormatW failed".to_string(),
        ));
    }
    let wide: Vec<Vec<u16>> = paths.iter().map(|path| wide_path(path)).collect();
    publish_with(&Win32ClipboardOps, format, &wide)
}
