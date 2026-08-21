use std::{fs, path::PathBuf, time::Duration};

use crate::{config::DataPaths, error::AgentResult, task_types::TaskRecord};

pub struct TaskStore {
    directory: PathBuf,
}

impl TaskStore {
    pub fn new(paths: &DataPaths) -> Self {
        Self {
            directory: paths.tasks_dir.clone(),
        }
    }

    pub fn persist(&self, task: &TaskRecord) -> AgentResult<()> {
        let path = self.directory.join(format!("{}.json", task.id));
        let temporary = path.with_extension("json.tmp");
        fs::write(&temporary, serde_json::to_vec_pretty(task)?)?;
        fs::rename(temporary, path)?;
        Ok(())
    }

    pub fn load(&self, retention: Duration) -> AgentResult<Vec<TaskRecord>> {
        let mut tasks = Vec::new();
        for entry in fs::read_dir(&self.directory)? {
            let Ok(entry) = entry else { continue };
            if entry.path().extension().and_then(|value| value.to_str()) != Some("json") {
                continue;
            }
            let old = entry
                .metadata()
                .and_then(|metadata| metadata.modified())
                .ok()
                .and_then(|modified| modified.elapsed().ok())
                .is_some_and(|age| age > retention);
            if old {
                let _ = fs::remove_file(entry.path());
                continue;
            }
            let Ok(bytes) = fs::read(entry.path()) else {
                continue;
            };
            if let Ok(task) = serde_json::from_slice(&bytes) {
                tasks.push(task);
            }
        }
        Ok(tasks)
    }
}
