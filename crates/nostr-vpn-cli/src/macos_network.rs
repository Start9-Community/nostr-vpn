use super::*;
#[cfg(target_os = "macos")]
use std::io::Write;
#[cfg(target_os = "macos")]
use std::{io, thread};
#[cfg(target_os = "macos")]
use tokio::sync::mpsc;

pub(super) fn macos_default_routes_from_netstat(output: &str) -> Vec<MacosRouteSpec> {
    let mut routes = Vec::new();

    for line in output.lines().map(str::trim) {
        let tokens = line.split_whitespace().collect::<Vec<_>>();
        if tokens.first().copied() != Some("default") || tokens.len() < 4 {
            continue;
        }

        let iface_index = if tokens.last().copied() == Some("!") {
            tokens.len().saturating_sub(2)
        } else {
            tokens.len().saturating_sub(1)
        };
        let Some(interface) = tokens.get(iface_index) else {
            continue;
        };

        routes.push(MacosRouteSpec {
            gateway: (!tokens[1].starts_with("link#")).then(|| tokens[1].to_string()),
            interface: (*interface).to_string(),
        });
    }

    routes
}

#[cfg(any(target_os = "macos", test))]
pub(crate) fn macos_selected_default_route_from_route_get(output: &str) -> Option<MacosRouteSpec> {
    let mut gateway = None;
    let mut interface = None;
    for line in output.lines().map(str::trim) {
        if let Some(value) = line.strip_prefix("gateway:") {
            let value = value.trim();
            if !value.is_empty() && !value.starts_with("link#") {
                gateway = Some(value.to_string());
            }
        } else if let Some(value) = line.strip_prefix("interface:") {
            let value = value.trim();
            if !value.is_empty() {
                interface = Some(value.to_string());
            }
        }
    }

    let interface = interface?;
    if gateway.is_none()
        || interface.starts_with("utun")
        || interface.starts_with("bridge")
        || interface == "lo0"
    {
        return None;
    }

    Some(MacosRouteSpec { gateway, interface })
}

#[cfg(target_os = "macos")]
pub(crate) fn macos_selected_default_route_from_system() -> Result<Option<MacosRouteSpec>> {
    let output = command_stdout_checked(
        ProcessCommand::new("route")
            .arg("-n")
            .arg("get")
            .arg("default"),
    )?;
    Ok(macos_selected_default_route_from_route_get(&output))
}

#[cfg(target_os = "macos")]
pub(crate) fn spawn_macos_route_change_monitor() -> Option<mpsc::Receiver<()>> {
    let fd = unsafe { libc::socket(libc::AF_ROUTE, libc::SOCK_RAW, libc::AF_UNSPEC) };
    if fd < 0 {
        eprintln!(
            "daemon: failed to open macOS route monitor socket: {}",
            io::Error::last_os_error()
        );
        return None;
    }

    let (tx, rx) = mpsc::channel(1);
    let spawn_result = thread::Builder::new()
        .name("nvpn-macos-route-monitor".to_string())
        .spawn(move || {
            let _fd = MacosRouteMonitorFd(fd);
            let mut buf = [0_u8; 8192];
            loop {
                let read = unsafe {
                    libc::read(
                        fd,
                        buf.as_mut_ptr().cast::<libc::c_void>(),
                        buf.len() as libc::size_t,
                    )
                };
                if read < 0 {
                    eprintln!(
                        "daemon: macOS route monitor read failed: {}",
                        io::Error::last_os_error()
                    );
                    break;
                }
                if read == 0 {
                    continue;
                }
                if !macos_route_message_is_underlay_relevant(&buf[..read as usize]) {
                    continue;
                }
                match tx.try_send(()) {
                    Ok(()) | Err(mpsc::error::TrySendError::Full(())) => {}
                    Err(mpsc::error::TrySendError::Closed(())) => break,
                }
            }
        });

    match spawn_result {
        Ok(_) => Some(rx),
        Err(error) => {
            unsafe {
                libc::close(fd);
            }
            eprintln!("daemon: failed to spawn macOS route monitor: {error}");
            None
        }
    }
}

#[cfg(target_os = "macos")]
struct MacosRouteMonitorFd(libc::c_int);

#[cfg(target_os = "macos")]
impl Drop for MacosRouteMonitorFd {
    fn drop(&mut self) {
        unsafe {
            libc::close(self.0);
        }
    }
}

