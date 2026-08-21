use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use windows::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE, REG_OPTION_NON_VOLATILE,
    REG_SAM_FLAGS, REG_SZ, REG_VALUE_TYPE, RegCloseKey, RegCreateKeyExW, RegDeleteTreeW,
    RegDeleteValueW, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    SPI_SETCURSORS, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SystemParametersInfoW,
};
use windows::core::PCWSTR;

const SCHEME_NAME: &str = "Meno macOS";
const CURSORS_KEY: &str = r"Control Panel\Cursors";
const BACKUP_KEY: &str = r"Software\Meno\CursorBackup";
const BACKUP_COMPLETE: &str = "Complete";
const BACKUP_SCHEME: &str = "Scheme";

// Registry value name, embedded file, bytes. The mapping mirrors the cursor
// package so every pointer role switches together.
const THEME_CURSORS: &[(&str, &str, &[u8])] = &[
    (
        "Arrow",
        "Pointer.cur",
        include_bytes!("../assets/cursors/Pointer.cur"),
    ),
    (
        "Help",
        "Help.cur",
        include_bytes!("../assets/cursors/Help.cur"),
    ),
    (
        "AppStarting",
        "Work.ani",
        include_bytes!("../assets/cursors/Work.ani"),
    ),
    (
        "Wait",
        "Busy.ani",
        include_bytes!("../assets/cursors/Busy.ani"),
    ),
    (
        "Crosshair",
        "Cross.cur",
        include_bytes!("../assets/cursors/Cross.cur"),
    ),
    (
        "IBeam",
        "Text.cur",
        include_bytes!("../assets/cursors/Text.cur"),
    ),
    (
        "NWPen",
        "Handwriting.cur",
        include_bytes!("../assets/cursors/Handwriting.cur"),
    ),
    (
        "No",
        "Unavailiable.cur",
        include_bytes!("../assets/cursors/Unavailiable.cur"),
    ),
    (
        "SizeNS",
        "Vert.cur",
        include_bytes!("../assets/cursors/Vert.cur"),
    ),
    (
        "SizeWE",
        "Horz.cur",
        include_bytes!("../assets/cursors/Horz.cur"),
    ),
    (
        "SizeNWSE",
        "Dng1.cur",
        include_bytes!("../assets/cursors/Dng1.cur"),
    ),
    (
        "SizeNESW",
        "Dng2.cur",
        include_bytes!("../assets/cursors/Dng2.cur"),
    ),
    (
        "SizeAll",
        "Move.cur",
        include_bytes!("../assets/cursors/Move.cur"),
    ),
    (
        "UpArrow",
        "Alternate.cur",
        include_bytes!("../assets/cursors/Alternate.cur"),
    ),
    (
        "Hand",
        "Link.cur",
        include_bytes!("../assets/cursors/Link.cur"),
    ),
    (
        "Pin",
        "Pin.cur",
        include_bytes!("../assets/cursors/Pin.cur"),
    ),
    (
        "Person",
        "Person.cur",
        include_bytes!("../assets/cursors/Person.cur"),
    ),
    (
        "Pan",
        "Pan.cur",
        include_bytes!("../assets/cursors/Pan.cur"),
    ),
    (
        "Grabbing",
        "Grabbing.cur",
        include_bytes!("../assets/cursors/Grabbing.cur"),
    ),
    (
        "Zoom-in",
        "Zoom-in.cur",
        include_bytes!("../assets/cursors/Zoom-in.cur"),
    ),
    (
        "Zoom-out",
        "Zoom-out.cur",
        include_bytes!("../assets/cursors/Zoom-out.cur"),
    ),
];

pub fn enabled() -> bool {
    let Ok(directory) = cursor_directory() else {
        return false;
    };
    let expected = directory.join(THEME_CURSORS[0].1);
    read_cursor_value(Some(THEME_CURSORS[0].0))
        .ok()
        .flatten()
        .is_some_and(|current| current.eq_ignore_ascii_case(&expected.to_string_lossy()))
}

pub fn set_enabled(enable: bool) -> io::Result<()> {
    if enable {
        if !backup_complete()? {
            if enabled() {
                return Err(io::Error::other(
                    "旧版 Meno 光标没有原方案备份，请先在 Windows 中手动选择一个光标方案",
                ));
            }
            capture_backup()?;
        }
        let directory = write_files()?;
        apply_registry(&directory)?;
    } else {
        restore_backup()?;
        if let Ok(directory) = cursor_directory() {
            let _ = fs::remove_dir_all(directory);
        }
    }
    reload_if_visible();
    Ok(())
}

