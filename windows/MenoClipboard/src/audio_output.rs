use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, TryLockError};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{BufferSize, Device, FromSample, Sample, SampleFormat, Stream, StreamConfig};

const CABLE_EXACT_NAME: &str = "CABLE Input (VB-Audio Virtual Cable)";
const SAMPLE_RATE: u32 = 48_000;
const SAMPLE_CAPACITY: usize = 9_600;
const PREBUFFER_SAMPLES: usize = 1_920;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct BufferStats {
    pub underflows: u64,
    pub overflows: u64,
    pub dropped_samples: u64,
    pub lock_misses: u64,
}

#[derive(Default)]
struct SampleQueue {
    samples: VecDeque<i16>,
    buffering: bool,
}

struct SharedSamples {
    queue: Mutex<SampleQueue>,
    resync: AtomicBool,
    underflows: AtomicU64,
    overflows: AtomicU64,
    dropped_samples: AtomicU64,
    lock_misses: AtomicU64,
}

impl SharedSamples {
    fn new() -> Self {
        Self {
            queue: Mutex::new(SampleQueue {
                samples: VecDeque::with_capacity(SAMPLE_CAPACITY),
                buffering: true,
            }),
            resync: AtomicBool::new(false),
            underflows: AtomicU64::new(0),
            overflows: AtomicU64::new(0),
            dropped_samples: AtomicU64::new(0),
            lock_misses: AtomicU64::new(0),
        }
    }

    fn push(&self, samples: &[i16]) {
        let mut queue = lock(&self.queue);
        if self.resync.swap(false, Ordering::AcqRel) {
            queue.samples.clear();
            queue.buffering = true;
        }
        let samples = if samples.len() > SAMPLE_CAPACITY {
            &samples[samples.len() - SAMPLE_CAPACITY..]
        } else {
            samples
        };
        let overflow = queue
            .samples
            .len()
            .saturating_add(samples.len())
            .saturating_sub(SAMPLE_CAPACITY);
        if overflow != 0 {
            queue.samples.drain(..overflow);
            self.overflows.fetch_add(1, Ordering::Relaxed);
            self.dropped_samples
                .fetch_add(overflow as u64, Ordering::Relaxed);
        }
        queue.samples.extend(samples.iter().copied());
    }

    fn clear(&self) {
        let mut queue = lock(&self.queue);
        queue.samples.clear();
        queue.buffering = true;
        self.resync.store(false, Ordering::Release);
    }

    fn fill<T>(&self, output: &mut [T], channels: usize)
    where
        T: Sample + FromSample<i16>,
    {
        let silence = T::EQUILIBRIUM;
        let mut queue = match self.queue.try_lock() {
            Ok(queue) => queue,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => {
                output.fill(silence);
                self.lock_misses.fetch_add(1, Ordering::Relaxed);
                self.resync.store(true, Ordering::Release);
                return;
            }
        };
        if self.resync.swap(false, Ordering::AcqRel) {
            queue.samples.clear();
            queue.buffering = true;
        }
        if channels == 0 {
            output.fill(silence);
            return;
        }

        let mut offset = 0;
        while offset < output.len() {
            if queue.buffering {
                if queue.samples.len() < PREBUFFER_SAMPLES {
                    output[offset..].fill(silence);
                    return;
                }
                queue.buffering = false;
            }
            let Some(sample) = queue.samples.pop_front() else {
                output[offset..].fill(silence);
                queue.buffering = true;
                self.underflows.fetch_add(1, Ordering::Relaxed);
                return;
            };
            let converted = T::from_sample(sample);
            let end = (offset + channels).min(output.len());
            output[offset..end].fill(converted);
            offset = end;
        }
    }

    fn take_stats(&self) -> BufferStats {
        BufferStats {
            underflows: self.underflows.swap(0, Ordering::Relaxed),
            overflows: self.overflows.swap(0, Ordering::Relaxed),
            dropped_samples: self.dropped_samples.swap(0, Ordering::Relaxed),
            lock_misses: self.lock_misses.swap(0, Ordering::Relaxed),
        }
    }
}

