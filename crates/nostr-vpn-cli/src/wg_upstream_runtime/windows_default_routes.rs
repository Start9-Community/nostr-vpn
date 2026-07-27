// POSIX, but the routing table is driven by `netsh interface ipv4`
// instead of `ip` / `route`, and the WG iface is identified by its
// kernel interface index rather than a name. The captured original
// default route is held verbatim from `route print 0.0.0.0` so we can
// re-add it on cleanup.
// ---------------------------------------------------------------------------

#[cfg(any(test, target_os = "windows"))]
const WINDOWS_ROUTE_CLEANUP_ATTEMPTS: usize = 3;

#[cfg(any(test, target_os = "windows"))]
#[derive(Debug, Clone, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
struct WindowsRouteSpec {
    prefix: String,
    interface_index: u32,
    next_hop: String,
    metric: u32,
}

#[cfg(any(test, target_os = "windows"))]
impl WindowsRouteSpec {
    fn endpoint(target: std::net::Ipv4Addr, underlay: &WindowsDefaultRoute) -> Self {
        Self {
            prefix: format!("{target}/32"),
            interface_index: underlay.interface_index,
            next_hop: underlay.gateway.clone(),
            metric: 1,
        }
    }

    fn wireguard_default(interface_index: u32) -> Self {
        Self {
            prefix: "0.0.0.0/0".to_string(),
            interface_index,
            next_hop: "0.0.0.0".to_string(),
            metric: 1,
        }
    }

    fn direct(prefix: &str, interface_index: u32) -> Result<Self> {
        let prefix = prefix.trim();
        let (address, prefix_len) = prefix
            .split_once('/')
            .ok_or_else(|| anyhow!("Windows route prefix must be IPv4 CIDR: {prefix}"))?;
        address
            .parse::<std::net::Ipv4Addr>()
            .with_context(|| format!("invalid Windows route IPv4 address {address}"))?;
        let prefix_len = prefix_len
            .parse::<u8>()
            .with_context(|| format!("invalid Windows route prefix length {prefix_len}"))?;
        if prefix_len > 32 {
            return Err(anyhow!("invalid Windows route prefix length {prefix_len}"));
        }
        Ok(Self {
            prefix: prefix.to_string(),
            interface_index,
            next_hop: "0.0.0.0".to_string(),
            metric: 1,
        })
    }
}

#[cfg(any(test, target_os = "windows"))]
trait WindowsRouteCommandRunner {
    fn route_exists(&mut self, route: &WindowsRouteSpec) -> Result<bool>;
    fn route_identity_exists(&mut self, route: &WindowsRouteSpec) -> Result<bool>;
    fn add_route(&mut self, route: &WindowsRouteSpec) -> Result<()>;
    fn set_route(&mut self, route: &WindowsRouteSpec) -> Result<()>;
    fn delete_route(&mut self, route: &WindowsRouteSpec) -> Result<()>;
}

#[cfg(any(test, target_os = "windows"))]
#[derive(Debug)]
struct WindowsRouteApplyFailure<T> {
    error: anyhow::Error,
    cleanup: T,
}

#[cfg(any(test, target_os = "windows"))]
impl<T> std::fmt::Display for WindowsRouteApplyFailure<T> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(&self.error, formatter)
    }
}

#[cfg(any(test, target_os = "windows"))]
impl<T: std::fmt::Debug> std::error::Error for WindowsRouteApplyFailure<T> {}

#[cfg(target_os = "windows")]
struct SystemWindowsRouteCommandRunner;

#[cfg(target_os = "windows")]
impl WindowsRouteCommandRunner for SystemWindowsRouteCommandRunner {
    fn route_exists(&mut self, route: &WindowsRouteSpec) -> Result<bool> {
        windows_route_exists(route, true)
    }

    fn route_identity_exists(&mut self, route: &WindowsRouteSpec) -> Result<bool> {
        windows_route_exists(route, false)
    }

    fn add_route(&mut self, route: &WindowsRouteSpec) -> Result<()> {
        run_windows_netsh(&windows_route_add_args(route))
    }

    fn set_route(&mut self, route: &WindowsRouteSpec) -> Result<()> {
        run_windows_netsh(&windows_route_set_args(route))
    }

    fn delete_route(&mut self, route: &WindowsRouteSpec) -> Result<()> {
        run_windows_netsh(&windows_route_delete_args(route))
    }
}

