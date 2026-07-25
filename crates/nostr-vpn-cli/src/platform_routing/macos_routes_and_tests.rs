#[cfg(target_os = "macos")]
fn split_cidr<'a>(address: &'a str, default_prefix: &'a str) -> (&'a str, &'a str) {
    address.split_once('/').unwrap_or((address, default_prefix))
}

#[cfg(target_os = "linux")]
pub(crate) fn linux_ipv4_route_source(address: &str) -> Option<String> {
    strip_cidr(address)
        .parse::<Ipv4Addr>()
        .ok()
        .map(|ip| ip.to_string())
}

#[cfg(any(target_os = "linux", test))]
fn linux_route_replace_args(
    target: &str,
    iface: &str,
    ipv4_route_source: Option<&str>,
) -> Vec<String> {
    let mut args = Vec::new();
    if linux_route_target_is_ipv6(target) {
        args.push("-6".to_string());
    } else if linux_route_target_is_ipv4(target) {
        args.push("-4".to_string());
    }
    args.extend([
        "route".to_string(),
        "replace".to_string(),
        target.to_string(),
        "dev".to_string(),
        iface.to_string(),
    ]);
    if linux_route_target_is_ipv4(target)
        && let Some(source) = ipv4_route_source
    {
        args.push("src".to_string());
        args.push(source.to_string());
    }
    args
}

#[cfg(any(target_os = "linux", target_os = "macos", test))]
pub(crate) fn linux_tunnel_address_is_ipv4(address: &str) -> bool {
    strip_cidr(address).parse::<Ipv4Addr>().is_ok()
}

#[cfg(any(target_os = "linux", target_os = "macos", test))]
pub(crate) fn linux_tunnel_address_is_ipv6(address: &str) -> bool {
    strip_cidr(address).parse::<Ipv6Addr>().is_ok()
}

#[cfg(any(target_os = "linux", test))]
pub(crate) fn linux_route_target_is_ipv4(target: &str) -> bool {
    strip_cidr(target).parse::<Ipv4Addr>().is_ok()
}

#[cfg(any(target_os = "linux", target_os = "macos", test))]
pub(crate) fn linux_route_target_is_ipv6(target: &str) -> bool {
    strip_cidr(target).parse::<Ipv6Addr>().is_ok()
}

