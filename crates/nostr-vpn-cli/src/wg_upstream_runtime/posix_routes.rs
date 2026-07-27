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
/// route **all** outbound traffic through it (Mullvad/Proton-style).
/// Linux installs a bypass /32 route for the WG endpoint. macOS binds
/// the encrypted UDP socket directly to the selected physical interface,
/// so no endpoint route is created or carried across underlay changes.
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

    // Linux replaces its default, so capture it and install an endpoint
    // bypass before touching routes. macOS keeps its physical default and
    // relies on the interface-bound UDP socket instead.
    #[cfg(target_os = "linux")]
    let original_default = capture_default_route()?;
    #[cfg(target_os = "linux")]
    let bypass_target = upstream_endpoint
        .ip()
        .is_ipv4()
        .then_some(upstream_endpoint.ip());
    #[cfg(target_os = "linux")]
    if let Some(target) = bypass_target.as_ref() {
        install_endpoint_bypass(target, &original_default)?;
    }
    #[cfg(target_os = "macos")]
    let _ = upstream_endpoint;

    let mut full_route = FullDefaultRoute {
        #[cfg(target_os = "macos")]
        iface: iface.to_string(),
        #[cfg(target_os = "linux")]
        bypass_target,
        #[cfg(target_os = "linux")]
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
    #[cfg(target_os = "linux")]
    bypass_target: Option<IpAddr>,
    #[cfg(target_os = "linux")]
    original_default: CapturedDefaultRoute,
    reverted: bool,
}

/// Captured underlay default route, used to restore on Drop. The
/// raw `ip route show default` line lets `ip route replace` put it
/// back verbatim.
#[cfg(target_os = "linux")]
#[derive(Debug, Clone)]
struct CapturedDefaultRoute {
    line: String,
}

#[cfg(target_os = "linux")]
fn capture_default_route() -> Result<CapturedDefaultRoute> {
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

#[cfg(target_os = "linux")]
fn install_endpoint_bypass(target: &IpAddr, original: &CapturedDefaultRoute) -> Result<()> {
    let target_str = target.to_string();
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
    run_checked(&mut command)
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
            crate::macos_network::delete_macos_default_route_for_interface(&self.iface)?;
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
            format!("split defaults on {}", self.iface)
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
