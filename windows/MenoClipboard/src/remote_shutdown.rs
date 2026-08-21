use std::ffi::OsString;
use std::io;
use std::os::windows::ffi::OsStringExt;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use windows::Win32::System::SystemInformation::GetSystemDirectoryW;
use windows::Win32::System::Threading::CREATE_NO_WINDOW;

pub(crate) fn handle_remote_shutdown(
    ready: bool,
    negotiated: bool,
    payload: &[u8],
    start: impl FnOnce(),
) -> bool {
    if !ready || !negotiated || !payload.is_empty() {
        return false;
    }
    start();
    true
}

pub(crate) fn start_remote_shutdown() {
    start_remote_shutdown_with(system_directory, |command| command.spawn().map(drop));
}

fn start_remote_shutdown_with(
    resolve_system_directory: impl FnOnce() -> io::Result<PathBuf>,
    spawn: impl FnOnce(&mut Command) -> io::Result<()>,
) {
    let result = resolve_system_directory().and_then(|directory| {
        let mut command = shutdown_command(&directory);
        spawn(&mut command)
    });
    match result {
        Ok(()) => crate::logging::info("remote shutdown command started"),
        Err(error) => {
            crate::logging::error(&format!("remote shutdown launch failed: {error}"));
        }
    }
}

fn shutdown_command(system_directory: &Path) -> Command {
    let mut command = Command::new(system_directory.join("shutdown.exe"));
    command.args(["/p", "/f", "/d", "p:0:0"]);
    command.creation_flags(CREATE_NO_WINDOW.0);
    command
}

fn system_directory() -> io::Result<PathBuf> {
    let mut buffer = [0_u16; 32_768];
    let length = unsafe { GetSystemDirectoryW(Some(&mut buffer)) } as usize;
    if length == 0 {
        return Err(io::Error::last_os_error());
    }
    if length >= buffer.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Windows system directory is too long",
        ));
    }
    Ok(PathBuf::from(OsString::from_wide(&buffer[..length])))
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use super::*;

    #[test]
    fn remote_shutdown_requires_ready_negotiated_empty_request() {
        for (ready, negotiated, payload) in [
            (false, true, &[][..]),
            (true, false, &[][..]),
            (true, true, &[1][..]),
        ] {
            let calls = Cell::new(0);
            assert!(!handle_remote_shutdown(ready, negotiated, payload, || {
                calls.set(calls.get() + 1)
            }));
            assert_eq!(calls.get(), 0);
        }

        let calls = Cell::new(0);
        assert!(handle_remote_shutdown(true, true, &[], || {
            calls.set(calls.get() + 1);
        }));
        assert_eq!(calls.get(), 1);
    }

    #[test]
    fn remote_shutdown_command_uses_system_executable_and_fixed_arguments() {
        let command = shutdown_command(Path::new(r"C:\Windows\System32"));
        assert_eq!(
            command.get_program(),
            Path::new(r"C:\Windows\System32\shutdown.exe")
        );
        assert_eq!(
            command.get_args().collect::<Vec<_>>(),
            ["/p", "/f", "/d", "p:0:0"].map(std::ffi::OsStr::new)
        );
    }

    #[test]
    fn remote_shutdown_launch_failure_is_consumed_without_retry() {
        let calls = Cell::new(0);
        start_remote_shutdown_with(
            || Ok(PathBuf::from(r"C:\Windows\System32")),
            |_| {
                calls.set(calls.get() + 1);
                Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "test failure",
                ))
            },
        );
        assert_eq!(calls.get(), 1);
    }

    #[test]
    fn remote_shutdown_directory_failure_skips_process_launch() {
        let calls = Cell::new(0);
        start_remote_shutdown_with(
            || Err(io::Error::new(io::ErrorKind::NotFound, "test failure")),
            |_| {
                calls.set(calls.get() + 1);
                Ok(())
            },
        );
        assert_eq!(calls.get(), 0);
    }

    #[test]
    fn system_shutdown_executable_exists() {
        assert!(system_directory().unwrap().join("shutdown.exe").is_file());
    }
}