#[cfg(any(target_os = "macos", test))]
pub(crate) fn macos_route_message_is_underlay_relevant(message: &[u8]) -> bool {
    let Some(message_type) = message.get(3).copied() else {
        return false;
    };
    // A handoff can be route-only: macOS may delete the old default route and
    // add the replacement without emitting a separate address or interface
    // notification. Include route add/delete/change so the daemon observes
    // that transition immediately. The debounced NetworkSnapshot comparison
    // below this monitor makes notifications caused by nvpn's own host-route
    // maintenance a no-op.
    matches!(message_type, 0x01 | 0x02 | 0x03 | 0x0c | 0x0d | 0x0e | 0x12)
}

pub(super) fn macos_underlay_default_route_from_routes(
    routes: &[MacosRouteSpec],
) -> Option<MacosRouteSpec> {
    macos_underlay_route_from_candidates(routes, None)
}

#[cfg(any(target_os = "macos", test))]
fn macos_underlay_route_from_candidates(
    routes: &[MacosRouteSpec],
    preferred_interface: Option<&str>,
) -> Option<MacosRouteSpec> {
    let is_physical = |route: &&MacosRouteSpec| {
        route.gateway.is_some()
            && !route.interface.starts_with("utun")
            && !route.interface.starts_with("bridge")
            && route.interface != "lo0"
    };
    preferred_interface
        .and_then(|preferred| {
            routes
                .iter()
                .filter(is_physical)
                .find(|route| route.interface == preferred)
        })
        .or_else(|| routes.iter().find(is_physical))
        .cloned()
}

#[cfg(any(target_os = "macos", test))]
pub(crate) fn macos_underlay_default_route_needs_restore(routes: &[MacosRouteSpec]) -> bool {
    macos_underlay_default_route_from_routes(routes).is_none()
}

#[cfg(any(target_os = "macos", test))]
pub(crate) fn macos_endpoint_bypass_targets_for_hosts(hosts: &[Ipv4Addr]) -> Vec<String> {
    let mut targets = hosts
        .iter()
        .map(|host| format!("{host}/32"))
        .collect::<Vec<_>>();
    targets.sort();
    targets.dedup();
    targets
}