#[cfg(any(test, target_os = "windows"))]
#[derive(Debug)]
struct WindowsManagedDefaultRoutes {
    wg_iface_index: u32,
    bypass_target: std::net::Ipv4Addr,
    underlay: WindowsDefaultRoute,
    bypass_owned: bool,
    manage_default: bool,
    default_owned: bool,
    orphaned_bypass_routes: Vec<WindowsRouteSpec>,
}

#[cfg(any(test, target_os = "windows"))]
impl WindowsManagedDefaultRoutes {
    fn apply_with(
        runner: &mut impl WindowsRouteCommandRunner,
        wg_iface_index: u32,
        upstream_ip: std::net::Ipv4Addr,
        underlay: WindowsDefaultRoute,
        manage_default: bool,
    ) -> std::result::Result<Self, WindowsRouteApplyFailure<Self>> {
        let mut routes = Self {
            wg_iface_index,
            bypass_target: upstream_ip,
            underlay,
            bypass_owned: false,
            manage_default,
            default_owned: false,
            orphaned_bypass_routes: Vec::new(),
        };
        if let Err(error) = validate_windows_underlay(&routes.underlay, &[wg_iface_index]) {
            return Err(WindowsRouteApplyFailure {
                error,
                cleanup: routes,
            });
        }
        let bypass = WindowsRouteSpec::endpoint(upstream_ip, &routes.underlay);
        match ensure_windows_route(runner, &bypass) {
            Ok(owned) => routes.bypass_owned = owned,
            Err(error) => {
                return Err(WindowsRouteApplyFailure {
                    error: error.context("install WireGuard endpoint bypass route"),
                    cleanup: routes,
                });
            }
        }
        if manage_default {
            let default = WindowsRouteSpec::wireguard_default(wg_iface_index);
            match ensure_windows_route(runner, &default) {
                Ok(owned) => routes.default_owned = owned,
                Err(error) => {
                    let rollback = routes.revert_with(runner);
                    return Err(WindowsRouteApplyFailure {
                        error: with_windows_route_rollback(
                            error.context("install WireGuard default route"),
                            rollback,
                        ),
                        cleanup: routes,
                    });
                }
            }
        }
        Ok(routes)
    }

    #[cfg(test)]
    fn refresh_with(
        &mut self,
        runner: &mut impl WindowsRouteCommandRunner,
        fresh_underlay: WindowsDefaultRoute,
        excluded_tunnel_interfaces: &[u32],
    ) -> Result<bool> {
        self.reconcile_with(
            runner,
            self.bypass_target,
            fresh_underlay,
            excluded_tunnel_interfaces,
        )
    }

    fn reconcile_with(
        &mut self,
        runner: &mut impl WindowsRouteCommandRunner,
        fresh_target: std::net::Ipv4Addr,
        fresh_underlay: WindowsDefaultRoute,
        excluded_tunnel_interfaces: &[u32],
    ) -> Result<bool> {
        self.cleanup_orphaned_bypasses_with(runner)
            .context("retry cleanup of a prior Windows endpoint-route rollback")?;
        let mut excluded = excluded_tunnel_interfaces.to_vec();
        excluded.push(self.wg_iface_index);
        validate_windows_underlay(&fresh_underlay, &excluded)?;
        let repaired = self
            .repair_current_routes_with(runner)
            .context("repair tracked WireGuard routes before underlay refresh")?;
        if self.underlay == fresh_underlay && self.bypass_target == fresh_target {
            return Ok(repaired);
        }

        let stale_bypass = WindowsRouteSpec::endpoint(self.bypass_target, &self.underlay);
        let fresh_bypass = WindowsRouteSpec::endpoint(fresh_target, &fresh_underlay);
        if stale_bypass == fresh_bypass {
            // A DHCP renewal can replace only the local source address while
            // retaining the interface/gateway tuple. The existing owned route
            // is still the exact desired bypass and must retain its ownership.
            self.underlay = fresh_underlay;
            return Ok(true);
        }

        // The replacement bypass must be usable before the old bypass is
        // removed, otherwise the WireGuard transport can be routed into itself.
        let fresh_owned = ensure_windows_route(runner, &fresh_bypass)
            .context("install fresh WireGuard endpoint bypass route")?;
        if self.bypass_owned
            && let Err(error) = delete_windows_route_with_retry(runner, &stale_bypass)
        {
            let rollback = if fresh_owned {
                delete_windows_route_with_retry(runner, &fresh_bypass)
            } else {
                Ok(())
            };
            if fresh_owned && rollback.is_err() {
                self.orphaned_bypass_routes.push(fresh_bypass);
            }
            return Err(with_windows_route_rollback(
                error.context("remove stale WireGuard endpoint bypass route"),
                rollback,
            ));
        }

        self.bypass_target = fresh_target;
        self.underlay = fresh_underlay;
        self.bypass_owned = fresh_owned;
        Ok(true)
    }

