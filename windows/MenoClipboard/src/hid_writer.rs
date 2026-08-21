use std::collections::VecDeque;
use std::sync::mpsc::{SyncSender, sync_channel};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
use windows::Win32::System::Threading::{
    CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, CreateWaitableTimerExW, GetCurrentThread,
    SetThreadPriority, SetWaitableTimer, THREAD_PRIORITY_ABOVE_NORMAL, TIMER_ALL_ACCESS,
    WaitForSingleObject,
};
use windows::core::PCWSTR;

use crate::virtual_hid::{HidReport, HidWriteError, VirtualHid};

const QUEUE_CAPACITY: usize = 64;
const REOPEN_DELAY: Duration = Duration::from_secs(1);
const MOVE_RATE_HZ: u64 = 240;
const MOVE_INTERVAL: Duration = Duration::from_nanos(1_000_000_000 / MOVE_RATE_HZ);
const PACER_WAIT_GRACE: Duration = Duration::from_millis(50);

#[derive(Clone, Debug)]
pub struct HidWriterStatus {
    pub available: bool,
    pub faults: u64,
    pub last_error: Option<String>,
    pub queue_high_water: usize,
}

pub struct HidWriter {
    shared: Arc<Shared>,
}

struct Shared {
    state: Mutex<State>,
    changed: Condvar,
}

struct State {
    queue: VecDeque<QueuedCommand>,
    stopped: bool,
    initialized: bool,
    available: bool,
    faults: u64,
    last_error: Option<String>,
    queue_high_water: usize,
}

struct QueuedCommand {
    kind: CommandKind,
    reply: Option<SyncSender<Result<(), String>>>,
}

enum CommandKind {
    Move(HidReport),
    Reports(Vec<HidReport>),
    Keyboard { modifiers: u8, keys: Vec<u8> },
    Reset(Option<HidReport>),
    Neutralize(Option<HidReport>),
}

trait HidBackend {
    fn reset(&mut self, position: Option<HidReport>) -> Result<(), HidWriteError>;
    fn submit(&mut self, reports: &[HidReport]) -> Result<(), HidWriteError>;
    fn keyboard(&mut self, modifiers: u8, keys: &[u8]) -> Result<(), HidWriteError>;
}

struct VirtualBackend(VirtualHid);

impl HidBackend for VirtualBackend {
    fn reset(&mut self, position: Option<HidReport>) -> Result<(), HidWriteError> {
        self.0.reset_at(position)
    }

    fn submit(&mut self, reports: &[HidReport]) -> Result<(), HidWriteError> {
        self.0.submit(reports)
    }

    fn keyboard(&mut self, modifiers: u8, keys: &[u8]) -> Result<(), HidWriteError> {
        self.0.set_keyboard_state(modifiers, keys)
    }
}

type BackendFactory = Arc<dyn Fn() -> Result<Box<dyn HidBackend>, String> + Send + Sync + 'static>;

impl HidWriter {
    pub fn start() -> Self {
        let factory: BackendFactory = Arc::new(|| {
            VirtualHid::open().map(|device| Box::new(VirtualBackend(device)) as Box<dyn HidBackend>)
        });
        Self::start_internal(factory)
    }

