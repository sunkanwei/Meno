use std::{
    fs::{self, File},
    io::{BufRead, BufReader, Read},
    path::{Path, PathBuf},
};

use rmcp::schemars;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use walkdir::WalkDir;

use crate::{
    config::AppConfig,
    error::{AgentError, AgentResult},
    security,
};

const MAX_PAGE: usize = 200;
const MAX_READ_BYTES: usize = 256 * 1024;
const MAX_READ_LINES: usize = 500;
const MAX_SEARCH_FILES: usize = 5_000;

#[derive(Clone, Debug, Deserialize, schemars::JsonSchema)]
pub struct PathScope {
    pub scope: String,
    pub workspace: Option<String>,
    pub path: String,
}

#[derive(Clone, Debug, Deserialize, schemars::JsonSchema)]
pub struct ListFilesRequest {
    #[serde(flatten)]
    pub target: PathScope,
    #[serde(default)]
    pub cursor: usize,
    pub limit: Option<usize>,
}

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct FileEntry {
    pub name: String,
    pub relative_path: String,
    pub kind: String,
    pub size: Option<u64>,
    pub modified_utc: Option<String>,
}

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct ListFilesResponse {
    pub entries: Vec<FileEntry>,
    pub next_cursor: Option<usize>,
}

#[derive(Clone, Debug, Deserialize, schemars::JsonSchema)]
pub struct ReadFileRequest {
    #[serde(flatten)]
    pub target: PathScope,
    pub start_line: Option<usize>,
    pub line_count: Option<usize>,
    pub byte_offset: Option<u64>,
    pub byte_count: Option<usize>,
}

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct ReadFileResponse {
    pub content: String,
    pub encoding: String,
    pub sha256: String,
    pub size: u64,
    pub start: usize,
    pub returned: usize,
    pub truncated: bool,
}

#[derive(Clone, Debug, Deserialize, schemars::JsonSchema)]
pub struct SearchFilesRequest {
    pub scope: String,
    pub workspace: Option<String>,
    pub root: String,
    pub name_contains: Option<String>,
    pub extension: Option<String>,
    pub text: Option<String>,
    #[serde(default)]
    pub cursor: usize,
    pub limit: Option<usize>,
}

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct SearchMatch {
    pub path: String,
    pub line: Option<usize>,
    pub preview: Option<String>,
}

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct SearchFilesResponse {
    pub matches: Vec<SearchMatch>,
    pub next_cursor: Option<usize>,
    pub scanned_files: usize,
    pub scan_truncated: bool,
}

pub fn list(config: &AppConfig, request: &ListFilesRequest) -> AgentResult<ListFilesResponse> {
    let root = resolve(config, &request.target)?;
    if !root.is_dir() {
        return Err(AgentError::InvalidArgument("目标不是目录".to_owned()));
    }
    let limit = request.limit.unwrap_or(100).clamp(1, MAX_PAGE);
    let mut entries = fs::read_dir(&root)?
        .filter_map(Result::ok)
        .collect::<Vec<_>>();
    entries.sort_by_key(|entry| entry.file_name().to_string_lossy().to_ascii_lowercase());
    let total = entries.len();
    let page = entries
        .into_iter()
        .skip(request.cursor)
        .take(limit)
        .map(|entry| {
            let metadata = entry.metadata().ok();
            let entry_path = entry.path();
            FileEntry {
                name: entry.file_name().to_string_lossy().into_owned(),
                relative_path: entry_path
                    .strip_prefix(&root)
                    .unwrap_or(&entry_path)
                    .to_string_lossy()
                    .into_owned(),
                kind: metadata
                    .as_ref()
                    .map(|value| if value.is_dir() { "directory" } else { "file" })
                    .unwrap_or("unknown")
                    .to_owned(),
                size: metadata
                    .as_ref()
                    .filter(|value| value.is_file())
                    .map(|value| value.len()),
                modified_utc: metadata
                    .and_then(|value| value.modified().ok())
                    .map(|value| chrono::DateTime::<chrono::Utc>::from(value).to_rfc3339()),
            }
        })
        .collect();
    let next = request.cursor.saturating_add(limit);
    Ok(ListFilesResponse {
        entries: page,
        next_cursor: (next < total).then_some(next),
    })
}

