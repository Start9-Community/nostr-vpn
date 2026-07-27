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

pub(crate) fn windows_add_route_args(
    prefix: &str,
    interface_index: u32,
    next_hop: Option<&str>,
) -> Result<Vec<String>> {
    validate_windows_route_prefix(prefix)?;
    let mut args = vec![
        "interface".to_string(),
        "ipv4".to_string(),
        "add".to_string(),
        "route".to_string(),
        prefix.trim().to_string(),
        format!("interface={interface_index}"),
    ];
    if let Some(next_hop) = next_hop {
        let next_hop = next_hop
            .trim()
            .parse::<Ipv4Addr>()
            .with_context(|| format!("invalid windows route next hop {next_hop}"))?;
        args.push(format!("nexthop={next_hop}"));
    }
    args.extend(["metric=1".to_string(), "store=active".to_string()]);
    Ok(args)
}

pub(crate) fn windows_delete_route_args(prefix: &str, interface_index: u32) -> Result<Vec<String>> {
    validate_windows_route_prefix(prefix)?;
    Ok(vec![
        "interface".to_string(),
        "ipv4".to_string(),
        "delete".to_string(),
        "route".to_string(),
        prefix.trim().to_string(),
        format!("interface={interface_index}"),
        "store=active".to_string(),
    ])
}

fn validate_windows_route_prefix(prefix: &str) -> Result<()> {
    let trimmed = prefix.trim();
    let (ip, prefix_len) = trimmed
        .split_once('/')
        .ok_or_else(|| anyhow!("windows route prefix must be IPv4 CIDR"))?;
    ip.parse::<Ipv4Addr>()
        .with_context(|| format!("invalid windows route IPv4 prefix {ip}"))?;
    let prefix_len = prefix_len
        .parse::<u8>()
        .with_context(|| format!("invalid windows route prefix length {prefix_len}"))?;
    if prefix_len > 32 {
        return Err(anyhow!("invalid windows route prefix length {prefix_len}"));
    }
    Ok(())
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
use std::process::Command as ProcessCommand;
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

#[cfg(target_os = "windows")]
pub(crate) fn apply_windows_routes(
    interface_index: u32,
    route_targets: &[String],
) -> Result<Vec<String>> {
    apply_windows_routes_with_next_hop(interface_index, route_targets, None)
}

#[cfg(target_os = "windows")]
fn apply_windows_routes_with_next_hop(
    interface_index: u32,
    route_targets: &[String],
    next_hop: Option<&str>,
) -> Result<Vec<String>> {
    let mut applied = Vec::new();
    for route_target in route_targets {
        let args = windows_add_route_args(route_target, interface_index, next_hop)?;
        if let Err(error) = run_windows_netsh(&args) {
            let _ = remove_windows_routes(interface_index, &applied);
            return Err(error);
        }
        applied.push(route_target.clone());
    }
    Ok(applied)
}

#[cfg(target_os = "windows")]
pub(crate) fn remove_windows_routes(interface_index: u32, route_targets: &[String]) -> Result<()> {
    let mut first_error = None;
    for route_target in route_targets {
        let args = windows_delete_route_args(route_target, interface_index)?;
        if let Err(error) = run_windows_netsh(&args)
            && first_error.is_none()
        {
            first_error = Some(error);
        }
    }
    if let Some(error) = first_error {
        return Err(error);
    }
    Ok(())
}

#[cfg(target_os = "windows")]
fn run_windows_netsh(args: &[String]) -> Result<()> {
    let display = format!("netsh {}", args.join(" "));
    let output = ProcessCommand::new("netsh")
        .args(args)
        .output()
        .with_context(|| format!("failed to execute {display}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        return Err(anyhow!(
            "command failed: {display}\nstdout: {}\nstderr: {}",
            stdout.trim(),
            stderr.trim()
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use super::{
        WindowsInterfaceAddress, windows_add_route_args, windows_delete_route_args,
        windows_interface_address,
    };

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

    #[test]
    fn builds_windows_route_add_arguments() {
        assert_eq!(
            windows_add_route_args("10.44.0.0/16", 7, None).expect("add args"),
            vec![
                "interface".to_string(),
                "ipv4".to_string(),
                "add".to_string(),
                "route".to_string(),
                "10.44.0.0/16".to_string(),
                "interface=7".to_string(),
                "metric=1".to_string(),
                "store=active".to_string(),
            ]
        );
    }

    #[test]
    fn builds_windows_route_via_arguments() {
        assert_eq!(
            windows_add_route_args("203.0.113.7/32", 9, Some("192.0.2.1")).expect("add via args"),
            vec![
                "interface".to_string(),
                "ipv4".to_string(),
                "add".to_string(),
                "route".to_string(),
                "203.0.113.7/32".to_string(),
                "interface=9".to_string(),
                "nexthop=192.0.2.1".to_string(),
                "metric=1".to_string(),
                "store=active".to_string(),
            ]
        );
    }

    #[test]
    fn builds_windows_route_delete_arguments() {
        assert_eq!(
            windows_delete_route_args("10.44.0.0/16", 7).expect("delete args"),
            vec![
                "interface".to_string(),
                "ipv4".to_string(),
                "delete".to_string(),
                "route".to_string(),
                "10.44.0.0/16".to_string(),
                "interface=7".to_string(),
                "store=active".to_string(),
            ]
        );
    }
}
