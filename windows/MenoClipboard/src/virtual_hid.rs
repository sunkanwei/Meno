use std::env;
use std::ffi::c_void;
use std::fmt;
use std::io::{self, Read, Write};
use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::ptr;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{CloseHandle, ERROR_IO_PENDING, HANDLE, WAIT_TIMEOUT};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_FLAG_OVERLAPPED, FILE_GENERIC_READ,
    FILE_GENERIC_WRITE, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING, WriteFile,
};
use windows::Win32::System::IO::{
    CancelIoEx, GetOverlappedResult, GetOverlappedResultEx, OVERLAPPED,
};
use windows::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
    SetInformationJobObject,
};
use windows::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};
use windows::Win32::System::Threading::{CREATE_NO_WINDOW, CreateEventW, ResetEvent};
use windows::core::{GUID, HRESULT, PCWSTR};

pub const DRIVER_ABI: u16 = 6;
pub const DRIVER_VERSION: (u16, u16, u16) = (2, 3, 5);
pub const REPORT_VERSION: u8 = 2;
pub const MAXIMUM_BATCH: usize = 15;
pub const MAXIMUM_KEYBOARD_KEYS: usize = 6;
pub const ABSOLUTE_MAXIMUM: u16 = 32767;
const WRITE_TIMEOUT_MS: u32 = 100;

const MENO_VENDOR_ID: u16 = 0x4D45;
const MENO_PRODUCT_ID: u16 = 0x4E4F;
const CONTROL_REPORT_ID: u8 = 0x10;
const CONTROL_REPORT_SIZE: usize = 133;
const OUTPUT_REPORT_ID: u8 = 0x11;
const OUTPUT_REPORT_SIZE: usize = 133;
const OUTPUT_HEADER_SIZE: usize = 7;
const COMMAND_SUBMIT: u8 = 1;
const COMMAND_RESET: u8 = 2;
const COMMAND_KEYBOARD_STATE: u8 = 3;
const REQUIRED_CAPABILITIES: u32 = 0x0000_01FF;
const INFO_SIZE: usize = 88;
const PATH_ANOMALY: Duration = Duration::from_millis(32);
const CR_SUCCESS: u32 = 0;
const CR_BUFFER_SMALL: u32 = 0x1A;
const CM_GET_DEVICE_INTERFACE_LIST_PRESENT: u32 = 0;
const BROKER_ARGUMENT: &str = "--meno-hid-broker";
const BROKER_PROTOCOL_VERSION: u8 = 1;
const BROKER_OP_QUERY: u8 = 1;
const BROKER_OP_WRITE: u8 = 2;
const BROKER_STATUS_OK: u8 = 0;
const BROKER_STATUS_ERROR: u8 = 1;
const BROKER_STATUS_READY: u8 = 2;
const BROKER_READY_SEQUENCE: u64 = u64::MAX;
const BROKER_HEADER_SIZE: usize = 12;
const BROKER_MAX_PAYLOAD: usize = 512;
const BROKER_START_TIMEOUT: Duration = Duration::from_millis(500);
const BROKER_RESPONSE_TIMEOUT: Duration = Duration::from_millis(50);

#[repr(C)]
struct HiddAttributes {
    size: u32,
    vendor_id: u16,
    product_id: u16,
    version_number: u16,
}

#[link(name = "hid")]
unsafe extern "system" {
    fn HidD_GetHidGuid(hid_guid: *mut GUID);
    fn HidD_GetAttributes(device: HANDLE, attributes: *mut HiddAttributes) -> u8;
    fn HidD_GetFeature(device: HANDLE, report_buffer: *mut c_void, report_length: u32) -> u8;
}

