use std::collections::VecDeque;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PushResult {
    Queued { wake: bool },
    Replaced { wake: bool },
    Full,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct QueueStats {
    pub items: usize,
    pub bytes: usize,
    pub high_items: usize,
    pub high_bytes: usize,
    pub replaced: u64,
    pub rejected: u64,
}

struct Item<T> {
    value: T,
    bytes: usize,
}

pub struct BoundedQueue<T> {
    items: VecDeque<Item<T>>,
    bytes: usize,
    max_items: usize,
    max_bytes: usize,
    wake_pending: bool,
    high_items: usize,
    high_bytes: usize,
    replaced: u64,
    rejected: u64,
}

impl<T> BoundedQueue<T> {
    pub fn new(max_items: usize, max_bytes: usize) -> Self {
        assert!(max_items > 0);
        assert!(max_bytes > 0);
        Self {
            items: VecDeque::new(),
            bytes: 0,
            max_items,
            max_bytes,
            wake_pending: false,
            high_items: 0,
            high_bytes: 0,
            replaced: 0,
            rejected: 0,
        }
    }

    pub fn push(&mut self, value: T, bytes: usize) -> PushResult {
        self.push_inner(value, bytes, |_| false)
    }

    pub fn push_latest(
        &mut self,
        value: T,
        bytes: usize,
        replace: impl Fn(&T) -> bool,
    ) -> PushResult {
        self.push_inner(value, bytes, replace)
    }

    fn push_inner(&mut self, value: T, bytes: usize, replace: impl Fn(&T) -> bool) -> PushResult {
        let mut removed_items = 0_usize;
        let mut removed_bytes = 0_usize;
        for item in &self.items {
            if replace(&item.value) {
                removed_items += 1;
                removed_bytes = removed_bytes.saturating_add(item.bytes);
            }
        }
        let remaining_items = self.items.len().saturating_sub(removed_items);
        let remaining_bytes = self.bytes.saturating_sub(removed_bytes);
        if bytes > self.max_bytes
            || remaining_items >= self.max_items
            || remaining_bytes > self.max_bytes - bytes
        {
            self.rejected += 1;
            return PushResult::Full;
        }

        if removed_items != 0 {
            self.items.retain(|item| !replace(&item.value));
            self.bytes = remaining_bytes;
            self.replaced += removed_items as u64;
        }
        self.bytes += bytes;
        self.items.push_back(Item { value, bytes });
        self.high_items = self.high_items.max(self.items.len());
        self.high_bytes = self.high_bytes.max(self.bytes);
        let wake = !self.wake_pending;
        self.wake_pending = true;
        if removed_items == 0 {
            PushResult::Queued { wake }
        } else {
            PushResult::Replaced { wake }
        }
    }

    pub fn take_batch(&mut self, maximum: usize) -> (Vec<T>, bool) {
        let count = maximum.min(self.items.len());
        let mut batch = Vec::with_capacity(count);
        for _ in 0..count {
            if let Some(item) = self.items.pop_front() {
                self.bytes = self.bytes.saturating_sub(item.bytes);
                batch.push(item.value);
            }
        }
        let remaining = !self.items.is_empty();
        self.wake_pending = remaining;
        (batch, remaining)
    }

    pub fn wake_failed(&mut self) {
        self.wake_pending = false;
    }

    pub fn clear(&mut self) {
        self.items.clear();
        self.bytes = 0;
        self.wake_pending = false;
    }

    pub fn stats(&self) -> QueueStats {
        QueueStats {
            items: self.items.len(),
            bytes: self.bytes,
            high_items: self.high_items,
            high_bytes: self.high_bytes,
            replaced: self.replaced,
            rejected: self.rejected,
        }
    }
}
