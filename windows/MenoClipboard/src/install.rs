use std::env;
use std::fs;
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use windows::Wdk::System::SystemServices::RtlGetVersion;
use windows::Win32::Devices::DeviceAndDriverInstallation::{
    DICD_GENERATE_ID, DIF_REGISTERDEVICE, DIIRFLAG_FORCE_INF, DiInstallDriverW,
    GUID_DEVCLASS_HIDCLASS, INSTALLFLAG_FORCE, SP_DEVINFO_DATA, SPDRP_HARDWAREID,
    SetupDiCallClassInstaller, SetupDiCreateDeviceInfoList, SetupDiCreateDeviceInfoW,
    SetupDiDestroyDeviceInfoList, SetupDiSetDeviceRegistryPropertyW,
    UpdateDriverForPlugAndPlayDevicesW,
};
use windows::Win32::Foundation::{CloseHandle, LPARAM, WAIT_OBJECT_0, WPARAM};
use windows::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
};
use windows::Win32::System::SystemInformation::OSVERSIONINFOW;
use windows::Win32::System::SystemInformation::{GetSystemDirectoryW, GetTickCount64};
use windows::Win32::System::Threading::{GetExitCodeProcess, INFINITE, WaitForSingleObject};
use windows::Win32::UI::Shell::{
    SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW, ShellExecuteExW, ShellExecuteW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    FindWindowW, IDYES, MB_DEFBUTTON2, MB_ICONERROR, MB_ICONINFORMATION, MB_OK, MB_YESNO,
    MessageBoxW, PostMessageW, WM_CLOSE, WM_COMMAND,
};
use windows::core::{HRESULT, PCWSTR, w};

const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE: &str = "MenoClipboard";
const DRIVER_HARDWARE_ID: &str = r"ROOT\MENOVIRTUALMOUSE";
const RESTART_MARKER: &str = "restart-required";
const WINDOWS_11_MINIMUM_BUILD: u32 = 22_000;
const AUDIO_DRIVER_ARCHIVE_NAME: &str = "VBCABLE_Driver_Pack45.zip";
const AUDIO_DRIVER_DIRECTORY_NAME: &str = "VBCABLE_Driver_Pack45-b950e39f";
const VB_CABLE_WEBSITE: &str = "https://vb-audio.com/Cable/";
const AUDIO_DRIVER_REQUIRED_FILES: &[&str] = &[
    "readme.txt",
    "VBCABLE_Setup_x64.exe",
    "vbMmeCable64_win10.inf",
    "vbaudio_cable64_win10.cat",
    "vbaudio_cable64_win10.sys",
];
const AUDIO_DRIVER_ARCHIVE: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/VBCABLE_Driver_Pack45.zip"));
const DRIVER_FILES: &[(&str, &[u8])] = &[
    (
        "MenoVirtualMouse.dll",
        include_bytes!(concat!(env!("OUT_DIR"), "/MenoVirtualMouse.dll")),
    ),
    (
        "MenoVirtualMouse.inf",
        include_bytes!(concat!(env!("OUT_DIR"), "/MenoVirtualMouse.inf")),
    ),
    (
        "MenoVirtualMouse.cat",
        include_bytes!(concat!(env!("OUT_DIR"), "/MenoVirtualMouse.cat")),
    ),
    (
        "MenoVirtualMouse.cer",
        include_bytes!(concat!(env!("OUT_DIR"), "/MenoVirtualMouse.cer")),
    ),
];

enum DriverInstallOutcome {
    Installed,
    RestartRequired,
}

pub fn fixed_executable() -> io::Result<PathBuf> {
    let local_app_data = env::var_os("LOCALAPPDATA")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "LOCALAPPDATA is unavailable"))?;
    Ok(PathBuf::from(local_app_data)
        .join("Meno")
        .join("MenoClipboard.exe"))
}

