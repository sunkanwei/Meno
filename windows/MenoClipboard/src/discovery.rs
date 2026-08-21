use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, UdpSocket};
use std::thread;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{ERROR_BUFFER_OVERFLOW, NO_ERROR};
use windows::Win32::NetworkManagement::IpHelper::{
    GAA_FLAG_SKIP_ANYCAST, GAA_FLAG_SKIP_DNS_SERVER, GAA_FLAG_SKIP_FRIENDLY_NAME,
    GAA_FLAG_SKIP_MULTICAST, GetAdaptersAddresses, IF_TYPE_ETHERNET_CSMACD, IF_TYPE_IEEE80211,
    IP_ADAPTER_ADDRESSES_LH,
};
use windows::Win32::NetworkManagement::Ndis::IfOperStatusUp;
use windows::Win32::Networking::WinSock::{AF_INET, SOCKADDR_IN};

use crate::protocol::{DISCOVERY_PORT, DiscoveryOffer, discovery_packet, parse_offer};

const DISCOVERY_DEADLINE: Duration = Duration::from_millis(300);
const DISCOVERY_POLL: Duration = Duration::from_millis(5);
const MAX_CANDIDATES: usize = 16;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DiscoveredCompanion {
    pub address: Ipv4Addr,
    pub offer: DiscoveryOffer,
}

pub fn discover() -> Result<Vec<DiscoveredCompanion>, String> {
    let mut sockets = Vec::new();
    let mut last_error = None;
    for (local_address, broadcast_address) in physical_broadcasts()? {
        let socket = match UdpSocket::bind(SocketAddrV4::new(local_address, 0)) {
            Ok(socket) => socket,
            Err(error) => {
                last_error = Some(error.to_string());
                continue;
            }
        };
        if let Err(error) = socket.set_broadcast(true) {
            last_error = Some(error.to_string());
            continue;
        }
        if let Err(error) = socket.set_nonblocking(true) {
            last_error = Some(error.to_string());
            continue;
        }
        let target = SocketAddrV4::new(broadcast_address, DISCOVERY_PORT);
        if let Err(error) = socket.send_to(&discovery_packet(1, 0, 0), target) {
            last_error = Some(error.to_string());
            continue;
        }
        sockets.push(socket);
    }
    if sockets.is_empty() {
        return match last_error {
            Some(error) => Err(error),
            None => Ok(Vec::new()),
        };
    }

    let deadline = Instant::now() + DISCOVERY_DEADLINE;
    let mut companions = Vec::new();
    let mut packet = [0_u8; 64];
    while Instant::now() < deadline && companions.len() < MAX_CANDIDATES {
        let mut received = false;
        for socket in &sockets {
            loop {
                match socket.recv_from(&mut packet) {
                    Ok((length, SocketAddr::V4(source))) => {
                        received = true;
                        let Some(offer) = parse_offer(&packet[..length]) else {
                            continue;
                        };
                        let companion = DiscoveredCompanion {
                            address: *source.ip(),
                            offer,
                        };
                        if !companions.contains(&companion) {
                            companions.push(companion);
                            if companions.len() == MAX_CANDIDATES {
                                break;
                            }
                        }
                    }
                    Ok(_) => continue,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                    Err(error) => {
                        crate::logging::debug(&format!("discovery receive failed: {error}"));
                        break;
                    }
                }
            }
        }
        if !received {
            thread::sleep(DISCOVERY_POLL.min(deadline.saturating_duration_since(Instant::now())));
        }
    }
    companions.sort_unstable_by_key(|candidate| {
        (
            u32::from(candidate.address),
            candidate.offer.clipboard_port,
            candidate.offer.mouse_port,
        )
    });
    Ok(companions)
}

fn physical_broadcasts() -> Result<Vec<(Ipv4Addr, Ipv4Addr)>, String> {
    let flags = GAA_FLAG_SKIP_ANYCAST
        | GAA_FLAG_SKIP_MULTICAST
        | GAA_FLAG_SKIP_DNS_SERVER
        | GAA_FLAG_SKIP_FRIENDLY_NAME;
    let mut size = 0_u32;
    let first_result =
        unsafe { GetAdaptersAddresses(AF_INET.0 as u32, flags, None, None, &mut size) };
    if first_result != ERROR_BUFFER_OVERFLOW.0 {
        return Err(format!("GetAdaptersAddresses size failed: {first_result}"));
    }
    let words = (size as usize).div_ceil(std::mem::size_of::<u64>());
    let mut buffer = vec![0_u64; words];
    let first = buffer.as_mut_ptr().cast::<IP_ADAPTER_ADDRESSES_LH>();
    let result =
        unsafe { GetAdaptersAddresses(AF_INET.0 as u32, flags, None, Some(first), &mut size) };
    if result != NO_ERROR.0 {
        return Err(format!("GetAdaptersAddresses failed: {result}"));
    }

    let mut addresses = Vec::new();
    let mut adapter = first;
    while !adapter.is_null() {
        let info = unsafe { &*adapter };
        if info.OperStatus == IfOperStatusUp
            && matches!(info.IfType, IF_TYPE_ETHERNET_CSMACD | IF_TYPE_IEEE80211)
        {
            let mut unicast = info.FirstUnicastAddress;
            while !unicast.is_null() {
                let item = unsafe { &*unicast };
                if let Some(ip) = socket_ipv4(&item.Address)
                    && !ip.is_loopback()
                    && !ip.is_unspecified()
                    && let Some(broadcast) = broadcast_address(ip, item.OnLinkPrefixLength)
                {
                    addresses.push((ip, broadcast));
                }
                unicast = item.Next;
            }
        }
        adapter = info.Next;
    }
    addresses.sort_unstable();
    addresses.dedup();
    Ok(addresses)
}

pub(crate) fn broadcast_address(ip: Ipv4Addr, prefix: u8) -> Option<Ipv4Addr> {
    if !(1..=31).contains(&prefix) {
        return None;
    }
    let prefix = u32::from(prefix);
    let mask = u32::MAX << (32 - prefix);
    Some(Ipv4Addr::from(u32::from(ip) | !mask))
}

fn socket_ipv4(address: &windows::Win32::Networking::WinSock::SOCKET_ADDRESS) -> Option<Ipv4Addr> {
    if address.lpSockaddr.is_null()
        || address.iSockaddrLength < std::mem::size_of::<SOCKADDR_IN>() as i32
    {
        return None;
    }
    let address = unsafe { &*address.lpSockaddr.cast::<SOCKADDR_IN>() };
    if address.sin_family != AF_INET {
        return None;
    }
    let octets = unsafe { address.sin_addr.S_un.S_un_b };
    Some(Ipv4Addr::new(
        octets.s_b1,
        octets.s_b2,
        octets.s_b3,
        octets.s_b4,
    ))
}
