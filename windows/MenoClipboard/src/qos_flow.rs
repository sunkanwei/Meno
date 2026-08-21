use std::net::TcpStream;
use std::os::windows::io::AsRawSocket;

use windows::Win32::Foundation::HANDLE;
use windows::Win32::NetworkManagement::QoS::{
    QOS_NON_ADAPTIVE_FLOW, QOS_VERSION, QOSAddSocketToFlow, QOSCloseHandle, QOSCreateHandle,
    QOSRemoveSocketFromFlow, QOSTrafficTypeControl,
};
use windows::Win32::Networking::WinSock::{
    AF_INET, IN_ADDR, IN_ADDR_0, SOCKADDR, SOCKADDR_IN, SOCKET,
};

pub(crate) struct QosFlow {
    handle: HANDLE,
    flow_id: u32,
}

impl QosFlow {
    pub(crate) fn establish(stream: &TcpStream) -> Option<Self> {
        let peer = match stream.peer_addr() {
            Ok(peer) => peer,
            Err(_) => return None,
        };
        let std::net::SocketAddr::V4(peer) = peer else {
            return None;
        };
        let mut handle = HANDLE::default();
        let mut version = QOS_VERSION {
            MajorVersion: 1,
            MinorVersion: 0,
        };
        if unsafe { QOSCreateHandle(&raw mut version, &raw mut handle) } == false {
            return None;
        }
        let address = SOCKADDR_IN {
            sin_family: AF_INET,
            sin_port: peer.port().to_be(),
            sin_addr: IN_ADDR {
                S_un: IN_ADDR_0 {
                    S_addr: u32::from_ne_bytes(peer.ip().octets()),
                },
            },
            sin_zero: [0; 8],
        };
        let mut flow_id = 0_u32;
        let added = unsafe {
            QOSAddSocketToFlow(
                handle,
                SOCKET(stream.as_raw_socket() as usize),
                Some((&raw const address).cast::<SOCKADDR>()),
                QOSTrafficTypeControl,
                Some(QOS_NON_ADAPTIVE_FLOW),
                &raw mut flow_id,
            )
        };
        if added == false {
            let _ = unsafe { QOSCloseHandle(handle) };
            return None;
        }
        Some(Self { handle, flow_id })
    }
}

impl Drop for QosFlow {
    fn drop(&mut self) {
        unsafe {
            let _ = QOSRemoveSocketFromFlow(self.handle, None, self.flow_id, None);
            let _ = QOSCloseHandle(self.handle);
        }
    }
}