pub fn install_if_needed(portable: bool) -> io::Result<bool> {
    if portable {
        return Ok(false);
    }
    let current = env::current_exe()?;
    let target = fixed_executable()?;
    if same_path(&current, &target) {
        return Ok(false);
    }
    if let Some(directory) = target.parent() {
        fs::create_dir_all(directory)?;
    }
    let first_install = !target.exists();
    if target.exists() {
        request_existing_exit();
    }
    replace_executable(&current, &target)?;
    if first_install {
        set_startup_enabled(true)?;
    }
    let mut relaunch = Command::new(target);
    if first_install {
        relaunch.arg("--first-install");
    }
    relaunch.spawn()?;
    Ok(true)
}

pub fn handle_driver_install_command() -> bool {
    let mut arguments = env::args().skip(1);
    if arguments.next().as_deref() != Some("--install-driver") || arguments.next().is_some() {
        return false;
    }
    handle_mouse_driver_install();
    true
}

fn handle_mouse_driver_install() {
    match install_driver_package() {
        Ok(DriverInstallOutcome::Installed) => {
            notify_existing_rediscover();
            show_message(
                "鼠标驱动已经安装完成。",
                "Meno 鼠标驱动",
                MB_OK | MB_ICONINFORMATION,
            );
        }
        Ok(DriverInstallOutcome::RestartRequired) => {
            show_message(
                "已完成驱动安装前的系统设置。\n\n请重启 Windows，然后从托盘菜单再次选择“修复鼠标驱动”。",
                "Meno 鼠标驱动",
                MB_OK | MB_ICONINFORMATION,
            );
        }
        Err(error) => {
            crate::logging::error(&format!(
                "Meno Virtual Mouse driver installation failed: {error}"
            ));
            show_message(
                &format!("鼠标驱动安装失败：\n\n{error}\n\n可在托盘菜单中选择“查看日志”查看详情。"),
                "Meno 鼠标驱动",
                MB_OK | MB_ICONERROR,
            );
        }
    }
}

pub fn request_driver_install() -> io::Result<bool> {
    if !driver_package_embedded() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "the EXE does not contain a Meno Virtual Mouse driver package",
        ));
    }
    let directory = driver_directory()?;
    let restart_state = restart_marker_state(&directory)?;
    if restart_state == Some(true) {
        show_message(
            "请先重启 Windows，然后从托盘菜单再次选择“修复鼠标驱动”。",
            "Meno 鼠标驱动",
            MB_OK | MB_ICONINFORMATION,
        );
        return Ok(false);
    }
    let executable = env::current_exe()?;
    let executable_wide = wide_os(executable.as_os_str());
    let parameters = wide("--install-driver");
    let result = unsafe {
        ShellExecuteW(
            None,
            w!("runas"),
            PCWSTR(executable_wide.as_ptr()),
            PCWSTR(parameters.as_ptr()),
            None,
            windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL,
        )
    };
    if result.0 as usize <= 32 {
        return Err(io::Error::other("driver elevation was declined or failed"));
    }
    Ok(true)
}

pub fn request_audio_driver_install() -> io::Result<bool> {
    request_audio_driver_install_inner(true)
}

pub fn request_audio_driver_install_if_missing() -> io::Result<bool> {
    request_audio_driver_install_inner(false)
}