#[link(name = "cfgmgr32")]
unsafe extern "system" {
    fn CM_Get_Device_Interface_List_SizeW(
        length: *mut u32,
        interface_class_guid: *const GUID,
        device_id: *const u16,
        flags: u32,
    ) -> u32;
    fn CM_Get_Device_Interface_ListW(
        interface_class_guid: *const GUID,
        device_id: *const u16,
        buffer: *mut u16,
        buffer_length: u32,
        flags: u32,
    ) -> u32;
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[allow(dead_code)]
pub struct DriverStats {
    pub accepted_reports: u64,
    pub maximum_queue_depth: u32,
    pub merge_count: u32,
    pub current_queue_depth: u32,
    pub output_writes: u64,
    pub last_output_sequence: u16,
    pub last_write_enter_qpc: u64,
    pub last_write_exit_qpc: u64,
    pub qpc_frequency: u64,
    pub last_write_duration_us: u32,
    pub maximum_write_duration_us: u32,
    pub last_write_status: i32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HidReport {
    pub x: u16,
    pub y: u16,
    pub wheel: i8,
    pub buttons: u8,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HidWriteErrorKind {
    TimedOut,
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HidWriteError {
    pub kind: HidWriteErrorKind,
    message: String,
}

impl fmt::Display for HidWriteError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for HidWriteError {}

pub struct VirtualHid {
    broker: BrokerClient,
    initialized: bool,
    dirty: bool,
    healthy: bool,
    sequence: u16,
    last_broker_io_us: Option<u64>,
    last_path_diagnostic: Option<String>,
}

struct DirectHid {
    handle: HANDLE,
    event: HANDLE,
}

impl VirtualHid {
    pub fn open() -> Result<Self, String> {
        let mut device = Self {
            broker: BrokerClient::spawn()?,
            initialized: false,
            dirty: false,
            healthy: true,
            sequence: 0,
            last_broker_io_us: None,
            last_path_diagnostic: None,
        };
        device.validate()?;
        Ok(device)
    }

    pub fn submit(&mut self, reports: &[HidReport]) -> Result<(), HidWriteError> {
        if !self.initialized {
            return Err(HidWriteError::failed(
                "Meno Virtual Mouse must be reset before its first submission",
            ));
        }
        if reports.is_empty() || reports.len() > MAXIMUM_BATCH {
            return Err(HidWriteError::failed("invalid virtual HID batch size"));
        }
        let mut output = self.output_report(COMMAND_SUBMIT, reports.len() as u8, 0)?;
        for (index, report) in reports.iter().enumerate() {
            if report.buttons & !0x07 != 0
                || report.x > ABSOLUTE_MAXIMUM
                || report.y > ABSOLUTE_MAXIMUM
                || report.wheel == i8::MIN
            {
                return Err(HidWriteError::failed("invalid virtual HID report"));
            }
            let offset = OUTPUT_HEADER_SIZE + index * 8;
            output[offset..offset + 2].copy_from_slice(&report.x.to_le_bytes());
            output[offset + 2..offset + 4].copy_from_slice(&report.y.to_le_bytes());
            output[offset + 4] = report.wheel as u8;
            output[offset + 5] = report.buttons;
        }
        self.write_command(&output)?;
        self.dirty = true;
        Ok(())
    }

    pub fn reset(&mut self) -> Result<(), HidWriteError> {
        self.reset_at(None)
    }

    pub fn reset_at(&mut self, position: Option<HidReport>) -> Result<(), HidWriteError> {
        if position.is_some_and(|report| report.x > ABSOLUTE_MAXIMUM || report.y > ABSOLUTE_MAXIMUM)
        {
            return Err(HidWriteError::failed("invalid virtual HID reset position"));
        }
        let mut output = self.output_report(COMMAND_RESET, u8::from(position.is_some()), 0)?;
        if let Some(position) = position {
            encode_reset_position(&mut output, position);
        }
        self.write_command(&output)?;
        self.initialized = true;
        self.dirty = false;
        Ok(())
    }

    pub fn set_keyboard_state(&mut self, modifiers: u8, keys: &[u8]) -> Result<(), HidWriteError> {
        if !self.initialized {
            return Err(HidWriteError::failed(
                "Meno Virtual Mouse must be reset before keyboard submission",
            ));
        }
        if keys.len() > MAXIMUM_KEYBOARD_KEYS {
            return Err(HidWriteError::failed("too many simultaneous keyboard keys"));
        }
        let mut sorted_keys = [0_u8; MAXIMUM_KEYBOARD_KEYS];
        sorted_keys[..keys.len()].copy_from_slice(keys);
        sorted_keys[..keys.len()].sort_unstable();
        for (index, key) in sorted_keys[..keys.len()].iter().enumerate() {
            if !(0x04..0xE0).contains(key) || (index > 0 && sorted_keys[index - 1] == *key) {
                return Err(HidWriteError::failed("invalid virtual keyboard state"));
            }
        }

        let mut output = self.output_report(COMMAND_KEYBOARD_STATE, keys.len() as u8, modifiers)?;
        output[OUTPUT_HEADER_SIZE..OUTPUT_HEADER_SIZE + MAXIMUM_KEYBOARD_KEYS]
            .copy_from_slice(&sorted_keys);
        self.write_command(&output)?;
        self.dirty = true;
        Ok(())
    }

    #[allow(dead_code)]
    pub fn stats(&mut self) -> Result<DriverStats, String> {
        Ok(parse_driver_stats(&self.query_info()?))
    }

    pub fn take_path_diagnostic(&mut self) -> Option<String> {
        self.last_path_diagnostic.take()
    }

    fn validate(&mut self) -> Result<(), String> {
        let output = self.query_info()?;
        validate_driver_info(&output)
    }

    fn query_info(&mut self) -> Result<[u8; INFO_SIZE], String> {
        let response = self
            .broker
            .exchange(BROKER_OP_QUERY, &[], true)
            .map_err(|error| error.to_string())?;
        if response.len() != INFO_SIZE {
            return Err(format!(
                "Meno HID broker returned {} of {INFO_SIZE} diagnostic bytes",
                response.len()
            ));
        }
        let mut output = [0_u8; INFO_SIZE];
        output.copy_from_slice(&response);
        Ok(output)
    }

    fn output_report(
        &mut self,
        command: u8,
        count: u8,
        flags: u8,
    ) -> Result<[u8; OUTPUT_REPORT_SIZE], HidWriteError> {
        if !self.healthy {
            return Err(HidWriteError::failed(
                "Meno Virtual Mouse handle is unhealthy and must be reopened",
            ));
        }
        self.sequence = self.sequence.wrapping_add(1);
        if self.sequence == 0 {
            self.sequence = 1;
        }
        Ok(encode_output_header(command, count, flags, self.sequence))
    }

    fn write_command(&mut self, output: &[u8; OUTPUT_REPORT_SIZE]) -> Result<(), HidWriteError> {
        let sequence = u16::from_le_bytes(output[5..7].try_into().unwrap());
        let app_start_qpc = performance_counter();
        let started = Instant::now();
        let result = self.write_output(output);
        let elapsed = started.elapsed();
        let app_end_qpc = performance_counter();
        let broker_diagnostic = self.broker.take_diagnostic();
        if elapsed >= PATH_ANOMALY || broker_diagnostic.is_some() {
            let app_qpc_frequency = performance_frequency();
            self.last_path_diagnostic = Some(match &result {
                Ok(()) => format!(
                    "sequence={sequence} app_us={} broker_io_us={} app_qpc={app_start_qpc}..{app_end_qpc} qpc_frequency={app_qpc_frequency} broker={} result=ok",
                    elapsed.as_micros(),
                    self.last_broker_io_us
                        .map_or_else(|| "unknown".to_string(), |value| value.to_string()),
                    broker_diagnostic.as_deref().unwrap_or("normal")
                ),
                Err(error) => format!(
                    "sequence={sequence} app_us={} broker_io_us={} app_qpc={app_start_qpc}..{app_end_qpc} qpc_frequency={app_qpc_frequency} broker={} write_error={error}",
                    elapsed.as_micros(),
                    self.last_broker_io_us
                        .map_or_else(|| "unknown".to_string(), |value| value.to_string()),
                    broker_diagnostic.as_deref().unwrap_or("normal")
                ),
            });
        }
        match result {
            Ok(()) => Ok(()),
            Err(error) => {
                self.healthy = false;
                Err(error)
            }
        }
    }

    fn write_output(&mut self, output: &[u8; OUTPUT_REPORT_SIZE]) -> Result<(), HidWriteError> {
        self.last_broker_io_us = None;
        let response =
            self.broker
                .exchange(BROKER_OP_WRITE, output, output_is_recoverable(output))?;
        self.last_broker_io_us = Some(parse_broker_write_response(&response)?);
        Ok(())
    }
}

impl DirectHid {
    fn open() -> Result<Self, String> {
        let mut hid_guid = GUID::zeroed();
        unsafe { HidD_GetHidGuid(&mut hid_guid) };
        let paths = hid_interface_paths(&hid_guid)?;
        let mut last_error = None;
        let mut validation_error = None;

        for mut path in paths {
            path.push(0);
            let handle = match unsafe {
                CreateFileW(
                    PCWSTR(path.as_ptr()),
                    FILE_GENERIC_READ.0 | FILE_GENERIC_WRITE.0,
                    FILE_SHARE_READ | FILE_SHARE_WRITE,
                    None,
                    OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
                    None,
                )
            } {
                Ok(handle) => handle,
                Err(error) => {
                    last_error = Some(error.to_string());
                    continue;
                }
            };

            let mut attributes = HiddAttributes {
                size: std::mem::size_of::<HiddAttributes>() as u32,
                vendor_id: 0,
                product_id: 0,
                version_number: 0,
            };
            if unsafe { HidD_GetAttributes(handle, &mut attributes) } == 0
                || attributes.vendor_id != MENO_VENDOR_ID
                || attributes.product_id != MENO_PRODUCT_ID
            {
                let _ = unsafe { CloseHandle(handle) };
                continue;
            }

            let event = match unsafe { CreateEventW(None, true, false, None) } {
                Ok(event) => event,
                Err(error) => {
                    let _ = unsafe { CloseHandle(handle) };
                    last_error = Some(error.to_string());
                    continue;
                }
            };
            let device = Self { handle, event };
            match device
                .query_info()
                .and_then(|info| validate_driver_info(&info))
            {
                Ok(()) => return Ok(device),
                Err(error) => validation_error = Some(error),
            }
        }

        Err(validation_error.or(last_error).unwrap_or_else(|| {
            "Meno Virtual Mouse control HID interface was not found".to_string()
        }))
    }

    fn query_info(&self) -> Result<[u8; INFO_SIZE], String> {
        let mut report = [0_u8; CONTROL_REPORT_SIZE];
        report[0] = CONTROL_REPORT_ID;
        if unsafe { HidD_GetFeature(self.handle, report.as_mut_ptr().cast(), report.len() as u32) }
            == 0
        {
            return Err(format!(
                "Meno Virtual Mouse query failed: {}",
                io::Error::last_os_error()
            ));
        }
        let mut output = [0_u8; INFO_SIZE];
        output.copy_from_slice(&report[1..1 + INFO_SIZE]);
        Ok(output)
    }

    fn write_output(&mut self, output: &[u8; OUTPUT_REPORT_SIZE]) -> Result<(), HidWriteError> {
        unsafe { ResetEvent(self.event) }.map_err(|error| {
            HidWriteError::failed(format!("could not reset HID event: {error}"))
        })?;
        let mut overlapped = OVERLAPPED {
            hEvent: self.event,
            ..Default::default()
        };
        let mut transferred = 0_u32;
        let write = unsafe { WriteFile(self.handle, Some(output), None, Some(&mut overlapped)) };

        match write {
            Ok(()) => {
                unsafe { GetOverlappedResult(self.handle, &overlapped, &mut transferred, false) }
                    .map_err(|error| {
                        HidWriteError::failed(format!(
                            "Meno Virtual Mouse immediate completion failed: {error}"
                        ))
                    })?
            }
            Err(error) if error.code() == ERROR_IO_PENDING.to_hresult() => {
                let completion = unsafe {
                    GetOverlappedResultEx(
                        self.handle,
                        &overlapped,
                        &mut transferred,
                        WRITE_TIMEOUT_MS,
                        false,
                    )
                };
                if let Err(error) = completion {
                    if error.code() == HRESULT::from_win32(WAIT_TIMEOUT.0) {
                        let cancel = unsafe { CancelIoEx(self.handle, Some(&overlapped)) };
                        let mut cancelled_bytes = 0_u32;
                        let completion_after_cancel = unsafe {
                            GetOverlappedResult(
                                self.handle,
                                &overlapped,
                                &mut cancelled_bytes,
                                true,
                            )
                        };
                        let cancellation_error = cancel.err().map(|value| value.to_string());
                        transferred = classify_completion_after_timeout(
                            output.len(),
                            cancellation_error.as_deref(),
                            completion_after_cancel
                                .map(|_| cancelled_bytes)
                                .map_err(|value| value.to_string()),
                        )?;
                    } else {
                        return Err(HidWriteError::failed(format!(
                            "Meno Virtual Mouse output completion failed: {error}"
                        )));
                    }
                }
            }
            Err(error) => {
                return Err(HidWriteError::failed(format!(
                    "Meno Virtual Mouse output failed: {error}"
                )));
            }
        }

        if transferred as usize != output.len() {
            return Err(HidWriteError::failed(format!(
                "Meno Virtual Mouse output wrote {transferred} of {} bytes",
                output.len()
            )));
        }
        Ok(())
    }
}

struct BrokerClient {
    _job: BrokerJob,
    child: Child,
    input: ChildStdin,
    responses: Receiver<Result<BrokerFrame, String>>,
    next_sequence: u64,
    last_diagnostic: Option<String>,
}

struct BrokerJob {
    handle: HANDLE,
}

#[derive(Debug, Eq, PartialEq)]
struct BrokerFrame {
    code: u8,
    sequence: u64,
    payload: Vec<u8>,
}

struct BrokerExchangeFailure {
    error: HidWriteError,
    transport: bool,
    reason: &'static str,
}

impl BrokerExchangeFailure {
    fn transport(error: HidWriteError, reason: &'static str) -> Self {
        Self {
            error,
            transport: true,
            reason,
        }
    }

    fn operation(error: HidWriteError) -> Self {
        Self {
            error,
            transport: false,
            reason: "operation",
        }
    }

    fn should_restart(&self, request_recoverable: bool) -> bool {
        self.transport && request_recoverable
    }
}

impl BrokerClient {
    fn spawn() -> Result<Self, String> {
        let job = BrokerJob::create()?;
        let executable = env::current_exe()
            .map_err(|error| format!("could not locate the Meno executable: {error}"))?;
        let mut command = Command::new(executable);
        command
            .arg(BROKER_ARGUMENT)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW.0);
        let mut child = command
            .spawn()
            .map_err(|error| format!("could not start the Meno HID broker: {error}"))?;
        if let Err(error) = job.assign(&child) {
            let _ = child.kill();
            return Err(error);
        }
        let input = child
            .stdin
            .take()
            .ok_or_else(|| "Meno HID broker stdin was unavailable".to_string())?;
        let output = child
            .stdout
            .take()
            .ok_or_else(|| "Meno HID broker stdout was unavailable".to_string())?;
        let (sender, responses) = mpsc::channel();
        if let Err(error) = thread::Builder::new()
            .name("meno-hid-broker-reader".to_string())
            .spawn(move || broker_response_reader(output, sender))
        {
            let _ = child.kill();
            return Err(format!("could not start the HID broker reader: {error}"));
        }
        if let Err(error) = wait_for_broker_ready(&responses) {
            let _ = child.kill();
            return Err(error);
        }
        Ok(Self {
            _job: job,
            child,
            input,
            responses,
            next_sequence: 0,
            last_diagnostic: None,
        })
    }

    fn exchange(
        &mut self,
        operation: u8,
        payload: &[u8],
        recoverable: bool,
    ) -> Result<Vec<u8>, HidWriteError> {
        let stalled_pid = self.child.id();
        let started = Instant::now();
        match self.exchange_once(operation, payload) {
            Ok(response) => Ok(response),
            Err(first) if first.should_restart(recoverable) => {
                let first_wait = started.elapsed();
                let first_kind = first.error.kind;
                let first_error = first.error.to_string();
                let recovery_reason = first.reason;
                self.restart().map_err(|restart| HidWriteError {
                    kind: first_kind,
                    message: format!("{first_error}; broker restart failed: {restart}"),
                })?;
                let replacement_pid = self.child.id();
                let retry_started = Instant::now();
                match self.exchange_once(operation, payload) {
                    Ok(response) => {
                        self.last_diagnostic = Some(format!(
                            "broker_recovery=true reason={recovery_reason} stalled_pid={stalled_pid} replacement_pid={replacement_pid} first_wait_us={} retry_us={}",
                            first_wait.as_micros(),
                            retry_started.elapsed().as_micros()
                        ));
                        Ok(response)
                    }
                    Err(retry) => Err(HidWriteError {
                        kind: combined_error_kind(first_kind, retry.error.kind),
                        message: format!(
                            "Meno HID broker recovery failed after terminating process {stalled_pid}: first={first_error}; retry={}",
                            retry.error
                        ),
                    }),
                }
            }
            Err(failure) => Err(failure.error),
        }
    }

    fn exchange_once(
        &mut self,
        operation: u8,
        payload: &[u8],
    ) -> Result<Vec<u8>, BrokerExchangeFailure> {
        self.next_sequence = self.next_sequence.wrapping_add(1).max(1);
        let sequence = self.next_sequence;
        write_broker_frame(&mut self.input, operation, sequence, payload).map_err(|error| {
            BrokerExchangeFailure::transport(
                HidWriteError::failed(format!("could not send an HID broker request: {error}")),
                "request-send",
            )
        })?;
        let response = match self.responses.recv_timeout(BROKER_RESPONSE_TIMEOUT) {
            Ok(Ok(response)) => response,
            Ok(Err(error)) => {
                return Err(BrokerExchangeFailure::transport(
                    HidWriteError::failed(format!("Meno HID broker response failed: {error}")),
                    "response-read",
                ));
            }
            Err(RecvTimeoutError::Timeout) => {
                return Err(BrokerExchangeFailure::transport(
                    HidWriteError::timed_out(format!(
                        "Meno HID broker process {} did not respond within {} ms",
                        self.child.id(),
                        BROKER_RESPONSE_TIMEOUT.as_millis()
                    )),
                    "timeout",
                ));
            }
            Err(RecvTimeoutError::Disconnected) => {
                return Err(BrokerExchangeFailure::transport(
                    HidWriteError::failed("Meno HID broker response channel closed"),
                    "response-disconnected",
                ));
            }
        };
        if response.sequence != sequence {
            return Err(BrokerExchangeFailure::transport(
                HidWriteError::failed(format!(
                    "Meno HID broker response sequence mismatch (expected {sequence}, got {})",
                    response.sequence
                )),
                "response-sequence",
            ));
        }
        match response.code {
            BROKER_STATUS_OK => {
                validate_broker_success_payload(operation, &response.payload).map_err(|error| {
                    BrokerExchangeFailure::transport(
                        HidWriteError::failed(error),
                        "response-payload",
                    )
                })?;
                Ok(response.payload)
            }
            BROKER_STATUS_ERROR => Err(BrokerExchangeFailure::operation(HidWriteError::failed(
                format!(
                    "Meno HID broker operation failed: {}",
                    String::from_utf8_lossy(&response.payload)
                ),
            ))),
            status => Err(BrokerExchangeFailure::transport(
                HidWriteError::failed(format!("Meno HID broker returned invalid status {status}")),
                "response-status",
            )),
        }
    }

    fn restart(&mut self) -> Result<(), String> {
        let _ = self.child.kill();
        let replacement = Self::spawn()?;
        *self = replacement;
        Ok(())
    }

    fn take_diagnostic(&mut self) -> Option<String> {
        self.last_diagnostic.take()
    }
}

impl BrokerJob {
    fn create() -> Result<Self, String> {
        let handle = unsafe { CreateJobObjectW(None, PCWSTR::null()) }
            .map_err(|error| format!("could not create the HID broker job: {error}"))?;
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if let Err(error) = unsafe {
            SetInformationJobObject(
                handle,
                JobObjectExtendedLimitInformation,
                (&raw const limits).cast(),
                std::mem::size_of_val(&limits) as u32,
            )
        } {
            let _ = unsafe { CloseHandle(handle) };
            return Err(format!(
                "could not configure the HID broker lifetime: {error}"
            ));
        }
        Ok(Self { handle })
    }

    fn assign(&self, child: &Child) -> Result<(), String> {
        let process = HANDLE(child.as_raw_handle());
        unsafe { AssignProcessToJobObject(self.handle, process) }
            .map_err(|error| format!("could not contain the HID broker process: {error}"))
    }
}

impl Drop for BrokerJob {
    fn drop(&mut self) {
        let _ = unsafe { CloseHandle(self.handle) };
    }
}

impl Drop for BrokerClient {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}

fn broker_response_reader(
    mut output: std::process::ChildStdout,
    sender: mpsc::Sender<Result<BrokerFrame, String>>,
) {
    loop {
        let response = read_broker_frame(&mut output).map_err(|error| error.to_string());
        let stop = response.is_err();
        if sender.send(response).is_err() || stop {
            break;
        }
    }
}

pub(crate) fn run_broker_command() -> bool {
    let mut arguments = env::args();
    let _ = arguments.next();
    if arguments.next().as_deref() != Some(BROKER_ARGUMENT) || arguments.next().is_some() {
        return false;
    }
    let _ = broker_main();
    true
}

fn broker_main() -> Result<(), String> {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut input = stdin.lock();
    let mut output = stdout.lock();
    write_broker_frame(&mut output, BROKER_STATUS_READY, BROKER_READY_SEQUENCE, &[])
        .map_err(|error| error.to_string())?;
    output.flush().map_err(|error| error.to_string())?;
    let mut device = None;

    loop {
        let request = match read_broker_frame(&mut input) {
            Ok(request) => request,
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(error) => return Err(error.to_string()),
        };
        let device = device.get_or_insert_with(DirectHid::open);
        let result = match device.as_mut() {
            Ok(device) => execute_broker_request(device, &request),
            Err(error) => Err(error.clone()),
        };
        match result {
            Ok(payload) => {
                write_broker_frame(&mut output, BROKER_STATUS_OK, request.sequence, &payload)
            }
            Err(error) => write_broker_frame(
                &mut output,
                BROKER_STATUS_ERROR,
                request.sequence,
                &bounded_error_payload(&error),
            ),
        }
        .map_err(|error| error.to_string())?;
        output.flush().map_err(|error| error.to_string())?;
    }
}

fn wait_for_broker_ready(responses: &Receiver<Result<BrokerFrame, String>>) -> Result<(), String> {
    let response = match responses.recv_timeout(BROKER_START_TIMEOUT) {
        Ok(Ok(response)) => response,
        Ok(Err(error)) => return Err(format!("Meno HID broker startup failed: {error}")),
        Err(RecvTimeoutError::Timeout) => {
            return Err(format!(
                "Meno HID broker did not start within {} ms",
                BROKER_START_TIMEOUT.as_millis()
            ));
        }
        Err(RecvTimeoutError::Disconnected) => {
            return Err("Meno HID broker startup channel closed".to_string());
        }
    };
    if response.code != BROKER_STATUS_READY
        || response.sequence != BROKER_READY_SEQUENCE
        || !response.payload.is_empty()
    {
        return Err("Meno HID broker returned an invalid startup handshake".to_string());
    }
    Ok(())
}

fn execute_broker_request(
    device: &mut DirectHid,
    request: &BrokerFrame,
) -> Result<Vec<u8>, String> {
    match request.code {
        BROKER_OP_QUERY if request.payload.is_empty() => Ok(device.query_info()?.to_vec()),
        BROKER_OP_WRITE if request.payload.len() == OUTPUT_REPORT_SIZE => {
            let output: &[u8; OUTPUT_REPORT_SIZE] = request
                .payload
                .as_slice()
                .try_into()
                .expect("validated broker write size");
            let started = Instant::now();
            device
                .write_output(output)
                .map_err(|error| error.to_string())?;
            let elapsed_us = started.elapsed().as_micros().min(u128::from(u64::MAX)) as u64;
            Ok(elapsed_us.to_le_bytes().to_vec())
        }
        BROKER_OP_QUERY => Err("invalid HID broker query payload".to_string()),
        BROKER_OP_WRITE => Err("invalid HID broker write payload".to_string()),
        operation => Err(format!("unsupported HID broker operation {operation}")),
    }
}

fn write_broker_frame(
    output: &mut impl Write,
    code: u8,
    sequence: u64,
    payload: &[u8],
) -> io::Result<()> {
    if payload.len() > BROKER_MAX_PAYLOAD || payload.len() > u16::MAX as usize {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "HID broker payload is too large",
        ));
    }
    let mut header = [0_u8; BROKER_HEADER_SIZE];
    header[0] = BROKER_PROTOCOL_VERSION;
    header[1] = code;
    header[2..4].copy_from_slice(&(payload.len() as u16).to_le_bytes());
    header[4..12].copy_from_slice(&sequence.to_le_bytes());
    output.write_all(&header)?;
    output.write_all(payload)
}

fn read_broker_frame(input: &mut impl Read) -> io::Result<BrokerFrame> {
    let mut header = [0_u8; BROKER_HEADER_SIZE];
    input.read_exact(&mut header)?;
    if header[0] != BROKER_PROTOCOL_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "HID broker protocol version mismatch",
        ));
    }
    let length = u16::from_le_bytes([header[2], header[3]]) as usize;
    if length > BROKER_MAX_PAYLOAD {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "HID broker payload exceeds the protocol limit",
        ));
    }
    let mut payload = vec![0_u8; length];
    input.read_exact(&mut payload)?;
    let sequence = u64::from_le_bytes(header[4..12].try_into().unwrap());
    if sequence == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "HID broker sequence must be nonzero",
        ));
    }
    Ok(BrokerFrame {
        code: header[1],
        sequence,
        payload,
    })
}