// The registry survives EXE replacement while the cursor files do not, so
// refresh the embedded files on every launch when the theme is active.
pub fn ensure_applied() {
    if !enabled() {
        return;
    }
    match write_files() {
        Ok(_) => {
            reload_if_visible();
        }
        Err(error) => crate::logging::error(&format!("Cursor theme refresh failed: {error}")),
    }
}

fn cursor_directory() -> io::Result<PathBuf> {
    let local_app_data = env::var_os("LOCALAPPDATA")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "LOCALAPPDATA is unavailable"))?;
    Ok(PathBuf::from(local_app_data).join("Meno").join("Cursors"))
}

fn write_files() -> io::Result<PathBuf> {
    let directory = cursor_directory()?;
    fs::create_dir_all(&directory)?;
    for (_, file, bytes) in THEME_CURSORS {
        fs::write(directory.join(file), bytes)?;
    }
    Ok(directory)
}

fn apply_registry(directory: &Path) -> io::Result<()> {
    let key = create_key(CURSORS_KEY, KEY_SET_VALUE)?;
    let result: io::Result<()> = (|| {
        for (name, file, _) in THEME_CURSORS {
            set_string_value(key, Some(name), &directory.join(file).to_string_lossy())?;
        }
        set_string_value(key, None, SCHEME_NAME)
    })();
    let _ = unsafe { RegCloseKey(key) };
    result
}

fn capture_backup() -> io::Result<()> {
    delete_backup()?;
    let backup = create_key(BACKUP_KEY, KEY_SET_VALUE)?;
    let result = (|| {
        save_backup_value(backup, BACKUP_SCHEME, read_cursor_value(None)?)?;
        for (name, _, _) in THEME_CURSORS {
            save_backup_value(backup, name, read_cursor_value(Some(name))?)?;
        }
        set_string_value(backup, Some(BACKUP_COMPLETE), "1")
    })();
    let _ = unsafe { RegCloseKey(backup) };
    result
}

fn save_backup_value(key: HKEY, name: &str, value: Option<String>) -> io::Result<()> {
    set_string_value(
        key,
        Some(&format!("{name}.Present")),
        if value.is_some() { "1" } else { "0" },
    )?;
    if let Some(value) = value {
        set_string_value(key, Some(name), &value)?;
    }
    Ok(())
}

fn backup_complete() -> io::Result<bool> {
    let Some(key) = open_existing_key(BACKUP_KEY, KEY_QUERY_VALUE)? else {
        return Ok(false);
    };
    let result =
        read_string_value(key, Some(BACKUP_COMPLETE)).map(|value| value.as_deref() == Some("1"));
    let _ = unsafe { RegCloseKey(key) };
    result
}

fn restore_backup() -> io::Result<()> {
    let Some(backup) = open_existing_key(BACKUP_KEY, KEY_QUERY_VALUE)? else {
        return Err(io::Error::other(
            "旧版 Meno 光标没有原方案备份，请先在 Windows 中手动选择一个光标方案",
        ));
    };
    let result = (|| {
        if read_string_value(backup, Some(BACKUP_COMPLETE))?.as_deref() != Some("1") {
            return Err(io::Error::other("cursor backup is incomplete"));
        }
        let directory = cursor_directory()?;
        let cursors = create_key(CURSORS_KEY, KEY_QUERY_VALUE | KEY_SET_VALUE)?;
        let restore_result: io::Result<()> = (|| {
            if read_string_value(cursors, None)?.as_deref() == Some(SCHEME_NAME) {
                restore_backup_value(backup, cursors, BACKUP_SCHEME, None)?;
            }
            for (name, file, _) in THEME_CURSORS {
                let expected = directory.join(file).to_string_lossy().into_owned();
                if read_string_value(cursors, Some(name))?
                    .is_some_and(|current| current.eq_ignore_ascii_case(&expected))
                {
                    restore_backup_value(backup, cursors, name, Some(name))?;
                }
            }
            Ok(())
        })();
        let _ = unsafe { RegCloseKey(cursors) };
        restore_result
    })();
    let _ = unsafe { RegCloseKey(backup) };
    result?;
    delete_backup()
}

fn restore_backup_value(
    backup: HKEY,
    cursors: HKEY,
    backup_name: &str,
    cursor_name: Option<&str>,
) -> io::Result<()> {
    match read_string_value(backup, Some(&format!("{backup_name}.Present")))?.as_deref() {
        Some("1") => {
            let value = read_string_value(backup, Some(backup_name))?
                .ok_or_else(|| io::Error::other("cursor backup value is missing"))?;
            set_string_value(cursors, cursor_name, &value)
        }
        Some("0") => delete_value(cursors, cursor_name),
        _ => Err(io::Error::other("cursor backup marker is invalid")),
    }
}

