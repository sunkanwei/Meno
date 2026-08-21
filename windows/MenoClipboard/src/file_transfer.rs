use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender, SyncSender};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use windows::Win32::Foundation::{CloseHandle, FILETIME, HWND};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAGS_AND_ATTRIBUTES, FILE_SHARE_DELETE,
    FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_WRITE_ATTRIBUTES, GetDiskFreeSpaceExW, OPEN_EXISTING,
    SetFileAttributesW, SetFileTime,
};
use windows::core::PCWSTR;

use crate::FileUiRequest;
use crate::connection::NetworkCommand;
use crate::file_cache::{self, CacheRecord};
use crate::file_manifest::{self, SourceEntry, SourceManifest};
use crate::file_protocol::{
    self, CANCEL_LOCAL_CLIPBOARD, CANCEL_READ_FAILED, CANCEL_SOURCE_CHANGED, CANCEL_SUPERSEDED,
    CANCEL_TIMEOUT, MAX_CHUNK_DATA, Offer, OfferEntry, OfferError, RESULT_BAD_MANIFEST,
    RESULT_CLIPBOARD_FAILED, RESULT_NO_SPACE, RESULT_OK, RESULT_SUPERSEDED, RESULT_WRITE_FAILED,
    TransferId,
};
use crate::protocol::{Frame, MessageKind};

const ACCEPT_TIMEOUT: Duration = Duration::from_secs(15);
const RESULT_TIMEOUT: Duration = Duration::from_secs(15);
const ACK_TIMEOUT: Duration = Duration::from_secs(30);
const UI_TIMEOUT: Duration = Duration::from_secs(15);
const HOUSEKEEPING_INTERVAL: Duration = Duration::from_secs(60 * 60);
const FILE_ATTRIBUTE_REPARSE_BITS: u32 = 0x400;
const FILE_ATTRIBUTE_DIRECTORY_BITS: u32 = 0x10;

pub enum WorkerEvent {
    LocalFiles(Vec<PathBuf>),
    LocalOther,
    RemoteContent,
    Link {
        connection_id: u64,
    },
    Closed {
        connection_id: u64,
    },
    Frame {
        connection_id: u64,
        frame: Frame,
    },
    Written {
        connection_id: u64,
        message_id: u64,
        ok: bool,
    },
}

pub fn spawn(hwnd: HWND, network: SyncSender<NetworkCommand>, inbox: Receiver<WorkerEvent>) {
    let cache_root = default_cache_root();
    spawn_at(hwnd, network, inbox, cache_root);
}

pub(crate) fn spawn_at(
    hwnd: HWND,
    network: SyncSender<NetworkCommand>,
    inbox: Receiver<WorkerEvent>,
    cache_root: PathBuf,
) {
    let hwnd_value = hwnd.0 as usize;
    thread::spawn(move || {
        let mut worker = Worker::new(HWND(hwnd_value as *mut _), network, cache_root);
        worker.run(inbox);
    });
}