pub fn read(config: &AppConfig, request: &ReadFileRequest) -> AgentResult<ReadFileResponse> {
    let path = resolve(config, &request.target)?;
    if !path.is_file() {
        return Err(AgentError::InvalidArgument("目标不是普通文件".to_owned()));
    }
    let metadata = fs::metadata(&path)?;
    let sha256 = hash_file(&path)?;
    if request.byte_offset.is_some() || request.byte_count.is_some() {
        let offset = request.byte_offset.unwrap_or(0);
        let count = request
            .byte_count
            .unwrap_or(64 * 1024)
            .clamp(1, MAX_READ_BYTES);
        let mut file = File::open(&path)?;
        use std::io::{Seek, SeekFrom};
        file.seek(SeekFrom::Start(offset))?;
        let mut bytes = vec![0; count];
        let returned = file.read(&mut bytes)?;
        bytes.truncate(returned);
        return Ok(ReadFileResponse {
            content: String::from_utf8_lossy(&bytes).into_owned(),
            encoding: "utf-8-lossy".to_owned(),
            sha256,
            size: metadata.len(),
            start: offset as usize,
            returned,
            truncated: offset.saturating_add(returned as u64) < metadata.len(),
        });
    }

    let start = request.start_line.unwrap_or(1).max(1);
    let count = request.line_count.unwrap_or(200).clamp(1, MAX_READ_LINES);
    let reader = BufReader::new(File::open(path)?);
    let mut lines = Vec::new();
    let mut has_more = false;
    for (index, line) in reader.lines().enumerate() {
        let number = index + 1;
        if number < start {
            continue;
        }
        if lines.len() == count {
            has_more = true;
            break;
        }
        lines.push(line?);
    }
    Ok(ReadFileResponse {
        content: lines.join("\n"),
        encoding: "utf-8".to_owned(),
        sha256,
        size: metadata.len(),
        start,
        returned: lines.len(),
        truncated: has_more,
    })
}

pub fn search(
    config: &AppConfig,
    request: &SearchFilesRequest,
) -> AgentResult<SearchFilesResponse> {
    if request.name_contains.is_none() && request.extension.is_none() && request.text.is_none() {
        return Err(AgentError::InvalidArgument(
            "至少提供一种搜索条件".to_owned(),
        ));
    }
    let target = PathScope {
        scope: request.scope.clone(),
        workspace: request.workspace.clone(),
        path: request.root.clone(),
    };
    let root = resolve(config, &target)?;
    if !root.is_dir() {
        return Err(AgentError::InvalidArgument("搜索根目录无效".to_owned()));
    }
    let limit = request.limit.unwrap_or(100).clamp(1, MAX_PAGE);
    let wanted_name = request
        .name_contains
        .as_ref()
        .map(|value| value.to_ascii_lowercase());
    let wanted_extension = request
        .extension
        .as_ref()
        .map(|value| value.trim_start_matches('.').to_ascii_lowercase());
    let wanted_text = request.text.as_deref();
    let mut found = Vec::new();
    let mut scanned = 0;
    let mut scan_truncated = false;

    for entry in WalkDir::new(&root)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
    {
        if !entry.file_type().is_file() {
            continue;
        }
        scanned += 1;
        if scanned > MAX_SEARCH_FILES {
            scan_truncated = true;
            break;
        }
        let path = entry.path();
        let file_name = entry.file_name().to_string_lossy().to_ascii_lowercase();
        if wanted_name
            .as_ref()
            .is_some_and(|value| !file_name.contains(value))
        {
            continue;
        }
        if wanted_extension.as_ref().is_some_and(|value| {
            path.extension()
                .and_then(|part| part.to_str())
                .map(|part| !part.eq_ignore_ascii_case(value))
                .unwrap_or(true)
        }) {
            continue;
        }
        if let Some(needle) = wanted_text {
            if fs::metadata(path)
                .map(|value| value.len())
                .unwrap_or(u64::MAX)
                > 4 * 1024 * 1024
            {
                continue;
            }
            let reader = match File::open(path) {
                Ok(file) => BufReader::new(file),
                Err(_) => continue,
            };
            for (index, line) in reader.lines().enumerate() {
                let Ok(line) = line else { break };
                if line.contains(needle) {
                    found.push(SearchMatch {
                        path: display_relative(&root, path),
                        line: Some(index + 1),
                        preview: Some(limit_preview(&line)),
                    });
                }
            }
        } else {
            found.push(SearchMatch {
                path: display_relative(&root, path),
                line: None,
                preview: None,
            });
        }
        if found.len() > request.cursor.saturating_add(limit) {
            break;
        }
    }
    let total_seen = found.len();
    let matches = found.into_iter().skip(request.cursor).take(limit).collect();
    Ok(SearchFilesResponse {
        matches,
        next_cursor: (total_seen > request.cursor.saturating_add(limit))
            .then_some(request.cursor.saturating_add(limit)),
        scanned_files: scanned.min(MAX_SEARCH_FILES),
        scan_truncated,
    })
}

pub fn hash_file(path: &Path) -> AgentResult<String> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hex::encode(hasher.finalize()))
}

pub fn resolve(config: &AppConfig, target: &PathScope) -> AgentResult<PathBuf> {
    match target.scope.as_str() {
        "workspace" => {
            let workspace = target.workspace.as_deref().ok_or_else(|| {
                AgentError::InvalidArgument("workspace 范围缺少工作区编号".to_owned())
            })?;
            security::resolve_workspace_existing(config, workspace, Path::new(&target.path))
        }
        "system" => security::resolve_system_existing(Path::new(&target.path)),
        _ => Err(AgentError::InvalidArgument(
            "scope 只能是 workspace 或 system".to_owned(),
        )),
    }
}

fn display_relative(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .into_owned()
}

fn limit_preview(line: &str) -> String {
    line.chars().take(300).collect()
}
