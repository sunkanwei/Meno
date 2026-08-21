use std::{fs, path::PathBuf, process::Stdio, ptr::NonNull, time::Duration};

use image::{ExtendedColorType, ImageEncoder, codecs::png::PngEncoder};
use rmcp::schemars;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    background_process,
    config::DataPaths,
    error::{AgentError, AgentResult},
};

#[repr(C)]
#[derive(Debug, Default)]
struct CaptureBuffer {
    data: *mut u8,
    width: u32,
    height: u32,
    stride: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct RawTargetInfo {
    id: u64,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    flags: u32,
    title: [u8; 512],
}

impl Default for RawTargetInfo {
    fn default() -> Self {
        Self {
            id: 0,
            x: 0,
            y: 0,
            width: 0,
            height: 0,
            flags: 0,
            title: [0; 512],
        }
    }
}

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct CaptureTarget {
    pub id: String,
    pub kind: String,
    pub title: String,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub primary: bool,
    pub minimized: bool,
}

unsafe extern "C" {
    fn capture_primary_monitor(output: *mut CaptureBuffer) -> i32;
    fn capture_monitor(id: u64, output: *mut CaptureBuffer) -> i32;
    fn capture_window(id: u64, output: *mut CaptureBuffer) -> i32;
    fn get_monitor_count() -> u32;
    fn get_window_count() -> u32;
    fn get_monitor_info(index: u32, output: *mut RawTargetInfo) -> i32;
    fn get_window_info(index: u32, output: *mut RawTargetInfo) -> i32;
    fn free_capture_buffer(data: *mut u8);
}

#[derive(Debug)]
pub struct CapturedFrame {
    data: NonNull<u8>,
    pub width: u32,
    pub height: u32,
    pub stride: u32,
}

#[derive(Clone, Debug)]
pub struct IsolatedCaptureRequest {
    pub target: String,
    pub id: Option<u64>,
    pub region: Option<(u32, u32, u32, u32)>,
    pub max_dimension: Option<u32>,
}

#[derive(Debug)]
pub struct IsolatedCapture {
    pub png: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub scaled: bool,
}

#[derive(Debug, Deserialize, Serialize)]
struct CaptureWorkerMetadata {
    width: u32,
    height: u32,
    scaled: bool,
    bytes: usize,
}

pub async fn capture_isolated(
    paths: &DataPaths,
    request: &IsolatedCaptureRequest,
) -> AgentResult<IsolatedCapture> {
    let output_path = paths
        .temp_dir
        .join(format!("capture-{}.png", Uuid::new_v4()));
    let mut command = background_process::tokio_command(std::env::current_exe()?);
    command
        .arg("--meno-agent-capture-worker")
        .arg("--target")
        .arg(&request.target)
        .arg("--output")
        .arg(&output_path)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command.kill_on_drop(true);
    if let Some(id) = request.id {
        command.arg("--id").arg(id.to_string());
    }
    if let Some((x, y, width, height)) = request.region {
        command
            .arg("--x")
            .arg(x.to_string())
            .arg("--y")
            .arg(y.to_string())
            .arg("--width")
            .arg(width.to_string())
            .arg("--height")
            .arg(height.to_string());
    }
    if let Some(max_dimension) = request.max_dimension {
        command
            .arg("--max-dimension")
            .arg(max_dimension.to_string());
    }
    let result = tokio::time::timeout(Duration::from_secs(8), command.output()).await;
    let cleanup = || {
        let _ = fs::remove_file(&output_path);
    };
    let output = match result {
        Err(_) => {
            cleanup();
            return Err(AgentError::Timeout(
                "screenshot_worker_timeout: 截图子进程超过 8 秒".to_owned(),
            ));
        }
        Ok(Err(error)) => {
            cleanup();
            return Err(error.into());
        }
        Ok(Ok(output)) => output,
    };
    if !output.status.success() {
        cleanup();
        let code = output
            .status
            .code()
            .map(|value| format!("{:#010x}", value as u32))
            .unwrap_or_else(|| "unknown".to_owned());
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(AgentError::ScreenshotFailed(format!(
            "screenshot_worker_failed: 截图子进程异常退出 code={code}; {}",
            stderr.trim()
        )));
    }
    let metadata: CaptureWorkerMetadata =
        serde_json::from_slice(&output.stdout).map_err(|error| {
            cleanup();
            AgentError::ScreenshotFailed(format!("screenshot_worker_protocol: {error}"))
        })?;
    let png = fs::read(&output_path).map_err(|error| {
        cleanup();
        AgentError::ScreenshotFailed(format!("screenshot_worker_output: {error}"))
    })?;
    cleanup();
    if png.len() != metadata.bytes || png.len() < 8 || &png[..8] != b"\x89PNG\r\n\x1a\n" {
        return Err(AgentError::ScreenshotFailed(
            "screenshot_worker_output: 截图结果不完整或格式无效".to_owned(),
        ));
    }
    Ok(IsolatedCapture {
        png,
        width: metadata.width,
        height: metadata.height,
        scaled: metadata.scaled,
    })
}

pub fn run_capture_worker(
    paths: &DataPaths,
    target: &str,
    id: Option<u64>,
    region: Option<(u32, u32, u32, u32)>,
    max_dimension: Option<u32>,
    output_path: PathBuf,
) -> AgentResult<()> {
    let expected_parent = fs::canonicalize(&paths.temp_dir)?;
    let parent = output_path
        .parent()
        .ok_or_else(|| AgentError::InvalidArgument("截图输出路径无父目录".to_owned()))?;
    let parent = fs::canonicalize(parent)?;
    let valid_name = output_path
        .file_name()
        .and_then(|value| value.to_str())
        .is_some_and(|value| value.starts_with("capture-") && value.ends_with(".png"));
    if parent != expected_parent || !valid_name {
        return Err(AgentError::PermissionDenied(
            "截图子进程只能写入代理临时目录".to_owned(),
        ));
    }
    let (pixels, width, height) = capture_target_rgba(target, id)?;
    if !pixels.iter().any(|value| *value != 0) {
        return Err(AgentError::ScreenshotProtected("捕获画面为空".to_owned()));
    }
    let automatic_scale = (pixels.len() > 11 * 1024 * 1024).then_some(1600);
    let (png, width, height, scaled) = render_rgba(
        pixels,
        width,
        height,
        region,
        max_dimension.or(automatic_scale),
    )
    .map_err(AgentError::InvalidArgument)?;
    if png.len() > 12 * 1024 * 1024 {
        return Err(AgentError::Internal(
            "screenshot_too_large: PNG 超过 12 MiB".to_owned(),
        ));
    }
    let temporary = output_path.with_extension("png.tmp");
    fs::write(&temporary, &png)?;
    fs::rename(&temporary, &output_path)?;
    println!(
        "{}",
        serde_json::to_string(&CaptureWorkerMetadata {
            width,
            height,
            scaled,
            bytes: png.len(),
        })
        .map_err(|error| AgentError::Internal(error.to_string()))?
    );
    Ok(())
}

fn capture_target_rgba(target: &str, id: Option<u64>) -> AgentResult<(Vec<u8>, u32, u32)> {
    match target {
        "virtual_desktop" => virtual_desktop_rgba().map_err(AgentError::Internal),
        "primary" => {
            let frame = CapturedFrame::capture_primary_monitor()
                .map_err(|code| AgentError::Internal(hr(code)))?;
            Ok((frame.to_rgba(), frame.width, frame.height))
        }
        "monitor" | "window" => {
            let id = id.ok_or_else(|| AgentError::InvalidArgument("截图目标缺少 id".to_owned()))?;
            let frame = CapturedFrame::capture(target, id)
                .map_err(|code| AgentError::Internal(hr(code)))?;
            Ok((frame.to_rgba(), frame.width, frame.height))
        }
        _ => Err(AgentError::InvalidArgument("截图目标无效".to_owned())),
    }
}

impl CapturedFrame {
    pub fn capture_primary_monitor() -> Result<Self, i32> {
        let mut raw = CaptureBuffer::default();
        // SAFETY: C++ initializes the output on success and never retains the pointer.
        let result = unsafe { capture_primary_monitor(&mut raw) };
        if result < 0 {
            return Err(result);
        }
        let data = NonNull::new(raw.data).ok_or(0x8000_4005_u32 as i32)?;
        Ok(Self {
            data,
            width: raw.width,
            height: raw.height,
            stride: raw.stride,
        })
    }

