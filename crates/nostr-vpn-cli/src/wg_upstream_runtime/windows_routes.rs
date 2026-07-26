// POSIX, but the routing table is driven by `netsh interface ipv4`
// instead of `ip` / `route`, and the WG iface is identified by its
// kernel interface index rather than a name. The captured original
// default route is held verbatim from `route print 0.0.0.0` so we can
// re-add it on cleanup.
// ---------------------------------------------------------------------------

#[cfg(target_os = "windows")]
pub fn apply_windows_full_default_route(
    wg_iface_index: u32,
    upstream: SocketAddr,
) -> Result<WindowsFullDefaultRoute> {
    let upstream_ip = match upstream.ip() {
        IpAddr::V4(ip) => ip,
        IpAddr::V6(_) => {
            return Err(anyhow!(
                "WG upstream IPv6 endpoint not yet supported on Windows"
            ));
        }
    };

    // Capture the underlay default route (gateway + interface index)
    // before we touch anything. We need the gateway to install a /32
    // bypass for the WG endpoint.
    let original = capture_windows_default_route()?;
    if original.interface_index == wg_iface_index {
        return Err(anyhow!(
            "captured default route already points at the WG WinTun adapter (interface={}); \
             refusing to swap to avoid creating a routing loop",
            wg_iface_index
        ));
    }

    // 1. /32 bypass for the WG endpoint via the original gateway.
    //    Must exist BEFORE we add the WG default; otherwise the
    //    encrypted UDP would loop into the WG iface.
    run_windows_netsh(&[
        "interface".to_string(),
        "ipv4".to_string(),
        "add".to_string(),
        "route".to_string(),
        format!("{upstream_ip}/32"),
        format!("interface={}", original.interface_index),
        format!("nexthop={}", original.gateway),
        "metric=1".to_string(),
        "store=active".to_string(),
    ])?;

    // 2. Default via the WG WinTun adapter at metric=1 so it wins
    //    against the underlay's default (typically metric ~10).
    if let Err(error) = run_windows_netsh(&[
        "interface".to_string(),
        "ipv4".to_string(),
        "add".to_string(),
        "route".to_string(),
        "0.0.0.0/0".to_string(),
        format!("interface={}", wg_iface_index),
        "metric=1".to_string(),
        "store=active".to_string(),
    ]) {
        // Roll back the bypass we just added before bubbling the
        // error up — leaving a /32 to a now-broken gateway around
        // would be a real footgun.
        let _ = run_windows_netsh(&[
            "interface".to_string(),
            "ipv4".to_string(),
            "delete".to_string(),
            "route".to_string(),
            format!("{upstream_ip}/32"),
            format!("interface={}", original.interface_index),
            "store=active".to_string(),
        ]);
        return Err(error);
    }

    Ok(WindowsFullDefaultRoute {
        wg_iface_index,
        bypass_target: upstream_ip,
        original,
        reverted: false,
    })
}

#[cfg(target_os = "windows")]
pub struct WindowsFullDefaultRoute {
    wg_iface_index: u32,
    bypass_target: std::net::Ipv4Addr,
    original: WindowsDefaultRoute,
    reverted: bool,
}

#[cfg(any(test, target_os = "windows"))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WindowsDefaultRoute {
    pub(crate) gateway: String,
    pub(crate) interface_index: u32,
    pub(crate) interface_ipv4: std::net::Ipv4Addr,
}

#[cfg(target_os = "windows")]
impl WindowsFullDefaultRoute {
    pub fn revert(&mut self) -> Result<()> {
        if self.reverted {
            return Ok(());
        }
        // Delete our 0.0.0.0/0 → WG-iface entry. The original default
        // (which we never touched) is still in the table at its
        // higher metric and now becomes the active default again.
        let _ = run_windows_netsh(&[
            "interface".to_string(),
            "ipv4".to_string(),
            "delete".to_string(),
            "route".to_string(),
            "0.0.0.0/0".to_string(),
            format!("interface={}", self.wg_iface_index),
            "store=active".to_string(),
        ]);
        // Delete the /32 bypass for the WG endpoint.
        let _ = run_windows_netsh(&[
            "interface".to_string(),
            "ipv4".to_string(),
            "delete".to_string(),
            "route".to_string(),
            format!("{}/32", self.bypass_target),
            format!("interface={}", self.original.interface_index),
            "store=active".to_string(),
        ]);
        self.reverted = true;
        Ok(())
    }
}

#[cfg(target_os = "windows")]
impl Drop for WindowsFullDefaultRoute {
    fn drop(&mut self) {
        if let Err(error) = self.revert() {
            eprintln!(
                "wg-upstream: WARNING — Windows route revert failed: {error}. \
                 You may need to run `netsh interface ipv4 delete route 0.0.0.0/0 \
                 interface={}` manually.",
                self.wg_iface_index
            );
        }
    }
}

#[cfg(target_os = "windows")]
pub(crate) fn capture_windows_default_route() -> Result<WindowsDefaultRoute> {
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
    let interface_ip = parse_windows_default_route_columns(&stdout)
        .ok_or_else(|| anyhow!("no IPv4 default route found in `route print` output"))?;
    let interface_index = resolve_windows_interface_index_for_address(&interface_ip.interface_ip)?;
    Ok(WindowsDefaultRoute {
        gateway: interface_ip.gateway,
        interface_index,
        interface_ipv4: interface_ip
            .interface_ip
            .parse()
            .context("parse Windows default-route interface IPv4 address")?,
    })
}

#[cfg(any(test, target_os = "windows"))]
struct ParsedWindowsDefaultRoute {
    gateway: String,
    interface_ip: String,
    metric: u32,
}

#[cfg(any(test, target_os = "windows"))]
fn parse_windows_default_route_columns(output: &str) -> Option<ParsedWindowsDefaultRoute> {
    let mut best: Option<ParsedWindowsDefaultRoute> = None;
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
            if best
                .as_ref()
                .is_none_or(|current| candidate.metric < current.metric)
            {
                best = Some(candidate);
            }
        }
    }
    best
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
