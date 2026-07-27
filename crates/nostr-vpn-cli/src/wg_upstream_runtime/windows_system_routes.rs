#[cfg(target_os = "windows")]
fn apply_windows_endpoint_bypass_route(
    wg_iface_index: u32,
    upstream: SocketAddr,
    excluded_tunnel_interfaces: &[u32],
) -> Result<WindowsFullDefaultRoute> {
    apply_windows_managed_default_routes(
        wg_iface_index,
        upstream,
        excluded_tunnel_interfaces,
        false,
    )
}

#[cfg(target_os = "windows")]
fn apply_windows_managed_default_routes(
    wg_iface_index: u32,
    upstream: SocketAddr,
    excluded_tunnel_interfaces: &[u32],
    manage_default: bool,
) -> Result<WindowsFullDefaultRoute> {
    retry_pending_windows_route_cleanup()?;
    let upstream_ip = match upstream.ip() {
        IpAddr::V4(ip) => ip,
        IpAddr::V6(_) => {
            return Err(anyhow!(
                "WG upstream IPv6 endpoint not yet supported on Windows"
            ));
        }
    };
    let mut excluded = excluded_tunnel_interfaces.to_vec();
    excluded.push(wg_iface_index);
    let underlay = capture_windows_default_route_excluding(&excluded)?;
    let routes = match WindowsManagedDefaultRoutes::apply_with(
        &mut SystemWindowsRouteCommandRunner,
        wg_iface_index,
        upstream_ip,
        underlay,
        manage_default,
    ) {
        Ok(routes) => routes,
        Err(mut failure) => {
            retain_pending_windows_route_cleanup(failure.cleanup.take_cleanup_snapshot());
            return Err(failure.error);
        }
    };
    Ok(WindowsFullDefaultRoute { routes })
}

#[cfg(target_os = "windows")]
pub struct WindowsFullDefaultRoute {
    routes: WindowsManagedDefaultRoutes,
}

#[cfg(any(test, target_os = "windows"))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WindowsDefaultRoute {
    pub(crate) gateway: String,
    pub(crate) interface_index: u32,
    pub(crate) interface_ipv4: std::net::Ipv4Addr,
}

#[cfg(any(test, target_os = "windows"))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WindowsIpv6DefaultRoute {
    pub(crate) gateway: Option<std::net::Ipv6Addr>,
    pub(crate) interface_index: u32,
    pub(crate) metric: u32,
}

#[cfg(target_os = "windows")]
impl WindowsFullDefaultRoute {
    pub fn reconcile_endpoint_and_underlay(
        &mut self,
        upstream: SocketAddr,
        excluded_tunnel_interfaces: &[u32],
    ) -> Result<bool> {
        let upstream_ip = match upstream.ip() {
            std::net::IpAddr::V4(ip) => ip,
            std::net::IpAddr::V6(_) => {
                return Err(anyhow!(
                    "WG upstream IPv6 endpoint not yet supported on Windows"
                ));
            }
        };
        let mut excluded = excluded_tunnel_interfaces.to_vec();
        excluded.push(self.routes.wg_iface_index);
        let fresh_underlay = capture_windows_default_route_excluding(&excluded)?;
        self.routes.reconcile_with(
            &mut SystemWindowsRouteCommandRunner,
            upstream_ip,
            fresh_underlay,
            excluded_tunnel_interfaces,
        )
    }

    pub fn revert(&mut self) -> Result<()> {
        self.routes
            .revert_with(&mut SystemWindowsRouteCommandRunner)
    }

    pub(crate) fn cleanup_snapshot(&self) -> WindowsRouteCleanupSnapshot {
        self.routes.cleanup_snapshot()
    }
}

#[cfg(target_os = "windows")]
impl Drop for WindowsFullDefaultRoute {
    fn drop(&mut self) {
        if let Err(error) = self
            .routes
            .revert_retaining_pending_with(&mut SystemWindowsRouteCommandRunner)
        {
            eprintln!(
                "wg-upstream: WARNING — Windows route revert failed: {error}. \
                 You may need to run `netsh interface ipv4 delete route 0.0.0.0/0 \
                 interface={}` manually.",
                self.routes.wg_iface_index
            );
        }
    }
}