fn default_cache_root() -> PathBuf {
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Meno")
        .join("FileClipboard")
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum SendPhase {
    WaitingAccept,
    Sending,
    WaitingResult,
}

struct SendTask {
    id: TransferId,
    manifest: SourceManifest,
    phase: SendPhase,
    deadline: Instant,
    pending_write: Option<u64>,
    pending_chunk: Option<(u32, u64, u64)>,
    cursor: usize,
    file: Option<File>,
    file_entry: u32,
    offset: u64,
}

struct ReceiveEntry {
    directory: bool,
    hidden: bool,
    size: u64,
    modified_millis: i64,
    abs: PathBuf,
    received: u64,
}

struct ReceiveTask {
    id: TransferId,
    directory: PathBuf,
    publish: Vec<PathBuf>,
    entries: Vec<ReceiveEntry>,
    next_data: usize,
    offset: u64,
    file: Option<File>,
    received_total: u64,
    logical_bytes: u64,
    entry_count: usize,
}

struct Worker {
    hwnd: HWND,
    network: SyncSender<NetworkCommand>,
    link: Option<u64>,
    send: Option<SendTask>,
    receive: Option<ReceiveTask>,
    cache_root: PathBuf,
    max_component: usize,
    next_housekeeping: Instant,
}

impl Worker {
    fn new(hwnd: HWND, network: SyncSender<NetworkCommand>, cache_root: PathBuf) -> Self {
        let _ = fs::create_dir_all(file_manifest::io_path(&cache_root));
        let max_component = file_manifest::volume_max_component(&cache_root);
        Self {
            hwnd,
            network,
            link: None,
            send: None,
            receive: None,
            cache_root,
            max_component,
            next_housekeeping: Instant::now() + HOUSEKEEPING_INTERVAL,
        }
    }

    fn run(&mut self, inbox: Receiver<WorkerEvent>) {
        self.housekeeping();
        loop {
            let send_deadline = self.send.as_ref().map(|task| task.deadline);
            let deadline = send_deadline.map_or(self.next_housekeeping, |deadline| {
                deadline.min(self.next_housekeeping)
            });
            let event = match inbox.recv_timeout(deadline.saturating_duration_since(Instant::now()))
            {
                Ok(event) => Some(event),
                Err(mpsc::RecvTimeoutError::Timeout) => None,
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
            };
            match event {
                Some(event) => self.handle(event),
                None => {
                    let now = Instant::now();
                    if send_deadline.is_some_and(|deadline| now >= deadline) {
                        self.expire_send();
                    }
                    if now >= self.next_housekeeping {
                        self.housekeeping();
                        self.next_housekeeping = now + HOUSEKEEPING_INTERVAL;
                    }
                }
            }
        }
    }

    fn handle(&mut self, event: WorkerEvent) {
        match event {
            WorkerEvent::LocalFiles(paths) => self.start_local(paths),
            WorkerEvent::LocalOther => {
                self.cancel_send(CANCEL_LOCAL_CLIPBOARD);
                self.cancel_receive(RESULT_SUPERSEDED);
            }
            WorkerEvent::RemoteContent => self.cancel_receive(RESULT_SUPERSEDED),
            WorkerEvent::Link { connection_id } => {
                self.link = Some(connection_id);
                self.drop_send_silently();
                self.drop_receive_silently();
                self.housekeeping();
            }
            WorkerEvent::Closed { connection_id } => {
                if self.link == Some(connection_id) {
                    self.link = None;
                    self.drop_send_silently();
                    self.drop_receive_silently();
                }
            }
            WorkerEvent::Written {
                connection_id,
                message_id,
                ok,
            } => self.handle_written(connection_id, message_id, ok),
            WorkerEvent::Frame {
                connection_id,
                frame,
            } => {
                if self.link == Some(connection_id) {
                    self.handle_frame(frame);
                }
            }
        }
    }

    fn handle_frame(&mut self, frame: Frame) {
        match frame.kind {
            MessageKind::FileOffer => self.handle_offer(&frame.payload),
            MessageKind::FileAccept => match file_protocol::decode_accept(&frame.payload) {
                Ok(id) => self.handle_accept(id),
                Err(_) => self.violation("malformed fileAccept"),
            },
            MessageKind::FileChunk => self.handle_chunk(&frame.payload),
            MessageKind::FileComplete => match file_protocol::decode_complete(&frame.payload) {
                Ok(id) => self.handle_complete(id),
                Err(_) => self.violation("malformed fileComplete"),
            },
            MessageKind::FileResult => match file_protocol::decode_result(&frame.payload) {
                Ok((id, status)) => self.handle_result(id, status),
                Err(_) => self.violation("malformed fileResult"),
            },
            MessageKind::FileCancel => match file_protocol::decode_cancel(&frame.payload) {
                Ok((id, reason)) => self.handle_cancel(id, reason),
                Err(_) => self.violation("malformed fileCancel"),
            },
            MessageKind::FileAck => match file_protocol::decode_ack(&frame.payload) {
                Ok((id, entry, next_offset)) => self.handle_ack(id, entry, next_offset),
                Err(_) => self.violation("malformed fileAck"),
            },
            _ => {}
        }
    }

    fn post_frame(&mut self, kind: MessageKind, payload: Vec<u8>) -> Option<u64> {
        let connection_id = self.link?;
        let frame = Frame::new(kind, payload);
        let message_id = frame.message_id;
        self.network
            .send(NetworkCommand::FileFrame {
                connection_id,
                frame,
            })
            .ok()?;
        Some(message_id)
    }

    fn violation(&mut self, reason: &str) {
        crate::logging::error(&format!("file transfer protocol violation: {reason}"));
        self.drop_send_silently();
        self.drop_receive_silently();
        if let Some(connection_id) = self.link.take() {
            let _ = self
                .network
                .send(NetworkCommand::ProtocolViolation { connection_id });
        }
        self.housekeeping();
    }

    // ----- sending -----

    fn start_local(&mut self, paths: Vec<PathBuf>) {
        if paths.is_empty() {
            return;
        }
        self.cancel_send(CANCEL_SUPERSEDED);
        self.cancel_receive(RESULT_SUPERSEDED);
        if self.link.is_none() {
            crate::logging::debug("file clipboard ignored: no negotiated link");
            return;
        }
        let manifest = match file_manifest::enumerate(&paths) {
            Ok(manifest) => manifest,
            Err(error) => {
                crate::logging::error(&format!("file enumeration failed: {error}"));
                return;
            }
        };
        let id = file_protocol::new_transfer_id();
        let offer = Offer {
            transfer_id: id,
            total_file_bytes: manifest.total_file_bytes,
            entries: manifest
                .entries
                .iter()
                .map(|entry| OfferEntry {
                    directory: entry.directory,
                    hidden: entry.hidden,
                    parent: entry.parent,
                    name: entry.name.clone(),
                    size: entry.size,
                    modified_millis: entry.modified_millis,
                })
                .collect(),
        };
        let payload = match file_protocol::encode_offer(&offer) {
            Ok(payload) => payload,
            Err(error) => {
                crate::logging::error(&format!("file offer encode failed: {error:?}"));
                return;
            }
        };
        let Some(message_id) = self.post_frame(MessageKind::FileOffer, payload) else {
            return;
        };
        crate::logging::info(&format!(
            "file offer -> mac: id={} entries={} bytes={}",
            file_protocol::transfer_id_hex(&id),
            manifest.entries.len(),
            manifest.total_file_bytes
        ));
        self.send = Some(SendTask {
            id,
            manifest,
            phase: SendPhase::WaitingAccept,
            deadline: Instant::now() + ACCEPT_TIMEOUT,
            pending_write: Some(message_id),
            pending_chunk: None,
            cursor: 0,
            file: None,
            file_entry: 0,
            offset: 0,
        });
    }

    fn handle_written(&mut self, connection_id: u64, message_id: u64, ok: bool) {
        if self.link != Some(connection_id) {
            return;
        }
        let Some(task) = self.send.as_mut() else {
            return;
        };
        if task.pending_write != Some(message_id) {
            return;
        }
        task.pending_write = None;
        if !ok {
            self.drop_send_silently();
        }
    }

    fn handle_accept(&mut self, id: TransferId) {
        let Some(task) = self.send.as_mut() else {
            return;
        };
        if task.id != id || task.phase != SendPhase::WaitingAccept {
            return;
        }
        task.phase = SendPhase::Sending;
        task.pending_write = None;
        self.advance_send();
    }

    fn advance_send(&mut self) {
        enum Step {
            Open(usize),
            Complete,
        }
        loop {
            let step = {
                let Some(task) = self.send.as_mut() else {
                    return;
                };
                let mut step = Step::Complete;
                while task.cursor < task.manifest.entries.len() {
                    let entry = &task.manifest.entries[task.cursor];
                    if entry.directory || entry.size == 0 {
                        task.cursor += 1;
                        continue;
                    }
                    step = Step::Open(task.cursor);
                    break;
                }
                step
            };
            match step {
                Step::Complete => {
                    let Some(task) = self.send.as_ref() else {
                        return;
                    };
                    let id = task.id;
                    let Some(message_id) = self.post_frame(
                        MessageKind::FileComplete,
                        file_protocol::encode_id_only(&id),
                    ) else {
                        self.drop_send_silently();
                        return;
                    };
                    let Some(task) = self.send.as_mut() else {
                        return;
                    };
                    task.phase = SendPhase::WaitingResult;
                    task.pending_write = Some(message_id);
                    task.deadline = Instant::now() + RESULT_TIMEOUT;
                    return;
                }
                Step::Open(index) => {
                    {
                        let Some(task) = self.send.as_ref() else {
                            return;
                        };
                        let entry = &task.manifest.entries[index];
                        if !file_manifest::unchanged(entry) {
                            self.cancel_send(CANCEL_SOURCE_CHANGED);
                            return;
                        }
                        let path = entry.path.clone().unwrap();
                        match File::open(&path) {
                            Ok(file) if verify_open(&file, entry).is_ok() => {
                                let task = self.send.as_mut().unwrap();
                                task.file = Some(file);
                                task.file_entry = index as u32;
                                task.offset = 0;
                            }
                            Ok(_) => {
                                self.cancel_send(CANCEL_SOURCE_CHANGED);
                                return;
                            }
                            Err(error) => {
                                crate::logging::error(&format!(
                                    "file source open failed for one entry: {error}"
                                ));
                                self.cancel_send(CANCEL_READ_FAILED);
                                return;
                            }
                        }
                    }
                    if self.read_send_chunk() {
                        return;
                    }
                }
            }
        }
    }

    // Returns false when the task was cancelled; the caller then loops and
    // observes the task is gone.
    fn read_send_chunk(&mut self) -> bool {
        let Some(task) = self.send.as_mut() else {
            return false;
        };
        let size = task.manifest.entries[task.file_entry as usize].size;
        let id = task.id;
        let entry_index = task.file_entry;
        let offset = task.offset;
        let mut buffer = vec![0_u8; (size - offset).min(MAX_CHUNK_DATA as u64) as usize];
        let mut filled = 0_usize;
        let read_result = loop {
            let file = task.file.as_mut().unwrap();
            match file.read(&mut buffer[filled..]) {
                Ok(0) => break Ok(filled),
                Ok(count) => {
                    filled += count;
                    if filled == buffer.len() {
                        break Ok(filled);
                    }
                }
                Err(error) => break Err(error),
            }
        };
        let count = match read_result {
            Ok(count) if count == buffer.len() => count,
            Ok(_) => {
                self.cancel_send(CANCEL_SOURCE_CHANGED);
                return false;
            }
            Err(error) => {
                crate::logging::error(&format!("file source read failed: {error}"));
                self.cancel_send(CANCEL_READ_FAILED);
                return false;
            }
        };
        let payload = file_protocol::encode_chunk(&id, entry_index, offset, &buffer[..count]);
        let Some(message_id) = self.post_frame(MessageKind::FileChunk, payload) else {
            self.drop_send_silently();
            return false;
        };
        let Some(task) = self.send.as_mut() else {
            return false;
        };
        task.pending_write = Some(message_id);
        task.pending_chunk = Some((entry_index, offset, offset + count as u64));
        task.deadline = Instant::now() + ACK_TIMEOUT;
        true
    }

    fn handle_ack(&mut self, id: TransferId, entry: u32, next_offset: u64) {
        let Some(task) = self.send.as_ref() else {
            return;
        };
        if task.id != id {
            return;
        }
        if task.phase != SendPhase::Sending {
            return;
        }
        let expected = task.pending_write.is_none()
            && task
                .pending_chunk
                .is_some_and(|(pending_entry, offset, end)| {
                    pending_entry == entry && offset == task.offset && end == next_offset
                });
        if !expected {
            self.violation("fileAck does not match the pending chunk");
            return;
        }
        let Some(task) = self.send.as_mut() else {
            return;
        };
        let (entry_index, _, end) = task.pending_chunk.take().unwrap();
        let size = task.manifest.entries[entry_index as usize].size;
        if end == size {
            let file = task.file.take().unwrap();
            let verified = verify_open(&file, &task.manifest.entries[entry_index as usize]);
            drop(file);
            if verified.is_err() {
                self.cancel_send(CANCEL_SOURCE_CHANGED);
                return;
            }
            let Some(task) = self.send.as_mut() else {
                return;
            };
            task.cursor = entry_index as usize + 1;
            task.offset = 0;
            self.advance_send();
        } else {
            task.offset = end;
            self.read_send_chunk();
        }
    }

    fn handle_result(&mut self, id: TransferId, status: u8) {
        let Some(task) = self.send.as_ref() else {
            return;
        };
        if task.id != id {
            return;
        }
        if status == RESULT_OK {
            crate::logging::info(&format!(
                "file transfer -> mac completed: id={}",
                file_protocol::transfer_id_hex(&id)
            ));
        } else {
            crate::logging::error(&format!(
                "file transfer -> mac failed: id={} status={status}",
                file_protocol::transfer_id_hex(&id)
            ));
        }
        self.send = None;
        self.housekeeping();
    }

    fn expire_send(&mut self) {
        if self.send.is_some() {
            self.cancel_send(CANCEL_TIMEOUT);
        }
    }

    fn cancel_send(&mut self, reason: u8) {
        let Some(task) = self.send.take() else { return };
        drop(task.file);
        crate::logging::info(&format!(
            "file transfer -> mac cancelled: id={} reason={reason}",
            file_protocol::transfer_id_hex(&task.id)
        ));
        if self.link.is_some() {
            let _ = self.post_frame(
                MessageKind::FileCancel,
                file_protocol::encode_cancel(&task.id, reason),
            );
        }
        self.housekeeping();
    }

    fn drop_send_silently(&mut self) {
        if let Some(task) = self.send.take() {
            drop(task.file);
        }
    }

    // ----- receiving -----

    fn handle_offer(&mut self, payload: &[u8]) {
        let offer = match file_protocol::decode_offer(payload) {
            Ok(offer) => offer,
            Err(OfferError::Malformed) => {
                self.violation("malformed fileOffer");
                return;
            }
            Err(OfferError::Illegal(reason)) => {
                crate::logging::error(&format!("illegal file offer rejected: {reason}"));
                self.post_frame(
                    MessageKind::FileResult,
                    file_protocol::encode_result(&offer_id(payload), RESULT_BAD_MANIFEST),
                );
                return;
            }
        };
        if self.receive.is_some() {
            self.cancel_receive(RESULT_SUPERSEDED);
        }
        match self.prepare_receive(offer) {
            Ok(task) => {
                let id = task.id;
                let total: u64 = task.entries.iter().map(|entry| entry.size).sum();
                crate::logging::info(&format!(
                    "file offer <- mac: id={} entries={} bytes={total}",
                    file_protocol::transfer_id_hex(&id),
                    task.entries.len(),
                ));
                if self
                    .post_frame(MessageKind::FileAccept, file_protocol::encode_id_only(&id))
                    .is_none()
                {
                    self.cleanup_receive(task);
                    return;
                }
                self.receive = Some(task);
            }
            Err((status, message)) => {
                crate::logging::error(&format!("file offer refused: status={status} {message}"));
                self.post_frame(
                    MessageKind::FileResult,
                    file_protocol::encode_result(&offer_id(payload), status),
                );
            }
        }
    }

    fn prepare_receive(&mut self, offer: Offer) -> Result<ReceiveTask, (u8, String)> {
        let referenced = self
            .ui_referenced()
            .map_err(|message| (RESULT_NO_SPACE, message))?;
        self.ensure_cache_capacity(offer.total_file_bytes, offer.entries.len(), &referenced)
            .map_err(|message| (RESULT_NO_SPACE, message))?;

        let mapped = file_manifest::map_receive_names(&offer.entries, self.max_component);
        let directory = self
            .cache_root
            .join(file_protocol::transfer_id_hex(&offer.transfer_id));
        let directory_io = file_manifest::io_path(&directory);
        let created = fs::create_dir(&directory_io);
        if let Err(error) = created {
            return Err((
                RESULT_WRITE_FAILED,
                format!("cache directory failed: {error}"),
            ));
        }
        if let Err(error) = file_cache::write_partial(
            &directory_io,
            &offer.transfer_id,
            offer.total_file_bytes,
            offer.entries.len(),
        ) {
            let _ = fs::remove_dir_all(&directory_io);
            return Err((RESULT_WRITE_FAILED, error));
        }
        let mut entries = Vec::with_capacity(offer.entries.len());
        for (index, entry) in offer.entries.iter().enumerate() {
            let abs = directory_io.join(&mapped[index]);
            if entry.directory
                && let Err(error) = fs::create_dir_all(&abs)
            {
                let _ = fs::remove_dir_all(&directory_io);
                return Err((
                    RESULT_WRITE_FAILED,
                    format!("cache directory creation failed: {error}"),
                ));
            }
            entries.push(ReceiveEntry {
                directory: entry.directory,
                hidden: entry.hidden,
                size: entry.size,
                modified_millis: entry.modified_millis,
                abs,
                received: 0,
            });
        }
        // Publish order follows the manifest, which preserves the sender's
        // clipboard order.
        let publish = offer
            .entries
            .iter()
            .enumerate()
            .filter(|(_, entry)| entry.parent.is_none())
            .map(|(index, _)| directory.join(&mapped[index]))
            .collect();
        let next_data = next_data_entry(&entries, 0);
        Ok(ReceiveTask {
            id: offer.transfer_id,
            directory,
            publish,
            entries,
            next_data,
            offset: 0,
            file: None,
            received_total: 0,
            logical_bytes: offer.total_file_bytes,
            entry_count: offer.entries.len(),
        })
    }

    fn handle_chunk(&mut self, payload: &[u8]) {
        let (id, entry_index, offset, data) = match file_protocol::decode_chunk(payload) {
            Ok(chunk) => chunk,
            Err(_) => {
                self.violation("malformed fileChunk");
                return;
            }
        };
        let Some(task) = self.receive.as_mut() else {
            return;
        };
        if task.id != id {
            return;
        }
        let valid = match task.entries.get(entry_index as usize) {
            Some(entry) => {
                !entry.directory
                    && entry_index as usize == task.next_data
                    && offset == task.offset
                    && offset + data.len() as u64 <= entry.size
            }
            None => false,
        };
        if !valid {
            self.violation("fileChunk is out of order or exceeds the declared size");
            return;
        }
        if task.file.is_none() {
            let path = task.entries[entry_index as usize].abs.clone();
            match OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(file) => task.file = Some(file),
                Err(error) => {
                    crate::logging::error(&format!("cache file create failed: {error}"));
                    self.fail_receive(RESULT_WRITE_FAILED);
                    return;
                }
            }
        }
        if let Err(error) = task.file.as_mut().unwrap().write_all(data) {
            crate::logging::error(&format!("cache file write failed: {error}"));
            self.fail_receive(RESULT_WRITE_FAILED);
            return;
        }
        let end = offset + data.len() as u64;
        task.entries[entry_index as usize].received = end;
        task.received_total += data.len() as u64;
        task.offset = end;
        if end == task.entries[entry_index as usize].size {
            drop(task.file.take());
            task.next_data = next_data_entry(&task.entries, entry_index as usize + 1);
            task.offset = 0;
        }
        if self
            .post_frame(
                MessageKind::FileAck,
                file_protocol::encode_ack(&id, entry_index, end),
            )
            .is_none()
        {
            self.drop_receive_silently();
        }
    }

    fn handle_complete(&mut self, id: TransferId) {
        let Some(task) = self.receive.as_ref() else {
            return;
        };
        if task.id != id {
            return;
        }
        let declared: u64 = task.entries.iter().map(|entry| entry.size).sum();
        if task.file.is_some()
            || task.next_data < task.entries.len()
            || task.received_total != declared
        {
            self.violation("fileComplete arrived before all declared bytes");
            return;
        }
        let Some(task) = self.receive.take() else {
            return;
        };
        if let Err(message) = finalize_receive(&task) {
            crate::logging::error(&format!("cache finalization failed: {message}"));
            self.fail_receive_task(task, RESULT_WRITE_FAILED);
            return;
        }
        if let Err(message) = file_cache::mark_completed(
            &file_manifest::io_path(&task.directory),
            &task.id,
            task.logical_bytes,
            task.entry_count,
        ) {
            crate::logging::error(&format!("cache completion marker failed: {message}"));
            self.fail_receive_task(task, RESULT_WRITE_FAILED);
            return;
        }
        match self.ui_publish(task.publish.clone()) {
            Ok(()) => {
                crate::logging::info(&format!(
                    "file transfer <- mac completed: id={} top={}",
                    file_protocol::transfer_id_hex(&id),
                    task.publish.len()
                ));
                self.post_frame(
                    MessageKind::FileResult,
                    file_protocol::encode_result(&id, RESULT_OK),
                );
                self.housekeeping();
            }
            Err(message) => {
                crate::logging::error(&format!("clipboard publish failed: {message}"));
                self.fail_receive_task(task, RESULT_CLIPBOARD_FAILED);
            }
        }
    }

    fn handle_cancel(&mut self, id: TransferId, reason: u8) {
        if let Some(task) = self.receive.as_ref()
            && task.id == id
        {
            crate::logging::info(&format!(
                "file transfer <- mac cancelled: id={} reason={reason}",
                file_protocol::transfer_id_hex(&id)
            ));
            let task = self.receive.take().unwrap();
            self.cleanup_receive(task);
            self.housekeeping();
            return;
        }
        if let Some(task) = self.send.as_ref()
            && task.id == id
        {
            crate::logging::info(&format!(
                "file transfer -> mac cancelled by peer: id={} reason={reason}",
                file_protocol::transfer_id_hex(&id)
            ));
            self.drop_send_silently();
            self.housekeeping();
        }
    }

    fn fail_receive(&mut self, status: u8) {
        let Some(task) = self.receive.take() else {
            return;
        };
        self.fail_receive_task(task, status);
    }

    fn fail_receive_task(&mut self, task: ReceiveTask, status: u8) {
        let id = task.id;
        self.cleanup_receive(task);
        self.post_frame(
            MessageKind::FileResult,
            file_protocol::encode_result(&id, status),
        );
        self.housekeeping();
    }

    fn cancel_receive(&mut self, status: u8) {
        let Some(task) = self.receive.take() else {
            return;
        };
        crate::logging::info(&format!(
            "file transfer <- mac aborted: id={} status={status}",
            file_protocol::transfer_id_hex(&task.id)
        ));
        self.fail_receive_task(task, status);
    }

    fn cleanup_receive(&mut self, task: ReceiveTask) {
        drop(task.file);
        let _ = fs::remove_dir_all(file_manifest::io_path(&task.directory));
    }

    fn drop_receive_silently(&mut self) {
        if let Some(task) = self.receive.take() {
            self.cleanup_receive(task);
        }
    }

    // ----- UI clipboard round trips -----

    fn ui_request<T: Send + 'static>(
        &self,
        build: impl FnOnce(Sender<T>) -> FileUiRequest,
        timeout: Duration,
    ) -> Option<T> {
        let (sender, receiver) = mpsc::channel();
        if !crate::post_file_ui_request(self.hwnd, build(sender)) {
            return None;
        }
        receiver.recv_timeout(timeout).ok()
    }

    fn ui_publish(&self, paths: Vec<PathBuf>) -> Result<(), String> {
        self.ui_request(
            |result| FileUiRequest::Publish { paths, result },
            UI_TIMEOUT,
        )
        .unwrap_or_else(|| Err("clipboard request timed out".to_string()))
    }

    fn ui_referenced(&self) -> Result<Vec<PathBuf>, String> {
        self.ui_request(
            |result| FileUiRequest::Referenced { result },
            Duration::from_secs(5),
        )
        .unwrap_or_else(|| Err("clipboard reference request timed out".to_string()))
    }

    // ----- cache housekeeping -----

    fn ensure_cache_capacity(
        &mut self,
        incoming_logical_bytes: u64,
        incoming_entries: usize,
        referenced: &[PathBuf],
    ) -> Result<(), String> {
        loop {
            let (records, legacy_referenced) = self.scan_cache(referenced, true)?;
            if legacy_referenced {
                return Err(
                    "the clipboard still references a legacy cache without quota metadata"
                        .to_string(),
                );
            }
            let available = free_space(&self.cache_root)
                .ok_or_else(|| "could not query free disk space".to_string())?;
            let plan = file_cache::plan_capacity(
                &records,
                incoming_logical_bytes,
                incoming_entries,
                available,
            );
            if plan.evict.is_empty() {
                return plan
                    .fits
                    .then_some(())
                    .ok_or_else(|| "cache quota or disk reserve is insufficient".to_string());
            }
            let mut removed = false;
            for name in plan.evict {
                removed |= self.delete_managed_directory(&name);
            }
            if !removed {
                return Err("cache quota could not be reclaimed safely".to_string());
            }
        }
    }

    fn canonical_cache_root(&self) -> Option<PathBuf> {
        let root_io = file_manifest::io_path(&self.cache_root);
        let metadata = fs::symlink_metadata(&root_io).ok()?;
        let attributes = std::os::windows::fs::MetadataExt::file_attributes(&metadata);
        if attributes & FILE_ATTRIBUTE_DIRECTORY_BITS == 0
            || attributes & FILE_ATTRIBUTE_REPARSE_BITS != 0
        {
            return None;
        }
        fs::canonicalize(root_io).ok()
    }

    fn validated_child(&self, name: &str) -> Option<PathBuf> {
        let canonical_root = self.canonical_cache_root()?;
        let path = file_manifest::io_path(&self.cache_root.join(name));
        let metadata = fs::symlink_metadata(&path).ok()?;
        let attributes = std::os::windows::fs::MetadataExt::file_attributes(&metadata);
        if attributes & FILE_ATTRIBUTE_DIRECTORY_BITS == 0
            || attributes & FILE_ATTRIBUTE_REPARSE_BITS != 0
        {
            return None;
        }
        let canonical = fs::canonicalize(&path).ok()?;
        (canonical.parent() == Some(canonical_root.as_path())).then_some(path)
    }

    fn delete_tombstone(&self, name: &str) -> bool {
        let Some(id) = name.strip_prefix(".delete-") else {
            return false;
        };
        if !file_cache::is_transfer_directory_name(id) {
            return false;
        }
        let Some(path) = self.validated_child(name) else {
            return false;
        };
        match fs::remove_dir_all(path) {
            Ok(()) => true,
            Err(error) => {
                crate::logging::debug(&format!("file cache cleanup deferred: {error}"));
                false
            }
        }
    }

    fn delete_managed_directory(&self, name: &str) -> bool {
        if !file_cache::is_transfer_directory_name(name) {
            return false;
        }
        let Some(path) = self.validated_child(name) else {
            return false;
        };
        let tombstone_name = format!(".delete-{name}");
        let tombstone = file_manifest::io_path(&self.cache_root.join(&tombstone_name));
        if fs::symlink_metadata(&tombstone).is_ok() && !self.delete_tombstone(&tombstone_name) {
            return false;
        }
        if fs::rename(&path, &tombstone).is_err() {
            return false;
        }
        if self.delete_tombstone(&tombstone_name) {
            crate::logging::info("file cache cleanup: removed 1 directory");
            true
        } else {
            false
        }
    }

    fn scan_cache(
        &self,
        referenced: &[PathBuf],
        purge_incomplete: bool,
    ) -> Result<(Vec<CacheRecord>, bool), String> {
        if self.canonical_cache_root().is_none() {
            return Err("cache root is missing, redirected, or not a directory".to_string());
        }
        let root_io = file_manifest::io_path(&self.cache_root);
        let Ok(children) = fs::read_dir(&root_io) else {
            return Err("cache root could not be listed".to_string());
        };
        let mut records = Vec::new();
        let mut legacy_referenced = false;
        for child in children.flatten() {
            let name = child.file_name();
            let Some(name) = name.to_str() else { continue };
            if name.starts_with(".delete-") {
                let _ = self.delete_tombstone(name);
                continue;
            }
            if !file_cache::is_transfer_directory_name(name) {
                continue;
            }
            if self.validated_child(name).is_none() {
                continue;
            }
            let plain = self.cache_root.join(name);
            if self
                .receive
                .as_ref()
                .is_some_and(|task| task.directory == plain)
            {
                continue;
            }
            let is_referenced = file_cache::is_referenced(&plain, referenced);
            match file_cache::load_completed(name, &child.path()) {
                Ok(metadata) => records.push(CacheRecord {
                    name: name.to_string(),
                    logical_bytes: metadata.logical_bytes,
                    entry_count: metadata.entry_count,
                    completed_millis: metadata.completed_millis,
                    referenced: is_referenced,
                }),
                Err(_) if is_referenced => legacy_referenced = true,
                Err(_) if purge_incomplete => {
                    if !self.delete_managed_directory(name) {
                        legacy_referenced = true;
                    }
                }
                Err(_) => {}
            }
        }
        Ok((records, legacy_referenced))
    }

    // Runs only when the current clipboard reference set is known; a failed
    // read keeps every directory rather than risking an in-use one.
    fn housekeeping(&mut self) {
        let Ok(referenced) = self.ui_referenced() else {
            return;
        };
        let Ok((records, _)) = self.scan_cache(&referenced, true) else {
            return;
        };
        let now_millis = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .min(u128::from(u64::MAX)) as u64;
        for record in records {
            if !record.referenced && file_cache::is_expired(record.completed_millis, now_millis) {
                let _ = self.delete_managed_directory(&record.name);
            }
        }
    }
}

