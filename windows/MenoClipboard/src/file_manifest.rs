use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::ffi::{OsStr, OsString};
use std::fs;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};

use windows::Win32::Globalization::{NormalizationC, NormalizeString};
use windows::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FindClose, FindFirstFileW, GetVolumeInformationW,
    WIN32_FIND_DATAW,
};
use windows::core::PCWSTR;

use crate::file_protocol::{
    MAX_DEPTH, MAX_ENTRIES, MAX_NAME_BYTES, MAX_TOP_LEVEL, OfferEntry, checked_logical_bytes,
};

const FILE_ATTRIBUTE_DIRECTORY_BITS: u32 = 0x10;
const FILE_ATTRIBUTE_HIDDEN_BITS: u32 = 0x2;
const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA000_0003;
const IO_REPARSE_TAG_SYMLINK: u32 = 0xA000_000C;
const DEFAULT_MAX_COMPONENT: usize = 255;
const RESERVED_NAMES: &[&str] = &[
    "con",
    "prn",
    "aux",
    "nul",
    "clock$",
    "conin$",
    "conout$",
    "com1",
    "com2",
    "com3",
    "com4",
    "com5",
    "com6",
    "com7",
    "com8",
    "com9",
    "lpt1",
    "lpt2",
    "lpt3",
    "lpt4",
    "lpt5",
    "lpt6",
    "lpt7",
    "lpt8",
    "lpt9",
    "com\u{00B9}",
    "com\u{00B2}",
    "com\u{00B3}",
    "lpt\u{00B9}",
    "lpt\u{00B2}",
    "lpt\u{00B3}",
];

#[derive(Clone, Debug)]
pub struct SourceEntry {
    pub directory: bool,
    pub hidden: bool,
    pub parent: Option<u32>,
    pub name: String,
    pub size: u64,
    pub modified_millis: i64,
    pub modified_ticks: u64,
    pub path: Option<PathBuf>,
}

#[derive(Clone, Debug)]
pub struct SourceManifest {
    pub entries: Vec<SourceEntry>,
    pub total_file_bytes: u64,
}

struct Attributes {
    directory: bool,
    hidden: bool,
    reparse: bool,
    size: u64,
    modified_ticks: u64,
}

