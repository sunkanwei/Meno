use std::{ffi::OsStr, os::windows::process::CommandExt, process::Command};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

pub(crate) fn std_command<S>(program: S) -> Command
where
    S: AsRef<OsStr>,
{
    let mut command = Command::new(program);
    command.creation_flags(CREATE_NO_WINDOW);
    command
}

pub(crate) fn tokio_command<S>(program: S) -> tokio::process::Command
where
    S: AsRef<OsStr>,
{
    let mut command = tokio::process::Command::new(program);
    command.creation_flags(CREATE_NO_WINDOW);
    command
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn background_command_runs_without_a_console_window() {
        let output = std_command("powershell.exe")
            .args([
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "Add-Type -Name Native -Namespace Test -MemberDefinition '[DllImport(\"kernel32.dll\")] public static extern System.IntPtr GetConsoleWindow();'; if ([Test.Native]::GetConsoleWindow() -eq [IntPtr]::Zero) { exit 0 } else { exit 1 }",
            ])
            .output()
            .expect("background PowerShell should start");
        assert!(
            output.status.success(),
            "background process unexpectedly received a console window: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}