fn offer_id(payload: &[u8]) -> TransferId {
    let mut id = [0_u8; file_protocol::TRANSFER_ID_SIZE];
    if payload.len() >= file_protocol::TRANSFER_ID_SIZE {
        id.copy_from_slice(&payload[..file_protocol::TRANSFER_ID_SIZE]);
    }
    id
}

fn verify_open(file: &File, entry: &SourceEntry) -> Result<(), ()> {
    use std::os::windows::fs::MetadataExt;
    let metadata = file.metadata().map_err(|_| ())?;
    if metadata.file_size() == entry.size && metadata.last_write_time() == entry.modified_ticks {
        Ok(())
    } else {
        Err(())
    }
}

fn next_data_entry(entries: &[ReceiveEntry], from: usize) -> usize {
    (from..entries.len())
        .find(|&index| !entries[index].directory && entries[index].size > 0)
        .unwrap_or(entries.len())
}

fn wide_path(path: &Path) -> Vec<u16> {
    std::os::windows::ffi::OsStrExt::encode_wide(path.as_os_str())
        .chain(std::iter::once(0))
        .collect()
}

fn free_space(path: &Path) -> Option<u64> {
    let wide = wide_path(path);
    let mut available = 0_u64;
    unsafe {
        GetDiskFreeSpaceExW(PCWSTR(wide.as_ptr()), Some(&mut available), None, None).ok()?;
    }
    Some(available)
}