#[cfg(target_os = "windows")]
pub(crate) fn capture_windows_default_route_excluding(
    excluded_tunnel_interfaces: &[u32],
) -> Result<WindowsDefaultRoute> {
    // `route print -4 0.0.0.0` lists IPv4 default routes. Output
    // includes columns like:
    //   Network Destination | Netmask | Gateway | Interface | Metric
    //   0.0.0.0             | 0.0.0.0 | 192.168.1.1 | 192.168.1.42 | 25
    let output = ProcessCommand::new("route")
        .arg("print")
        .arg("-4")
        .arg("0.0.0.0")
        .output()
        .context("spawn `route print -4 0.0.0.0`")?;
    if !output.status.success() {
        return Err(anyhow!("route print failed: {}", output.status));
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    select_windows_default_route_from_output(
        &stdout,
        excluded_tunnel_interfaces,
        resolve_windows_interface_index_for_address,
    )
}

#[cfg(target_os = "windows")]
fn select_windows_default_route_from_output(
    output: &str,
    excluded_tunnel_interfaces: &[u32],
    resolve_interface_index: impl FnMut(&str) -> Result<u32>,
) -> Result<WindowsDefaultRoute> {
    select_windows_default_route_candidate(
        parse_windows_default_route_candidates(output),
        excluded_tunnel_interfaces,
        resolve_interface_index,
    )
}

#[cfg(any(test, target_os = "windows"))]
fn select_windows_default_route_candidate(
    candidates: Vec<ParsedWindowsDefaultRoute>,
    excluded_tunnel_interfaces: &[u32],
    mut resolve_interface_index: impl FnMut(&str) -> Result<u32>,
) -> Result<WindowsDefaultRoute> {
    let mut resolution_failures = Vec::new();
    for candidate in candidates {
        let interface_index = match resolve_interface_index(&candidate.interface_ip) {
            Ok(interface_index) => interface_index,
            Err(error) => {
                resolution_failures.push(format!("{}: {error:#}", candidate.interface_ip));
                continue;
            }
        };
        if excluded_tunnel_interfaces.contains(&interface_index) {
            continue;
        }
        return Ok(WindowsDefaultRoute {
            gateway: candidate.gateway,
            interface_index,
            interface_ipv4: candidate
                .interface_ip
                .parse()
                .context("parse Windows default-route interface IPv4 address")?,
        });
    }
    Err(anyhow!(
        "no physical IPv4 default route found outside excluded tunnel interfaces \
         {excluded_tunnel_interfaces:?}; interface resolution failures: {}",
        resolution_failures.join("; ")
    ))
}

#[cfg(target_os = "windows")]
pub(crate) fn capture_windows_ipv6_default_routes() -> Result<Vec<WindowsIpv6DefaultRoute>> {
    let output = ProcessCommand::new("route")
        .args(["print", "-6", "::/0"])
        .output()
        .context("spawn `route print -6 ::/0`")?;
    if !output.status.success() {
        return Err(anyhow!("IPv6 route print failed: {}", output.status));
    }
    Ok(parse_windows_ipv6_default_route_columns(
        &String::from_utf8_lossy(&output.stdout),
    ))
}

#[cfg(any(test, target_os = "windows"))]
struct ParsedWindowsDefaultRoute {
    gateway: String,
    interface_ip: String,
    metric: u32,
}

#[cfg(test)]
fn parse_windows_default_route_columns(output: &str) -> Option<ParsedWindowsDefaultRoute> {
    parse_windows_default_route_candidates(output)
        .into_iter()
        .next()
}

#[cfg(any(test, target_os = "windows"))]
fn parse_windows_default_route_candidates(output: &str) -> Vec<ParsedWindowsDefaultRoute> {
    let mut candidates = Vec::new();
    for line in output.lines() {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 5 {
            continue;
        }
        if tokens[0] == "0.0.0.0" && tokens[1] == "0.0.0.0" {
            // Some columns may be "On-link" for the gateway when the
            // default goes via a /32 host route; skip those — they
            // can't be used as the bypass nexthop.
            if tokens[2].eq_ignore_ascii_case("on-link") {
                continue;
            }
            let metric = tokens[4].parse::<u32>().unwrap_or(u32::MAX);
            let candidate = ParsedWindowsDefaultRoute {
                gateway: tokens[2].to_string(),
                interface_ip: tokens[3].to_string(),
                metric,
            };
            candidates.push(candidate);
        }
    }
    candidates.sort_by_key(|candidate| candidate.metric);
    candidates
}

#[cfg(any(test, target_os = "windows"))]
fn parse_windows_ipv6_default_route_columns(output: &str) -> Vec<WindowsIpv6DefaultRoute> {
    let mut routes = output
        .lines()
        .filter_map(|line| {
            let tokens = line.split_whitespace().collect::<Vec<_>>();
            if tokens.len() < 4 || tokens[2] != "::/0" {
                return None;
            }
            let interface_index = tokens[0].parse().ok()?;
            let metric = tokens[1].parse().ok()?;
            let gateway = if tokens[3].eq_ignore_ascii_case("on-link") {
                None
            } else {
                Some(tokens[3].parse().ok()?)
            };
            Some(WindowsIpv6DefaultRoute {
                gateway,
                interface_index,
                metric,
            })
        })
        .collect::<Vec<_>>();
    routes.sort_by_key(|route| route.metric);
    routes
}

#[cfg(target_os = "windows")]
fn resolve_windows_interface_index_for_address(interface_ip: &str) -> Result<u32> {
    use std::net::Ipv4Addr;
    let target: Ipv4Addr = interface_ip
        .parse()
        .with_context(|| format!("invalid IPv4 interface address {interface_ip}"))?;

    // `netsh interface ipv4 show ipaddresses level=verbose` enumerates
    // every IPv4 address with its interface index. Cheap parse; we
    // could use the IpHelper API but that's a bigger crate dep.
    let output = ProcessCommand::new("netsh")
        .args(["interface", "ipv4", "show", "ipaddresses", "level=verbose"])
        .output()
        .context("spawn `netsh interface ipv4 show ipaddresses`")?;
    if !output.status.success() {
        return Err(anyhow!("netsh show ipaddresses failed: {}", output.status));
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    match parse_windows_ipaddresses_interface(&stdout, target) {
        Some(WindowsAddressInterface::Index(idx)) => return Ok(idx),
        Some(WindowsAddressInterface::Alias(alias)) => {
            let output = ProcessCommand::new("netsh")
                .args(["interface", "ipv4", "show", "interfaces"])
                .output()
                .context("spawn `netsh interface ipv4 show interfaces`")?;
            if !output.status.success() {
                return Err(anyhow!("netsh show interfaces failed: {}", output.status));
            }
            let stdout = String::from_utf8_lossy(&output.stdout);
            if let Some(idx) = parse_windows_interface_index_for_alias(&stdout, &alias) {
                return Ok(idx);
            }
            return Err(anyhow!(
                "no Windows interface index found for alias {alias:?} with IPv4 address {target}"
            ));
        }
        None => {}
    }
    Err(anyhow!(
        "no Windows interface found with IPv4 address {target}"
    ))
}

#[cfg(any(test, target_os = "windows"))]
#[derive(Debug, Clone, PartialEq, Eq)]
enum WindowsAddressInterface {
    Index(u32),
    Alias(String),
}

#[cfg(any(test, target_os = "windows"))]
fn parse_windows_ipaddresses_interface(
    output: &str,
    target: std::net::Ipv4Addr,
) -> Option<WindowsAddressInterface> {
    let mut current_index: Option<u32> = None;
    let mut current_address_matches = false;
    for line in output.lines() {
        let trimmed = line.trim();
        if current_address_matches
            && let Some((_, alias)) = trimmed.split_once(':')
            && trimmed.starts_with("Interface Luid")
        {
            let alias = alias.trim();
            if !alias.is_empty() {
                return Some(WindowsAddressInterface::Alias(alias.to_string()));
            }
        } else if let Some(rest) = trimmed.strip_prefix("Interface ") {
            // "Interface 7: ..."
            if let Some((idx_str, _)) = rest.split_once(':')
                && let Ok(idx) = idx_str.trim().parse::<u32>()
            {
                current_index = Some(idx);
            }
        } else if let Some(rest) = trimmed.strip_prefix("Address ") {
            current_address_matches = false;
            let Some(addr_str) = rest.split_whitespace().next() else {
                continue;
            };
            if let Ok(addr) = addr_str.parse::<std::net::Ipv4Addr>()
                && addr == target
            {
                if let Some(idx) = current_index {
                    return Some(WindowsAddressInterface::Index(idx));
                }
                current_address_matches = true;
            }
        }
    }
    None
}

#[cfg(any(test, target_os = "windows"))]
fn parse_windows_interface_index_for_alias(output: &str, alias: &str) -> Option<u32> {
    for line in output.lines() {
        let trimmed = line.trim();
        let tokens: Vec<&str> = trimmed.split_whitespace().collect();
        if tokens.len() < 5 {
            continue;
        }
        let Ok(idx) = tokens[0].parse::<u32>() else {
            continue;
        };
        let name = tokens[4..].join(" ");
        if name.eq_ignore_ascii_case(alias.trim()) {
            return Some(idx);
        }
    }
    None
}

#[cfg(target_os = "windows")]
fn resolve_windows_interface_index_for_alias_name(alias: &str) -> Result<u32> {
    let output = ProcessCommand::new("netsh")
        .args(["interface", "ipv4", "show", "interfaces"])
        .output()
        .context("spawn `netsh interface ipv4 show interfaces`")?;
    if !output.status.success() {
        return Err(anyhow!("netsh show interfaces failed: {}", output.status));
    }
    parse_windows_interface_index_for_alias(&String::from_utf8_lossy(&output.stdout), alias)
        .ok_or_else(|| anyhow!("no Windows interface index found for alias {alias:?}"))
}

#[cfg(any(test, target_os = "windows"))]
fn windows_route_add_args(route: &WindowsRouteSpec) -> Vec<String> {
    let mut args = vec![
        "interface".to_string(),
        "ipv4".to_string(),
        "add".to_string(),
        "route".to_string(),
        route.prefix.clone(),
        format!("interface={}", route.interface_index),
    ];
    if route.next_hop != "0.0.0.0" {
        args.push(format!("nexthop={}", route.next_hop));
    }
    args.extend([
        format!("metric={}", route.metric),
        "store=active".to_string(),
    ]);
    args
}

#[cfg(any(test, target_os = "windows"))]
fn windows_route_set_args(route: &WindowsRouteSpec) -> Vec<String> {
    let mut args = windows_route_add_args(route);
    args[2] = "set".to_string();
    args
}

#[cfg(any(test, target_os = "windows"))]
fn windows_route_delete_args(route: &WindowsRouteSpec) -> Vec<String> {
    vec![
        "interface".to_string(),
        "ipv4".to_string(),
        "delete".to_string(),
        "route".to_string(),
        route.prefix.clone(),
        format!("interface={}", route.interface_index),
        format!("nexthop={}", route.next_hop),
        "store=active".to_string(),
    ]
}

#[cfg(target_os = "windows")]
fn windows_route_exists(route: &WindowsRouteSpec, exact_attributes: bool) -> Result<bool> {
    let prefix = route.prefix.replace('\'', "''");
    let next_hop = route.next_hop.replace('\'', "''");
    let metric_filter = if exact_attributes {
        format!(" -and $_.RouteMetric -eq {}", route.metric)
    } else {
        String::new()
    };
    let script = format!(
        "$route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '{prefix}' \
         -InterfaceIndex {} -ErrorAction SilentlyContinue | \
         Where-Object {{ $_.NextHop -eq '{next_hop}'{metric_filter} }} | \
         Select-Object -First 1; if ($null -eq $route) {{ 'false' }} else {{ 'true' }}",
        route.interface_index
    );
    let output = ProcessCommand::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .output()
        .context("query exact Windows route ownership state")?;
    if !output.status.success() {
        return Err(anyhow!(
            "Get-NetRoute query failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    match String::from_utf8_lossy(&output.stdout)
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "true" => Ok(true),
        "false" => Ok(false),
        output => Err(anyhow!(
            "unexpected Get-NetRoute existence response {output:?}"
        )),
    }
}

#[cfg(target_os = "windows")]
fn run_windows_netsh(args: &[String]) -> Result<()> {
    let output = ProcessCommand::new("netsh")
        .args(args)
        .output()
        .with_context(|| format!("spawn `netsh {}`", args.join(" ")))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        return Err(anyhow!(
            "netsh {} failed:\n  stdout: {}\n  stderr: {}",
            args.join(" "),
            stdout.trim(),
            stderr.trim()
        ));
    }
    Ok(())
}
