#[cfg(target_os = "windows")]
impl WindowsNetworkCleanupState {
    pub(crate) fn from_runtime_and_pending(
        runtime: Option<&FipsPrivateTunnelRuntime>,
    ) -> Self {
        let mut routes =
            crate::wg_upstream_runtime::pending_windows_route_cleanup_snapshot();
        let mut native_wireguard =
            crate::wg_upstream_runtime::pending_windows_native_cleanup_snapshot();
        if let Some(runtime) = runtime {
            routes.merge(runtime.route_guard.cleanup_snapshot());
            if let Some(endpoint_routes) = runtime.endpoint_bypass_routes.as_ref() {
                routes.merge(endpoint_routes.cleanup_snapshot());
            }
            if let Some(upstream) = runtime.wg_upstream.as_ref() {
                routes.merge(upstream.route_cleanup_snapshot());
                if let Some(native) = upstream.native_cleanup_state() {
                    native_wireguard.push(native);
                }
            }
        }
        Self {
            routes,
            native_wireguard,
        }
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.routes.is_empty() && self.native_wireguard.is_empty()
    }
}

#[cfg(target_os = "windows")]
pub(crate) fn repair_windows_network_cleanup_state(
    state: &mut WindowsNetworkCleanupState,
) -> Result<()> {
    let mut failures = Vec::new();
    if let Err(error) =
        crate::wg_upstream_runtime::retry_windows_route_cleanup_snapshot(&mut state.routes)
    {
        failures.push(format!("Windows routes: {error:#}"));
    }

    let mut remaining_native = Vec::new();
    for mut cleanup in std::mem::take(&mut state.native_wireguard) {
        if let Err(error) =
            crate::wg_upstream_runtime::cleanup_windows_native_wireguard_state(&mut cleanup)
        {
            failures.push(format!("native WireGuard service/config: {error:#}"));
            remaining_native.push(cleanup);
        }
    }
    state.native_wireguard = remaining_native;

    if failures.is_empty() {
        Ok(())
    } else {
        Err(anyhow!(
            "Windows network cleanup remains incomplete: {}",
            failures.join("; ")
        ))
    }
}