#[derive(Debug)]
pub enum OpenError {
    DeviceUnavailable(String),
    Other(String),
}

pub struct AudioOutput {
    _stream: Stream,
    samples: Arc<SharedSamples>,
    device_failed: Arc<AtomicBool>,
    device_error: Arc<Mutex<Option<String>>>,
    pub device_name: String,
    pub device_id: String,
    pub channels: u16,
    pub sample_format: SampleFormat,
}

pub fn cable_is_available() -> bool {
    let host = cpal::default_host();
    host.output_devices().is_ok_and(|mut devices| {
        devices.any(|device| {
            device
                .description()
                .is_ok_and(|description| cable_name_matches(description.name()))
        })
    })
}

impl AudioOutput {
    pub fn open(preferred_device_id: Option<&str>) -> Result<Self, OpenError> {
        let host = cpal::default_host();
        let device = select_cable_device(&host, preferred_device_id)?;
        let description = device
            .description()
            .map_err(|error| OpenError::Other(format!("could not describe VB-CABLE: {error}")))?;
        let device_name = description.name().to_string();
        let device_id = device
            .id()
            .map_err(|error| OpenError::Other(format!("could not identify VB-CABLE: {error}")))?
            .to_string();
        let supported = select_config(&device)?;
        let channels = supported.channels();
        let sample_format = supported.sample_format();
        let config = StreamConfig {
            channels,
            sample_rate: SAMPLE_RATE,
            buffer_size: BufferSize::Default,
        };
        let samples = Arc::new(SharedSamples::new());
        let device_failed = Arc::new(AtomicBool::new(false));
        let device_error = Arc::new(Mutex::new(None));
        let stream = build_stream(
            &device,
            config,
            sample_format,
            samples.clone(),
            device_failed.clone(),
            device_error.clone(),
        )?;
        stream
            .play()
            .map_err(|error| OpenError::Other(format!("could not start VB-CABLE: {error}")))?;
        Ok(Self {
            _stream: stream,
            samples,
            device_failed,
            device_error,
            device_name,
            device_id,
            channels,
            sample_format,
        })
    }

    pub fn push(&self, samples: &[i16]) {
        self.samples.push(samples);
    }

    pub fn clear(&self) {
        self.samples.clear();
    }

    pub fn take_stats(&self) -> BufferStats {
        self.samples.take_stats()
    }

    pub fn take_device_error(&self) -> Option<String> {
        if !self.device_failed.swap(false, Ordering::AcqRel) {
            return None;
        }
        lock(&self.device_error)
            .take()
            .or_else(|| Some("VB-CABLE became unavailable".to_string()))
    }
}

fn select_cable_device(
    host: &cpal::Host,
    preferred_device_id: Option<&str>,
) -> Result<Device, OpenError> {
    let devices = host.output_devices().map_err(|error| {
        OpenError::Other(format!("could not enumerate output devices: {error}"))
    })?;
    let mut exact = Vec::new();
    let mut fallback = Vec::new();
    for device in devices {
        let Ok(description) = device.description() else {
            continue;
        };
        let name = description.name();
        let id_matches = preferred_device_id.is_some_and(|preferred| {
            device
                .id()
                .is_ok_and(|device_id| device_id.to_string() == preferred)
        });
        if name == CABLE_EXACT_NAME {
            if id_matches {
                return Ok(device);
            }
            exact.push(device);
            continue;
        }
        if cable_name_matches(name) {
            if id_matches {
                return Ok(device);
            }
            fallback.push(device);
        }
    }
    let mut candidates = if exact.is_empty() { fallback } else { exact };
    match candidates.len() {
        1 => Ok(candidates.remove(0)),
        0 => Err(OpenError::DeviceUnavailable(
            "CABLE Input (VB-Audio Virtual Cable) was not found".to_string(),
        )),
        count => Err(OpenError::Other(format!(
            "found {count} matching VB-CABLE output devices"
        ))),
    }
}