fn bounded_error_payload(error: &str) -> Vec<u8> {
    let bytes = error.as_bytes();
    let mut length = bytes.len().min(BROKER_MAX_PAYLOAD);
    while length > 0 && !error.is_char_boundary(length) {
        length -= 1;
    }
    bytes[..length].to_vec()
}

fn output_is_recoverable(output: &[u8; OUTPUT_REPORT_SIZE]) -> bool {
    match output[2] {
        COMMAND_RESET | COMMAND_KEYBOARD_STATE => true,
        COMMAND_SUBMIT if output[3] == 1 => output[OUTPUT_HEADER_SIZE + 4] == 0,
        _ => false,
    }
}

fn parse_broker_write_response(response: &[u8]) -> Result<u64, HidWriteError> {
    let encoded: [u8; 8] = response.try_into().map_err(|_| {
        HidWriteError::failed(format!(
            "Meno HID broker returned {} of 8 write timing bytes",
            response.len()
        ))
    })?;
    Ok(u64::from_le_bytes(encoded))
}

fn validate_broker_success_payload(operation: u8, payload: &[u8]) -> Result<(), String> {
    let expected = match operation {
        BROKER_OP_QUERY => INFO_SIZE,
        BROKER_OP_WRITE => std::mem::size_of::<u64>(),
        _ => return Err(format!("unsupported HID broker operation {operation}")),
    };
    if payload.len() != expected {
        return Err(format!(
            "Meno HID broker returned {} of {expected} response bytes for operation {operation}",
            payload.len()
        ));
    }
    Ok(())
}

