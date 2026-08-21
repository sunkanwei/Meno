use std::fs;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use windows::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
use windows::core::PCWSTR;

use crate::file_cache::{self, CacheRecord};
use crate::file_manifest;

const FILE_ATTRIBUTE_REPARSE_BITS: u32 = 0x400;
const FILE_ATTRIBUTE_DIRECTORY_BITS: u32 = 0x10;

pub(crate) struct TransferCache {
    root: PathBuf,
    max_component: usize,
}

impl TransferCache {
    pub(crate) fn new(root: PathBuf) -> Self {
        let _ = fs::create_dir_all(file_manifest::io_path(&root));
        let max_component = file_manifest::volume_max_component(&root);
        Self {
            root,
            max_component,
        }
    }

    pub(crate) fn max_component(&self) -> usize {
        self.max_component
    }

    pub(crate) fn transfer_path(&self, name: &str) -> PathBuf {
        self.root.join(name)
    }

    pub(crate) fn ensure_capacity(
        &self,
        incoming_logical_bytes: u64,
        incoming_entries: usize,
        referenced: &[PathBuf],
        active_receive: Option<&Path>,
    ) -> Result<(), String> {
        loop {
            let (records, legacy_referenced) = self.scan(referenced, active_receive, true)?;
            if legacy_referenced {
                return Err(
                    "the clipboard still references a legacy cache without quota metadata"
                        .to_string(),
                );
            }
            let available = free_space(&self.root)
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

    pub(crate) fn housekeeping(&self, referenced: &[PathBuf], active_receive: Option<&Path>) {
        let Ok((records, _)) = self.scan(referenced, active_receive, true) else {
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

    fn canonical_root(&self) -> Option<PathBuf> {
        let root_io = file_manifest::io_path(&self.root);
        let metadata = fs::symlink_metadata(&root_io).ok()?;
        let attributes = metadata.file_attributes();
        if attributes & FILE_ATTRIBUTE_DIRECTORY_BITS == 0
            || attributes & FILE_ATTRIBUTE_REPARSE_BITS != 0
        {
            return None;
        }
        fs::canonicalize(root_io).ok()
    }

    fn validated_child(&self, name: &str) -> Option<PathBuf> {
        let canonical_root = self.canonical_root()?;
        let path = file_manifest::io_path(&self.root.join(name));
        let metadata = fs::symlink_metadata(&path).ok()?;
        let attributes = metadata.file_attributes();
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
        fs::remove_dir_all(path).is_ok()
    }

    fn delete_managed_directory(&self, name: &str) -> bool {
        if !file_cache::is_transfer_directory_name(name) {
            return false;
        }
        let Some(path) = self.validated_child(name) else {
            return false;
        };
        let tombstone_name = format!(".delete-{name}");
        let tombstone = file_manifest::io_path(&self.root.join(&tombstone_name));
        if fs::symlink_metadata(&tombstone).is_ok() && !self.delete_tombstone(&tombstone_name) {
            return false;
        }
        if fs::rename(&path, &tombstone).is_err() {
            return false;
        }
        self.delete_tombstone(&tombstone_name)
    }

    fn scan(
        &self,
        referenced: &[PathBuf],
        active_receive: Option<&Path>,
        purge_incomplete: bool,
    ) -> Result<(Vec<CacheRecord>, bool), String> {
        if self.canonical_root().is_none() {
            return Err("cache root is missing, redirected, or not a directory".to_string());
        }
        let root_io = file_manifest::io_path(&self.root);
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
            let plain = self.root.join(name);
            if active_receive.is_some_and(|active| active == plain) {
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
}

fn free_space(path: &Path) -> Option<u64> {
    let wide: Vec<u16> = path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let mut free = 0_u64;
    unsafe { GetDiskFreeSpaceExW(PCWSTR(wide.as_ptr()), Some(&mut free), None, None) }
        .is_ok()
        .then_some(free)
}
