#[cfg(target_os = "linux")]
use crate::{
    LinuxExitNodeRuntime, LinuxNetworkCleanupState, LinuxWireGuardExitRuntime,
};

#[cfg(any(test, target_os = "linux"))]
const LINUX_NETWORK_CLEANUP_ATTEMPTS: usize = 3;

#[cfg(target_os = "linux")]
static PENDING_LINUX_NETWORK_CLEANUP: std::sync::Mutex<Option<LinuxNetworkCleanupState>> =
    std::sync::Mutex::new(None);

#[cfg(target_os = "linux")]
pub(crate) fn pending_linux_network_cleanup_state() -> Option<LinuxNetworkCleanupState> {
    PENDING_LINUX_NETWORK_CLEANUP
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone()
}

#[cfg(target_os = "linux")]
fn retain_pending_linux_network_cleanup_state(state: LinuxNetworkCleanupState) {
    *PENDING_LINUX_NETWORK_CLEANUP
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(state);
}

#[cfg(all(test, target_os = "linux"))]
fn take_pending_linux_network_cleanup_state() -> Option<LinuxNetworkCleanupState> {
    PENDING_LINUX_NETWORK_CLEANUP
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
}

#[cfg(any(test, target_os = "linux"))]
trait LinuxNetworkCleanupActions {
    fn cleanup_endpoint_bypass_routes(&mut self) -> anyhow::Result<()>;
    fn cleanup_forwarding_and_wireguard(&mut self) -> anyhow::Result<()>;
    fn restore_original_ipv4_default(&mut self);
    fn restore_original_ipv6_default(&mut self);
    fn ipv4_default_restore_pending(&self) -> bool;
    fn ipv6_default_restore_pending(&self) -> bool;
    fn flush_route_cache(&mut self) -> anyhow::Result<()>;
}

#[cfg(any(test, target_os = "linux"))]
fn cleanup_linux_network_state_with_actions(
    actions: &mut impl LinuxNetworkCleanupActions,
) -> anyhow::Result<()> {
    let mut failures = Vec::new();
    let mut endpoint_cleanup_error = None;
    for _ in 0..LINUX_NETWORK_CLEANUP_ATTEMPTS {
        match actions.cleanup_endpoint_bypass_routes() {
            Ok(()) => {
                endpoint_cleanup_error = None;
                break;
            }
            Err(error) => endpoint_cleanup_error = Some(error),
        }
    }
    if let Some(error) = endpoint_cleanup_error {
        failures.push(format!(
            "endpoint bypass cleanup failed after three attempts: {error:#}"
        ));
    }

    let mut forwarding_cleanup_error = None;
    for _ in 0..LINUX_NETWORK_CLEANUP_ATTEMPTS {
        match actions.cleanup_forwarding_and_wireguard() {
            Ok(()) => {
                forwarding_cleanup_error = None;
                break;
            }
            Err(error) => forwarding_cleanup_error = Some(error),
        }
    }
    if let Some(error) = forwarding_cleanup_error {
        failures.push(format!(
            "forwarding/WireGuard cleanup failed after three attempts: {error:#}"
        ));
    }

    // Physical default restoration and cache invalidation are independent
    // safety obligations. They must run even when overlay-owned cleanup is
    // still incomplete, otherwise a transient firewall or WireGuard teardown
    // error can strand native internet access.
    actions.restore_original_ipv4_default();
    actions.restore_original_ipv6_default();
    if actions.ipv4_default_restore_pending() {
        failures.push("failed to restore original IPv4 default route".to_string());
    }
    if actions.ipv6_default_restore_pending() {
        failures.push("failed to restore original IPv6 default route".to_string());
    }
    if let Err(error) = actions.flush_route_cache() {
        failures.push(format!("failed to flush Linux route cache: {error:#}"));
    }

    if failures.is_empty() {
        Ok(())
    } else {
        Err(anyhow::anyhow!(
            "Linux network cleanup remains incomplete: {}",
            failures.join("; ")
        ))
    }
}