    fn start_internal(factory: BackendFactory) -> Self {
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                queue: VecDeque::with_capacity(QUEUE_CAPACITY),
                stopped: false,
                initialized: false,
                available: false,
                faults: 0,
                last_error: None,
                queue_high_water: 0,
            }),
            changed: Condvar::new(),
        });
        let worker_shared = Arc::clone(&shared);
        let writer_started = thread::Builder::new()
            .name("meno-hid-writer".to_string())
            .spawn(move || writer_loop(worker_shared, factory))
            .is_ok();
        if !writer_started {
            let mut state = lock_state(&shared);
            state.initialized = true;
            state.available = false;
            state.last_error = Some("could not start the Meno HID writer thread".to_string());
        }

        let deadline = Instant::now() + Duration::from_secs(2);
        let mut state = lock_state(&shared);
        while !state.initialized {
            let now = Instant::now();
            if now >= deadline {
                state.last_error = Some("Meno HID writer startup timed out".to_string());
                break;
            }
            let (next, _) = shared
                .changed
                .wait_timeout(state, deadline.duration_since(now))
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            state = next;
        }
        drop(state);

        Self { shared }
    }

    pub fn status(&self) -> HidWriterStatus {
        let state = lock_state(&self.shared);
        HidWriterStatus {
            available: state.available,
            faults: state.faults,
            last_error: state.last_error.clone(),
            queue_high_water: state.queue_high_water,
        }
    }

    pub fn submit_move(&self, report: HidReport) -> Result<(), String> {
        let mut state = lock_state(&self.shared);
        ensure_available(&state)?;
        if let Some(tail) = state.queue.back_mut()
            && matches!(tail.kind, CommandKind::Move(_))
        {
            tail.kind = CommandKind::Move(report);
            return Ok(());
        }
        if state.queue.len() == QUEUE_CAPACITY {
            return Err("Meno HID command queue is full".to_string());
        }
        state.queue.push_back(QueuedCommand {
            kind: CommandKind::Move(report),
            reply: None,
        });
        state.queue_high_water = state.queue_high_water.max(state.queue.len());
        self.shared.changed.notify_one();
        Ok(())
    }

    pub fn submit_reports(&self, reports: Vec<HidReport>) -> Result<(), String> {
        self.enqueue(CommandKind::Reports(reports), false, false)
    }

    pub fn submit_keyboard(&self, modifiers: u8, keys: Vec<u8>) -> Result<(), String> {
        self.enqueue(CommandKind::Keyboard { modifiers, keys }, false, false)
    }

    pub fn submit_initial(&self, report: HidReport) -> Result<(), String> {
        self.enqueue(CommandKind::Reports(vec![report]), true, false)
    }

    pub fn reset_barrier(&self, position: Option<HidReport>) -> Result<(), String> {
        self.enqueue(
            CommandKind::Reset(position.map(|report| HidReport {
                x: report.x,
                y: report.y,
                wheel: 0,
                buttons: 0,
            })),
            true,
            true,
        )
    }

    pub fn neutralize_barrier(&self, position: Option<HidReport>) -> Result<(), String> {
        self.enqueue(CommandKind::Neutralize(position), true, true)
    }

    fn enqueue(
        &self,
        kind: CommandKind,
        wait_for_completion: bool,
        replace_pending: bool,
    ) -> Result<(), String> {
        let (reply, receiver) = if wait_for_completion {
            let (sender, receiver) = sync_channel(1);
            (Some(sender), Some(receiver))
        } else {
            (None, None)
        };
        let mut state = lock_state(&self.shared);
        ensure_available(&state)?;
        if replace_pending {
            clear_queue(&mut state, "superseded by a safety reset");
        }
        if state.queue.len() == QUEUE_CAPACITY {
            if let Some(index) = state
                .queue
                .iter()
                .position(|command| matches!(command.kind, CommandKind::Move(_)))
            {
                state.queue.remove(index);
            } else {
                return Err("Meno HID command queue is full".to_string());
            }
        }
        state.queue.push_back(QueuedCommand { kind, reply });
        state.queue_high_water = state.queue_high_water.max(state.queue.len());
        self.shared.changed.notify_one();
        drop(state);

        let Some(receiver) = receiver else {
            return Ok(());
        };
        // The backend owns overlapped I/O cancellation and reports its final
        // outcome. Returning earlier could apply a stale report after the
        // mouse session has already changed state.
        match receiver.recv() {
            Ok(result) => result,
            Err(_) => Err("Meno HID acknowledgement channel closed".to_string()),
        }
    }
}

impl Drop for HidWriter {
    fn drop(&mut self) {
        let mut state = lock_state(&self.shared);
        state.stopped = true;
        clear_queue(&mut state, "Meno HID writer is shutting down");
        self.shared.changed.notify_all();
    }
}