fn request_audio_driver_install_inner(notify_if_available: bool) -> io::Result<bool> {
    ensure_windows_11_x64()?;
    if crate::audio_output::cable_is_available() {
        if notify_if_available {
            show_message(
                "已经检测到 VB-CABLE，音频驱动无需重复安装。",
                "Meno 音频驱动",
                MB_OK | MB_ICONINFORMATION,
            );
        }
        return Ok(false);
    }
    if !audio_driver_package_embedded() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "the EXE does not contain the official VB-CABLE package",
        ));
    }
    let decision = show_message(
        "Meno 将安装 VB-Audio 提供的官方 VB-CABLE 驱动。\n\nVB-CABLE 来源：www.vb-cable.com。它是捐赠软件，所有参与和捐赠都受到欢迎；官网可从托盘菜单打开。\n\n安装需要管理员权限，完成后必须重启 Windows。是否继续？",
        "安装 Meno 音频驱动",
        MB_YESNO | MB_DEFBUTTON2 | MB_ICONINFORMATION,
    );
    if decision != IDYES {
        return Ok(false);
    }
    match install_audio_driver_package() {
        Ok(()) => {
            notify_existing_rediscover();
            show_message(
                "VB-CABLE 音频驱动安装程序已经执行完成。\n\n请重启 Windows 后再使用 Mac 麦克风。\n\nVB-CABLE 来源：www.vb-cable.com。它是捐赠软件，可通过托盘菜单访问其官网。",
                "Meno 音频驱动",
                MB_OK | MB_ICONINFORMATION,
            );
            Ok(true)
        }
        Err(error) => {
            show_message(
                &format!(
                    "VB-CABLE 音频驱动安装失败：\n\n{error}\n\n可在托盘菜单中选择“查看日志”查看详情。"
                ),
                "Meno 音频驱动",
                MB_OK | MB_ICONERROR,
            );
            Err(error)
        }
    }
}

pub fn open_vb_cable_website() -> io::Result<()> {
    let website = wide(VB_CABLE_WEBSITE);
    let result = unsafe {
        ShellExecuteW(
            None,
            w!("open"),
            PCWSTR(website.as_ptr()),
            PCWSTR::null(),
            None,
            windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL,
        )
    };
    if result.0 as usize <= 32 {
        Err(io::Error::other("could not open the VB-CABLE website"))
    } else {
        Ok(())
    }
}

pub fn driver_package_embedded() -> bool {
    env!("MENO_DRIVER_EMBEDDED") == "1" && DRIVER_FILES.iter().all(|(_, bytes)| !bytes.is_empty())
}

pub fn audio_driver_package_embedded() -> bool {
    env!("MENO_AUDIO_DRIVER_EMBEDDED") == "1" && !AUDIO_DRIVER_ARCHIVE.is_empty()
}

pub fn startup_enabled() -> bool {
    let Ok(reg) = system_executable("reg.exe") else {
        return false;
    };
    Command::new(reg)
        .args(["query", RUN_KEY, "/v", RUN_VALUE])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

pub fn set_startup_enabled(enabled: bool) -> io::Result<()> {
    let reg = system_executable("reg.exe")?;
    let status = if enabled {
        let quoted_path = format!("\"{}\"", fixed_executable()?.display());
        Command::new(&reg)
            .args([
                "add",
                RUN_KEY,
                "/v",
                RUN_VALUE,
                "/t",
                "REG_SZ",
                "/d",
                &quoted_path,
                "/f",
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?
    } else {
        Command::new(&reg)
            .args(["delete", RUN_KEY, "/v", RUN_VALUE, "/f"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?
    };
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other("could not update startup registration"))
    }
}

pub fn log_path() -> io::Result<PathBuf> {
    Ok(fixed_executable()?.with_file_name("MenoClipboard.log"))
}

pub fn open_log() -> io::Result<()> {
    let path = log_path()?;
    if let Some(directory) = path.parent() {
        fs::create_dir_all(directory)?;
    }
    let _ = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;
    Command::new(system_executable("notepad.exe")?)
        .arg(path)
        .spawn()?;
    Ok(())
}

fn same_path(left: &Path, right: &Path) -> bool {
    left.to_string_lossy()
        .eq_ignore_ascii_case(&right.to_string_lossy())
}

fn install_driver_package() -> io::Result<DriverInstallOutcome> {
    if !driver_package_embedded() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "the EXE does not contain a Meno Virtual Mouse driver package",
        ));
    }
    let directory = driver_directory()?;
    fs::create_dir_all(&directory)?;
    for (name, bytes) in DRIVER_FILES {
        fs::write(directory.join(name), bytes)?;
    }
    for (name, expected) in DRIVER_FILES {
        let actual = fs::read(directory.join(name))?;
        if actual.as_slice() != *expected {
            return Err(io::Error::other(format!(
                "written driver file verification failed: {name}"
            )));
        }
    }

    // UMDF drivers run in user mode: once the test certificate is trusted,
    // the catalog verifies without TESTSIGNING or Secure Boot changes.
    let certificate = directory.join("MenoVirtualMouse.cer");
    let certificate = certificate.to_string_lossy().into_owned();
    run_checked(
        "certutil.exe",
        &["-f", "-addstore", "Root", &certificate],
        &[],
    )?;
    run_checked(
        "certutil.exe",
        &["-f", "-addstore", "TrustedPublisher", &certificate],
        &[],
    )?;

    let inf = directory.join("MenoVirtualMouse.inf");
    let inf = inf.canonicalize()?;
    let inf_argument = inf.to_string_lossy().into_owned();
    // pnputil returns ERROR_NO_MORE_ITEMS (259) when this exact package is
    // already present and the target device is already current.
    run_checked(
        "pnputil.exe",
        &["/add-driver", &inf_argument, "/install"],
        &[259],
    )?;
    let reboot_required =
        install_root_device(&inf).map_err(|error| io::Error::other(error.to_string()))?;
    if reboot_required {
        fs::write(
            directory.join(RESTART_MARKER),
            current_boot_epoch_seconds()?.to_string(),
        )?;
        return Ok(DriverInstallOutcome::RestartRequired);
    }
    if let Err(error) = crate::virtual_hid::VirtualHid::open() {
        return Err(io::Error::other(format!("driver did not start: {error}")));
    }
    let _ = fs::remove_file(directory.join(RESTART_MARKER));
    Ok(DriverInstallOutcome::Installed)
}