fn combined_error_kind(first: HidWriteErrorKind, retry: HidWriteErrorKind) -> HidWriteErrorKind {
    if first == HidWriteErrorKind::TimedOut || retry == HidWriteErrorKind::TimedOut {
        HidWriteErrorKind::TimedOut
    } else {
        HidWriteErrorKind::Failed
    }
}

fn classify_completion_after_timeout(
    expected_bytes: usize,
    cancellation_error: Option<&str>,
    completion: Result<u32, String>,
) -> Result<u32, HidWriteError> {
    let cancel_detail = cancellation_error
        .map(|value| format!("; cancellation={value}"))
        .unwrap_or_default();
    let transferred = completion.map_err(|error| {
        HidWriteError::timed_out(format!(
            "Meno Virtual Mouse output timed out after {WRITE_TIMEOUT_MS} ms{cancel_detail}; completion={error}"
        ))
    })?;
    if transferred as usize != expected_bytes {
        return Err(HidWriteError::failed(format!(
            "Meno Virtual Mouse output completed late with {transferred} of {expected_bytes} bytes{cancel_detail}"
        )));
    }
    Ok(transferred)
}

impl HidWriteError {
    pub(crate) fn failed(message: impl Into<String>) -> Self {
        Self {
            kind: HidWriteErrorKind::Failed,
            message: message.into(),
        }
    }

