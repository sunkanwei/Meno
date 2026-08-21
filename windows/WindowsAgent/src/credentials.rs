use std::ptr;

use windows::{
    Win32::Security::Credentials::{
        CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC, CREDENTIALW, CredFree, CredReadW, CredWriteW,
    },
    core::{HSTRING, PWSTR},
};

use crate::error::{AgentError, AgentResult};

pub fn write(target: &str, secret: &str) -> AgentResult<()> {
    if secret.is_empty() || secret.len() > 5 * 512 {
        return Err(AgentError::InvalidArgument("凭据长度无效".to_owned()));
    }
    let mut target = target.encode_utf16().collect::<Vec<_>>();
    target.push(0);
    let mut username = "Windows Agent".encode_utf16().collect::<Vec<_>>();
    username.push(0);
    let mut blob = secret.as_bytes().to_vec();
    let credential = CREDENTIALW {
        Type: CRED_TYPE_GENERIC,
        TargetName: PWSTR(target.as_mut_ptr()),
        CredentialBlobSize: blob.len() as u32,
        CredentialBlob: blob.as_mut_ptr(),
        Persist: CRED_PERSIST_LOCAL_MACHINE,
        UserName: PWSTR(username.as_mut_ptr()),
        ..Default::default()
    };
    unsafe { CredWriteW(&credential, 0) }
        .map_err(|error| AgentError::Internal(format!("写入 Windows 凭据失败: {error}")))
}

pub fn read(target: &str) -> AgentResult<String> {
    let target = HSTRING::from(target);
    let mut credential = ptr::null_mut();
    unsafe { CredReadW(&target, CRED_TYPE_GENERIC, None, &mut credential) }
        .map_err(|_| AgentError::NotFound("Windows 凭据不存在".to_owned()))?;
    if credential.is_null() {
        return Err(AgentError::NotFound("Windows 凭据不存在".to_owned()));
    }
    let value = unsafe {
        let credential_ref = &*credential;
        let bytes = std::slice::from_raw_parts(
            credential_ref.CredentialBlob,
            credential_ref.CredentialBlobSize as usize,
        );
        String::from_utf8(bytes.to_vec())
    };
    unsafe { CredFree(credential.cast()) };
    value.map_err(|_| AgentError::Internal("Windows 凭据不是 UTF-8".to_owned()))
}