#[cfg(target_os = "linux")]
impl LinuxNetworkCleanupActions for FipsPrivateTunnelRuntime {
    fn cleanup_endpoint_bypass_routes(&mut self) -> anyhow::Result<()> {
        self.reconcile_linux_endpoint_bypass_routes(&[])
    }

    fn cleanup_forwarding_and_wireguard(&mut self) -> anyhow::Result<()> {
        self.reconcile_linux_exit_node_forwarding_cleanup()
    }

    fn restore_original_ipv4_default(&mut self) {
        self.restore_linux_original_default_route();
    }

    fn restore_original_ipv6_default(&mut self) {
        self.restore_linux_original_default_ipv6_route();
    }

    fn ipv4_default_restore_pending(&self) -> bool {
        self.original_default_route.is_some()
    }

    fn ipv6_default_restore_pending(&self) -> bool {
        self.original_default_ipv6_route.is_some()
    }

    fn flush_route_cache(&mut self) -> anyhow::Result<()> {
        crate::flush_linux_route_cache()
    }
}

#[cfg(target_os = "linux")]
impl LinuxNetworkCleanupState {
    pub(crate) fn from_runtime(runtime: &FipsPrivateTunnelRuntime) -> Option<Self> {
        let state = Self {
            iface: runtime.iface.clone(),
            endpoint_bypass_routes: runtime.endpoint_bypass_routes.clone(),
            original_default_route: runtime.original_default_route.clone(),
            original_default_ipv6_route: runtime.original_default_ipv6_route.clone(),
            exit_node_runtime: runtime.exit_node_runtime.clone(),
        };
        (!state.is_empty()).then_some(state)
    }

    fn is_empty(&self) -> bool {
        self.endpoint_bypass_routes.is_empty()
            && self.original_default_route.is_none()
            && self.original_default_ipv6_route.is_none()
            && linux_exit_cleanup_state_is_empty(&self.exit_node_runtime)
    }
}

#[cfg(target_os = "linux")]
fn linux_exit_cleanup_state_is_empty(state: &LinuxExitNodeRuntime) -> bool {
    state.ipv4_outbound_iface.is_none()
        && state.ipv6_outbound_iface.is_none()
        && state.ipv4_tunnel_source_cidr.is_none()
        && state.ipv4_mss_clamp.is_none()
        && state.ipv4_forward_was_enabled.is_none()
        && state.ipv6_forward_was_enabled.is_none()
        && state.wireguard_exit.is_none()
        && state.pending_wireguard_exit_cleanup.is_empty()
}

#[cfg(target_os = "linux")]
fn cleanup_linux_endpoint_bypass_state(state: &mut LinuxNetworkCleanupState) -> Result<()> {
    let mut remaining = Vec::new();
    let mut failures = Vec::new();
    for route in std::mem::take(&mut state.endpoint_bypass_routes) {
        match crate::restore_linux_managed_endpoint_bypass_route(&route) {
            Ok(()) => {}
            Err(error) => {
                failures.push(format!("{}: {error:#}", route.route.target));
                remaining.push(route);
            }
        }
    }
    state.endpoint_bypass_routes = remaining;
    if failures.is_empty() {
        Ok(())
    } else {
        Err(anyhow!(
            "failed to restore endpoint bypass routes: {}",
            failures.join("; ")
        ))
    }
}

#[cfg(target_os = "linux")]
fn restore_linux_saved_default(route: &mut Option<String>, ipv6: bool) {
    let Some(saved) = route.take() else {
        return;
    };
    let result = if ipv6 {
        crate::restore_linux_default_ipv6_route(&saved)
    } else {
        crate::restore_linux_default_route(&saved)
    };
    if result.is_err() {
        *route = Some(saved);
    }
}

#[cfg(target_os = "linux")]
fn cleanup_linux_wireguard_inbound_guard(
    iface: &str,
    runtime: &LinuxWireGuardExitRuntime,
) -> Result<()> {
    let rule = crate::linux_wireguard_exit_inbound_drop_rule(
        &runtime.interface,
        iface,
        &runtime.source_cidr,
    );
    let mut last_error = None;
    for _ in 0..LINUX_NETWORK_CLEANUP_ATTEMPTS {
        match crate::linux_iptables_delete_rule(
            crate::LinuxExitNodeIpFamily::V4,
            None,
            &rule,
        ) {
            Ok(()) => return Ok(()),
            Err(error) => last_error = Some(error),
        }
    }
    Err(last_error.expect("cleanup attempts are non-zero"))
        .context("remove WireGuard inbound guard")
}