// Internal disk IO uses verbatim paths so deep trees do not depend on the
// system long-path policy; paths published to the Shell stay plain absolute.
pub fn io_path(path: &Path) -> PathBuf {
    let text = path.as_os_str().to_string_lossy();
    if text.starts_with(r"\\?\") {
        return path.to_path_buf();
    }
    if let Some(unc) = text.strip_prefix(r"\\") {
        let mut verbatim = OsString::from(r"\\?\UNC\");
        verbatim.push(unc);
        return PathBuf::from(verbatim);
    }
    if path.is_absolute() {
        let mut verbatim = OsString::from(r"\\?\");
        verbatim.push(path.as_os_str());
        return PathBuf::from(verbatim);
    }
    path.to_path_buf()
}

fn wide(path: &Path) -> Vec<u16> {
    path.as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

fn stat(path: &Path) -> Result<Attributes, String> {
    let metadata = fs::symlink_metadata(path).map_err(|error| format!("stat failed: {error}"))?;
    let attributes = metadata.file_attributes();
    Ok(Attributes {
        directory: attributes & FILE_ATTRIBUTE_DIRECTORY_BITS != 0,
        hidden: attributes & FILE_ATTRIBUTE_HIDDEN_BITS != 0,
        reparse: attributes & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0,
        size: metadata.file_size(),
        modified_ticks: metadata.last_write_time(),
    })
}

// Cloud placeholders carry other reparse tags and read as ordinary files;
// only links that would move the tree boundary elsewhere are rejected.
fn reject_links(path: &Path, attributes: &Attributes) -> Result<(), String> {
    if !attributes.reparse {
        return Ok(());
    }
    let wide = wide(path);
    let mut data = WIN32_FIND_DATAW::default();
    let handle = unsafe { FindFirstFileW(PCWSTR(wide.as_ptr()), &mut data) }
        .map_err(|error| format!("reparse point inspection failed: {error}"))?;
    let _ = unsafe { FindClose(handle) };
    if data.dwReserved0 == IO_REPARSE_TAG_SYMLINK || data.dwReserved0 == IO_REPARSE_TAG_MOUNT_POINT
    {
        return Err("symbolic links, junctions and mount points are not transferable".to_string());
    }
    Ok(())
}

pub fn ticks_to_millis(ticks: u64) -> i64 {
    ((ticks / 10_000) as i64).saturating_sub(11_644_473_600_000)
}

fn push_entry(
    entries: &mut Vec<SourceEntry>,
    attributes: &Attributes,
    parent: Option<u32>,
    name: String,
    path: &Path,
) -> Result<(), String> {
    if entries.len() >= MAX_ENTRIES {
        return Err(format!("more than {MAX_ENTRIES} manifest entries"));
    }
    if name.len() > MAX_NAME_BYTES {
        return Err(format!("a name exceeds {MAX_NAME_BYTES} UTF-8 bytes"));
    }
    entries.push(SourceEntry {
        directory: attributes.directory,
        hidden: attributes.hidden,
        parent,
        name,
        size: if attributes.directory {
            0
        } else {
            attributes.size
        },
        modified_millis: ticks_to_millis(attributes.modified_ticks),
        modified_ticks: attributes.modified_ticks,
        path: (!attributes.directory).then(|| path.to_path_buf()),
    });
    Ok(())
}

fn wide_order(left: &OsStr, right: &OsStr) -> Ordering {
    left.encode_wide().cmp(right.encode_wide())
}

// Enumeration is iterative with an explicit heap stack so deep trees never
// depend on the worker thread stack. The wire limit is enforced below.
// Top-level entries keep the clipboard order, directory children are
// sorted per directory, and parents always precede their children.
struct PendingChildren {
    children: Vec<(OsString, PathBuf)>,
    next: usize,
    parent: Option<u32>,
    depth: usize,
}

fn list_children(
    stack: &mut Vec<PendingChildren>,
    directory: &Path,
    parent: u32,
    depth: usize,
) -> Result<(), String> {
    let mut children = Vec::new();
    for child in
        fs::read_dir(directory).map_err(|error| format!("directory listing failed: {error}"))?
    {
        let child = child.map_err(|error| format!("directory listing failed: {error}"))?;
        children.push((child.file_name(), child.path()));
    }
    children.sort_by(|left, right| wide_order(&left.0, &right.0));
    stack.push(PendingChildren {
        children,
        next: 0,
        parent: Some(parent),
        depth,
    });
    Ok(())
}

pub fn enumerate(top_paths: &[PathBuf]) -> Result<SourceManifest, String> {
    if top_paths.is_empty() || top_paths.len() > MAX_TOP_LEVEL {
        return Err(format!("top-level item count must be 1..={MAX_TOP_LEVEL}"));
    }
    let mut roots = Vec::with_capacity(top_paths.len());
    for path in top_paths {
        let name = path
            .file_name()
            .ok_or_else(|| "a top-level path has no file name".to_string())?
            .to_os_string();
        roots.push((name, io_path(path)));
    }
    let mut entries = Vec::new();
    let mut total = 0_u64;
    let mut stack = vec![PendingChildren {
        children: roots,
        next: 0,
        parent: None,
        depth: 0,
    }];
    while let Some(frame) = stack.last_mut() {
        let Some((name, path)) = frame.children.get(frame.next).cloned() else {
            stack.pop();
            continue;
        };
        frame.next += 1;
        let parent = frame.parent;
        let child_depth = frame.depth + 1;
        if child_depth > MAX_DEPTH {
            return Err(format!("directory nesting exceeds {MAX_DEPTH} levels"));
        }
        let attributes = stat(&path)?;
        reject_links(&path, &attributes)?;
        let name = name
            .to_str()
            .ok_or_else(|| "a file name is not representable in UTF-8".to_string())?
            .to_string();
        push_entry(&mut entries, &attributes, parent, name, &path)?;
        if !attributes.directory {
            total = checked_logical_bytes(total, attributes.size)
                .ok_or_else(|| "total file bytes exceed the fixed limit".to_string())?;
        }
        if attributes.directory {
            let index = (entries.len() - 1) as u32;
            list_children(&mut stack, &path, index, child_depth)?;
        }
    }
    Ok(SourceManifest {
        entries,
        total_file_bytes: total,
    })
}

// Source consistency is judged by kind, size and last-write time; any change
// cancels the whole task rather than sending mixed generations.
pub fn unchanged(entry: &SourceEntry) -> bool {
    let Some(path) = &entry.path else { return true };
    match stat(path) {
        Ok(attributes) => {
            !attributes.directory
                && attributes.size == entry.size
                && attributes.modified_ticks == entry.modified_ticks
        }
        Err(_) => false,
    }
}

fn truncate_units(value: &str, max_units: usize) -> String {
    let mut result = String::new();
    let mut units = 0;
    for character in value.chars() {
        let width = character.len_utf16();
        if units + width > max_units {
            break;
        }
        units += width;
        result.push(character);
    }
    result
}

fn split_extension(name: &str) -> (&str, &str) {
    match name.rfind('.') {
        Some(dot) if dot > 0 => (&name[..dot], &name[dot..]),
        _ => (name, ""),
    }
}

fn is_reserved_basename(name: &str) -> bool {
    let basename = match name.find('.') {
        Some(dot) => &name[..dot],
        None => name,
    };
    let folded = basename.to_lowercase();
    RESERVED_NAMES.contains(&folded.as_str())
}

pub fn map_component(name: &str, max_units: usize) -> String {
    let mapped: String = name
        .chars()
        .map(|character| {
            if matches!(
                character,
                '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*'
            ) || (character as u32) < 0x20
            {
                '_'
            } else {
                character
            }
        })
        .collect();
    let trimmed = mapped.trim_end_matches(['.', ' ']);
    let mut cleaned = if trimmed.is_empty() {
        "_".to_string()
    } else {
        trimmed.to_string()
    };
    if is_reserved_basename(&cleaned) {
        match cleaned.find('.') {
            Some(dot) => cleaned.insert(dot, '_'),
            None => cleaned.push('_'),
        }
    }
    if cleaned.encode_utf16().count() > max_units {
        let (stem, extension) = split_extension(&cleaned);
        let extension_units = extension.encode_utf16().count();
        if !extension.is_empty() && extension_units + 1 < max_units {
            cleaned = format!(
                "{}{}",
                truncate_units(stem, max_units - extension_units),
                extension
            );
        } else {
            cleaned = truncate_units(&cleaned, max_units);
        }
    }
    if cleaned.is_empty() {
        "_".to_string()
    } else {
        cleaned
    }
}

pub fn with_suffix(name: &str, number: u32, max_units: usize) -> String {
    let (stem, extension) = split_extension(name);
    let suffix = format!(" ({number})");
    let suffix_units = suffix.encode_utf16().count();
    let extension_units = extension.encode_utf16().count();
    let stem_budget = max_units
        .saturating_sub(extension_units + suffix_units)
        .max(1);
    let candidate = format!(
        "{}{}{}",
        truncate_units(stem, stem_budget),
        suffix,
        extension
    );
    // A pathological extension can still overflow the budget; never emit a
    // name the target volume would reject.
    if candidate.encode_utf16().count() > max_units {
        return truncate_units(&candidate, max_units);
    }
    candidate
}

pub fn nfc(value: &str) -> String {
    let wide: Vec<u16> = value.encode_utf16().collect();
    let needed = unsafe { NormalizeString(NormalizationC, &wide, None) };
    if needed <= 0 {
        return value.to_string();
    }
    let mut buffer = vec![0_u16; needed as usize];
    let written = unsafe { NormalizeString(NormalizationC, &wide, Some(&mut buffer)) };
    if written <= 0 {
        return value.to_string();
    }
    String::from_utf16_lossy(&buffer[..written as usize])
}

pub fn conflict_key(name: &str) -> String {
    nfc(name).chars().flat_map(char::to_lowercase).collect()
}

// Same-parent duplicates after replacement/truncation are renamed with a
// stable " (n)" suffix; wire order is preserved so parent rows stay valid.
pub fn map_receive_names(entries: &[OfferEntry], max_units: usize) -> Vec<PathBuf> {
    #[derive(Default)]
    struct Scope {
        used: HashSet<String>,
        next_suffix: HashMap<String, u32>,
    }

    let mut scopes: HashMap<Option<u32>, Scope> = HashMap::new();
    let mut rels: Vec<PathBuf> = Vec::with_capacity(entries.len());
    for entry in entries {
        let base = map_component(&entry.name, max_units);
        let scope = scopes.entry(entry.parent).or_default();
        let base_key = conflict_key(&base);
        let name = if scope.used.insert(base_key.clone()) {
            scope.next_suffix.entry(base_key).or_insert(2);
            base
        } else {
            let suffix = scope.next_suffix.entry(base_key).or_insert(2);
            loop {
                let candidate = with_suffix(&base, *suffix, max_units);
                *suffix += 1;
                if scope.used.insert(conflict_key(&candidate)) {
                    break candidate;
                }
            }
        };
        let rel = match entry.parent {
            None => PathBuf::from(&name),
            Some(parent) => rels[parent as usize].join(&name),
        };
        rels.push(rel);
    }
    rels
}

pub fn volume_max_component(path: &Path) -> usize {
    let mut components = path.components();
    let Some(Component::Prefix(prefix)) = components.next() else {
        return DEFAULT_MAX_COMPONENT;
    };
    if !matches!(components.next(), Some(Component::RootDir)) {
        return DEFAULT_MAX_COMPONENT;
    }
    let root = format!("{}\\", prefix.as_os_str().to_string_lossy());
    let wide: Vec<u16> = root.encode_utf16().chain(std::iter::once(0)).collect();
    let mut maximum = 0_u32;
    let result = unsafe {
        GetVolumeInformationW(
            PCWSTR(wide.as_ptr()),
            None,
            None,
            Some(&mut maximum),
            None,
            None,
        )
    };
    if result.is_err() || maximum == 0 {
        return DEFAULT_MAX_COMPONENT;
    }
    maximum as usize
}