    fn timed_out(message: impl Into<String>) -> Self {
        Self {
            kind: HidWriteErrorKind::TimedOut,
            message: message.into(),
        }
    }
}

impl Drop for VirtualHid {
    fn drop(&mut self) {
        if self.dirty && self.healthy {
            let _ = self.reset();
        }
    }
}

impl Drop for DirectHid {
    fn drop(&mut self) {
        let _ = unsafe { CloseHandle(self.handle) };
        let _ = unsafe { CloseHandle(self.event) };
    }
}

pub(crate) fn validate_driver_info(output: &[u8; INFO_SIZE]) -> Result<(), String> {
    let abi = u16::from_le_bytes([output[0], output[1]]);
    if abi != DRIVER_ABI {
        return Err(format!(
            "Meno Virtual Mouse ABI mismatch (driver {abi}, app {DRIVER_ABI})"
        ));
    }

    let version = (
        u16::from_le_bytes([output[2], output[3]]),
        u16::from_le_bytes([output[4], output[5]]),
        u16::from_le_bytes([output[6], output[7]]),
    );
    if version < DRIVER_VERSION {
        return Err(format!(
            "Meno Virtual Mouse is outdated (driver {}.{}.{}, required {}.{}.{})",
            version.0, version.1, version.2, DRIVER_VERSION.0, DRIVER_VERSION.1, DRIVER_VERSION.2
        ));
    }

    let capabilities = u32::from_le_bytes(output[8..12].try_into().unwrap());
    let maximum_batch = u16::from_le_bytes([output[12], output[13]]) as usize;
    let mouse_report_size = u16::from_le_bytes([output[16], output[17]]);
    let keyboard_report_size = u16::from_le_bytes([output[18], output[19]]);
    if capabilities & REQUIRED_CAPABILITIES != REQUIRED_CAPABILITIES
        || maximum_batch < MAXIMUM_BATCH
        || mouse_report_size != 7
        || keyboard_report_size != 9
    {
        return Err(format!(
            "Meno Virtual Mouse capability mismatch (capabilities 0x{capabilities:08X}, batch {maximum_batch}, reports {mouse_report_size}/{keyboard_report_size})"
        ));
    }
    Ok(())
}

