use std::{
    fs,
    path::{Component, Path, PathBuf},
};

use crate::{
    config::{AppConfig, WorkspaceConfig},
    error::{AgentError, AgentResult},
};

pub fn workspace<'a>(config: &'a AppConfig, id: &str) -> AgentResult<&'a WorkspaceConfig> {
    config
        .workspaces
        .iter()
        .find(|workspace| workspace.id == id)
        .ok_or_else(|| AgentError::WorkspaceNotFound(id.to_owned()))
}

pub fn resolve_workspace_existing(
    config: &AppConfig,
    workspace_id: &str,
    relative: &Path,
) -> AgentResult<PathBuf> {
    validate_relative(relative)?;
    let workspace = workspace(config, workspace_id)?;
    let root = fs::canonicalize(&workspace.path).map_err(|_| {
        AgentError::NotFound(format!("登记项目不存在: {}", workspace.path.display()))
    })?;
    let target = fs::canonicalize(root.join(relative))
        .map_err(|_| AgentError::NotFound(format!("路径不存在: {}", relative.display())))?;
    ensure_within(&root, &target)?;
    Ok(target)
}

pub fn resolve_workspace_target(
    config: &AppConfig,
    workspace_id: &str,
    relative: &Path,
) -> AgentResult<PathBuf> {
    validate_relative(relative)?;
    if relative.as_os_str().is_empty() {
        return Err(AgentError::PermissionDenied(
            "写入目标不能是登记项目根目录".to_owned(),
        ));
    }
    let workspace = workspace(config, workspace_id)?;
    let root = fs::canonicalize(&workspace.path).map_err(|_| {
        AgentError::NotFound(format!("登记项目不存在: {}", workspace.path.display()))
    })?;
    let lexical = root.join(relative);
    if lexical.exists() {
        let target = fs::canonicalize(&lexical)?;
        ensure_within(&root, &target)?;
        return Ok(target);
    }
    let mut existing = lexical.as_path();
    while !existing.exists() {
        existing = existing
            .parent()
            .ok_or_else(|| AgentError::PathOutsideWorkspace(lexical.display().to_string()))?;
    }
    let canonical_parent = fs::canonicalize(existing)?;
    ensure_within(&root, &canonical_parent)?;
    let suffix = lexical
        .strip_prefix(existing)
        .map_err(|_| AgentError::PathOutsideWorkspace(lexical.display().to_string()))?;
    Ok(canonical_parent.join(suffix))
}

pub fn resolve_system_existing(path: &Path) -> AgentResult<PathBuf> {
    if !path.is_absolute() {
        return Err(AgentError::InvalidArgument(
            "system 范围必须使用绝对路径".to_owned(),
        ));
    }
    fs::canonicalize(path)
        .map_err(|_| AgentError::NotFound(format!("路径不存在: {}", path.display())))
}

pub fn ensure_within(root: &Path, target: &Path) -> AgentResult<()> {
    let root_text = normalize_case(root);
    let target_text = normalize_case(target);
    let prefix = format!(
        "{}{}",
        root_text.trim_end_matches(['\\', '/']),
        std::path::MAIN_SEPARATOR
    );
    if target_text != root_text && !target_text.starts_with(&prefix) {
        return Err(AgentError::PathOutsideWorkspace(
            target.display().to_string(),
        ));
    }
    Ok(())
}

fn validate_relative(path: &Path) -> AgentResult<()> {
    if path.is_absolute()
        || path
            .components()
            .any(|part| matches!(part, Component::ParentDir | Component::Prefix(_)))
    {
        return Err(AgentError::InvalidArgument(
            "登记项目路径必须是无 .. 的相对路径".to_owned(),
        ));
    }
    Ok(())
}

fn normalize_case(path: &Path) -> String {
    path.to_string_lossy()
        .replace('/', "\\")
        .to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_parent_components() {
        let config = AppConfig::default();
        let error =
            resolve_workspace_existing(&config, "missing", Path::new("..\\secret")).unwrap_err();
        assert!(matches!(error, AgentError::InvalidArgument(_)));
    }

    #[test]
    fn boundary_comparison_is_case_insensitive() {
        assert!(
            ensure_within(
                Path::new(r"D:\APP\Root"),
                Path::new(r"d:\app\root\file.txt")
            )
            .is_ok()
        );
        assert!(
            ensure_within(
                Path::new(r"D:\APP\Root"),
                Path::new(r"D:\APP\Root2\file.txt")
            )
            .is_err()
        );
    }
}
