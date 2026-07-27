/// Bring up a userspace WG tun interface and install **only** a single
/// host route via it. Default route is not touched, so this is safe to
/// run on a host with live internet — even if the WG handshake fails,
/// the worst case is that the one scoped target becomes unreachable.
///
/// Returns a `ScopedHostRoute` guard that, when dropped, removes the
/// route. The caller should also drop the `TunSocket` to delete the
/// tun device (utun on macOS auto-vanishes when the fd closes).
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub fn apply_scoped_host_route(
    iface: &str,
    address: &str,
    target: IpAddr,
    mtu: u16,
) -> Result<ScopedHostRoute> {
    let target_str = target.to_string();
    let address_ip = address
        .split('/')
        .next()
        .ok_or_else(|| anyhow!("empty WG tunnel address"))?
        .to_string();
    let mtu_str = mtu.to_string();

    #[cfg(target_os = "linux")]
    {
        run_checked(
            ProcessCommand::new("ip")
                .arg("address")
                .arg("replace")
                .arg(format!("{address_ip}/32"))
                .arg("dev")
                .arg(iface),
        )?;
        run_checked(
            ProcessCommand::new("ip")
                .arg("link")
                .arg("set")
                .arg("mtu")
                .arg(&mtu_str)
                .arg("up")
                .arg("dev")
                .arg(iface),
        )?;
        run_checked(
            ProcessCommand::new("ip")
                .arg("route")
                .arg("replace")
                .arg(format!("{target_str}/32"))
                .arg("dev")
                .arg(iface),
        )?;
        return Ok(ScopedHostRoute {
            iface: iface.to_string(),
            target,
        });
    }

    #[cfg(target_os = "macos")]
    {
        // ifconfig <iface> inet <addr> <addr> netmask 255.255.255.255 mtu N up
        run_checked(
            ProcessCommand::new("ifconfig")
                .arg(iface)
                .arg("inet")
                .arg(&address_ip)
                .arg(&address_ip)
                .arg("netmask")
                .arg("255.255.255.255")
                .arg("mtu")
                .arg(&mtu_str)
                .arg("up"),
        )?;
        // route add -host <target> -interface <iface>
        run_checked(
            ProcessCommand::new("route")
                .arg("-n")
                .arg("add")
                .arg("-host")
                .arg(&target_str)
                .arg("-interface")
                .arg(iface),
        )?;
        return Ok(ScopedHostRoute {
            iface: iface.to_string(),
            target,
        });
    }

    #[allow(unreachable_code)]
    Err(anyhow!(
        "scoped host route is only implemented on Linux and macOS"
    ))
}

/// Drop guard that removes the host route installed by
/// [`apply_scoped_host_route`]. Idempotent and best-effort: if the
/// route was already gone (or the tun device disappeared first, taking
/// its routes with it), this just logs.
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub struct ScopedHostRoute {
    iface: String,
    target: IpAddr,
}

