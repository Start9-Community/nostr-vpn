use anyhow::{Context, Result, anyhow};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WindowsInterfaceAddress {
    pub address: Ipv4Addr,
    pub mask: Ipv4Addr,
}

pub(crate) fn windows_interface_address(address: &str) -> Result<WindowsInterfaceAddress> {
    let (ip, prefix_len) = address
        .trim()
        .split_once('/')
        .ok_or_else(|| anyhow!("windows interface address must be IPv4 CIDR"))?;
    let address = ip
        .parse::<Ipv4Addr>()
        .with_context(|| format!("invalid IPv4 interface address {ip}"))?;
    let prefix_len = prefix_len
        .parse::<u8>()
        .with_context(|| format!("invalid IPv4 prefix length {prefix_len}"))?;
    if prefix_len > 32 {
        return Err(anyhow!("invalid IPv4 prefix length {prefix_len}"));
    }

    Ok(WindowsInterfaceAddress {
        address,
        mask: ipv4_netmask(prefix_len),
    })
}

fn ipv4_netmask(prefix_len: u8) -> Ipv4Addr {
    if prefix_len == 0 {
        return Ipv4Addr::UNSPECIFIED;
    }

    Ipv4Addr::from(u32::MAX << (32 - prefix_len))
}

#[cfg(any(target_os = "windows", test))]
use std::net::Ipv4Addr;
#[cfg(target_os = "windows")]
use std::sync::Arc;
#[cfg(target_os = "windows")]
use wintun::Session;

#[cfg(target_os = "windows")]
pub(crate) fn write_tunnel_packet_slices<'a, I>(session: &Arc<Session>, packets: I) -> Result<()>
where
    I: IntoIterator<Item = &'a [u8]>,
{
    for packet in packets {
        let size = u16::try_from(packet.len())
            .map_err(|_| anyhow!("tunnel packet too large for wintun: {}", packet.len()))?;
        let mut outbound = session
            .allocate_send_packet(size)
            .context("failed to allocate packet for wintun session")?;
        outbound.bytes_mut().copy_from_slice(packet);
        session.send_packet(outbound);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use super::{WindowsInterfaceAddress, windows_interface_address};

    #[test]
    fn parses_windows_interface_address_from_cidr() {
        assert_eq!(
            windows_interface_address("10.44.0.7/24").expect("parsed address"),
            WindowsInterfaceAddress {
                address: Ipv4Addr::new(10, 44, 0, 7),
                mask: Ipv4Addr::new(255, 255, 255, 0),
            }
        );
        assert_eq!(
            windows_interface_address("10.44.0.7/32").expect("parsed address"),
            WindowsInterfaceAddress {
                address: Ipv4Addr::new(10, 44, 0, 7),
                mask: Ipv4Addr::new(255, 255, 255, 255),
            }
        );
    }

    #[test]
    fn rejects_non_ipv4_windows_interface_address() {
        assert!(windows_interface_address("fd00::7/64").is_err());
        assert!(windows_interface_address("10.44.0.7").is_err());
    }
}