    fn revert_with(&mut self, runner: &mut impl WindowsRouteCommandRunner) -> Result<()> {
        let mut failures = Vec::new();
        if self.default_owned {
            let route = WindowsRouteSpec::wireguard_default(self.wg_iface_index);
            match delete_windows_route_with_retry(runner, &route) {
                Ok(()) => self.default_owned = false,
                Err(error) => failures.push(format!("remove WireGuard default route: {error:#}")),
            }
        }
        if self.bypass_owned {
            let route = WindowsRouteSpec::endpoint(self.bypass_target, &self.underlay);
            match delete_windows_route_with_retry(runner, &route) {
                Ok(()) => self.bypass_owned = false,
                Err(error) => {
                    failures.push(format!("remove WireGuard endpoint bypass route: {error:#}"))
                }
            }
        }
        if let Err(error) = self.cleanup_orphaned_bypasses_with(runner) {
            failures.push(format!(
                "remove residual WireGuard endpoint bypass routes: {error:#}"
            ));
        }
        if failures.is_empty() {
            Ok(())
        } else {
            Err(anyhow!(failures.join("; ")))
        }
    }

    fn cleanup_orphaned_bypasses_with(
        &mut self,
        runner: &mut impl WindowsRouteCommandRunner,
    ) -> Result<()> {
        let mut remaining = Vec::new();
        let mut failures = Vec::new();
        for route in self.orphaned_bypass_routes.drain(..) {
            if let Err(error) = delete_windows_route_with_retry(runner, &route) {
                failures.push(format!("{}: {error:#}", route.prefix));
                remaining.push(route);
            }
        }
        self.orphaned_bypass_routes = remaining;
        if failures.is_empty() {
            Ok(())
        } else {
            Err(anyhow!(failures.join("; ")))
        }
    }

    fn repair_current_routes_with(
        &mut self,
        runner: &mut impl WindowsRouteCommandRunner,
    ) -> Result<bool> {
        let bypass = WindowsRouteSpec::endpoint(self.bypass_target, &self.underlay);
        let repaired_bypass = ensure_tracked_windows_route(runner, &bypass, self.bypass_owned)
            .context("ensure current WireGuard endpoint bypass route")?;
        if repaired_bypass {
            self.bypass_owned = true;
        }
        let repaired_default = if self.manage_default {
            let route = WindowsRouteSpec::wireguard_default(self.wg_iface_index);
            match ensure_tracked_windows_route(runner, &route, self.default_owned) {
                Ok(owned) => {
                    if owned {
                        self.default_owned = true;
                    }
                    owned
                }
                Err(error) => {
                    let rollback = if repaired_bypass {
                        delete_windows_route_with_retry(runner, &bypass)
                    } else {
                        Ok(())
                    };
                    if repaired_bypass && rollback.is_ok() {
                        self.bypass_owned = false;
                    }
                    return Err(with_windows_route_rollback(
                        error.context("ensure current WireGuard default route"),
                        rollback,
                    ));
                }
            }
        } else {
            false
        };
        Ok(repaired_bypass || repaired_default)
    }

    fn cleanup_snapshot(&self) -> WindowsRouteCleanupSnapshot {
        let mut owned_routes = Vec::new();
        if self.default_owned {
            owned_routes.push(WindowsRouteSpec::wireguard_default(self.wg_iface_index));
        }
        if self.bypass_owned {
            owned_routes.push(WindowsRouteSpec::endpoint(
                self.bypass_target,
                &self.underlay,
            ));
        }
        owned_routes.extend(self.orphaned_bypass_routes.iter().cloned());
        WindowsRouteCleanupSnapshot::from_owned_routes(owned_routes)
    }

    fn take_cleanup_snapshot(&mut self) -> WindowsRouteCleanupSnapshot {
        let cleanup = self.cleanup_snapshot();
        self.default_owned = false;
        self.bypass_owned = false;
        self.orphaned_bypass_routes.clear();
        cleanup
    }

    fn revert_retaining_pending_with(
        &mut self,
        runner: &mut impl WindowsRouteCommandRunner,
    ) -> Result<()> {
        let result = self.revert_with(runner);
        if result.is_err() {
            let cleanup = self.take_cleanup_snapshot();
            retain_pending_windows_route_cleanup(cleanup);
        }
        result
    }
}