/// Full default-route replacement: bring up the userspace WG tun and
/// route **all** outbound traffic through it (Mullvad/Proton-style),
/// while installing a bypass /32 route for the WG endpoint itself so
/// the encrypted UDP keeps escaping via the original default route.
///
/// **This is the dangerous mode** — if the WG handshake fails after
/// this call returns, the host has lost its way to the internet
/// except through a tunnel that doesn't work. The caller is expected
/// to either:
///   1. Wait for handshake completion (with a timeout) BEFORE calling
///      this, so we only swap the default once we know the tunnel is
///      live, OR
///   2. Spawn a watchdog that drops the returned guard if the
///      handshake doesn't complete within a few seconds.
///
/// The returned guard restores the original routing state + deletes the
/// bypass on Drop, even on panic. On macOS the underlay default is never
/// replaced; cleanup removes only the two WireGuard split-default routes.
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub fn apply_full_default_route(
    iface: &str,
    address: &str,
    upstream_endpoint: SocketAddr,
    mtu: u16,
) -> Result<FullDefaultRoute> {
    let upstream_ip = upstream_endpoint.ip();
    let address_ip = address
        .split('/')
        .next()
        .ok_or_else(|| anyhow!("empty WG tunnel address"))?
        .to_string();
    let mtu_str = mtu.to_string();

    // 1. Bring up the tun with the WG tunnel IP.
    #[cfg(target_os = "linux")]
    {
        run_checked(
            ProcessCommand::new("ip")
                .arg("address")
                .arg("replace")
                .arg(format!("{address_ip}/32"))
                .arg("dev")
                .arg(iface),
        )?;
        run_checked(
            ProcessCommand::new("ip")
                .arg("link")
                .arg("set")
                .arg("mtu")
                .arg(&mtu_str)
                .arg("up")
                .arg("dev")
                .arg(iface),
        )?;
    }
    #[cfg(target_os = "macos")]
    {
        run_checked(
            ProcessCommand::new("ifconfig")
                .arg(iface)
                .arg("inet")
                .arg(&address_ip)
                .arg(&address_ip)
                .arg("netmask")
                .arg("255.255.255.255")
                .arg("mtu")
                .arg(&mtu_str)
                .arg("up"),
        )?;
    }

    // 2. Capture the original default route for the endpoint bypass and,
    // on Linux, restoration on Drop. Do this before touching routes.
    let original_default = capture_default_route()?;

    // 3. Install the bypass /32 for an IPv4 WG endpoint via the original
    // default gateway. The route swap below is IPv4-only, so an IPv6
    // endpoint must remain on its untouched IPv6 underlay and needs no
    // bypass.
    let bypass_target = ipv4_default_swap_bypass_target(upstream_ip);
    if let Some(target) = bypass_target.as_ref() {
        install_endpoint_bypass(target, &original_default)?;
    }

    let mut full_route = FullDefaultRoute {
        #[cfg(target_os = "macos")]
        iface: iface.to_string(),
        bypass_target,
        original_default,
        reverted: false,
    };

    // 4. Swap the default route to the WG tun. If any command fails after
    // partially applying the route set, remove every route we own before
    // returning the error.
    if let Err(error) = install_default_via_iface(iface, &address_ip) {
        let cleanup = full_route.revert();
        return match cleanup {
            Ok(()) => Err(error),
            Err(cleanup) => Err(error.context(format!(
                "rollback partially applied WG routes: {cleanup:#}"
            ))),
        };
    }

    Ok(full_route)
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
pub struct FullDefaultRoute {
    #[cfg(target_os = "macos")]
    iface: String,
    bypass_target: Option<IpAddr>,
    original_default: CapturedDefaultRoute,
    reverted: bool,
}

#[cfg(any(target_os = "linux", target_os = "macos", test))]
fn ipv4_default_swap_bypass_target(upstream_ip: IpAddr) -> Option<IpAddr> {
    upstream_ip.is_ipv4().then_some(upstream_ip)
}

/// Captured underlay default route, used to restore on Drop. The
/// shape differs by platform — Linux carries the raw `ip route show
/// default` line so `ip route replace` puts it back verbatim; macOS
/// carries gateway + interface so we can call `route add default`.
#[cfg(any(target_os = "linux", target_os = "macos"))]
#[derive(Debug, Clone)]
struct CapturedDefaultRoute {
    #[cfg(target_os = "linux")]
    line: String,
    #[cfg(target_os = "macos")]
    gateway: String,
    #[cfg(target_os = "macos")]
    interface: String,
}

#[cfg(any(target_os = "macos", test))]
fn macos_underlay_gateway_interface_from_netstat(output: &str) -> Option<(String, String)> {
    output.lines().find_map(|line| {
        let tokens = line.split_whitespace().collect::<Vec<_>>();
        if tokens.len() < 4 || tokens[0] != "default" {
            return None;
        }
        let gateway = tokens[1];
        let interface = tokens.last().copied().unwrap_or("");
        if interface.starts_with("utun")
            || interface.starts_with("bridge")
            || interface == "lo0"
            || gateway.starts_with("link#")
        {
            return None;
        }
        Some((gateway.to_string(), interface.to_string()))
    })
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn capture_default_route() -> Result<CapturedDefaultRoute> {
    #[cfg(target_os = "linux")]
    {
        let output = ProcessCommand::new("ip")
            .arg("-4")
            .arg("route")
            .arg("show")
            .arg("default")
            .output()
            .context("ip route show default")?;
        if !output.status.success() {
            return Err(anyhow!("ip route show default exited {}", output.status));
        }
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Take the first non-empty line, prefer one that doesn't go
        // through a utun (in case a previous run left a stale default
        // there; this is the kind of state the watchdog protects
        // against, but capturing the wrong one would be terminal).
        let line = stdout
            .lines()
            .find(|line| {
                let line = line.trim();
                !line.is_empty()
                    && !line.contains(" dev utun")
                    && !line.contains(" dev wg-")
                    && !line.contains(" dev nvpn-wg")
            })
            .or_else(|| stdout.lines().find(|line| !line.trim().is_empty()))
            .ok_or_else(|| anyhow!("no IPv4 default route found"))?
            .trim()
            .to_string();
        Ok(CapturedDefaultRoute { line })
    }
    #[cfg(target_os = "macos")]
    {
        let output = ProcessCommand::new("netstat")
            .arg("-rn")
            .arg("-f")
            .arg("inet")
            .output()
            .context("netstat -rn -f inet")?;
        if !output.status.success() {
            return Err(anyhow!("netstat exited {}", output.status));
        }
        let stdout = String::from_utf8_lossy(&output.stdout);
        if let Some((gateway, interface)) =
            macos_underlay_gateway_interface_from_netstat(&stdout)
        {
            return Ok(CapturedDefaultRoute {
                gateway,
                interface,
            });
        }

        // Packet-tunnel Network Extensions can leave only an interface-scoped
        // utun default visible in netstat. DHCP still knows the physical
        // gateway, and that is the route the WireGuard endpoint bypass needs.
        if let Some(route) = crate::macos_underlay_default_route_from_system()? {
            let gateway = route
                .gateway
                .ok_or_else(|| anyhow!("macOS underlay route has no gateway"))?;
            return Ok(CapturedDefaultRoute {
                gateway,
                interface: route.interface,
            });
        }
        Err(anyhow!(
            "no physical IPv4 default route or DHCP underlay gateway found"
        ))
    }
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn install_endpoint_bypass(target: &IpAddr, original: &CapturedDefaultRoute) -> Result<()> {
    let target_str = target.to_string();
    #[cfg(target_os = "linux")]
    {
        // Reuse the captured `ip route show default` line, just swap
        // the destination from "default" to the host IP. e.g.
        //   "default via 192.168.1.1 dev en0 ..." →
        //   "192.168.1.1/32 ..." with the rest preserved.
        let after_default = original
            .line
            .strip_prefix("default ")
            .unwrap_or(&original.line)
            .trim();
        let mut command = ProcessCommand::new("ip");
        command
            .arg("route")
            .arg("replace")
            .arg(format!("{target_str}/32"));
        for arg in after_default.split_whitespace() {
            command.arg(arg);
        }
        run_checked(&mut command)?;
    }
    #[cfg(target_os = "macos")]
    {
        // The daemon installs 0/1 + 128/1 routes through the WG utun.
        // The WG server itself must be an unscoped host route so
        // ordinary lookups still prefer the underlay gateway.
        let _ = ProcessCommand::new("route")
            .arg("-n")
            .arg("delete")
            .arg("-host")
            .arg(&target_str)
            .arg("-ifscope")
            .arg(&original.interface)
            .status();
        let _ = ProcessCommand::new("route")
            .arg("-n")
            .arg("delete")
            .arg("-host")
            .arg(&target_str)
            .status();
        run_checked(
            ProcessCommand::new("route")
                .arg("-n")
                .arg("add")
                .arg("-host")
                .arg(&target_str)
                .arg(&original.gateway),
        )?;
    }
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn install_default_via_iface(iface: &str, _src: &str) -> Result<()> {
    #[cfg(target_os = "linux")]
    {
        // Replace the default route to go via the WG iface.
        run_checked(
            ProcessCommand::new("ip")
                .arg("-4")
                .arg("route")
                .arg("replace")
                .arg("default")
                .arg("dev")
                .arg(iface)
                .arg("src")
                .arg(_src),
        )?;
    }
    #[cfg(target_os = "macos")]
    {
        // Keep the underlay default route intact and steer ordinary
        // internet traffic through the WG utun with two covering /1s.
        // This mirrors the main macOS tunnel path and avoids restoring
        // an accidentally interface-scoped default during cleanup.
        for target in MACOS_WG_DEFAULT_ROUTE_TARGETS {
            run_checked(
                ProcessCommand::new("route")
                    .arg("-n")
                    .arg("add")
                    .arg("-net")
                    .arg(target)
                    .arg("-interface")
                    .arg(iface),
            )?;
        }
    }
    Ok(())
}

#[cfg(any(target_os = "macos", test))]
fn macos_wg_default_route_cleanup_args(iface: &str) -> Vec<Vec<String>> {
    MACOS_WG_DEFAULT_ROUTE_TARGETS
        .iter()
        .map(|target| {
            vec![
                "-n".to_string(),
                "delete".to_string(),
                "-net".to_string(),
                (*target).to_string(),
                "-interface".to_string(),
                iface.to_string(),
            ]
        })
        .collect()
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
impl FullDefaultRoute {
    /// Cleanup explicitly. Returning a `Result` lets the caller see
    /// what failed; on Drop the result is ignored.
    pub fn revert(&mut self) -> Result<()> {
        if self.reverted {
            return Ok(());
        }
        // Linux replaces its default and restores it first. macOS leaves
        // the underlay default intact and only removes its two covering /1s.
        #[cfg(target_os = "linux")]
        {
            // `ip route replace` is idempotent: it'll overwrite
            // whatever the default currently is (likely "dev <wg
            // iface>").
            let mut command = ProcessCommand::new("ip");
            command.arg("route").arg("replace");
            for arg in self.original_default.line.split_whitespace() {
                command.arg(arg);
            }
            run_checked(&mut command)?;
            if let Some(target) = self.bypass_target {
                let _ = ProcessCommand::new("ip")
                    .arg("route")
                    .arg("del")
                    .arg(format!("{target}/32"))
                    .status();
            }
        }
        #[cfg(target_os = "macos")]
        {
            for args in macos_wg_default_route_cleanup_args(&self.iface) {
                let _ = ProcessCommand::new("route").args(args).status();
            }
            if let Some(target) = self.bypass_target {
                let target = target.to_string();
                let _ = ProcessCommand::new("route")
                    .arg("-n")
                    .arg("delete")
                    .arg("-host")
                    .arg(&target)
                    .arg(&self.original_default.gateway)
                    .arg("-ifscope")
                    .arg(&self.original_default.interface)
                    .status();
                let _ = ProcessCommand::new("route")
                    .arg("-n")
                    .arg("delete")
                    .arg("-host")
                    .arg(&target)
                    .arg("-ifscope")
                    .arg(&self.original_default.interface)
                    .status();
                let _ = ProcessCommand::new("route")
                    .arg("-n")
                    .arg("delete")
                    .arg("-host")
                    .arg(&target)
                    .status();
            }
        }
        self.reverted = true;
        Ok(())
    }
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
impl Drop for FullDefaultRoute {
    fn drop(&mut self) {
        if let Err(error) = self.revert() {
            eprintln!(
                "wg-upstream: WARNING — failed to restore default route on cleanup: {error}. \
                 You may need to run `route delete default && route add default <gateway>` \
                 (macOS) or `ip route replace {}` (Linux) manually.",
                self.original_default_repr()
            );
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
impl FullDefaultRoute {
    fn original_default_repr(&self) -> String {
        #[cfg(target_os = "linux")]
        {
            self.original_default.line.clone()
        }
        #[cfg(target_os = "macos")]
        {
            format!("default via {}", self.original_default.gateway)
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
impl Drop for ScopedHostRoute {
    fn drop(&mut self) {
        let target = self.target.to_string();
        #[cfg(target_os = "linux")]
        {
            let _ = ProcessCommand::new("ip")
                .arg("route")
                .arg("del")
                .arg(format!("{target}/32"))
                .arg("dev")
                .arg(&self.iface)
                .status();
        }
        #[cfg(target_os = "macos")]
        {
            let _ = ProcessCommand::new("route")
                .arg("-n")
                .arg("delete")
                .arg("-host")
                .arg(&target)
                .arg("-interface")
                .arg(&self.iface)
                .status();
        }
    }
}