fn set_modified(path: &Path, millis: i64, directory: bool) -> Result<(), String> {
    if millis == file_protocol::UNKNOWN_MILLIS {
        return Ok(());
    }
    let ticks = (i128::from(millis) + 11_644_473_600_000) * 10_000;
    if !(0..=i128::from(i64::MAX)).contains(&ticks) {
        return Ok(());
    }
    let ticks = ticks as u64;
    let file_time = FILETIME {
        dwLowDateTime: ticks as u32,
        dwHighDateTime: (ticks >> 32) as u32,
    };
    let wide = wide_path(path);
    let flags = if directory {
        FILE_FLAG_BACKUP_SEMANTICS
    } else {
        FILE_FLAGS_AND_ATTRIBUTES(0)
    };
    let handle = unsafe {
        CreateFileW(
            PCWSTR(wide.as_ptr()),
            FILE_WRITE_ATTRIBUTES.0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            None,
            OPEN_EXISTING,
            flags,
            None,
        )
        .map_err(|error| format!("SetFileTime open failed: {error}"))?
    };
    let result = unsafe { SetFileTime(handle, None, None, Some(&file_time)) };
    let _ = unsafe { CloseHandle(handle) };
    result.map_err(|error| format!("SetFileTime failed: {error}"))
}

fn set_hidden(path: &Path) -> Result<(), String> {
    use windows::Win32::Storage::FileSystem::{FILE_ATTRIBUTE_HIDDEN, GetFileAttributesW};
    let wide = wide_path(path);
    unsafe {
        let existing = GetFileAttributesW(PCWSTR(wide.as_ptr()));
        if existing == u32::MAX {
            return Err(format!(
                "GetFileAttributes failed: {}",
                windows::core::Error::from_thread()
            ));
        }
        SetFileAttributesW(
            PCWSTR(wide.as_ptr()),
            FILE_FLAGS_AND_ATTRIBUTES(existing | FILE_ATTRIBUTE_HIDDEN.0),
        )
        .map_err(|error| format!("SetFileAttributes failed: {error}"))
    }
}

fn finalize_receive(task: &ReceiveTask) -> Result<(), String> {
    for entry in &task.entries {
        if !entry.directory && entry.size == 0 && entry.received == 0 {
            File::create(&entry.abs)
                .map_err(|error| format!("empty file create failed: {error}"))?;
        }
    }
    for entry in &task.entries {
        if !entry.directory {
            set_modified(&entry.abs, entry.modified_millis, false)?;
        }
        if entry.hidden {
            set_hidden(&entry.abs)?;
        }
    }
    // Directory times go deepest first so stamping a parent never gets
    // undone by a later child write.
    let mut directories: Vec<&ReceiveEntry> = task
        .entries
        .iter()
        .filter(|entry| entry.directory)
        .collect();
    directories.sort_by_key(|entry| std::cmp::Reverse(entry.abs.components().count()));
    for entry in directories {
        set_modified(&entry.abs, entry.modified_millis, true)?;
    }
    Ok(())
}