fn install_audio_driver_package() -> io::Result<()> {
    ensure_windows_11_x64()?;
    if !audio_driver_package_embedded() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "the EXE does not contain the official VB-CABLE package",
        ));
    }

    let directory = audio_driver_directory()?;
    ensure_safe_directory(
        directory
            .parent()
            .ok_or_else(|| io::Error::other("audio driver directory has no parent"))?,
    )?;
    reset_audio_driver_directory(&directory)?;
    fs::create_dir_all(&directory)?;
    let result = install_audio_driver_from_directory(&directory);
    if let Err(error) = reset_audio_driver_directory(&directory) {
        crate::logging::error(&format!(
            "Could not remove temporary VB-CABLE files: {error}"
        ));
    }
    result
}

fn install_audio_driver_from_directory(directory: &Path) -> io::Result<()> {
    let archive = directory.join(AUDIO_DRIVER_ARCHIVE_NAME);
    fs::write(&archive, AUDIO_DRIVER_ARCHIVE)?;
    if fs::read(&archive)?.as_slice() != AUDIO_DRIVER_ARCHIVE {
        return Err(io::Error::other(
            "written VB-CABLE archive verification failed",
        ));
    }

    let archive_argument = archive.to_string_lossy().into_owned();
    let directory_argument = directory.to_string_lossy().into_owned();
    run_checked(
        "tar.exe",
        &["-xf", &archive_argument, "-C", &directory_argument],
        &[],
    )?;
    for name in AUDIO_DRIVER_REQUIRED_FILES {
        if !directory.join(name).is_file() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("extracted VB-CABLE package is missing: {name}"),
            ));
        }
    }

    let exit_code = run_elevated_audio_driver_setup(directory)?;
    if exit_code == 0 || exit_code == 3010 {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "VB-CABLE 安装程序执行失败，退出码为 {exit_code}"
        )))
    }
}