fn encode_output_header(
    command: u8,
    count: u8,
    flags: u8,
    sequence: u16,
) -> [u8; OUTPUT_REPORT_SIZE] {
    let mut output = [0_u8; OUTPUT_REPORT_SIZE];
    output[0] = OUTPUT_REPORT_ID;
    output[1] = REPORT_VERSION;
    output[2] = command;
    output[3] = count;
    output[4] = flags;
    output[5..7].copy_from_slice(&sequence.to_le_bytes());
    output
}

fn performance_counter() -> i64 {
    let mut value = 0_i64;
    if unsafe { QueryPerformanceCounter(&mut value) }.is_ok() {
        value
    } else {
        0
    }
}

fn performance_frequency() -> i64 {
    let mut value = 0_i64;
    if unsafe { QueryPerformanceFrequency(&mut value) }.is_ok() {
        value
    } else {
        0
    }
}

#[allow(dead_code)]
fn parse_driver_stats(output: &[u8; INFO_SIZE]) -> DriverStats {
    DriverStats {
        accepted_reports: u64::from_le_bytes(output[20..28].try_into().unwrap()),
        maximum_queue_depth: u32::from_le_bytes(output[28..32].try_into().unwrap()),
        merge_count: u32::from_le_bytes(output[32..36].try_into().unwrap()),
        current_queue_depth: u32::from_le_bytes(output[36..40].try_into().unwrap()),
        output_writes: u64::from_le_bytes(output[40..48].try_into().unwrap()),
        last_output_sequence: u16::from_le_bytes(output[48..50].try_into().unwrap()),
        last_write_enter_qpc: u64::from_le_bytes(output[52..60].try_into().unwrap()),
        last_write_exit_qpc: u64::from_le_bytes(output[60..68].try_into().unwrap()),
        qpc_frequency: u64::from_le_bytes(output[68..76].try_into().unwrap()),
        last_write_duration_us: u32::from_le_bytes(output[76..80].try_into().unwrap()),
        maximum_write_duration_us: u32::from_le_bytes(output[80..84].try_into().unwrap()),
        last_write_status: i32::from_le_bytes(output[84..88].try_into().unwrap()),
    }
}