#[cfg(target_os = "macos")]
fn apply_macos_route(iface: &str, target: &str) -> Result<()> {
    if linux_route_target_is_ipv6(target) {
        let (target_ip, prefix) = split_cidr(target, "128");
        let _ = ProcessCommand::new("route")
            .arg("delete")
            .arg("-inet6")
            .arg("-prefixlen")
            .arg(prefix)
            .arg(target_ip)
            .arg("-interface")
            .arg(iface)
            .status();
        return run_checked(
            ProcessCommand::new("route")
                .arg("add")
                .arg("-inet6")
                .arg("-prefixlen")
                .arg(prefix)
                .arg(target_ip)
                .arg("-interface")
                .arg(iface),
        );
    }
    if target == "0.0.0.0/0" {
        eprintln!("tunnel: applying macOS default route via interface {iface}");
        return apply_macos_default_route(None, Some(iface));
    }
    apply_macos_route_spec(target, None, Some(iface))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linux_route_family_helpers_detect_ipv4_and_ipv6_cidrs() {
        assert!(linux_tunnel_address_is_ipv4("10.44.0.1/32"));
        assert!(!linux_tunnel_address_is_ipv6("10.44.0.1/32"));
        assert!(linux_tunnel_address_is_ipv6("fd00::1/128"));
        assert!(!linux_tunnel_address_is_ipv4("fd00::1/128"));
        assert!(linux_route_target_is_ipv4("0.0.0.0/0"));
        assert!(!linux_route_target_is_ipv4("::/0"));
        assert!(linux_route_target_is_ipv6("::/0"));
        assert!(!linux_route_target_is_ipv6("10.44.0.0/16"));
    }

    #[test]
    fn linux_route_replace_args_selects_address_family() {
        assert_eq!(
            linux_route_replace_args("fd00::/8", "utun100", Some("10.44.0.1")),
            vec!["-6", "route", "replace", "fd00::/8", "dev", "utun100"]
        );
        assert_eq!(
            linux_route_replace_args("10.44.0.2/32", "utun100", Some("10.44.0.1")),
            vec![
                "-4",
                "route",
                "replace",
                "10.44.0.2/32",
                "dev",
                "utun100",
                "src",
                "10.44.0.1"
            ]
        );
    }

    #[test]
    fn wireguard_upstream_inbound_drop_rule_blocks_new_mesh_forwards() {
        assert_eq!(
            linux_wireguard_exit_inbound_drop_rule("nvpn-wg-exit", "nvpn0", "10.44.0.0/16"),
            vec![
                "FORWARD",
                "-i",
                "nvpn-wg-exit",
                "-o",
                "nvpn0",
                "-d",
                "10.44.0.0/16",
                "-m",
                "conntrack",
                "--ctstate",
                "NEW,INVALID",
                "-m",
                "comment",
                "--comment",
                "nvpn-wg-upstream-inbound-drop",
                "-j",
                "DROP",
            ]
        );
    }

    #[test]
    fn exit_node_forward_rules_are_scoped_to_mesh_source_and_outbound_iface() {
        assert_eq!(
            linux_exit_node_forward_in_rule(
                "utun100",
                "enp41s0",
                "10.44.0.0/16",
                LinuxExitNodeIpFamily::V4
            ),
            vec![
                "FORWARD",
                "-i",
                "utun100",
                "-o",
                "enp41s0",
                "-s",
                "10.44.0.0/16",
                "-m",
                "comment",
                "--comment",
                "nvpn-exit-forward-in",
                "-j",
                "ACCEPT",
            ]
        );
        assert_eq!(
            linux_exit_node_forward_out_rule("utun100", "enp41s0", LinuxExitNodeIpFamily::V4),
            vec![
                "FORWARD",
                "-i",
                "enp41s0",
                "-o",
                "utun100",
                "-m",
                "conntrack",
                "--ctstate",
                "RELATED,ESTABLISHED",
                "-m",
                "comment",
                "--comment",
                "nvpn-exit-forward-out",
                "-j",
                "ACCEPT",
            ]
        );
        assert_eq!(
            linux_exit_node_ipv4_mss_clamp_rule("utun100", "enp41s0", "10.44.0.0/16", 1110),
            vec![
                "FORWARD",
                "-i",
                "utun100",
                "-o",
                "enp41s0",
                "-s",
                "10.44.0.0/16",
                "-p",
                "tcp",
                "--tcp-flags",
                "SYN,RST",
                "SYN",
                "-m",
                "comment",
                "--comment",
                "nvpn-exit-mss",
                "-j",
                "TCPMSS",
                "--set-mss",
                "1110",
            ]
        );
    }

    #[test]
    fn legacy_exit_node_forward_rules_match_old_unscoped_rules_for_cleanup() {
        assert_eq!(
            linux_exit_node_legacy_forward_in_rule("utun100", LinuxExitNodeIpFamily::V6),
            vec![
                "FORWARD",
                "-i",
                "utun100",
                "-m",
                "comment",
                "--comment",
                "nvpn-exit6-forward-in",
                "-j",
                "ACCEPT",
            ]
        );
        assert_eq!(
            linux_exit_node_legacy_forward_out_rule("utun100", LinuxExitNodeIpFamily::V6),
            vec![
                "FORWARD",
                "-o",
                "utun100",
                "-m",
                "conntrack",
                "--ctstate",
                "RELATED,ESTABLISHED",
                "-m",
                "comment",
                "--comment",
                "nvpn-exit6-forward-out",
                "-j",
                "ACCEPT",
            ]
        );
    }
}