    pub fn capture(kind: &str, id: u64) -> Result<Self, i32> {
        let mut raw = CaptureBuffer::default();
        let result = unsafe {
            match kind {
                "monitor" => capture_monitor(id, &mut raw),
                "window" => capture_window(id, &mut raw),
                _ => return Err(0x8007_0057_u32 as i32),
            }
        };
        Self::from_raw(result, raw)
    }

    fn from_raw(result: i32, raw: CaptureBuffer) -> Result<Self, i32> {
        if result < 0 {
            return Err(result);
        }
        let data = NonNull::new(raw.data).ok_or(0x8000_4005_u32 as i32)?;
        Ok(Self {
            data,
            width: raw.width,
            height: raw.height,
            stride: raw.stride,
        })
    }

    pub fn byte_len(&self) -> usize {
        self.stride as usize * self.height as usize
    }

    pub fn has_nonzero_pixel_data(&self) -> bool {
        // SAFETY: The allocation belongs to this frame and is valid for byte_len bytes.
        unsafe { std::slice::from_raw_parts(self.data.as_ptr(), self.byte_len()) }
            .iter()
            .any(|value| *value != 0)
    }

    pub fn to_png(&self) -> Result<Vec<u8>, image::ImageError> {
        let mut output = Vec::new();
        let pixels = self.to_rgba();
        PngEncoder::new(&mut output).write_image(
            &pixels,
            self.width,
            self.height,
            ExtendedColorType::Rgba8,
        )?;
        Ok(output)
    }