fn run_elevated_audio_driver_setup(directory: &Path) -> io::Result<u32> {
    let setup = wide_os(directory.join("VBCABLE_Setup_x64.exe").as_os_str());
    let parameters = wide("-i -h");
    let working_directory = wide_os(directory.as_os_str());
    let mut execution = SHELLEXECUTEINFOW {
        cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOCLOSEPROCESS,
        lpVerb: w!("runas"),
        lpFile: PCWSTR(setup.as_ptr()),
        lpParameters: PCWSTR(parameters.as_ptr()),
        lpDirectory: PCWSTR(working_directory.as_ptr()),
        nShow: windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL.0,
        ..Default::default()
    };
    unsafe { ShellExecuteExW(&mut execution) }
        .map_err(|error| io::Error::other(format!("audio driver elevation failed: {error}")))?;
    if execution.hProcess.is_invalid() {
        return Err(io::Error::other(
            "audio driver installer did not return a process handle",
        ));
    }
    let wait_result = unsafe { WaitForSingleObject(execution.hProcess, INFINITE) };
    let mut exit_code = 0_u32;
    let result = if wait_result != WAIT_OBJECT_0 {
        Err(io::Error::last_os_error())
    } else {
        unsafe { GetExitCodeProcess(execution.hProcess, &mut exit_code) }
            .map_err(io::Error::other)
            .map(|()| exit_code)
    };
    let _ = unsafe { CloseHandle(execution.hProcess) };
    result
}

fn ensure_windows_11_x64() -> io::Result<()> {
    if !cfg!(target_arch = "x86_64") {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "Meno only supports Windows 11 x64",
        ));
    }
    let mut version = OSVERSIONINFOW {
        dwOSVersionInfoSize: std::mem::size_of::<OSVERSIONINFOW>() as u32,
        ..Default::default()
    };
    let status = unsafe { RtlGetVersion(&mut version) };
    if status.0 < 0 {
        return Err(io::Error::other(format!(
            "could not read the Windows version: 0x{:08X}",
            status.0 as u32
        )));
    }
    if version.dwMajorVersion != 10 || version.dwBuildNumber < WINDOWS_11_MINIMUM_BUILD {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "Meno audio driver only supports Windows 11 x64",
        ));
    }
    Ok(())
}

fn audio_driver_directory() -> io::Result<PathBuf> {
    let local_app_data = env::var_os("LOCALAPPDATA")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "LOCALAPPDATA is unavailable"))?;
    Ok(PathBuf::from(local_app_data)
        .join("Meno")
        .join("AudioDriver")
        .join(AUDIO_DRIVER_DIRECTORY_NAME))
}

fn reset_audio_driver_directory(directory: &Path) -> io::Result<()> {
    let metadata = match fs::symlink_metadata(directory) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0 {
        return Err(io::Error::other(
            "refusing to replace an unsafe audio driver directory",
        ));
    }
    fs::remove_dir_all(directory)
}

fn ensure_safe_directory(directory: &Path) -> io::Result<()> {
    if let Some(parent) = directory.parent() {
        let metadata = fs::symlink_metadata(parent)?;
        if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0 {
            return Err(io::Error::other(
                "refusing to use an unsafe audio driver parent directory",
            ));
        }
    }
    match fs::symlink_metadata(directory) {
        Ok(metadata)
            if metadata.is_dir()
                && metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT.0 == 0 =>
        {
            Ok(())
        }
        Ok(_) => Err(io::Error::other(
            "refusing to use an unsafe audio driver directory",
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => fs::create_dir(directory),
        Err(error) => Err(error),
    }
}

fn driver_directory() -> io::Result<PathBuf> {
    let local_app_data = env::var_os("LOCALAPPDATA")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "LOCALAPPDATA is unavailable"))?;
    let version = crate::virtual_hid::DRIVER_VERSION;
    Ok(PathBuf::from(local_app_data)
        .join("Meno")
        .join("Driver")
        .join(format!("{}.{}.{}", version.0, version.1, version.2)))
}

