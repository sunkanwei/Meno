use windows::Win32::Graphics::Gdi::{
    DEVMODEW, DISPLAY_DEVICE_ACTIVE, DISPLAY_DEVICE_ATTACHED_TO_DESKTOP,
    DISPLAY_DEVICE_PRIMARY_DEVICE, DISPLAY_DEVICEW, ENUM_CURRENT_SETTINGS, EnumDisplayDevicesW,
    EnumDisplaySettingsW,
};
use windows::core::PCWSTR;

const PHILIPS_PNP_VENDOR: &str = "PHL";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DisplayContract {
    pub device_name: String,
    pub monitor_id: String,
    pub screen_width: u32,
    pub screen_height: u32,
}

impl DisplayContract {
    pub fn current() -> Result<Self, String> {
        let mut matches = Vec::new();
        let mut adapter_index = 0_u32;
        loop {
            let mut adapter = display_device();
            if unsafe { EnumDisplayDevicesW(PCWSTR::null(), adapter_index, &raw mut adapter, 0) }
                == false
            {
                break;
            }
            adapter_index += 1;
            if !adapter
                .StateFlags
                .contains(DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)
            {
                continue;
            }

            let mut monitor_index = 0_u32;
            loop {
                let mut monitor = display_device();
                if unsafe {
                    EnumDisplayDevicesW(
                        PCWSTR(adapter.DeviceName.as_ptr()),
                        monitor_index,
                        &raw mut monitor,
                        windows::Win32::UI::WindowsAndMessaging::EDD_GET_DEVICE_INTERFACE_NAME,
                    )
                } == false
                {
                    break;
                }
                monitor_index += 1;
                if !monitor.StateFlags.contains(DISPLAY_DEVICE_ACTIVE) {
                    continue;
                }
                let interface_id = wide_string(&monitor.DeviceID);
                let Some(monitor_id) = philips_monitor_id(&interface_id) else {
                    continue;
                };
                matches.push((
                    wide_string(&adapter.DeviceName),
                    monitor_id,
                    adapter.StateFlags.contains(DISPLAY_DEVICE_PRIMARY_DEVICE),
                ));
            }
        }

        let [(device_name, monitor_id, primary)] = matches.as_slice() else {
            return Err(match matches.len() {
                0 => "no active Philips display was found".to_string(),
                count => {
                    format!("{count} active Philips displays were found; identity is ambiguous")
                }
            });
        };
        if !primary {
            return Err(format!(
                "Philips display {monitor_id} on {device_name} is not the Windows primary display"
            ));
        }

        let device_name_wide: Vec<u16> = device_name
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let mut mode = DEVMODEW {
            dmSize: std::mem::size_of::<DEVMODEW>() as u16,
            ..Default::default()
        };
        if unsafe {
            EnumDisplaySettingsW(
                PCWSTR(device_name_wide.as_ptr()),
                ENUM_CURRENT_SETTINGS,
                &raw mut mode,
            )
        } == false
        {
            return Err(format!(
                "could not read the current display mode for {device_name}"
            ));
        }
        let position = unsafe { mode.Anonymous1.Anonymous2.dmPosition };
        if position.x != 0 || position.y != 0 {
            return Err(format!(
                "Philips primary display {monitor_id} has unexpected origin {},{}",
                position.x, position.y
            ));
        }
        let width = mode.dmPelsWidth;
        let height = mode.dmPelsHeight;
        if width < 2 || height == 0 || width > i32::MAX as u32 || height > i32::MAX as u32 {
            return Err(format!(
                "Windows reported an invalid primary display size {width}x{height}"
            ));
        }

        Ok(Self {
            device_name: device_name.clone(),
            monitor_id: monitor_id.clone(),
            screen_width: width,
            screen_height: height,
        })
    }

    pub fn ensure_current(&self) -> Result<(), String> {
        let current = Self::current()?;
        if current == *self {
            Ok(())
        } else {
            Err(format!(
                "Philips primary display contract changed from {} on {} {}x{} to {} on {} {}x{}",
                self.monitor_id,
                self.device_name,
                self.screen_width,
                self.screen_height,
                current.monitor_id,
                current.device_name,
                current.screen_width,
                current.screen_height,
            ))
        }
    }
}

fn display_device() -> DISPLAY_DEVICEW {
    DISPLAY_DEVICEW {
        cb: std::mem::size_of::<DISPLAY_DEVICEW>() as u32,
        ..Default::default()
    }
}

fn wide_string(value: &[u16]) -> String {
    let length = value
        .iter()
        .position(|character| *character == 0)
        .unwrap_or(value.len());
    String::from_utf16_lossy(&value[..length])
}

pub(crate) fn philips_monitor_id(interface_id: &str) -> Option<String> {
    let normalized = interface_id.trim().to_ascii_uppercase();
    let model = if let Some(start) = normalized.find("DISPLAY#") {
        normalized[start + "DISPLAY#".len()..].split('#').next()
    } else if let Some(start) = normalized.find("DISPLAY\\") {
        normalized[start + "DISPLAY\\".len()..].split('\\').next()
    } else if let Some(start) = normalized.find("MONITOR\\") {
        normalized[start + "MONITOR\\".len()..].split('\\').next()
    } else {
        None
    }?;
    (model.len() > PHILIPS_PNP_VENDOR.len() && model.starts_with(PHILIPS_PNP_VENDOR))
        .then(|| format!("DISPLAY\\{model}"))
}