fn writer_loop(shared: Arc<Shared>, factory: BackendFactory) {
    elevate_writer_priority();
    let pacer = MovePacer::new();
    let mut backend: Option<Box<dyn HidBackend>> = None;
    let mut next_move_at: Option<Instant> = None;

    loop {
        if backend.is_none() {
            if lock_state(&shared).stopped {
                break;
            }
            match factory().and_then(|mut device| {
                device.reset(None).map_err(|error| error.to_string())?;
                Ok(device)
            }) {
                Ok(device) => {
                    backend = Some(device);
                    let mut state = lock_state(&shared);
                    state.initialized = true;
                    state.available = true;
                    state.last_error = None;
                    shared.changed.notify_all();
                }
                Err(error) => {
                    let mut state = lock_state(&shared);
                    state.initialized = true;
                    state.available = false;
                    state.last_error = Some(error);
                    shared.changed.notify_all();
                    let (state, _) = shared
                        .changed
                        .wait_timeout(state, REOPEN_DELAY)
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    if state.stopped {
                        break;
                    }
                    continue;
                }
            }
        }

        let command = loop {
            let mut state = lock_state(&shared);
            while state.queue.is_empty() && !state.stopped {
                state = shared
                    .changed
                    .wait(state)
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
            }
            if state.stopped {
                break None;
            }

            let now = Instant::now();
            if let Some(delay) = move_delay(&state.queue, next_move_at, now) {
                drop(state);
                pacer.wait(delay);
                continue;
            }
            break state.queue.pop_front();
        };
        let Some(command) = command else {
            break;
        };

        let started = Instant::now();
        let is_move = matches!(command.kind, CommandKind::Move(_));
        let backend_ref = backend.as_mut().expect("backend is open");
        let result = execute(backend_ref, &command.kind);
        if is_move {
            next_move_at = Some(started + MOVE_INTERVAL);
        }
        let reply_result = result.as_ref().map(|_| ()).map_err(ToString::to_string);
        let mut state = lock_state(&shared);
        if let Err(error) = result {
            if state.available {
                state.faults += 1;
            }
            state.available = false;
            state.last_error = Some(error.to_string());
            crate::logging::error(&format!("Meno HID writer failure: {error}"));
            clear_queue(&mut state, "discarded after an HID writer failure");
            backend = None;
        }
        if let Some(reply) = command.reply {
            let _ = reply.send(reply_result);
        }
        shared.changed.notify_all();
    }

    let mut state = lock_state(&shared);
    state.available = false;
    shared.changed.notify_all();
}

fn elevate_writer_priority() {
    // Above normal only: never high, time-critical or realtime.
    let _ = unsafe { SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL) };
}

fn move_delay(
    queue: &VecDeque<QueuedCommand>,
    next_move_at: Option<Instant>,
    now: Instant,
) -> Option<Duration> {
    // Pace only a lone replaceable move. If an ordered command is waiting
    // behind it, publish the move immediately so the command is not delayed.
    if queue.len() != 1 || !matches!(queue.front()?.kind, CommandKind::Move(_)) {
        return None;
    }
    next_move_at?.checked_duration_since(now)
}

struct MovePacer {
    timer: Option<HANDLE>,
}

impl MovePacer {
    fn new() -> Self {
        let timer = unsafe {
            CreateWaitableTimerExW(
                None,
                PCWSTR::null(),
                CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
                TIMER_ALL_ACCESS.0,
            )
        };
        Self { timer: timer.ok() }
    }

    fn wait(&self, delay: Duration) {
        let Some(timer) = self.timer else {
            thread::sleep(delay);
            return;
        };
        let hundred_nanoseconds = delay.as_nanos().div_ceil(100).min(i64::MAX as u128) as i64;
        let due_time = -hundred_nanoseconds.max(1);
        let started = Instant::now();
        let armed = unsafe { SetWaitableTimer(timer, &due_time, 0, None, None, false) };
        let wait_timeout_ms = delay
            .saturating_add(PACER_WAIT_GRACE)
            .as_millis()
            .min(u128::from(u32::MAX)) as u32;
        if (armed.is_err()
            || unsafe { WaitForSingleObject(timer, wait_timeout_ms) } != WAIT_OBJECT_0)
            && let Some(remaining) = delay.checked_sub(started.elapsed())
        {
            thread::sleep(remaining);
        }
    }
}

impl Drop for MovePacer {
    fn drop(&mut self) {
        if let Some(timer) = self.timer.take() {
            let _ = unsafe { CloseHandle(timer) };
        }
    }
}

fn execute(backend: &mut Box<dyn HidBackend>, command: &CommandKind) -> Result<(), HidWriteError> {
    match command {
        CommandKind::Move(report) => backend.submit(std::slice::from_ref(report)),
        CommandKind::Reports(reports) => backend.submit(reports),
        CommandKind::Keyboard { modifiers, keys } => backend.keyboard(*modifiers, keys),
        CommandKind::Reset(position) => backend.reset(*position),
        CommandKind::Neutralize(position) => {
            backend.keyboard(0, &[])?;
            backend.reset(*position)
        }
    }
}

fn ensure_available(state: &State) -> Result<(), String> {
    if !state.initialized {
        return Err(state
            .last_error
            .clone()
            .unwrap_or_else(|| "Meno HID writer is still starting".to_string()));
    }
    if state.available {
        Ok(())
    } else {
        Err(state
            .last_error
            .clone()
            .unwrap_or_else(|| "Meno Virtual Mouse is unavailable".to_string()))
    }
}

fn clear_queue(state: &mut State, reason: &str) {
    while let Some(command) = state.queue.pop_front() {
        if let Some(reply) = command.reply {
            let _ = reply.send(Err(reason.to_string()));
        }
    }
}