fn install_root_device(inf: &Path) -> windows::core::Result<bool> {
    let inf_wide = wide(inf.as_os_str().to_string_lossy().as_ref());
    let hardware_id = wide(DRIVER_HARDWARE_ID);
    let mut reboot_required = windows::core::BOOL(0);
    unsafe {
        DiInstallDriverW(
            None,
            PCWSTR(inf_wide.as_ptr()),
            DIIRFLAG_FORCE_INF,
            Some(&mut reboot_required),
        )?;
    }
    let first_update = unsafe {
        UpdateDriverForPlugAndPlayDevicesW(
            None,
            PCWSTR(hardware_id.as_ptr()),
            PCWSTR(inf_wide.as_ptr()),
            INSTALLFLAG_FORCE,
            Some(&mut reboot_required),
        )
    };
    match first_update {
        Ok(()) => return Ok(reboot_required.as_bool()),
        Err(error) if is_no_such_device(error.code()) => {}
        Err(error) => return Err(error),
    }

    let device_set = unsafe { SetupDiCreateDeviceInfoList(Some(&GUID_DEVCLASS_HIDCLASS), None)? };
    let create_result = (|| unsafe {
        let name = wide("MenoVirtualMouse");
        let mut device_info = SP_DEVINFO_DATA {
            cbSize: std::mem::size_of::<SP_DEVINFO_DATA>() as u32,
            ..Default::default()
        };
        SetupDiCreateDeviceInfoW(
            device_set,
            PCWSTR(name.as_ptr()),
            &GUID_DEVCLASS_HIDCLASS,
            PCWSTR::null(),
            None,
            DICD_GENERATE_ID,
            Some(&mut device_info),
        )?;
        let mut multi_string: Vec<u16> = DRIVER_HARDWARE_ID.encode_utf16().collect();
        multi_string.extend_from_slice(&[0, 0]);
        let bytes = std::slice::from_raw_parts(
            multi_string.as_ptr().cast::<u8>(),
            multi_string.len() * std::mem::size_of::<u16>(),
        );
        SetupDiSetDeviceRegistryPropertyW(
            device_set,
            &mut device_info,
            SPDRP_HARDWAREID,
            Some(bytes),
        )?;
        SetupDiCallClassInstaller(DIF_REGISTERDEVICE, device_set, Some(&device_info))
    })();
    let _ = unsafe { SetupDiDestroyDeviceInfoList(device_set) };
    create_result?;

    unsafe {
        UpdateDriverForPlugAndPlayDevicesW(
            None,
            PCWSTR(hardware_id.as_ptr()),
            PCWSTR(inf_wide.as_ptr()),
            INSTALLFLAG_FORCE,
            Some(&mut reboot_required),
        )?;
    }
    Ok(reboot_required.as_bool())
}

fn is_no_such_device(code: HRESULT) -> bool {
    code == HRESULT::from_win32(433)
}

fn run_checked(
    program: &str,
    arguments: &[&str],
    additional_success_codes: &[i32],
) -> io::Result<()> {
    let program_path = system_executable(program)?;
    let output = Command::new(&program_path).args(arguments).output()?;
    let exit_code = output.status.code();
    if output.status.success()
        || exit_code == Some(3010)
        || exit_code.is_some_and(|code| additional_success_codes.contains(&code))
    {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "{program} 执行失败，退出码为 {}",
            exit_code.map_or_else(|| "未知".to_string(), |code| code.to_string())
        )))
    }
}

fn restart_marker_state(directory: &Path) -> io::Result<Option<bool>> {
    let marker = directory.join(RESTART_MARKER);
    let contents = match fs::read_to_string(marker) {
        Ok(contents) => contents,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let Ok(previous_boot) = contents.trim().parse::<u64>() else {
        return Ok(None);
    };
    let current_boot = current_boot_epoch_seconds()?;
    Ok(Some(previous_boot.abs_diff(current_boot) <= 10))
}

fn current_boot_epoch_seconds() -> io::Result<u64> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_secs();
    Ok(now.saturating_sub(unsafe { GetTickCount64() } / 1000))
}

