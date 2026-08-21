use std::collections::HashMap;

use mdns_sd::{ServiceDaemon, ServiceInfo};

use crate::error::{AgentError, AgentResult};

pub struct DiscoveryService {
    daemon: ServiceDaemon,
    fullname: String,
}

impl DiscoveryService {
    pub fn start(port: u16) -> AgentResult<Self> {
        let daemon = ServiceDaemon::new()
            .map_err(|error| AgentError::Internal(format!("mDNS 启动失败: {error}")))?;
        let hostname = std::env::var("COMPUTERNAME")
            .unwrap_or_else(|_| "windows-agent".to_owned())
            .replace(['.', ' '], "-");
        let host_fqdn = format!("{hostname}.local.");
        let mut properties = HashMap::new();
        properties.insert("path".to_owned(), "/mcp".to_owned());
        properties.insert("protocol".to_owned(), "mcp-streamable-http".to_owned());
        properties.insert("version".to_owned(), env!("CARGO_PKG_VERSION").to_owned());
        let service = ServiceInfo::new(
            "_meno-agent._tcp.local.",
            "Windows Agent",
            &host_fqdn,
            "",
            port,
            Some(properties),
        )
        .map_err(|error| AgentError::Internal(format!("mDNS 服务信息无效: {error}")))?
        .enable_addr_auto();
        let fullname = service.get_fullname().to_owned();
        daemon
            .register(service)
            .map_err(|error| AgentError::Internal(format!("mDNS 发布失败: {error}")))?;
        Ok(Self { daemon, fullname })
    }
}

impl Drop for DiscoveryService {
    fn drop(&mut self) {
        let _ = self.daemon.unregister(&self.fullname);
        let _ = self.daemon.shutdown();
    }
}