#[cfg(target_os = "linux")]
fn cleanup_linux_wireguard_state(iface: &str, state: &mut LinuxExitNodeRuntime) -> Result<()> {
    let pending = std::mem::take(&mut state.pending_wireguard_exit_cleanup);
    let mut remaining = Vec::new();
    let mut failures = Vec::new();
    for mut obligation in pending {
        if let Err(error) = crate::cleanup_linux_wireguard_exit_obligation(&mut obligation) {
            failures.push(format!("retained apply rollback: {error:#}"));
            remaining.push(obligation);
        }
    }
    state.pending_wireguard_exit_cleanup = remaining;

    if let Some(runtime) = state.wireguard_exit.take() {
        let guard = cleanup_linux_wireguard_inbound_guard(iface, &runtime);
        let network = crate::cleanup_linux_wireguard_exit_upstream(&runtime);
        if guard.is_ok() && network.is_ok() {
        } else {
            if let Err(error) = guard {
                failures.push(format!("inbound guard: {error:#}"));
            }
            if let Err(error) = network {
                failures.push(format!("WireGuard network state: {error:#}"));
            }
            state.wireguard_exit = Some(runtime);
        }
    }

    if failures.is_empty() {
        Ok(())
    } else {
        Err(anyhow!(
            "Linux WireGuard cleanup incomplete: {}",
            failures.join("; ")
        ))
    }
}