fn lock_state(shared: &Shared) -> std::sync::MutexGuard<'_, State> {
    shared
        .state
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct DelayBackend {
        delay: Duration,
        calls: Arc<AtomicUsize>,
    }

    struct FailingBackend;

    struct RecordingBackend {
        records: Arc<Mutex<Vec<(Instant, HidReport)>>>,
    }

    impl HidBackend for DelayBackend {
        fn reset(&mut self, _position: Option<HidReport>) -> Result<(), HidWriteError> {
            Ok(())
        }

        fn submit(&mut self, _reports: &[HidReport]) -> Result<(), HidWriteError> {
            self.calls.fetch_add(1, Ordering::Relaxed);
            thread::sleep(self.delay);
            Ok(())
        }

        fn keyboard(&mut self, _modifiers: u8, _keys: &[u8]) -> Result<(), HidWriteError> {
            Ok(())
        }
    }

    impl HidBackend for FailingBackend {
        fn reset(&mut self, _position: Option<HidReport>) -> Result<(), HidWriteError> {
            Ok(())
        }

        fn submit(&mut self, _reports: &[HidReport]) -> Result<(), HidWriteError> {
            Err(HidWriteError::failed("simulated HID failure"))
        }

        fn keyboard(&mut self, _modifiers: u8, _keys: &[u8]) -> Result<(), HidWriteError> {
            Ok(())
        }
    }

    impl HidBackend for RecordingBackend {
        fn reset(&mut self, _position: Option<HidReport>) -> Result<(), HidWriteError> {
            Ok(())
        }

        fn submit(&mut self, reports: &[HidReport]) -> Result<(), HidWriteError> {
            let mut records = self.records.lock().unwrap();
            records.extend(
                reports
                    .iter()
                    .copied()
                    .map(|report| (Instant::now(), report)),
            );
            Ok(())
        }

        fn keyboard(&mut self, _modifiers: u8, _keys: &[u8]) -> Result<(), HidWriteError> {
            Ok(())
        }
    }

    fn delayed_writer(delay: Duration) -> (HidWriter, Arc<AtomicUsize>) {
        let calls = Arc::new(AtomicUsize::new(0));
        let factory_calls = Arc::clone(&calls);
        let factory: BackendFactory = Arc::new(move || {
            Ok(Box::new(DelayBackend {
                delay,
                calls: Arc::clone(&factory_calls),
            }))
        });
        (HidWriter::start_internal(factory), calls)
    }

    fn report(x: u16) -> HidReport {
        HidReport {
            x,
            y: 1,
            wheel: 0,
            buttons: 0,
        }
    }

    fn idle_writer() -> HidWriter {
        HidWriter {
            shared: Arc::new(Shared {
                state: Mutex::new(State {
                    queue: VecDeque::new(),
                    stopped: false,
                    initialized: true,
                    available: true,
                    faults: 0,
                    last_error: None,
                    queue_high_water: 0,
                }),
                changed: Condvar::new(),
            }),
        }
    }

    #[test]
    fn delayed_backend_never_blocks_move_submission() {
        let (writer, calls) = delayed_writer(Duration::from_millis(400));
        let started = Instant::now();
        writer.submit_move(report(1)).unwrap();
        writer.submit_move(report(2)).unwrap();
        assert!(started.elapsed() < Duration::from_millis(30));
        thread::sleep(Duration::from_millis(140));
        let status = writer.status();
        assert!(status.available);
        assert_eq!(status.faults, 0);
        assert!(calls.load(Ordering::Relaxed) >= 1);
    }

    #[test]
    fn delayed_backend_barrier_waits_for_the_real_result() {
        let delay = Duration::from_millis(200);
        let (writer, calls) = delayed_writer(delay);
        let started = Instant::now();
        writer.submit_initial(report(1)).unwrap();
        assert!(started.elapsed() >= delay);
        let status = writer.status();
        assert!(status.available);
        assert_eq!(status.faults, 0);
        assert!(calls.load(Ordering::Relaxed) >= 1);
    }

    #[test]
    fn real_backend_failure_is_returned_and_recorded() {
        let factory: BackendFactory = Arc::new(|| Ok(Box::new(FailingBackend)));
        let writer = HidWriter::start_internal(factory);

        assert_eq!(
            writer.submit_initial(report(1)).unwrap_err(),
            "simulated HID failure"
        );
        let status = writer.status();
        assert_eq!(status.faults, 1);
    }

    #[test]
    fn move_tail_is_coalesced_without_crossing_a_critical_command() {
        let writer = idle_writer();
        writer.submit_move(report(1)).unwrap();
        writer.submit_move(report(2)).unwrap();
        writer.submit_reports(vec![report(3)]).unwrap();
        writer.submit_move(report(4)).unwrap();

        let state = lock_state(&writer.shared);
        assert_eq!(state.queue.len(), 3);
        assert!(matches!(state.queue[0].kind, CommandKind::Move(value) if value.x == 2));
        assert!(matches!(state.queue[1].kind, CommandKind::Reports(_)));
        assert!(matches!(state.queue[2].kind, CommandKind::Move(value) if value.x == 4));
    }

    #[test]
    fn critical_command_evicts_a_move_from_a_full_queue() {
        let writer = idle_writer();
        writer.submit_move(report(0)).unwrap();
        for x in 1..QUEUE_CAPACITY {
            writer.submit_reports(vec![report(x as u16)]).unwrap();
        }

        writer.submit_keyboard(0, Vec::new()).unwrap();

        let state = lock_state(&writer.shared);
        assert_eq!(state.queue.len(), QUEUE_CAPACITY);
        assert!(matches!(
            state.queue.front().unwrap().kind,
            CommandKind::Reports(_)
        ));
        assert!(matches!(
            state.queue.back().unwrap().kind,
            CommandKind::Keyboard { .. }
        ));
    }

    #[test]
    fn full_critical_queue_is_rejected_without_reordering() {
        let writer = idle_writer();
        for x in 0..QUEUE_CAPACITY {
            writer.submit_reports(vec![report(x as u16)]).unwrap();
        }

        assert!(writer.submit_keyboard(0, Vec::new()).is_err());

        let state = lock_state(&writer.shared);
        assert_eq!(state.queue.len(), QUEUE_CAPACITY);
        assert!(matches!(
            state.queue.front().unwrap().kind,
            CommandKind::Reports(_)
        ));
        assert!(matches!(
            state.queue.back().unwrap().kind,
            CommandKind::Reports(_)
        ));
    }

    #[test]
    fn full_queue_rejects_a_move_instead_of_silently_dropping_it() {
        let writer = idle_writer();
        {
            let mut state = lock_state(&writer.shared);
            for _ in 0..QUEUE_CAPACITY {
                state.queue.push_back(QueuedCommand {
                    kind: CommandKind::Reports(vec![report(1)]),
                    reply: None,
                });
            }
        }
        assert_eq!(
            writer.submit_move(report(2)).unwrap_err(),
            "Meno HID command queue is full"
        );
    }

    #[test]
    fn lone_move_waits_for_the_next_publish_slot() {
        let now = Instant::now();
        let deadline = now + MOVE_INTERVAL;
        let queue = VecDeque::from([QueuedCommand {
            kind: CommandKind::Move(report(1)),
            reply: None,
        }]);

        assert_eq!(move_delay(&queue, Some(deadline), now), Some(MOVE_INTERVAL));
    }

    #[test]
    fn critical_command_bypasses_move_pacing_without_crossing_the_move() {
        let now = Instant::now();
        let deadline = now + MOVE_INTERVAL;
        let queue = VecDeque::from([
            QueuedCommand {
                kind: CommandKind::Move(report(1)),
                reply: None,
            },
            QueuedCommand {
                kind: CommandKind::Reports(vec![report(2)]),
                reply: None,
            },
        ]);

        assert_eq!(move_delay(&queue, Some(deadline), now), None);
        assert!(matches!(queue[0].kind, CommandKind::Move(_)));
        assert!(matches!(queue[1].kind, CommandKind::Reports(_)));
    }

    #[test]
    fn high_rate_moves_publish_latest_state_at_the_paced_rate() {
        let records = Arc::new(Mutex::new(Vec::new()));
        let factory_records = Arc::clone(&records);
        let factory: BackendFactory = Arc::new(move || {
            Ok(Box::new(RecordingBackend {
                records: Arc::clone(&factory_records),
            }))
        });
        let writer = HidWriter::start_internal(factory);

        for x in 0..1000 {
            writer.submit_move(report(x)).unwrap();
        }
        let deadline = Instant::now() + Duration::from_secs(2);
        while records
            .lock()
            .unwrap()
            .last()
            .is_none_or(|(_, report)| report.x != 999)
            && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(1));
        }

        let records = records.lock().unwrap();
        assert!(!records.is_empty());
        assert!(records.len() < 1000);
        assert_eq!(records.last().unwrap().1.x, 999);
        for pair in records.windows(2) {
            assert!(
                pair[1].0.duration_since(pair[0].0) >= MOVE_INTERVAL - Duration::from_micros(100)
            );
        }
    }
}