fn show_message(
    message: &str,
    title: &str,
    style: windows::Win32::UI::WindowsAndMessaging::MESSAGEBOX_STYLE,
) -> windows::Win32::UI::WindowsAndMessaging::MESSAGEBOX_RESULT {
    let message = wide(message);
    let title = wide(title);
    unsafe {
        MessageBoxW(
            None,
            PCWSTR(message.as_ptr()),
            PCWSTR(title.as_ptr()),
            style,
        )
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

fn wide_os(value: &std::ffi::OsStr) -> Vec<u16> {
    value.encode_wide().chain(std::iter::once(0)).collect()
}

pub(crate) fn system_executable(name: &str) -> io::Result<PathBuf> {
    if name.is_empty()
        || name.contains(['\\', '/'])
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid system executable name",
        ));
    }
    let mut buffer = vec![0_u16; 32_768];
    let length = unsafe { GetSystemDirectoryW(Some(&mut buffer)) };
    if length == 0 || length as usize >= buffer.len() {
        return Err(io::Error::last_os_error());
    }
    buffer.truncate(length as usize);
    let directory = PathBuf::from(String::from_utf16_lossy(&buffer));
    let executable = directory.join(name);
    if !executable.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("system executable was not found: {}", executable.display()),
        ));
    }
    Ok(executable)
}

fn request_existing_exit() {
    if let Ok(window) =
        unsafe { FindWindowW(w!("MenoClipboardMessageWindow"), w!("MenoClipboard")) }
    {
        let _ = unsafe { PostMessageW(Some(window), WM_CLOSE, WPARAM(0), LPARAM(0)) };
    }
}

fn notify_existing_rediscover() {
    if let Ok(window) =
        unsafe { FindWindowW(w!("MenoClipboardMessageWindow"), w!("MenoClipboard")) }
    {
        let _ = unsafe {
            PostMessageW(
                Some(window),
                WM_COMMAND,
                WPARAM(crate::tray::COMMAND_REDISCOVER),
                LPARAM(0),
            )
        };
    }
}

fn replace_executable(source: &Path, target: &Path) -> io::Result<()> {
    let parent = target
        .parent()
        .ok_or_else(|| io::Error::other("executable target has no parent"))?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_nanos();
    let staging = parent.join(format!(
        ".{}.stage-{}-{nonce:032x}",
        target
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("Meno"),
        std::process::id()
    ));
    let prepared = (|| {
        fs::copy(source, &staging)?;
        fs::OpenOptions::new()
            .write(true)
            .open(&staging)?
            .sync_all()?;
        if fs::read(source)? != fs::read(&staging)? {
            return Err(io::Error::other("staged executable failed verification"));
        }
        Ok(())
    })();
    if let Err(error) = prepared {
        let _ = fs::remove_file(&staging);
        return Err(error);
    }
    let staging_wide: Vec<u16> = staging.as_os_str().encode_wide().chain(Some(0)).collect();
    let target_wide: Vec<u16> = target.as_os_str().encode_wide().chain(Some(0)).collect();
    let mut last_error = None;
    for _ in 0..20 {
        match unsafe {
            MoveFileExW(
                PCWSTR(staging_wide.as_ptr()),
                PCWSTR(target_wide.as_ptr()),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )
        } {
            Ok(()) => return Ok(()),
            Err(error) => last_error = Some(io::Error::other(error)),
        }
        thread::sleep(Duration::from_millis(100));
    }
    let _ = fs::remove_file(&staging);
    Err(last_error.unwrap_or_else(|| io::Error::other("could not replace executable")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn system_program_resolution_rejects_names_with_paths() {
        assert!(system_executable(r"..\\pnputil.exe").is_err());
        assert!(system_executable(r"subdir/pnputil.exe").is_err());
        let reg = system_executable("reg.exe").unwrap();
        assert!(reg.is_absolute());
        assert_eq!(
            reg.file_name().and_then(|name| name.to_str()),
            Some("reg.exe")
        );
    }

    #[test]
    fn root_device_creation_is_only_allowed_for_no_such_device() {
        assert!(is_no_such_device(HRESULT::from_win32(433)));
        assert!(!is_no_such_device(HRESULT::from_win32(5)));
        assert!(!is_no_such_device(HRESULT::from_win32(259)));
    }

    #[test]
    fn official_audio_driver_archive_is_embedded() {
        assert!(audio_driver_package_embedded());
        assert_eq!(AUDIO_DRIVER_ARCHIVE.len(), 1_318_877);
        assert!(AUDIO_DRIVER_ARCHIVE.starts_with(b"PK\x03\x04"));
    }
}