    pub fn to_rgba(&self) -> Vec<u8> {
        let source = unsafe { std::slice::from_raw_parts(self.data.as_ptr(), self.byte_len()) };
        let mut pixels = source.to_vec();
        for pixel in pixels.chunks_exact_mut(4) {
            pixel.swap(0, 2);
        }
        pixels
    }
}

pub fn enumerate(kind: &str) -> Result<Vec<CaptureTarget>, i32> {
    let count = unsafe {
        if kind == "monitor" {
            get_monitor_count()
        } else if kind == "window" {
            get_window_count()
        } else {
            return Err(0x8007_0057_u32 as i32);
        }
    };
    let mut result = Vec::with_capacity(count as usize);
    for index in 0..count {
        let mut raw = RawTargetInfo::default();
        let code = unsafe {
            if kind == "monitor" {
                get_monitor_info(index, &mut raw)
            } else {
                get_window_info(index, &mut raw)
            }
        };
        if code < 0 {
            return Err(code);
        }
        let end = raw
            .title
            .iter()
            .position(|byte| *byte == 0)
            .unwrap_or(raw.title.len());
        result.push(CaptureTarget {
            id: raw.id.to_string(),
            kind: kind.to_owned(),
            title: String::from_utf8_lossy(&raw.title[..end]).into_owned(),
            x: raw.x,
            y: raw.y,
            width: raw.width,
            height: raw.height,
            primary: raw.flags & 1 != 0,
            minimized: raw.flags & 2 != 0,
        });
    }
    Ok(result)
}

pub fn virtual_desktop_rgba() -> Result<(Vec<u8>, u32, u32), String> {
    let monitors = enumerate("monitor").map_err(hr)?;
    if monitors.is_empty() {
        return Err("no_display: 未发现活动显示器".to_owned());
    }
    let left = monitors.iter().map(|m| m.x).min().unwrap();
    let top = monitors.iter().map(|m| m.y).min().unwrap();
    let right = monitors.iter().map(|m| m.x + m.width as i32).max().unwrap();
    let bottom = monitors
        .iter()
        .map(|m| m.y + m.height as i32)
        .max()
        .unwrap();
    let width = (right - left) as u32;
    let height = (bottom - top) as u32;
    if width as u64 * height as u64 > 80_000_000 {
        return Err("screenshot_too_large: 虚拟桌面超过 8000 万像素".to_owned());
    }
    let mut canvas = vec![0_u8; width as usize * height as usize * 4];
    for monitor in monitors {
        let frame = CapturedFrame::capture(
            "monitor",
            monitor.id.parse().map_err(|_| "invalid monitor id")?,
        )
        .map_err(hr)?;
        let pixels = frame.to_rgba();
        let offset_x = (monitor.x - left) as usize;
        let offset_y = (monitor.y - top) as usize;
        for row in 0..frame.height as usize {
            let src = &pixels[row * frame.width as usize * 4..(row + 1) * frame.width as usize * 4];
            let start = ((offset_y + row) * width as usize + offset_x) * 4;
            canvas[start..start + src.len()].copy_from_slice(src);
        }
    }
    Ok((canvas, width, height))
}

pub fn render_rgba(
    pixels: Vec<u8>,
    width: u32,
    height: u32,
    region: Option<(u32, u32, u32, u32)>,
    max_dimension: Option<u32>,
) -> Result<(Vec<u8>, u32, u32, bool), String> {
    let image =
        image::RgbaImage::from_raw(width, height, pixels).ok_or("invalid screenshot buffer")?;
    let (x, y, crop_width, crop_height) = region.unwrap_or((0, 0, width, height));
    if crop_width == 0
        || crop_height == 0
        || x.checked_add(crop_width).is_none_or(|end| end > width)
        || y.checked_add(crop_height).is_none_or(|end| end > height)
    {
        return Err("invalid_region: 截取区域超出目标边界".to_owned());
    }
    let mut output = image::imageops::crop_imm(&image, x, y, crop_width, crop_height).to_image();
    let mut scaled = false;
    if let Some(maximum) = max_dimension {
        let maximum = maximum.clamp(320, 7680);
        let largest = output.width().max(output.height());
        if largest > maximum {
            let ratio = maximum as f64 / largest as f64;
            let new_width = (output.width() as f64 * ratio).round().max(1.0) as u32;
            let new_height = (output.height() as f64 * ratio).round().max(1.0) as u32;
            output = image::imageops::resize(
                &output,
                new_width,
                new_height,
                image::imageops::FilterType::Triangle,
            );
            scaled = true;
        }
    }
    let (output_width, output_height) = output.dimensions();
    let mut png = Vec::new();
    PngEncoder::new(&mut png)
        .write_image(
            output.as_raw(),
            output_width,
            output_height,
            ExtendedColorType::Rgba8,
        )
        .map_err(|error| error.to_string())?;
    Ok((png, output_width, output_height, scaled))
}

pub fn hr(code: i32) -> String {
    if code as u32 == 0x8007_0578 {
        "window_minimized: 目标窗口已最小化".to_owned()
    } else if code as u32 == 0x8007_0005 {
        "screenshot_protected: Windows 拒绝捕获该内容".to_owned()
    } else if matches!(code as u32, 0x887A_0005 | 0x887A_0007) {
        "graphics_device_lost: 图形设备已移除或重置".to_owned()
    } else if code as u32 == 0x8007_010E {
        "interactive_session_disconnected: 用户桌面会话已断开".to_owned()
    } else {
        format!("screenshot_failed: HRESULT {code:#x}")
    }
}

impl Drop for CapturedFrame {
    fn drop(&mut self) {
        // SAFETY: The pointer was allocated by the C++ bridge and is freed exactly once here.
        unsafe { free_capture_buffer(self.data.as_ptr()) };
    }
}

#[cfg(test)]
mod tests {
    use super::CapturedFrame;

    #[test]
    fn captures_primary_monitor_and_releases_cpp_buffer() {
        let frame = CapturedFrame::capture_primary_monitor()
            .expect("Windows Graphics Capture should return the primary monitor frame");
        assert!(frame.width > 0);
        assert!(frame.height > 0);
        assert_eq!(frame.stride, frame.width * 4);
        assert!(frame.has_nonzero_pixel_data());
    }
}