fn encode_reset_position(output: &mut [u8; OUTPUT_REPORT_SIZE], position: HidReport) {
    output[OUTPUT_HEADER_SIZE..OUTPUT_HEADER_SIZE + 2].copy_from_slice(&position.x.to_le_bytes());
    output[OUTPUT_HEADER_SIZE + 2..OUTPUT_HEADER_SIZE + 4]
        .copy_from_slice(&position.y.to_le_bytes());
}

fn hid_interface_paths(hid_guid: &GUID) -> Result<Vec<Vec<u16>>, String> {
    for _ in 0..3 {
        let mut length = 0_u32;
        let result = unsafe {
            CM_Get_Device_Interface_List_SizeW(
                &mut length,
                hid_guid,
                ptr::null(),
                CM_GET_DEVICE_INTERFACE_LIST_PRESENT,
            )
        };
        if result != CR_SUCCESS {
            return Err(format!(
                "could not enumerate HID interfaces (0x{result:08X})"
            ));
        }
        if length <= 1 {
            return Ok(Vec::new());
        }

        let mut buffer = vec![0_u16; length as usize];
        let result = unsafe {
            CM_Get_Device_Interface_ListW(
                hid_guid,
                ptr::null(),
                buffer.as_mut_ptr(),
                length,
                CM_GET_DEVICE_INTERFACE_LIST_PRESENT,
            )
        };
        if result == CR_BUFFER_SMALL {
            continue;
        }
        if result != CR_SUCCESS {
            return Err(format!(
                "could not read HID interface list (0x{result:08X})"
            ));
        }

        let mut paths = Vec::new();
        let mut start = 0;
        while start < buffer.len() && buffer[start] != 0 {
            let end = buffer[start..]
                .iter()
                .position(|value| *value == 0)
                .map(|offset| start + offset)
                .unwrap_or(buffer.len());
            paths.push(buffer[start..end].to_vec());
            start = end.saturating_add(1);
        }
        return Ok(paths);
    }
    Err("HID interface list kept changing during enumeration".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn broker_frame_has_a_bounded_versioned_layout() {
        let mut encoded = Vec::new();
        write_broker_frame(
            &mut encoded,
            BROKER_OP_WRITE,
            0x0102_0304_0506_0708,
            &[9, 8, 7],
        )
        .unwrap();
        assert_eq!(
            &encoded[..BROKER_HEADER_SIZE],
            &[1, 2, 3, 0, 8, 7, 6, 5, 4, 3, 2, 1]
        );
        assert_eq!(
            read_broker_frame(&mut Cursor::new(encoded)).unwrap(),
            BrokerFrame {
                code: BROKER_OP_WRITE,
                sequence: 0x0102_0304_0506_0708,
                payload: vec![9, 8, 7],
            }
        );
    }

    #[test]
    fn only_idempotent_hid_outputs_can_be_replayed_after_a_broker_timeout() {
        let reset = encode_output_header(COMMAND_RESET, 0, 0, 1);
        let keyboard = encode_output_header(COMMAND_KEYBOARD_STATE, 1, 0, 2);
        let movement = encode_output_header(COMMAND_SUBMIT, 1, 0, 3);
        let mut wheel = movement;
        wheel[OUTPUT_HEADER_SIZE + 4] = 1;
        let batch = encode_output_header(COMMAND_SUBMIT, 2, 0, 4);

        assert!(output_is_recoverable(&reset));
        assert!(output_is_recoverable(&keyboard));
        assert!(output_is_recoverable(&movement));
        assert!(!output_is_recoverable(&wheel));
        assert!(!output_is_recoverable(&batch));
    }

    #[test]
    fn broker_startup_requires_the_exact_ready_handshake() {
        let (sender, receiver) = mpsc::channel();
        sender
            .send(Ok(BrokerFrame {
                code: BROKER_STATUS_READY,
                sequence: BROKER_READY_SEQUENCE,
                payload: Vec::new(),
            }))
            .unwrap();
        assert!(wait_for_broker_ready(&receiver).is_ok());

        let (sender, receiver) = mpsc::channel();
        sender
            .send(Ok(BrokerFrame {
                code: BROKER_STATUS_OK,
                sequence: BROKER_READY_SEQUENCE,
                payload: Vec::new(),
            }))
            .unwrap();
        assert!(wait_for_broker_ready(&receiver).is_err());
    }

    #[test]
    fn broker_rejects_oversized_frames_before_allocating_payload() {
        let mut header = [0_u8; BROKER_HEADER_SIZE];
        header[0] = BROKER_PROTOCOL_VERSION;
        header[2..4].copy_from_slice(&u16::MAX.to_le_bytes());
        let error = read_broker_frame(&mut Cursor::new(header)).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn broker_rejects_a_zero_sequence() {
        let mut header = [0_u8; BROKER_HEADER_SIZE];
        header[0] = BROKER_PROTOCOL_VERSION;
        let error = read_broker_frame(&mut Cursor::new(header)).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn broker_restarts_only_for_safe_requests_after_transport_failures() {
        let transport = BrokerExchangeFailure::transport(
            HidWriteError::failed("pipe closed"),
            "response-disconnected",
        );
        let operation = BrokerExchangeFailure::operation(HidWriteError::failed("driver rejected"));

        assert!(transport.should_restart(true));
        assert!(!transport.should_restart(false));
        assert!(!operation.should_restart(true));
    }

    #[test]
    fn broker_success_payload_lengths_are_operation_specific() {
        assert!(validate_broker_success_payload(BROKER_OP_QUERY, &[0; INFO_SIZE]).is_ok());
        assert!(
            validate_broker_success_payload(BROKER_OP_WRITE, &[0; std::mem::size_of::<u64>()])
                .is_ok()
        );
        assert!(validate_broker_success_payload(BROKER_OP_QUERY, &[0; INFO_SIZE - 1]).is_err());
        assert!(validate_broker_success_payload(BROKER_OP_WRITE, &[]).is_err());
        assert!(validate_broker_success_payload(99, &[]).is_err());
    }

    #[test]
    fn a_timeout_in_either_attempt_is_preserved_in_final_metrics() {
        assert_eq!(
            combined_error_kind(HidWriteErrorKind::TimedOut, HidWriteErrorKind::Failed),
            HidWriteErrorKind::TimedOut
        );
        assert_eq!(
            combined_error_kind(HidWriteErrorKind::Failed, HidWriteErrorKind::TimedOut),
            HidWriteErrorKind::TimedOut
        );
        assert_eq!(
            combined_error_kind(HidWriteErrorKind::Failed, HidWriteErrorKind::Failed),
            HidWriteErrorKind::Failed
        );
    }

    #[test]
    fn broker_write_timing_has_an_exact_little_endian_layout() {
        assert_eq!(
            parse_broker_write_response(&0x0102_0304_0506_0708_u64.to_le_bytes()).unwrap(),
            0x0102_0304_0506_0708
        );
        assert!(parse_broker_write_response(&[0; 7]).is_err());
        assert!(parse_broker_write_response(&[0; 9]).is_err());
    }

    #[test]
    fn broker_error_payload_truncation_preserves_utf8() {
        let error = "错".repeat(BROKER_MAX_PAYLOAD);
        let payload = bounded_error_payload(&error);
        assert!(payload.len() <= BROKER_MAX_PAYLOAD);
        assert!(std::str::from_utf8(&payload).is_ok());
    }

    #[test]
    fn output_header_has_fixed_little_endian_layout() {
        let output = encode_output_header(COMMAND_SUBMIT, 3, 0, 0x1234);
        assert_eq!(&output[..7], &[0x11, 2, 1, 3, 0, 0x34, 0x12]);
        assert!(output[7..].iter().all(|byte| *byte == 0));
    }

    #[test]
    fn reset_position_only_encodes_coordinates() {
        let mut output = encode_output_header(COMMAND_RESET, 1, 0, 0x1234);
        encode_reset_position(
            &mut output,
            HidReport {
                x: 0x1234,
                y: 0x5678,
                wheel: 99,
                buttons: 7,
            },
        );
        assert_eq!(&output[7..15], &[0x34, 0x12, 0x78, 0x56, 0, 0, 0, 0]);
        assert!(output[15..].iter().all(|byte| *byte == 0));
    }

    #[test]
    fn full_late_completion_is_success_even_when_cancel_found_nothing() {
        assert_eq!(
            classify_completion_after_timeout(
                OUTPUT_REPORT_SIZE,
                Some("The element was not found"),
                Ok(OUTPUT_REPORT_SIZE as u32),
            ),
            Ok(OUTPUT_REPORT_SIZE as u32)
        );
    }

    #[test]
    fn cancelled_late_completion_remains_a_timeout() {
        let error = classify_completion_after_timeout(
            OUTPUT_REPORT_SIZE,
            None,
            Err("The I/O operation has been aborted".to_string()),
        )
        .unwrap_err();
        assert_eq!(error.kind, HidWriteErrorKind::TimedOut);
    }

    #[test]
    fn short_late_completion_is_a_failure() {
        let error = classify_completion_after_timeout(
            OUTPUT_REPORT_SIZE,
            None,
            Ok((OUTPUT_REPORT_SIZE - 1) as u32),
        )
        .unwrap_err();
        assert_eq!(error.kind, HidWriteErrorKind::Failed);
    }

    #[test]
    fn driver_diagnostics_have_a_fixed_little_endian_layout() {
        let mut output = [0_u8; INFO_SIZE];
        output[20..28].copy_from_slice(&11_u64.to_le_bytes());
        output[40..48].copy_from_slice(&22_u64.to_le_bytes());
        output[48..50].copy_from_slice(&33_u16.to_le_bytes());
        output[52..60].copy_from_slice(&44_u64.to_le_bytes());
        output[60..68].copy_from_slice(&55_u64.to_le_bytes());
        output[68..76].copy_from_slice(&66_u64.to_le_bytes());
        output[76..80].copy_from_slice(&77_u32.to_le_bytes());
        output[80..84].copy_from_slice(&88_u32.to_le_bytes());
        output[84..88].copy_from_slice(&(-99_i32).to_le_bytes());

        let stats = parse_driver_stats(&output);
        assert_eq!(stats.accepted_reports, 11);
        assert_eq!(stats.output_writes, 22);
        assert_eq!(stats.last_output_sequence, 33);
        assert_eq!(stats.last_write_enter_qpc, 44);
        assert_eq!(stats.last_write_exit_qpc, 55);
        assert_eq!(stats.qpc_frequency, 66);
        assert_eq!(stats.last_write_duration_us, 77);
        assert_eq!(stats.maximum_write_duration_us, 88);
        assert_eq!(stats.last_write_status, -99);
    }
}