fn delete_backup() -> io::Result<()> {
    let path = wide(BACKUP_KEY);
    let result = unsafe { RegDeleteTreeW(HKEY_CURRENT_USER, PCWSTR(path.as_ptr())) };
    if result.is_ok() || result.0 == 2 {
        Ok(())
    } else {
        Err(io::Error::from_raw_os_error(result.0 as i32))
    }
}

fn reload_if_visible() {
    if crate::cursor_hider::is_hidden() {
        return;
    }
    if unsafe {
        SystemParametersInfoW(
            SPI_SETCURSORS,
            0,
            None,
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
    }
    .is_err()
    {
        crate::logging::error("Cursor theme reload failed");
    }
}

fn create_key(path: &str, access: REG_SAM_FLAGS) -> io::Result<HKEY> {
    let path = wide(path);
    let mut key = HKEY::default();
    let result = unsafe {
        RegCreateKeyExW(
            HKEY_CURRENT_USER,
            PCWSTR(path.as_ptr()),
            None,
            PCWSTR::null(),
            REG_OPTION_NON_VOLATILE,
            access,
            None,
            &mut key,
            None,
        )
    };
    if result.is_err() {
        Err(io::Error::from_raw_os_error(result.0 as i32))
    } else {
        Ok(key)
    }
}

fn open_existing_key(path: &str, access: REG_SAM_FLAGS) -> io::Result<Option<HKEY>> {
    let path = wide(path);
    let mut key = HKEY::default();
    let result = unsafe {
        RegOpenKeyExW(
            HKEY_CURRENT_USER,
            PCWSTR(path.as_ptr()),
            None,
            access,
            &mut key,
        )
    };
    if result.0 == 2 {
        Ok(None)
    } else if result.is_err() {
        Err(io::Error::from_raw_os_error(result.0 as i32))
    } else {
        Ok(Some(key))
    }
}

fn read_cursor_value(name: Option<&str>) -> io::Result<Option<String>> {
    let key = create_key(CURSORS_KEY, KEY_QUERY_VALUE)?;
    let result = read_string_value(key, name);
    let _ = unsafe { RegCloseKey(key) };
    result
}

fn read_string_value(key: HKEY, name: Option<&str>) -> io::Result<Option<String>> {
    let name_wide = name.map(wide);
    let name = name_wide
        .as_ref()
        .map_or(PCWSTR::null(), |value| PCWSTR(value.as_ptr()));
    let mut length = 0_u32;
    let mut value_type = REG_VALUE_TYPE::default();
    let result = unsafe {
        RegQueryValueExW(
            key,
            name,
            None,
            Some(&mut value_type),
            None,
            Some(&mut length),
        )
    };
    if result.0 == 2 {
        return Ok(None);
    }
    if result.is_err() || value_type != REG_SZ || length < 2 || !length.is_multiple_of(2) {
        return Err(io::Error::other("cursor registry value is invalid"));
    }
    let mut buffer = vec![0_u16; (length / 2) as usize];
    let result = unsafe {
        RegQueryValueExW(
            key,
            name,
            None,
            Some(&mut value_type),
            Some(buffer.as_mut_ptr().cast()),
            Some(&mut length),
        )
    };
    if result.is_err() || value_type != REG_SZ {
        return Err(io::Error::other("cursor registry value read failed"));
    }
    while buffer.last() == Some(&0) {
        buffer.pop();
    }
    Ok(Some(String::from_utf16_lossy(&buffer)))
}

fn set_string_value(key: HKEY, name: Option<&str>, data: &str) -> io::Result<()> {
    let name_wide = name.map(wide);
    let name = name_wide
        .as_ref()
        .map_or(PCWSTR::null(), |value| PCWSTR(value.as_ptr()));
    let data_wide: Vec<u16> = data.encode_utf16().chain(std::iter::once(0)).collect();
    let bytes = unsafe {
        std::slice::from_raw_parts(
            data_wide.as_ptr().cast::<u8>(),
            std::mem::size_of_val(&data_wide[..]),
        )
    };
    let result = unsafe { RegSetValueExW(key, name, None, REG_SZ, Some(bytes)) };
    if result.is_err() {
        Err(io::Error::from_raw_os_error(result.0 as i32))
    } else {
        Ok(())
    }
}

fn delete_value(key: HKEY, name: Option<&str>) -> io::Result<()> {
    let name_wide = name.map(wide);
    let name = name_wide
        .as_ref()
        .map_or(PCWSTR::null(), |value| PCWSTR(value.as_ptr()));
    let result = unsafe { RegDeleteValueW(key, name) };
    if result.is_ok() || result.0 == 2 {
        Ok(())
    } else {
        Err(io::Error::from_raw_os_error(result.0 as i32))
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}