fn cable_name_matches(name: &str) -> bool {
    if name == CABLE_EXACT_NAME {
        return true;
    }
    let folded = name.to_lowercase();
    folded.contains("cable input") && folded.contains("vb-audio virtual cable")
}

fn select_config(device: &Device) -> Result<cpal::SupportedStreamConfig, OpenError> {
    let configs = device
        .supported_output_configs()
        .map_err(|error| OpenError::Other(format!("could not query VB-CABLE formats: {error}")))?;
    configs
        .filter(|config| {
            config.channels() >= 1
                && config.min_sample_rate() <= SAMPLE_RATE
                && config.max_sample_rate() >= SAMPLE_RATE
                && !config.sample_format().is_dsd()
        })
        .max_by_key(|config| {
            let stereo = u8::from(config.channels() == 2);
            let format = match config.sample_format() {
                SampleFormat::F32 => 2,
                SampleFormat::I16 => 1,
                _ => 0,
            };
            (stereo, format, std::cmp::Reverse(config.channels()))
        })
        .map(|config| config.with_sample_rate(SAMPLE_RATE))
        .ok_or_else(|| OpenError::Other("VB-CABLE does not expose a 48 kHz output format".into()))
}

fn build_stream(
    device: &Device,
    config: StreamConfig,
    sample_format: SampleFormat,
    samples: Arc<SharedSamples>,
    device_failed: Arc<AtomicBool>,
    device_error: Arc<Mutex<Option<String>>>,
) -> Result<Stream, OpenError> {
    macro_rules! build {
        ($sample:ty) => {{
            let channels = usize::from(config.channels);
            let samples = samples.clone();
            let failed = device_failed.clone();
            let stored_error = device_error.clone();
            device.build_output_stream::<$sample, _, _>(
                config.clone(),
                move |output, _| samples.fill(output, channels),
                move |error| {
                    *lock(&stored_error) = Some(error.to_string());
                    failed.store(true, Ordering::Release);
                },
                None,
            )
        }};
    }

    let result = match sample_format {
        SampleFormat::I8 => build!(i8),
        SampleFormat::I16 => build!(i16),
        SampleFormat::I24 => build!(cpal::I24),
        SampleFormat::I32 => build!(i32),
        SampleFormat::I64 => build!(i64),
        SampleFormat::U8 => build!(u8),
        SampleFormat::U16 => build!(u16),
        SampleFormat::U24 => build!(cpal::U24),
        SampleFormat::U32 => build!(u32),
        SampleFormat::U64 => build!(u64),
        SampleFormat::F32 => build!(f32),
        SampleFormat::F64 => build!(f64),
        SampleFormat::DsdU8 | SampleFormat::DsdU16 | SampleFormat::DsdU32 => {
            return Err(OpenError::Other(
                "VB-CABLE only exposes an unsupported DSD format".into(),
            ));
        }
        _ => {
            return Err(OpenError::Other(
                "VB-CABLE exposes an unknown sample format".into(),
            ));
        }
    };
    result.map_err(|error| OpenError::Other(format!("could not open VB-CABLE: {error}")))
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn samples(count: usize, value: i16) -> Vec<i16> {
        vec![value; count]
    }

    #[test]
    fn output_waits_for_prebuffer_and_duplicates_channels() {
        let shared = SharedSamples::new();
        shared.push(&samples(PREBUFFER_SAMPLES - 1, 100));
        let mut output = [1_i16; 8];
        shared.fill(&mut output, 2);
        assert_eq!(output, [0; 8]);

        shared.push(&[200]);
        shared.fill(&mut output, 2);
        assert_eq!(output, [100; 8]);
    }

    #[test]
    fn sample_conversion_uses_cpal_scaling() {
        let shared = SharedSamples::new();
        let mut input = samples(PREBUFFER_SAMPLES, 0);
        input[0] = i16::MIN;
        input[1] = i16::MAX;
        shared.push(&input);
        let mut output = [0.0_f32; 2];
        shared.fill(&mut output, 1);
        assert_eq!(output[0], -1.0);
        assert_eq!(output[1], f32::from(i16::MAX) / 32_768.0);
    }

    #[test]
    fn arbitrary_callback_lengths_preserve_partial_network_frames() {
        let shared = SharedSamples::new();
        let input: Vec<i16> = (0..PREBUFFER_SAMPLES as i16).collect();
        shared.push(&input);
        let mut first = vec![0_i16; 701 * 2];
        shared.fill(&mut first, 2);
        assert_eq!(first[0..4], [0, 0, 1, 1]);
        let mut second = vec![0_i16; 259 * 2];
        shared.fill(&mut second, 2);
        assert_eq!(second[0..4], [701, 701, 702, 702]);
    }

    #[test]
    fn underflow_fills_silence_and_requires_a_new_prebuffer() {
        let shared = SharedSamples::new();
        shared.push(&samples(PREBUFFER_SAMPLES, 7));
        let mut output = vec![1_i16; (PREBUFFER_SAMPLES + 2) * 2];
        shared.fill(&mut output, 2);
        assert_eq!(output[PREBUFFER_SAMPLES * 2..], [0, 0, 0, 0]);
        assert_eq!(shared.take_stats().underflows, 1);

        shared.push(&samples(PREBUFFER_SAMPLES - 1, 9));
        let mut waiting = [1_i16; 4];
        shared.fill(&mut waiting, 2);
        assert_eq!(waiting, [0; 4]);
    }

    #[test]
    fn overflow_drops_oldest_samples_without_growing() {
        let shared = SharedSamples::new();
        let initial: Vec<i16> = (0..SAMPLE_CAPACITY).map(|value| value as i16).collect();
        shared.push(&initial);
        shared.push(&samples(10, -1));
        let queue = lock(&shared.queue);
        assert_eq!(queue.samples.len(), SAMPLE_CAPACITY);
        assert_eq!(queue.samples.front(), Some(&(10_i16)));
        drop(queue);
        let stats = shared.take_stats();
        assert_eq!(stats.overflows, 1);
        assert_eq!(stats.dropped_samples, 10);
    }

    #[test]
    fn clear_discards_every_sample_and_reenters_prebuffering() {
        let shared = SharedSamples::new();
        shared.push(&samples(PREBUFFER_SAMPLES, 5));
        shared.clear();
        let queue = lock(&shared.queue);
        assert!(queue.samples.is_empty());
        assert!(queue.buffering);
    }

    #[test]
    fn callback_lock_miss_discards_stale_samples_before_resuming() {
        let shared = SharedSamples::new();
        shared.push(&samples(PREBUFFER_SAMPLES, 5));
        let queue = lock(&shared.queue);
        let mut output = [1_i16; 4];
        shared.fill(&mut output, 2);
        assert_eq!(output, [0; 4]);
        assert_eq!(shared.take_stats().lock_misses, 1);
        drop(queue);

        shared.push(&samples(PREBUFFER_SAMPLES, 7));
        let queue = lock(&shared.queue);
        assert_eq!(queue.samples.len(), PREBUFFER_SAMPLES);
        assert!(queue.samples.iter().all(|sample| *sample == 7));
        assert!(queue.buffering);
    }

    #[test]
    fn cable_name_matching_rejects_unrelated_audio_devices() {
        assert!(cable_name_matches(CABLE_EXACT_NAME));
        assert!(cable_name_matches("cable input (vb-audio virtual cable)"));
        assert!(!cable_name_matches("Microphone (USB Audio Device)"));
        assert!(!cable_name_matches("CABLE Output (VB-Audio Virtual Cable)"));
    }
}
