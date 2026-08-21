use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread;

use arboard::ImageData;
use windows::Win32::Foundation::HWND;

use crate::bounded_queue::{BoundedQueue, PushResult};
use crate::protocol::{Frame, MAX_IMAGE_SIZE, MessageKind};
use crate::ui_events::{EVENT_BATCH, wake_queue};
use crate::{clipboard_flow, image_codec, logging, with_state};

pub(crate) const WM_IMAGE_WORKER_EVENT: u32 = windows::Win32::UI::WindowsAndMessaging::WM_APP + 4;
const IMAGE_RESULT_MAX_ITEMS: usize = 4;
const IMAGE_RESULT_MAX_BYTES: usize = image_codec::MAX_RGBA_BYTES + MAX_IMAGE_SIZE;

static IMAGE_WORKER_EVENTS: OnceLock<Mutex<BoundedQueue<ImageWorkerEvent>>> = OnceLock::new();

pub(crate) enum ImageTask {
    Encode {
        generation: u64,
        image: ImageData<'static>,
    },
    Decode {
        generation: u64,
        payload: Vec<u8>,
    },
}

pub(crate) enum ImageWorkerEvent {
    Encoded {
        generation: u64,
        result: Result<Vec<u8>, String>,
    },
    Decoded {
        generation: u64,
        encoded_bytes: usize,
        result: Result<ImageData<'static>, String>,
    },
}

#[derive(Clone)]
pub(crate) struct ImageTaskSender {
    shared: Arc<ImageTaskSlot>,
}

struct ImageTaskSlot {
    pending: Mutex<Option<ImageTask>>,
    ready: Condvar,
}

impl ImageTaskSender {
    pub(crate) fn submit(&self, task: ImageTask) -> bool {
        let mut pending = self
            .shared
            .pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let replaced = pending.replace(task).is_some();
        self.shared.ready.notify_one();
        replaced
    }
}

pub(crate) fn spawn_image_worker(hwnd: HWND) -> ImageTaskSender {
    let shared = Arc::new(ImageTaskSlot {
        pending: Mutex::new(None),
        ready: Condvar::new(),
    });
    let worker = Arc::clone(&shared);
    let hwnd_value = hwnd.0 as usize;
    thread::spawn(move || {
        loop {
            let task = {
                let mut pending = worker
                    .pending
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                while pending.is_none() {
                    pending = worker
                        .ready
                        .wait(pending)
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                }
                pending.take().unwrap()
            };
            let event = match task {
                ImageTask::Encode { generation, image } => ImageWorkerEvent::Encoded {
                    generation,
                    result: image_codec::encode_png(image),
                },
                ImageTask::Decode {
                    generation,
                    payload,
                } => {
                    let encoded_bytes = payload.len();
                    ImageWorkerEvent::Decoded {
                        generation,
                        encoded_bytes,
                        result: image_codec::decode_png(&payload),
                    }
                }
            };
            if !post_image_worker_event(HWND(hwnd_value as *mut _), event) {
                return;
            }
        }
    });
    ImageTaskSender { shared }
}

pub(crate) fn submit_image_task(task: ImageTask) {
    match with_state(|state| state.image_tasks.submit(task)) {
        Some(_) => {}
        None => logging::error("Clipboard image skipped: application state is unavailable"),
    }
}

pub(crate) fn next_image_generation() -> Option<u64> {
    with_state(|state| {
        state.image_generation = state.image_generation.wrapping_add(1);
        state.image_generation
    })
}

fn image_generation_is_current(generation: u64) -> bool {
    with_state(|state| state.image_generation == generation).unwrap_or(false)
}

fn handle_image_worker_event(event: ImageWorkerEvent) {
    match event {
        ImageWorkerEvent::Encoded { generation, result } => {
            if !image_generation_is_current(generation) {
                return;
            }
            match result {
                Ok(payload) => {
                    clipboard_flow::send_clipboard(Frame::new(MessageKind::Png, payload))
                }
                Err(error) => logging::error(&format!("Clipboard image encode failed: {error}")),
            }
        }
        ImageWorkerEvent::Decoded {
            generation,
            encoded_bytes,
            result,
        } => {
            if !image_generation_is_current(generation)
                || with_state(|state| state.paused || state.suspended).unwrap_or(true)
            {
                return;
            }
            match result {
                Ok(image) => {
                    clipboard_flow::apply_remote_clipboard(
                        MessageKind::Png,
                        encoded_bytes,
                        |clipboard| clipboard.set_image(image.to_owned_img()),
                    );
                }
                Err(error) => {
                    logging::error(&format!("Remote clipboard PNG decode failed: {error}"))
                }
            }
        }
    }
}

fn post_image_worker_event(hwnd: HWND, event: ImageWorkerEvent) -> bool {
    let bytes = match &event {
        ImageWorkerEvent::Encoded { result, .. } => {
            result.as_ref().map_or(1, |payload| payload.len())
        }
        ImageWorkerEvent::Decoded { result, .. } => {
            result.as_ref().map_or(1, |image| image.bytes.len())
        }
    };
    let queue = IMAGE_WORKER_EVENTS.get_or_init(|| {
        Mutex::new(BoundedQueue::new(
            IMAGE_RESULT_MAX_ITEMS,
            IMAGE_RESULT_MAX_BYTES,
        ))
    });
    let Ok(mut queue) = queue.lock() else {
        return false;
    };
    let result = queue.push_latest(event, bytes, |_| true);
    let wake = match result {
        PushResult::Queued { wake } | PushResult::Replaced { wake } => wake,
        PushResult::Full => {
            logging::error("image result queue rejected an oversized result");
            return false;
        }
    };
    drop(queue);
    !wake || wake_queue(hwnd, WM_IMAGE_WORKER_EVENT, &IMAGE_WORKER_EVENTS)
}

pub(crate) fn drain_events(hwnd: HWND) {
    let Some(queue) = IMAGE_WORKER_EVENTS.get() else {
        return;
    };
    let (events, more) = match queue.lock() {
        Ok(mut queue) => queue.take_batch(EVENT_BATCH),
        Err(_) => return,
    };
    for event in events {
        handle_image_worker_event(event);
    }
    if more {
        let _ = wake_queue(hwnd, WM_IMAGE_WORKER_EVENT, &IMAGE_WORKER_EVENTS);
    }
}

pub(crate) fn clear_events() {
    if let Some(queue) = IMAGE_WORKER_EVENTS.get()
        && let Ok(mut queue) = queue.lock()
    {
        queue.clear();
    }
}
