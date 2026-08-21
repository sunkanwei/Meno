use windows::Win32::{
    Foundation::{CloseHandle, HANDLE},
    System::{
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
            SetInformationJobObject,
        },
        Threading::{OpenProcess, PROCESS_SET_QUOTA, PROCESS_TERMINATE},
    },
};

use crate::error::{AgentError, AgentResult};

pub struct ProcessJob(HANDLE);

unsafe impl Send for ProcessJob {}
unsafe impl Sync for ProcessJob {}

impl ProcessJob {
    pub fn assign(pid: u32) -> AgentResult<Self> {
        unsafe {
            let job = CreateJobObjectW(None, None).map_err(win_error)?;
            let mut information = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            information.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if let Err(error) = SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &information as *const _ as *const _,
                std::mem::size_of_val(&information) as u32,
            ) {
                let _ = CloseHandle(job);
                return Err(win_error(error));
            }
            let process = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, false, pid)
                .map_err(win_error)?;
            let assigned = AssignProcessToJobObject(job, process);
            let _ = CloseHandle(process);
            if let Err(error) = assigned {
                let _ = CloseHandle(job);
                return Err(win_error(error));
            }
            Ok(Self(job))
        }
    }
}

impl Drop for ProcessJob {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

fn win_error(error: windows::core::Error) -> AgentError {
    AgentError::Internal(format!("Windows Job Object 失败: {error}"))
}