#[cfg(any(target_os = "macos", test))]
pub(crate) fn macos_interface_names_from_ifconfig_list(output: &str) -> Vec<String> {
    output
        .split_whitespace()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

#[cfg(any(target_os = "macos", test))]
pub(crate) fn macos_ipconfig_router_from_output(output: &str) -> Option<Ipv4Addr> {
    for line in output.lines().map(str::trim) {
        let value = if let Some(value) = line.strip_prefix("router (ip):") {
            value.trim()
        } else if let Some(value) = line.strip_prefix("router (ip_mult):") {
            value.trim().trim_start_matches('{').trim_end_matches('}')
        } else {
            continue;
        };

        if let Ok(router) = value.parse::<Ipv4Addr>() {
            return Some(router);
        }
    }

    None
}

#[cfg(target_os = "macos")]
pub(crate) fn macos_ipconfig_ipv4_for_interface(iface: &str) -> Result<Option<Ipv4Addr>> {
    match command_stdout_checked(ProcessCommand::new("ipconfig").arg("getifaddr").arg(iface)) {
        Ok(output) => Ok(output.trim().parse::<Ipv4Addr>().ok()),
        Err(error) => {
            if error.to_string().to_ascii_lowercase().contains("not found") {
                Ok(None)
            } else {
                Err(error)
            }
        }
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn macos_ipconfig_router_for_interface(iface: &str) -> Result<Option<Ipv4Addr>> {
    if let Ok(output) = command_stdout_checked(
        ProcessCommand::new("ipconfig")
            .arg("getoption")
            .arg(iface)
            .arg("router"),
    ) && let Ok(router) = output.trim().parse::<Ipv4Addr>()
    {
        return Ok(Some(router));
    }

    let output =
        command_stdout_checked(ProcessCommand::new("ipconfig").arg("getpacket").arg(iface))?;
    Ok(macos_ipconfig_router_from_output(&output))
}

#[cfg(target_os = "macos")]
pub(crate) fn macos_underlay_default_route_from_system() -> Result<Option<MacosRouteSpec>> {
    macos_underlay_default_route_from_system_for_interface(None)
}

#[cfg(target_os = "macos")]
pub(crate) fn macos_underlay_default_route_from_system_for_interface(
    preferred_interface: Option<&str>,
) -> Result<Option<MacosRouteSpec>> {
    let output = command_stdout_checked(ProcessCommand::new("ifconfig").arg("-l"))?;
    let mut candidates = Vec::new();
    for iface in macos_interface_names_from_ifconfig_list(&output) {
        if iface.starts_with("utun")
            || iface.starts_with("bridge")
            || iface == "lo0"
            || iface == "gif0"
            || iface == "stf0"
            || iface.starts_with("anpi")
            || iface.starts_with("awdl")
            || iface.starts_with("llw")
        {
            continue;
        }

        let Ok(Some(_ipv4)) = macos_ipconfig_ipv4_for_interface(&iface) else {
            continue;
        };
        let Ok(Some(router)) = macos_ipconfig_router_for_interface(&iface) else {
            continue;
        };

        candidates.push(MacosRouteSpec {
            gateway: Some(router.to_string()),
            interface: iface,
        });
    }

    Ok(macos_underlay_route_from_candidates(
        &candidates,
        preferred_interface,
    ))
}

#[cfg(target_os = "macos")]
pub(crate) fn macos_tunnel_interfaces_with_ipv4(tunnel_ip: Ipv4Addr) -> Result<Vec<String>> {
    let output = command_stdout_checked(ProcessCommand::new("ifconfig").arg("-l"))?;
    let mut matches = Vec::new();
    for iface in macos_interface_names_from_ifconfig_list(&output) {
        if !iface.starts_with("utun") {
            continue;
        }
        if macos_iface_has_ipv4_address(&iface, tunnel_ip)? {
            matches.push(iface);
        }
    }
    Ok(matches)
}

#[cfg(target_os = "macos")]
pub(super) fn macos_default_routes() -> Result<Vec<MacosRouteSpec>> {
    let output = command_stdout_checked(
        ProcessCommand::new("netstat")
            .arg("-rn")
            .arg("-f")
            .arg("inet"),
    )?;
    Ok(macos_default_routes_from_netstat(&output))
}

#[cfg(target_os = "macos")]
pub(super) fn delete_macos_managed_route(
    target: &str,
    gateway: Option<&str>,
    interface: Option<&str>,
) -> Result<()> {
    if gateway.is_none()
        && let Some(iface) = interface
    {
        return delete_macos_direct_route_variants(target, iface);
    }

    delete_macos_route_spec(target, None)
}

#[cfg(target_os = "macos")]
pub(super) fn restore_macos_default_route(route: &MacosRouteSpec) -> Result<()> {
    apply_macos_default_route(route.gateway.as_deref(), Some(route.interface.as_str()))
}

#[cfg(any(target_os = "macos", test))]
fn macos_add_underlay_default_route_args(gateway: &str) -> Vec<String> {
    vec![
        "-n".to_string(),
        "add".to_string(),
        "default".to_string(),
        gateway.to_string(),
    ]
}

#[cfg(target_os = "macos")]
pub(crate) fn restore_macos_underlay_default_route_if_missing() -> Result<bool> {
    let routes = macos_default_routes()?;
    if !macos_underlay_default_route_needs_restore(&routes) {
        return Ok(false);
    }

    let route = macos_underlay_default_route_from_system()?
        .ok_or_else(|| anyhow!("no physical macOS underlay default route is available"))?;
    let gateway = route
        .gateway
        .as_deref()
        .ok_or_else(|| anyhow!("physical macOS underlay route has no gateway"))?;

    // A Network Extension may retain an interface-scoped default on its utun.
    // Add the physical default alongside it: changing `default` here could
    // mutate a foreign VPN route and leave that VPN in an inconsistent state.
    let mut command = ProcessCommand::new("route");
    command.args(macos_add_underlay_default_route_args(gateway));
    run_checked(&mut command).with_context(|| {
        format!(
            "failed to restore physical macOS default route via {} on {}",
            gateway, route.interface
        )
    })?;

    let restored = macos_default_routes()?;
    if macos_underlay_default_route_needs_restore(&restored) {
        return Err(anyhow!(
            "physical macOS default route via {} on {} was not installed",
            gateway,
            route.interface
        ));
    }

    eprintln!(
        "tunnel: restored missing macOS underlay default route on {}",
        route.interface
    );
    Ok(true)
}

#[cfg(any(target_os = "macos", test))]
pub(crate) fn macos_tunnel_default_route_targets() -> &'static [&'static str] {
    &["0.0.0.0/1", "128.0.0.0/1"]
}

#[cfg(any(target_os = "macos", test))]
fn macos_split_default_route_interface(output: &str) -> Option<&str> {
    let has_split_mask = output.lines().map(str::trim).any(|line| {
        line.strip_prefix("mask:")
            .is_some_and(|mask| mask.trim() == "128.0.0.0")
    });
    if !has_split_mask {
        return None;
    }

    output.lines().map(str::trim).find_map(|line| {
        line.strip_prefix("interface:")
            .map(str::trim)
            .filter(|iface| !iface.is_empty())
    })
}

#[cfg(target_os = "macos")]
fn macos_split_default_route_owner(target: &str) -> Result<Option<String>> {
    let probe = match target {
        "0.0.0.0/1" => "1.0.0.1",
        "128.0.0.0/1" => "129.0.0.1",
        _ => return Err(anyhow!("unsupported macOS split-default target {target}")),
    };
    let output =
        command_stdout_checked(ProcessCommand::new("route").arg("-n").arg("get").arg(probe))?;
    Ok(macos_split_default_route_interface(&output).map(ToOwned::to_owned))
}

#[cfg(any(target_os = "macos", test))]
fn macos_gateway_route_args(action: &str, target: &str, gateway: &str) -> Vec<String> {
    let target_ip = strip_cidr(target);
    let is_host = target.ends_with("/32") || !target.contains('/');

    let mut args = vec!["-n".to_string(), action.to_string()];
    if is_host {
        args.push("-host".to_string());
        args.push(target_ip.to_string());
    } else if target == "0.0.0.0/0" {
        args.push("default".to_string());
    } else {
        args.push("-net".to_string());
        args.push(target.to_string());
    }
    args.push(gateway.to_string());
    args
}

#[cfg(target_os = "macos")]
pub(super) fn apply_macos_default_route(
    gateway: Option<&str>,
    ifscope: Option<&str>,
) -> Result<()> {
    if let Some(ifscope) = ifscope {
        let _ = delete_macos_default_route_for_interface(ifscope);
        let _ = ProcessCommand::new("route")
            .arg("-n")
            .arg("delete")
            .arg("default")
            .arg("-ifscope")
            .arg(ifscope)
            .status();
    }

    if gateway.is_none() {
        let iface = ifscope.ok_or_else(|| anyhow!("missing interface for direct default route"))?;
        for target in macos_tunnel_default_route_targets() {
            apply_macos_route_spec(target, None, Some(iface)).with_context(|| {
                format!("failed to install macOS default route target {target} on {iface}")
            })?;
        }
        return Ok(());
    }

    let mut change = ProcessCommand::new("route");
    change.arg("-n").arg("change").arg("default");
    change.arg(gateway.expect("gateway checked above"));

    match run_checked(&mut change) {
        Ok(()) => Ok(()),
        Err(_) => {
            let mut add = ProcessCommand::new("route");
            add.arg("-n").arg("add").arg("default");
            add.arg(gateway.expect("gateway checked above"));
            run_checked(&mut add)
        }
    }
}

#[cfg(target_os = "macos")]
pub(super) fn delete_macos_default_route_for_interface(iface: &str) -> Result<()> {
    let mut failures = Vec::new();
    for target in macos_tunnel_default_route_targets() {
        match macos_split_default_route_owner(target) {
            Ok(Some(owner)) if owner == iface => {}
            Ok(Some(_)) | Ok(None) => continue,
            Err(error) => {
                failures.push(format!("inspect {target}: {error}"));
                continue;
            }
        }
        if let Err(error) = delete_macos_direct_route_variants(target, iface) {
            failures.push(format!("remove {target} on {iface}: {error}"));
        }
    }

    if failures.is_empty() {
        Ok(())
    } else {
        Err(anyhow!(failures.join("; ")))
    }
}

pub(super) fn macos_ifconfig_has_ipv4(output: &str, needle: Ipv4Addr) -> bool {
    output.lines().map(str::trim).any(|line| {
        line.strip_prefix("inet ")
            .and_then(|rest| rest.split_whitespace().next())
            .is_some_and(|value| value == needle.to_string())
    })
}

#[cfg(target_os = "macos")]
pub(super) fn macos_iface_has_ipv4_address(iface: &str, needle: Ipv4Addr) -> Result<bool> {
    let output = command_stdout_checked(ProcessCommand::new("ifconfig").arg(iface))?;
    Ok(macos_ifconfig_has_ipv4(&output, needle))
}

#[cfg(target_os = "macos")]
pub(super) fn apply_macos_route_spec(
    target: &str,
    gateway: Option<&str>,
    ifscope: Option<&str>,
) -> Result<()> {
    let target_ip = strip_cidr(target);
    let is_host = target.ends_with("/32") || !target.contains('/');

    let mut add = ProcessCommand::new("route");
    if let Some(gateway) = gateway {
        add.args(macos_gateway_route_args("add", target, gateway));
    } else {
        if let Some(iface) = ifscope {
            let _ = delete_macos_route_spec(target, Some(iface));
            let _ = delete_macos_route_spec(target, None);
        }
        add.arg("-n").arg("add");
        if is_host {
            add.arg("-host").arg(target_ip);
        } else if target == "0.0.0.0/0" {
            add.arg("default");
        } else {
            add.arg("-net").arg(target);
        }
        let iface = ifscope.ok_or_else(|| anyhow!("missing interface for direct route"))?;
        add.arg("-interface").arg(iface);
    }

    match run_checked(&mut add) {
        Ok(()) => Ok(()),
        Err(_) => {
            let mut change = ProcessCommand::new("route");
            if let Some(gateway) = gateway {
                change.args(macos_gateway_route_args("change", target, gateway));
            } else {
                change.arg("-n").arg("change");
                if is_host {
                    change.arg("-host").arg(target_ip);
                } else if target == "0.0.0.0/0" {
                    change.arg("default");
                } else {
                    change.arg("-net").arg(target);
                }
                let iface = ifscope.ok_or_else(|| anyhow!("missing interface for direct route"))?;
                change.arg("-interface").arg(iface);
            }
            run_checked(&mut change)
        }
    }
}

#[cfg(target_os = "macos")]
fn delete_macos_route_spec(target: &str, ifscope: Option<&str>) -> Result<()> {
    let target_ip = strip_cidr(target);
    let is_host = target.ends_with("/32") || !target.contains('/');

    let mut delete = ProcessCommand::new("route");
    delete.arg("-n").arg("delete");
    if let Some(ifscope) = ifscope {
        delete.arg("-ifscope").arg(ifscope);
    }
    if is_host {
        delete.arg("-host").arg(target_ip);
    } else if target == "0.0.0.0/0" {
        delete.arg("default");
    } else {
        delete.arg("-net").arg(target);
    }

    run_checked(&mut delete)
}

#[cfg(target_os = "macos")]
fn delete_macos_direct_route_variants(target: &str, iface: &str) -> Result<()> {
    let mut failures = Vec::new();

    for attempt in [Some(iface), None] {
        if let Err(error) = delete_macos_route_spec(target, attempt)
            && !crate::daemon_runtime::macos_route_delete_error_is_absent(&error.to_string())
        {
            failures.push(error.to_string());
        }
    }

    if failures.is_empty() {
        Ok(())
    } else {
        Err(anyhow!(failures.join("; ")))
    }
}

#[cfg(any(target_os = "macos", test))]
const MACOS_PF_EXIT_ANCHOR: &str = "com.apple/nostrvpn-exit";

#[cfg(any(target_os = "macos", test))]
pub(crate) fn macos_exit_node_pf_rules(
    tunnel_iface: &str,
    outbound_iface: &str,
    tunnel_source_cidr: &str,
) -> String {
    format!(
        concat!(
            "nat on {outbound_iface} inet from {tunnel_source_cidr} to any -> ({outbound_iface})\n",
            "pass in quick on {tunnel_iface} inet from {tunnel_source_cidr} to any keep state\n",
            "pass out quick on {outbound_iface} inet from {tunnel_source_cidr} to any keep state\n",
        ),
        tunnel_iface = tunnel_iface,
        outbound_iface = outbound_iface,
        tunnel_source_cidr = tunnel_source_cidr,
    )
}

#[cfg(any(target_os = "macos", test))]
pub(crate) fn parse_macos_ipv4_forwarding_state(output: &str) -> Result<bool> {
    match output.trim() {
        "0" => Ok(false),
        "1" => Ok(true),
        value => Err(anyhow!("unexpected net.inet.ip.forwarding value '{value}'")),
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn read_macos_ipv4_forwarding() -> Result<bool> {
    let output = command_stdout_checked(
        ProcessCommand::new("sysctl")
            .arg("-n")
            .arg("net.inet.ip.forwarding"),
    )?;
    parse_macos_ipv4_forwarding_state(&output)
}

#[cfg(target_os = "macos")]
pub(crate) fn write_macos_ipv4_forwarding(enabled: bool) -> Result<()> {
    run_checked(
        ProcessCommand::new("sysctl")
            .arg("-w")
            .arg(format!("net.inet.ip.forwarding={}", u8::from(enabled))),
    )
}

#[cfg(target_os = "macos")]
pub(super) fn macos_pf_enabled() -> Result<bool> {
    let output = command_stdout_checked(ProcessCommand::new("pfctl").arg("-s").arg("info"))?;
    parse_macos_pf_enabled(&output)
}

#[cfg(any(target_os = "macos", test))]
pub(crate) fn parse_macos_pf_enabled(output: &str) -> Result<bool> {
    let state = output.lines().map(str::trim).find_map(|line| {
        let (key, value) = line.split_once(':')?;
        key.eq_ignore_ascii_case("status")
            .then(|| value.split_whitespace().next())
            .flatten()
    });
    match state {
        Some(state) if state.eq_ignore_ascii_case("enabled") => Ok(true),
        Some(state) if state.eq_ignore_ascii_case("disabled") => Ok(false),
        Some(state) => Err(anyhow!("unexpected PF status '{state}'")),
        None => Err(anyhow!("PF status output did not contain a status line")),
    }
}

#[cfg(target_os = "macos")]
pub(super) fn apply_macos_exit_node_pf_rules(
    tunnel_iface: &str,
    outbound_iface: &str,
    tunnel_source_cidr: &str,
) -> Result<()> {
    let rules = macos_exit_node_pf_rules(tunnel_iface, outbound_iface, tunnel_source_cidr);
    let mut command = ProcessCommand::new("pfctl")
        .arg("-a")
        .arg(MACOS_PF_EXIT_ANCHOR)
        .arg("-f")
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to execute pfctl")?;
    if let Some(stdin) = command.stdin.as_mut() {
        stdin
            .write_all(rules.as_bytes())
            .context("failed to write nvpn PF rules")?;
    }
    let output = command
        .wait_with_output()
        .context("failed to wait for pfctl")?;
    if output.status.success() {
        return Ok(());
    }

    Err(anyhow!(
        "command failed: pfctl -a {MACOS_PF_EXIT_ANCHOR} -f -\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout).trim(),
        String::from_utf8_lossy(&output.stderr).trim()
    ))
}

#[cfg(target_os = "macos")]
pub(super) fn enable_macos_pf() -> Result<()> {
    run_checked(ProcessCommand::new("pfctl").arg("-e"))
}

#[cfg(any(target_os = "macos", test))]
pub(crate) fn macos_pf_anchor_flush_args() -> Vec<String> {
    vec![
        "-a".to_string(),
        MACOS_PF_EXIT_ANCHOR.to_string(),
        "-F".to_string(),
        "all".to_string(),
    ]
}

#[cfg(target_os = "macos")]
pub(super) fn cleanup_macos_pf_nat() -> Result<()> {
    let mut command = ProcessCommand::new("pfctl");
    command.args(macos_pf_anchor_flush_args());
    run_checked(&mut command)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn macos_default_routes_from_netstat_finds_underlay_and_utun_routes() {
        let routes = macos_default_routes_from_netstat(
            "Routing tables\n\
Internet:\n\
Destination        Gateway            Flags               Netif Expire\n\
default            192.168.64.1       UGScg                 en0\n\
default            link#13            UCSIg               utun5\n\
default            link#26            UCSIg           bridge100      !\n",
        );

        assert_eq!(
            routes,
            vec![
                MacosRouteSpec {
                    gateway: Some("192.168.64.1".to_string()),
                    interface: "en0".to_string(),
                },
                MacosRouteSpec {
                    gateway: None,
                    interface: "utun5".to_string(),
                },
                MacosRouteSpec {
                    gateway: None,
                    interface: "bridge100".to_string(),
                },
            ]
        );

        assert_eq!(
            macos_underlay_default_route_from_routes(&routes),
            Some(MacosRouteSpec {
                gateway: Some("192.168.64.1".to_string()),
                interface: "en0".to_string(),
            })
        );
    }

    #[test]
    fn macos_underlay_selection_prefers_the_snapshot_interface_when_two_are_active() {
        let candidates = vec![
            MacosRouteSpec {
                gateway: Some("192.168.178.1".to_string()),
                interface: "en0".to_string(),
            },
            MacosRouteSpec {
                gateway: Some("10.168.32.48".to_string()),
                interface: "en1".to_string(),
            },
        ];

        assert_eq!(
            macos_underlay_route_from_candidates(&candidates, Some("en1")),
            Some(candidates[1].clone()),
            "the daemon snapshot, not interface enumeration order, owns the selected underlay"
        );
        assert_eq!(
            macos_underlay_route_from_candidates(&candidates, Some("en0")),
            Some(candidates[0].clone())
        );
    }

    #[test]
    fn macos_selected_default_route_uses_kernel_global_route_during_handoff() {
        let route_get = "\
   route to: default
destination: default
       mask: default
    gateway: 10.168.32.48
  interface: en1
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
";

        assert_eq!(
            macos_selected_default_route_from_route_get(route_get),
            Some(MacosRouteSpec {
                gateway: Some("10.168.32.48".to_string()),
                interface: "en1".to_string(),
            }),
            "the kernel-selected global default must win even while netstat still lists stale en0 first"
        );
    }

    #[test]
    fn macos_gateway_route_args_install_global_host_routes() {
        assert_eq!(
            macos_gateway_route_args("add", "65.109.48.91/32", "192.168.64.1"),
            vec![
                "-n".to_string(),
                "add".to_string(),
                "-host".to_string(),
                "65.109.48.91".to_string(),
                "192.168.64.1".to_string(),
            ]
        );
        assert_eq!(
            macos_gateway_route_args("change", "0.0.0.0/0", "192.168.64.1"),
            vec![
                "-n".to_string(),
                "change".to_string(),
                "default".to_string(),
                "192.168.64.1".to_string(),
            ]
        );
    }

    #[test]
    fn macos_ifconfig_has_ipv4_matches_exact_interface_address() {
        let output = "utun5: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380\n\
\tinet 10.44.10.23 --> 10.44.10.23 netmask 0xffffffff\n\
\tinet6 fe80::1%utun5 prefixlen 64 scopeid 0x8\n";

        assert!(macos_ifconfig_has_ipv4(
            output,
            Ipv4Addr::new(10, 44, 10, 23)
        ));
        assert!(!macos_ifconfig_has_ipv4(
            output,
            Ipv4Addr::new(10, 44, 10, 24)
        ));
    }

    #[test]
    fn split_default_cleanup_only_claims_the_route_owner() {
        let wireguard_route = "\
   route to: 1.0.0.1\n\
destination: 0.0.0.0\n\
       mask: 128.0.0.0\n\
    gateway: utun6\n\
  interface: utun6\n";
        assert_eq!(
            macos_split_default_route_interface(wireguard_route),
            Some("utun6")
        );

        let physical_default = "\
   route to: 1.0.0.1\n\
destination: default\n\
       mask: default\n\
    gateway: 192.168.64.1\n\
  interface: en0\n";
        assert_eq!(macos_split_default_route_interface(physical_default), None);
    }

    #[test]
    fn direct_transition_repairs_only_a_missing_physical_default() {
        let tunnel_only = vec![MacosRouteSpec {
            gateway: None,
            interface: "utun5".to_string(),
        }];
        assert!(macos_underlay_default_route_needs_restore(&tunnel_only));

        let physical_and_tunnel = vec![
            MacosRouteSpec {
                gateway: Some("192.168.64.1".to_string()),
                interface: "en0".to_string(),
            },
            MacosRouteSpec {
                gateway: None,
                interface: "utun5".to_string(),
            },
        ];
        assert!(!macos_underlay_default_route_needs_restore(
            &physical_and_tunnel
        ));
    }

    #[test]
    fn underlay_restore_adds_without_changing_a_foreign_default() {
        assert_eq!(
            macos_add_underlay_default_route_args("192.168.64.1"),
            vec!["-n", "add", "default", "192.168.64.1"]
        );
    }
}