#[cfg(target_os = "linux")]
fn cleanup_linux_legacy_forwarding_rules(iface: &str) -> Result<()> {
    let mut failures = Vec::new();
    for family in [
        crate::LinuxExitNodeIpFamily::V4,
        crate::LinuxExitNodeIpFamily::V6,
    ] {
        let forward_in = crate::linux_exit_node_legacy_forward_in_rule(iface, family);
        let forward_out = crate::linux_exit_node_legacy_forward_out_rule(iface, family);
        if let Err(error) = crate::linux_iptables_delete_rule(family, None, &forward_out) {
            failures.push(format!("remove legacy forward-out rule: {error:#}"));
        }
        if let Err(error) = crate::linux_iptables_delete_rule(family, None, &forward_in) {
            failures.push(format!("remove legacy forward-in rule: {error:#}"));
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(anyhow!(failures.join("; ")))
    }
}

#[cfg(target_os = "linux")]
pub(super) fn cleanup_linux_forwarding_state(
    iface: &str,
    state: &mut LinuxExitNodeRuntime,
) -> Result<()> {
    let mut failures = Vec::new();
    let outbound_iface = state.ipv4_outbound_iface.clone();
    let tunnel_source_cidr = state.ipv4_tunnel_source_cidr.clone();
    let mut firewall_clean = true;
    if let (Some(outbound_iface), Some(tunnel_source_cidr)) =
        (outbound_iface.as_deref(), tunnel_source_cidr.as_deref())
    {
        if let Some(mss) = state.ipv4_mss_clamp {
            let rule = crate::linux_exit_node_ipv4_mss_clamp_rule(
                iface,
                outbound_iface,
                tunnel_source_cidr,
                mss,
            );
            if let Err(error) = crate::linux_iptables_delete_rule(
                crate::LinuxExitNodeIpFamily::V4,
                Some("mangle"),
                &rule,
            ) {
                firewall_clean = false;
                failures.push(format!("remove MSS clamp rule: {error:#}"));
            }
        }
        let forward_in = crate::linux_exit_node_forward_in_rule(
            iface,
            outbound_iface,
            tunnel_source_cidr,
            crate::LinuxExitNodeIpFamily::V4,
        );
        let forward_out = crate::linux_exit_node_forward_out_rule(
            iface,
            outbound_iface,
            crate::LinuxExitNodeIpFamily::V4,
        );
        let masquerade =
            crate::linux_exit_node_ipv4_masquerade_rule(outbound_iface, tunnel_source_cidr);
        for (label, table, rule) in [
            ("masquerade", Some("nat"), &masquerade),
            ("forward-out", None, &forward_out),
            ("forward-in", None, &forward_in),
        ] {
            if let Err(error) = crate::linux_iptables_delete_rule(
                crate::LinuxExitNodeIpFamily::V4,
                table,
                rule,
            ) {
                firewall_clean = false;
                failures.push(format!("remove {label} rule: {error:#}"));
            }
        }
    } else if outbound_iface.is_some()
        || tunnel_source_cidr.is_some()
        || state.ipv4_mss_clamp.is_some()
    {
        firewall_clean = false;
        failures.push("incomplete retained IPv4 firewall ownership identity".to_string());
    }
    if firewall_clean {
        state.ipv4_outbound_iface = None;
        state.ipv4_tunnel_source_cidr = None;
        state.ipv4_mss_clamp = None;
    }

    if let Err(error) = cleanup_linux_legacy_forwarding_rules(iface) {
        failures.push(format!("legacy forwarding rules: {error:#}"));
    }
    for (family, previous, label) in [
        (
            crate::LinuxExitNodeIpFamily::V4,
            &mut state.ipv4_forward_was_enabled,
            "IPv4",
        ),
        (
            crate::LinuxExitNodeIpFamily::V6,
            &mut state.ipv6_forward_was_enabled,
            "IPv6",
        ),
    ] {
        if *previous == Some(false) {
            match crate::write_linux_ip_forward(family, false) {
                Ok(()) => *previous = None,
                Err(error) => failures.push(format!("restore {label} forwarding: {error:#}")),
            }
        } else {
            *previous = None;
        }
    }
    state.ipv6_outbound_iface = None;

    if failures.is_empty() {
        Ok(())
    } else {
        Err(anyhow!(
            "Linux exit forwarding cleanup incomplete: {}",
            failures.join("; ")
        ))
    }
}

#[cfg(target_os = "linux")]
pub(super) fn cleanup_linux_exit_node_state(
    iface: &str,
    state: &mut LinuxExitNodeRuntime,
) -> Result<()> {
    let forwarding = cleanup_linux_forwarding_state(iface, state);
    let wireguard = cleanup_linux_wireguard_state(iface, state);
    match (forwarding, wireguard) {
        (Ok(()), Ok(())) => {
            *state = LinuxExitNodeRuntime::default();
            Ok(())
        }
        (Err(forwarding), Ok(())) => Err(forwarding),
        (Ok(()), Err(wireguard)) => Err(wireguard),
        (Err(forwarding), Err(wireguard)) => Err(anyhow!(
            "forwarding cleanup failed ({forwarding:#}); \
             WireGuard cleanup failed ({wireguard:#})"
        )),
    }
}

#[cfg(target_os = "linux")]
impl LinuxNetworkCleanupActions for LinuxNetworkCleanupState {
    fn cleanup_endpoint_bypass_routes(&mut self) -> Result<()> {
        cleanup_linux_endpoint_bypass_state(self)
    }

    fn cleanup_forwarding_and_wireguard(&mut self) -> Result<()> {
        let iface = self.iface.clone();
        cleanup_linux_exit_node_state(&iface, &mut self.exit_node_runtime)
    }

    fn restore_original_ipv4_default(&mut self) {
        restore_linux_saved_default(&mut self.original_default_route, false);
    }

    fn restore_original_ipv6_default(&mut self) {
        restore_linux_saved_default(&mut self.original_default_ipv6_route, true);
    }

    fn ipv4_default_restore_pending(&self) -> bool {
        self.original_default_route.is_some()
    }

    fn ipv6_default_restore_pending(&self) -> bool {
        self.original_default_ipv6_route.is_some()
    }

    fn flush_route_cache(&mut self) -> Result<()> {
        crate::flush_linux_route_cache()
    }
}

#[cfg(target_os = "linux")]
pub(crate) fn repair_linux_network_cleanup_state(
    state: &mut LinuxNetworkCleanupState,
) -> Result<()> {
    cleanup_linux_network_state_with_actions(state)
}
