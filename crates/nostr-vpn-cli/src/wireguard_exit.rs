#[path = "wireguard_exit/linux_runtime.rs"]
mod linux_runtime;

use std::net::{IpAddr, Ipv4Addr, ToSocketAddrs};

use anyhow::{Result, anyhow};
use nostr_vpn_core::config::WireGuardExitConfig;

pub(crate) use linux_runtime::{
    LinuxWireGuardExitCleanupObligation, LinuxWireGuardExitRuntime,
    apply_linux_wireguard_exit_upstream, cleanup_linux_wireguard_exit_obligation,
    cleanup_linux_wireguard_exit_upstream,
};

pub(crate) fn validate_linux_wireguard_exit_config(config: &WireGuardExitConfig) -> Result<String> {
    if !config.enabled {
        return Err(anyhow!("WireGuard exit upstream is disabled"));
    }
    let iface = config.interface.trim();
    if !linux_iface_name_is_safe(iface) {
        return Err(anyhow!("invalid WireGuard exit interface '{iface}'"));
    }
    if config.address.trim().is_empty() {
        return Err(anyhow!(
            "WireGuard exit upstream is missing a tunnel address"
        ));
    }
    if config.private_key.trim().is_empty() {
        return Err(anyhow!("WireGuard exit upstream is missing a private key"));
    }
    if config.peer_public_key.trim().is_empty() {
        return Err(anyhow!(
            "WireGuard exit upstream is missing a peer public key"
        ));
    }
    if config.endpoint.trim().is_empty() {
        return Err(anyhow!(
            "WireGuard exit upstream is missing a peer endpoint"
        ));
    }
    if !config.allowed_ips.iter().any(|route| route == "0.0.0.0/0") {
        return Err(anyhow!(
            "WireGuard exit upstream allowed IPs must include 0.0.0.0/0"
        ));
    }
    Ok(iface.to_string())
}

pub(crate) fn linux_wireguard_exit_ipv6_default(config: &WireGuardExitConfig) -> bool {
    config.allowed_ips.iter().any(|route| route == "::/0")
        && config
            .address
            .split('/')
            .next()
            .is_some_and(|ip| ip.contains(':'))
}

fn validated_linux_wireguard_underlay_default_route(
    route: &str,
    wireguard_iface: &str,
) -> Option<String> {
    let mut lines = route.lines().map(str::trim).filter(|line| !line.is_empty());
    let line = lines.next()?;
    if lines.next().is_some() || line.split_whitespace().next() != Some("default") {
        return None;
    }
    let spec = crate::linux_route_get_spec_from_output(line)?;
    if spec.dev == wireguard_iface {
        return None;
    }
    Some(line.to_string())
}

pub(crate) fn select_linux_wireguard_underlay_default_route(
    fresh_hint: Option<&str>,
    previous_runtime_route: Option<&str>,
    current_route: Option<&str>,
    wireguard_iface: &str,
) -> Option<String> {
    [fresh_hint, previous_runtime_route, current_route]
        .into_iter()
        .flatten()
        .find_map(|route| validated_linux_wireguard_underlay_default_route(route, wireguard_iface))
}

pub(super) fn wireguard_exit_endpoint_ipv4_hosts(endpoint: &str) -> Vec<Ipv4Addr> {
    let Some((host, port)) = crate::split_host_port(endpoint, 51820) else {
        return Vec::new();
    };
    if let Ok(ip) = host.parse::<Ipv4Addr>() {
        return vec![ip];
    }
    if host.parse::<IpAddr>().is_ok() {
        return Vec::new();
    }

    let mut hosts = (host.as_str(), port)
        .to_socket_addrs()
        .map(|addrs| {
            addrs
                .filter_map(|addr| match addr.ip() {
                    IpAddr::V4(ip) => Some(ip),
                    IpAddr::V6(_) => None,
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    hosts.sort_unstable();
    hosts.dedup();
    hosts
}

fn linux_iface_name_is_safe(iface: &str) -> bool {
    !iface.is_empty()
        && iface.len() <= 15
        && iface
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use super::{
        select_linux_wireguard_underlay_default_route, wireguard_exit_endpoint_ipv4_hosts,
    };

    #[test]
    fn endpoint_bypass_hosts_parse_ipv4_endpoint() {
        assert_eq!(
            wireguard_exit_endpoint_ipv4_hosts("198.51.100.20:51830"),
            vec!["198.51.100.20".parse::<Ipv4Addr>().unwrap()]
        );
    }

    #[test]
    fn fresh_underlay_hint_replaces_stale_wireguard_runtime_route() {
        let old = "default via 192.0.2.1 dev enp1s0 src 192.0.2.10 metric 100";
        let fresh = "default via 198.51.100.1 dev enp7s0 src 198.51.100.10 metric 600";
        let selected = select_linux_wireguard_underlay_default_route(
            Some(fresh),
            Some(old),
            Some("default dev nvwg0 src 10.200.0.2"),
            "nvwg0",
        )
        .expect("fresh physical default");
        assert_eq!(selected, fresh);

        let bypass = crate::linux_endpoint_bypass_route_from_output(
            "203.0.113.9".parse().expect("host"),
            "203.0.113.9 via 192.0.2.1 dev enp1s0 src 192.0.2.10",
            "nvwg0",
            Some(&selected),
        )
        .expect("fresh WireGuard endpoint bypass");
        assert_eq!(bypass.dev, "enp7s0");
        assert_eq!(bypass.gateway.as_deref(), Some("198.51.100.1"));
        assert_eq!(bypass.src.as_deref(), Some("198.51.100.10"));
    }

    #[test]
    fn rejects_tunnel_and_malformed_default_route_hints() {
        assert_eq!(
            select_linux_wireguard_underlay_default_route(
                Some("default dev nvwg0"),
                Some("not-default via 192.0.2.1 dev enp1s0"),
                Some("default via 192.0.2.1 dev enp1s0"),
                "nvwg0",
            )
            .as_deref(),
            Some("default via 192.0.2.1 dev enp1s0")
        );
    }
}
