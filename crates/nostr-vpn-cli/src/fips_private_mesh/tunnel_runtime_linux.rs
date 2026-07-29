#[cfg(target_os = "linux")]
fn linux_route_targets_require_ip_endpoint_bypass(route_targets: &[String]) -> bool {
    crate::route_targets_require_endpoint_bypass(route_targets)
}

#[cfg(any(target_os = "linux", test))]
fn linux_strict_exit_requested(route_targets: &[String], exit_node_leak_protection: bool) -> bool {
    exit_node_leak_protection
        && route_targets
            .iter()
            .any(|route| route == "0.0.0.0/0" || route == "::/0")
}

#[cfg(any(target_os = "linux", test))]
fn linux_ipv4_underlay_capture_requested(
    route_targets: &[String],
    wireguard_exit_enabled: bool,
) -> bool {
    wireguard_exit_enabled || route_targets.iter().any(|route| route == "0.0.0.0/0")
}

#[cfg(any(target_os = "linux", test))]
fn linux_ipv4_underlay_restore_due(
    requested_ipv4_exit: bool,
    active_mesh_ipv4_exit: bool,
    wireguard_exit_enabled: bool,
    strict_exit: bool,
) -> bool {
    requested_ipv4_exit
        && !active_mesh_ipv4_exit
        && !wireguard_exit_enabled
        && !strict_exit
}

#[cfg(any(target_os = "linux", test))]
trait LinuxEndpointBypassTarget {
    fn endpoint_bypass_target(&self) -> &str;
}

#[cfg(any(target_os = "linux", test))]
impl LinuxEndpointBypassTarget for String {
    fn endpoint_bypass_target(&self) -> &str {
        self
    }
}

#[cfg(any(target_os = "linux", test))]
impl LinuxEndpointBypassTarget for crate::LinuxManagedEndpointBypassRoute {
    fn endpoint_bypass_target(&self) -> &str {
        &self.route.target
    }
}

#[cfg(any(target_os = "linux", test))]
fn linux_endpoint_bypass_hosts_unchanged<T: LinuxEndpointBypassTarget>(
    current_routes: &[T],
    desired_hosts: &[Ipv4Addr],
) -> bool {
    let mut current_targets = current_routes
        .iter()
        .map(|managed| managed.endpoint_bypass_target().to_string())
        .collect::<Vec<_>>();
    current_targets.sort_unstable();
    current_targets.dedup();

    let mut desired_targets = desired_hosts
        .iter()
        .map(|host| format!("{host}/32"))
        .collect::<Vec<_>>();
    desired_targets.sort_unstable();
    desired_targets.dedup();

    current_targets == desired_targets
}

#[cfg(target_os = "linux")]
fn linux_control_only_network_intent(config: &FipsPrivateTunnelConfig) -> bool {
    config.route_targets.is_empty()
        && config.fips_host.is_none()
        && config.local_exit_forwarding_routes.is_empty()
        && !config.wireguard_exit.enabled
        && !linux_strict_exit_requested(&config.route_targets, config.exit_node_leak_protection)
}

#[cfg(target_os = "linux")]
fn linux_exit_node_runtime_is_inactive(runtime: &crate::LinuxExitNodeRuntime) -> bool {
    runtime.ipv4_outbound_iface.is_none()
        && runtime.ipv6_outbound_iface.is_none()
        && runtime.ipv4_tunnel_source_cidr.is_none()
        && runtime.ipv4_mss_clamp.is_none()
        && runtime.ipv4_forward_was_enabled.is_none()
        && runtime.ipv6_forward_was_enabled.is_none()
        && runtime.wireguard_exit.is_none()
        && runtime.pending_wireguard_exit_cleanup.is_empty()
}

impl FipsPrivateTunnelRuntime {
    #[cfg(target_os = "linux")]
    async fn apply_linux_network_state(&mut self, config: &FipsPrivateTunnelConfig) -> Result<()> {
        let requested_ipv4_exit =
            linux_ipv4_underlay_capture_requested(&config.route_targets, config.wireguard_exit.enabled);
        let requested_ipv6_exit = config.route_targets.iter().any(|route| route == "::/0")
            || (config.wireguard_exit.enabled
                && crate::linux_wireguard_exit_ipv6_default(&config.wireguard_exit));
        let mut route_targets = effective_fips_route_targets(config, &self.mesh.peer_statuses());
        let strict_exit =
            linux_strict_exit_requested(&route_targets, config.exit_node_leak_protection);
        let original_route_targets_require_bypass =
            linux_route_targets_require_ip_endpoint_bypass(&route_targets);
        let mut peer_endpoint_hosts = Vec::new();
        if original_route_targets_require_bypass {
            peer_endpoint_hosts = self.endpoint_bypass_ipv4_hosts(config).await?;
            if route_targets.iter().any(|route| route == "0.0.0.0/0")
                && peer_endpoint_hosts.is_empty()
            {
                eprintln!(
                    "fips: withholding default route until the selected exit peer underlay endpoint is known"
                );
                route_targets.retain(|route| !crate::is_exit_node_route(route));
            }
        }

        let active_ipv4_exit = route_targets.iter().any(|route| route == "0.0.0.0/0");
        let active_ipv6_exit = route_targets.iter().any(|route| route == "::/0");

        if requested_ipv4_exit {
            self.capture_linux_original_default_route(config.underlay_interface.as_deref())?;
        } else {
            self.restore_linux_original_default_route();
        }
        if requested_ipv6_exit {
            self.capture_linux_original_default_ipv6_route(config.underlay_interface.as_deref())?;
        } else {
            self.restore_linux_original_default_ipv6_route();
        }
        if linux_ipv4_underlay_restore_due(
            requested_ipv4_exit,
            active_ipv4_exit,
            config.wireguard_exit.enabled,
            strict_exit,
        ) {
            self.restore_linux_original_default_route();
        }
        if !strict_exit
            && requested_ipv6_exit
            && !active_ipv6_exit
            && !crate::linux_wireguard_exit_ipv6_default(&config.wireguard_exit)
        {
            self.restore_linux_original_default_ipv6_route();
        }
        // The saved physical defaults are the only information that can
        // restore native internet after a hard crash. Fsync them before any
        // endpoint, interface, split-default, firewall, or forwarding
        // mutation below.
        self.persist_network_cleanup_ownership()?;

        let endpoint_bypass_specs = if original_route_targets_require_bypass || strict_exit {
            let mut bypass_hosts = config.control_plane_bypass_hosts.clone();
            bypass_hosts.extend(peer_endpoint_hosts);
            bypass_hosts.sort_unstable();
            bypass_hosts.dedup();
            crate::linux_bypass_route_specs_for_hosts(
                bypass_hosts,
                &self.iface,
                self.original_default_route.as_deref(),
            )?
        } else {
            Vec::new()
        };
        self.reconcile_linux_endpoint_bypass_routes(&endpoint_bypass_specs)?;

        let interface_route_targets = config.interface_route_targets(route_targets.clone());
        let interface_addresses = config.interface_addresses();
        // A control-only node has no managed routes or forwarding state to
        // reconcile. Audit the actual TUN state before mutating it so our own
        // idempotent-looking `ip` commands cannot create a netlink refresh loop.
        // A missing address, changed MTU/queue, or down link still falls through
        // to the normal restoration path.
        let unchanged_control_only_state = self.linux_network_state_initialized
            && linux_control_only_network_intent(&self.config)
            && linux_control_only_network_intent(config)
            && self.config.interface_addresses() == interface_addresses
            && self.config.interface_mtu() == config.interface_mtu()
            && endpoint_bypass_specs.is_empty()
            && self.endpoint_bypass_routes.is_empty()
            && self.original_default_route.is_none()
            && self.original_default_ipv6_route.is_none()
            && linux_exit_node_runtime_is_inactive(&self.exit_node_runtime)
            && linux_interface_state_matches(
                &self.iface,
                &interface_addresses,
                config.interface_mtu(),
                linux_tun_tx_queue_len(),
            );
        if unchanged_control_only_state {
            return Ok(());
        }
        crate::apply_local_interface_network_with_mtu_and_addresses(
            &self.iface,
            &interface_addresses,
            &interface_route_targets,
            config.interface_mtu(),
        )
        .with_context(|| format!("failed to configure FIPS tunnel interface {}", self.iface))?;
        apply_linux_tun_tx_queue_len(&self.iface)?;
        if let Err(error) = crate::flush_linux_route_cache() {
            eprintln!("fips: failed to flush linux route cache: {error}");
        }
        if strict_exit {
            if requested_ipv4_exit && !active_ipv4_exit {
                self.block_linux_original_default_route();
            }
            if requested_ipv6_exit && !active_ipv6_exit {
                self.block_linux_original_default_ipv6_route();
            }
        }
        self.reconcile_linux_exit_node_forwarding(
            &config.local_address,
            &config.local_exit_forwarding_routes,
            &config.wireguard_exit,
            config.exit_node_leak_protection,
            config.mesh_mtu.tunnel,
        )?;
        self.linux_network_state_initialized = true;
        Ok(())
    }

    #[cfg(target_os = "linux")]
    fn capture_linux_original_default_route(
        &mut self,
        underlay_interface: Option<&str>,
    ) -> Result<()> {
        if underlay_interface.is_none() && self.original_default_route.is_some() {
            return Ok(());
        }
        let route = match underlay_interface {
            Some(interface) => {
                match crate::linux_current_default_route_for_interface(interface)
                    .with_context(|| {
                        format!("failed to inspect IPv4 underlay route on {interface}")
                    })? {
                    Some(route) => route,
                    None => self
                        .exit_node_runtime
                        .wireguard_exit
                        .as_ref()
                        .and_then(|runtime| {
                            runtime.underlay_default_route_for_interface(interface)
                        })
                        .ok_or_else(|| {
                            anyhow!("failed to resolve IPv4 underlay route on {interface}")
                        })?,
                }
            }
            None => match crate::linux_default_route() {
                Ok(route) => route,
                Err(error) => {
                    eprintln!("fips: failed to capture original default route: {error}");
                    return Ok(());
                }
            },
        };
        crate::update_linux_underlay_default_route(
            &mut self.original_default_route,
            route,
            &self.iface,
        )
        .context("failed to update cached IPv4 underlay route")
    }

    #[cfg(target_os = "linux")]
    pub(crate) fn linux_underlay_default_route_hints(&self) -> Vec<String> {
        if let Some(runtime) = self.exit_node_runtime.wireguard_exit.as_ref() {
            return runtime.underlay_default_route_hints().to_vec();
        }
        self.original_default_route.iter().cloned().collect()
    }

    #[cfg(target_os = "linux")]
    fn capture_linux_original_default_ipv6_route(
        &mut self,
        underlay_interface: Option<&str>,
    ) -> Result<()> {
        if underlay_interface.is_none() && self.original_default_ipv6_route.is_some() {
            return Ok(());
        }
        let route = match underlay_interface {
            Some(interface) => crate::linux_default_ipv6_route_for_interface(interface)
                .with_context(|| format!("failed to refresh IPv6 underlay route on {interface}"))?,
            None => match crate::linux_default_ipv6_route() {
                Ok(route) => route,
                Err(error) => {
                    eprintln!("fips: failed to capture original IPv6 default route: {error}");
                    return Ok(());
                }
            },
        };
        crate::update_linux_underlay_default_route(
            &mut self.original_default_ipv6_route,
            route,
            &self.iface,
        )
        .context("failed to update cached IPv6 underlay route")
    }

    #[cfg(target_os = "linux")]
    fn restore_linux_original_default_route(&mut self) {
        let owned = linux_owned_default_interfaces(&self.iface, &self.exit_node_runtime);
        restore_linux_saved_default(&mut self.original_default_route, false, &owned);
    }

    #[cfg(target_os = "linux")]
    fn restore_linux_original_default_ipv6_route(&mut self) {
        let owned = linux_owned_default_interfaces(&self.iface, &self.exit_node_runtime);
        restore_linux_saved_default(&mut self.original_default_ipv6_route, true, &owned);
    }

    #[cfg(target_os = "linux")]
    fn block_linux_original_default_route(&mut self) {
        match crate::linux_default_route() {
            Ok(route) if Some(route.line.as_str()) == self.original_default_route.as_deref() => {
                if let Err(error) = crate::delete_linux_default_route() {
                    eprintln!("fips: failed to block IPv4 default route: {error}");
                }
            }
            Ok(_) => {}
            Err(_) => {}
        }
    }

    #[cfg(target_os = "linux")]
    fn block_linux_original_default_ipv6_route(&mut self) {
        match crate::linux_default_ipv6_route() {
            Ok(route)
                if Some(route.line.as_str()) == self.original_default_ipv6_route.as_deref() =>
            {
                if let Err(error) = crate::delete_linux_default_ipv6_route() {
                    eprintln!("fips: failed to block IPv6 default route: {error}");
                }
            }
            Ok(_) => {}
            Err(_) => {}
        }
    }

    #[cfg(target_os = "linux")]
    fn reconcile_linux_endpoint_bypass_routes(
        &mut self,
        routes: &[crate::LinuxEndpointBypassRoute],
    ) -> Result<()> {
        let mut desired = routes.to_vec();
        desired.sort_by(|left, right| left.target.cmp(&right.target));
        desired.dedup_by(|left, right| left.target == right.target);
        let desired_targets = desired
            .iter()
            .map(|route| route.target.clone())
            .collect::<std::collections::HashSet<_>>();

        // Secure every fresh identity before restoring stale identities so an
        // underlay handoff never drops all transport bypasses at once.
        for route in desired {
            let current = crate::linux_endpoint_bypass_route_snapshot(&route.target)?;
            let current_is_desired = current.len() == 1
                && crate::linux_endpoint_bypass_route_matches_line(&route, &current[0]);
            if let Some(index) = self
                .endpoint_bypass_routes
                .iter()
                .position(|managed| managed.route.target == route.target)
            {
                if current_is_desired {
                    self.endpoint_bypass_routes[index].route = route;
                    continue;
                }
                let previous_managed = self.endpoint_bypass_routes[index].route.clone();
                let current_is_previous = current.len() == 1
                    && crate::linux_endpoint_bypass_route_matches_line(
                        &previous_managed,
                        &current[0],
                    );
                if !current.is_empty() && !current_is_previous {
                    return Err(anyhow!(
                        "refusing to overwrite drifted unowned endpoint route {}: {:?}",
                        route.target,
                        current
                    ));
                }
                {
                    let managed = &mut self.endpoint_bypass_routes[index];
                    if !managed.owned {
                        managed.previous_routes = current;
                        managed.owned = true;
                    }
                    managed.route = route;
                }
                self.persist_network_cleanup_ownership()?;
                let managed_route = self.endpoint_bypass_routes[index].route.clone();
                crate::apply_linux_endpoint_bypass_route(&managed_route).with_context(|| {
                    format!(
                        "failed to install endpoint bypass route {}",
                        managed_route.target
                    )
                })?;
                continue;
            }

            if current_is_desired {
                self.endpoint_bypass_routes
                    .push(crate::LinuxManagedEndpointBypassRoute {
                        route,
                        previous_routes: current,
                        owned: false,
                    });
                continue;
            }
            if current.len() > 1 {
                return Err(anyhow!(
                    "refusing to replace ambiguous endpoint route identity {}: {:?}",
                    route.target,
                    current
                ));
            }
            self.endpoint_bypass_routes
                .push(crate::LinuxManagedEndpointBypassRoute {
                    route,
                    previous_routes: current,
                    owned: true,
                });
            self.persist_network_cleanup_ownership()?;
            let managed = self
                .endpoint_bypass_routes
                .last()
                .expect("managed endpoint route was just inserted");
            crate::apply_linux_endpoint_bypass_route(&managed.route).with_context(|| {
                format!(
                    "failed to install endpoint bypass route {}",
                    managed.route.target
                )
            })?;
        }

        let mut failures = Vec::new();
        let mut index = 0;
        while index < self.endpoint_bypass_routes.len() {
            if desired_targets.contains(&self.endpoint_bypass_routes[index].route.target) {
                index += 1;
                continue;
            }
            match crate::restore_linux_managed_endpoint_bypass_route(
                &self.endpoint_bypass_routes[index],
            ) {
                Ok(()) => {
                    self.endpoint_bypass_routes.remove(index);
                }
                Err(error) => {
                    failures.push(format!(
                        "{}: {error:#}",
                        self.endpoint_bypass_routes[index].route.target
                    ));
                    index += 1;
                }
            }
        }
        self.endpoint_bypass_routes
            .sort_by(|left, right| left.route.target.cmp(&right.route.target));
        if failures.is_empty() {
            Ok(())
        } else {
            Err(anyhow!(
                "failed to restore stale endpoint bypass routes: {}",
                failures.join("; ")
            ))
        }
    }

    #[cfg(target_os = "linux")]
    fn reconcile_linux_exit_node_forwarding(
        &mut self,
        local_address: &str,
        routes: &[String],
        wireguard_exit: &WireGuardExitConfig,
        exit_node_leak_protection: bool,
        tunnel_mtu: u16,
    ) -> Result<()> {
        let ipv4_mss_clamp = exit_node_ipv4_mss_clamp(tunnel_mtu);
        let mut route_families = crate::linux_exit_node_default_route_families(routes);
        if route_families.ipv6 {
            eprintln!(
                "fips: IPv6 exit-node forwarding is disabled until nvpn has IPv6 mesh source filtering"
            );
            route_families.ipv6 = false;
        }
        // WG upstream as this host's own egress does not imply mesh
        // exit-node forwarding. Only advertised default routes should
        // turn on ip_forward/NAT below.
        let needs_ipv4_tunnel_source = route_families.ipv4 || wireguard_exit.enabled;
        let ipv4_tunnel_source_cidr = if needs_ipv4_tunnel_source {
            let Some(tunnel_source_cidr) = crate::linux_exit_node_source_cidr(local_address) else {
                self.reconcile_linux_exit_node_forwarding_cleanup()?;
                return Err(anyhow!(
                    "invalid IPv4 tunnel address '{local_address}' for exit forwarding"
                ));
            };
            Some(tunnel_source_cidr)
        } else {
            None
        };

        let wireguard_exit_iface = if wireguard_exit.enabled {
            let Some(source_cidr) = ipv4_tunnel_source_cidr.as_deref() else {
                self.reconcile_linux_exit_node_forwarding_cleanup()?;
                return Err(anyhow!("WireGuard exit has no IPv4 tunnel source"));
            };
            match crate::validate_linux_wireguard_exit_config(wireguard_exit) {
                Ok(iface) => {
                    if !crate::linux_wireguard_exit_ipv6_default(wireguard_exit) {
                        route_families.ipv6 = false;
                    }
                    if let Err(error) =
                        self.apply_linux_wireguard_exit_upstream(wireguard_exit, source_cidr)
                    {
                        let _ = self.cleanup_linux_exit_node_forwarding_rules();
                        self.block_linux_wireguard_exit_if_strict(exit_node_leak_protection);
                        return Err(error).context("failed to configure WireGuard exit upstream");
                    }
                    Some((iface, source_cidr.to_string()))
                }
                Err(error) => {
                    let _ = self.cleanup_linux_exit_node_forwarding_rules();
                    self.cleanup_linux_wireguard_exit_upstream()?;
                    self.block_linux_wireguard_exit_if_strict(
                        exit_node_leak_protection && wireguard_exit.enabled,
                    );
                    return Err(error).context("WireGuard exit upstream is not ready");
                }
            }
        } else {
            self.cleanup_linux_wireguard_exit_upstream()?;
            None
        };

        if !route_families.ipv4 && !route_families.ipv6 {
            self.cleanup_linux_exit_node_forwarding_rules()?;
            return Ok(());
        }

        let ipv4_outbound_iface = if route_families.ipv4 {
            if let Some((iface, _)) = wireguard_exit_iface.as_ref() {
                Some(iface.clone())
            } else {
                match crate::linux_default_route() {
                    Ok(route) => Some(route.dev),
                    Err(error) => {
                        let _ = self.cleanup_linux_exit_node_forwarding_rules();
                        return Err(error).context("failed to resolve default IPv4 route device");
                    }
                }
            }
        } else {
            None
        };

        let ipv6_outbound_iface = None;

        let already_configured = self.exit_node_runtime.ipv4_outbound_iface == ipv4_outbound_iface
            && self.exit_node_runtime.ipv6_outbound_iface == ipv6_outbound_iface
            && self.exit_node_runtime.ipv4_tunnel_source_cidr == ipv4_tunnel_source_cidr
            && self.exit_node_runtime.ipv4_mss_clamp == Some(ipv4_mss_clamp);
        if already_configured {
            return Ok(());
        }

        self.cleanup_linux_exit_node_forwarding_rules()?;

        self.exit_node_runtime.ipv4_outbound_iface = ipv4_outbound_iface.clone();
        self.exit_node_runtime.ipv6_outbound_iface = ipv6_outbound_iface.clone();
        self.exit_node_runtime.ipv4_tunnel_source_cidr = ipv4_tunnel_source_cidr.clone();
        self.exit_node_runtime.ipv4_mss_clamp = Some(ipv4_mss_clamp);
        self.persist_network_cleanup_ownership()?;

        if route_families.ipv4 {
            match crate::read_linux_ip_forward(crate::LinuxExitNodeIpFamily::V4) {
                Ok(previous) => {
                    self.exit_node_runtime.ipv4_forward_was_enabled = Some(previous);
                    self.persist_network_cleanup_ownership()?;
                    if !previous
                        && let Err(error) =
                            crate::write_linux_ip_forward(crate::LinuxExitNodeIpFamily::V4, true)
                    {
                        let _ = self.cleanup_linux_exit_node_forwarding_rules();
                        return Err(error).context("failed to enable IPv4 forwarding");
                    }
                }
                Err(error) => {
                    let _ = self.cleanup_linux_exit_node_forwarding_rules();
                    return Err(error).context("failed to read IPv4 forwarding state");
                }
            }
        }

        if let (Some(outbound_iface), Some(tunnel_source_cidr)) = (
            ipv4_outbound_iface.as_deref(),
            ipv4_tunnel_source_cidr.as_deref(),
        ) {
            eprintln!(
                "fips: enabling IPv4 exit forwarding on {} via {} source {}",
                self.iface, outbound_iface, tunnel_source_cidr
            );
            self.cleanup_linux_legacy_exit_node_forwarding_rules()?;
            let forward_in = crate::linux_exit_node_forward_in_rule(
                &self.iface,
                outbound_iface,
                tunnel_source_cidr,
                crate::LinuxExitNodeIpFamily::V4,
            );
            let forward_out = crate::linux_exit_node_forward_out_rule(
                &self.iface,
                outbound_iface,
                crate::LinuxExitNodeIpFamily::V4,
            );
            let masquerade =
                crate::linux_exit_node_ipv4_masquerade_rule(outbound_iface, tunnel_source_cidr);
            let mss_clamp = crate::linux_exit_node_ipv4_mss_clamp_rule(
                &self.iface,
                outbound_iface,
                tunnel_source_cidr,
                ipv4_mss_clamp,
            );

            if let Err(error) = crate::linux_iptables_ensure_rule_at_front(
                crate::LinuxExitNodeIpFamily::V4,
                None,
                &forward_in,
            )
            .and_then(|()| {
                crate::linux_iptables_ensure_rule_at_front(
                    crate::LinuxExitNodeIpFamily::V4,
                    None,
                    &forward_out,
                )
            })
            .and_then(|()| {
                crate::linux_iptables_ensure_rule(
                    crate::LinuxExitNodeIpFamily::V4,
                    Some("nat"),
                    &masquerade,
                )
            })
            .and_then(|()| {
                crate::linux_iptables_ensure_rule_at_front(
                    crate::LinuxExitNodeIpFamily::V4,
                    Some("mangle"),
                    &mss_clamp,
                )
            }) {
                let _ = self.cleanup_linux_exit_node_forwarding_rules();
                return Err(error).context("failed to install IPv4 exit firewall rules");
            }
        }

        self.cleanup_linux_legacy_exit_node_forwarding_rules()?;
        Ok(())
    }

    #[cfg(target_os = "linux")]
    fn apply_linux_wireguard_exit_upstream(
        &mut self,
        config: &WireGuardExitConfig,
        source_cidr: &str,
    ) -> Result<()> {
        self.cleanup_pending_linux_wireguard_exit_obligations()
            .context("retry incomplete prior WireGuard apply cleanup")?;
        let mut previous_runtime = self.exit_node_runtime.wireguard_exit.take();
        if previous_runtime.as_ref().is_some_and(|runtime| {
            runtime.interface != config.interface.trim()
                || runtime.managed_address != config.address.trim()
                || runtime.source_cidr != source_cidr
        }) {
            let runtime = previous_runtime.take().expect("checked WireGuard runtime");
            if let Err(error) = self.cleanup_detached_linux_wireguard_exit_upstream(&runtime) {
                self.exit_node_runtime.wireguard_exit = Some(runtime);
                return Err(error);
            }
        }
        if let Some(runtime) = previous_runtime.as_mut()
            && let Some(refreshed_default) = crate::select_linux_wireguard_underlay_default_route(
                self.original_default_route.as_deref(),
                runtime.previous_default_route.as_deref(),
                None,
                config.interface.trim(),
            )
        {
            runtime.refresh_underlay_default_route(refreshed_default);
        }
        let original_default_route = self.original_default_route.clone();
        let apply_result = {
            let mut persist_cleanup_intent =
                |obligation: &crate::LinuxWireGuardExitCleanupObligation| {
                    self.exit_node_runtime
                        .pending_wireguard_exit_cleanup
                        .clear();
                    self.exit_node_runtime
                        .pending_wireguard_exit_cleanup
                        .push(obligation.clone());
                    self.persist_network_cleanup_ownership()
                };
            crate::apply_linux_wireguard_exit_upstream(
                config,
                source_cidr,
                previous_runtime.as_ref(),
                original_default_route.as_deref(),
                &mut persist_cleanup_intent,
            )
        };
        let runtime = match apply_result {
            Ok(runtime) => runtime,
            Err(failure) => {
                let (error, cleanup_obligation) = failure.into_parts();
                if let Some(obligation) = cleanup_obligation {
                    self.exit_node_runtime
                        .pending_wireguard_exit_cleanup
                        .clear();
                    self.exit_node_runtime
                        .pending_wireguard_exit_cleanup
                        .push(obligation);
                    self.exit_node_runtime.wireguard_exit = previous_runtime;
                    return match self.persist_network_cleanup_ownership() {
                        Ok(()) => Err(error),
                        Err(persist) => Err(anyhow!(
                            "{error:#}; failed to persist remaining WireGuard cleanup \
                             ownership: {persist:#}"
                        )),
                    };
                }
                self.exit_node_runtime
                    .pending_wireguard_exit_cleanup
                    .clear();
                if let Some(runtime) = previous_runtime.take() {
                    if let Err(cleanup) =
                        self.cleanup_detached_linux_wireguard_exit_upstream(&runtime)
                    {
                        self.exit_node_runtime.wireguard_exit = Some(runtime);
                        return Err(anyhow!(
                            "{error:#}; failed to clean previous WireGuard runtime: {cleanup:#}"
                        ));
                    }
                }
                return match self.persist_network_cleanup_ownership() {
                    Ok(()) => Err(error),
                    Err(persist) => Err(anyhow!(
                        "{error:#}; failed to persist completed WireGuard rollback: {persist:#}"
                    )),
                };
            }
        };
        self.exit_node_runtime
            .pending_wireguard_exit_cleanup
            .clear();
        self.exit_node_runtime.wireguard_exit = Some(runtime);
        // Persist the complete runtime before the inbound firewall mutation.
        // The conservative apply rollback remains on disk if this replacement
        // fails, so either journal can restore native internet after a crash.
        self.persist_network_cleanup_ownership()?;
        let inbound_guard = self
            .exit_node_runtime
            .wireguard_exit
            .as_ref()
            .ok_or_else(|| anyhow!("WireGuard runtime disappeared before inbound guard"))
            .and_then(|runtime| self.ensure_linux_wireguard_exit_inbound_guard(runtime));
        if let Err(error) = inbound_guard {
            let runtime = self
                .exit_node_runtime
                .wireguard_exit
                .take()
                .expect("WireGuard runtime exists for inbound-guard rollback");
            if let Err(cleanup) = self.cleanup_detached_linux_wireguard_exit_upstream(&runtime) {
                self.exit_node_runtime.wireguard_exit = Some(runtime);
                let persist = self.persist_network_cleanup_ownership().err();
                return Err(match persist {
                    Some(persist) => anyhow!(
                        "{error:#}; failed to roll back WireGuard after inbound-guard failure \
                         ({cleanup:#}); failed to persist remaining ownership ({persist:#})"
                    ),
                    None => anyhow!(
                        "{error:#}; failed to roll back WireGuard after inbound-guard failure: \
                         {cleanup:#}"
                    ),
                });
            }
            self.persist_network_cleanup_ownership()?;
            return Err(error);
        }
        self.persist_network_cleanup_ownership()?;
        Ok(())
    }

    #[cfg(target_os = "linux")]
    fn ensure_linux_wireguard_exit_inbound_guard(
        &self,
        runtime: &crate::LinuxWireGuardExitRuntime,
    ) -> Result<()> {
        let drop_inbound = crate::linux_wireguard_exit_inbound_drop_rule(
            &runtime.interface,
            &self.iface,
            &runtime.source_cidr,
        );
        crate::linux_iptables_ensure_rule_at_front(
            crate::LinuxExitNodeIpFamily::V4,
            None,
            &drop_inbound,
        )
    }

    #[cfg(target_os = "linux")]
    fn cleanup_linux_wireguard_exit_inbound_guard(
        &self,
        runtime: &crate::LinuxWireGuardExitRuntime,
    ) -> Result<()> {
        let drop_inbound = crate::linux_wireguard_exit_inbound_drop_rule(
            &runtime.interface,
            &self.iface,
            &runtime.source_cidr,
        );
        let mut last_error = None;
        for _ in 0..3 {
            match crate::linux_iptables_delete_rule(
                crate::LinuxExitNodeIpFamily::V4,
                None,
                &drop_inbound,
            ) {
                Ok(()) => return Ok(()),
                Err(error) => last_error = Some(error),
            }
        }
        Err(last_error.expect("bounded inbound-guard cleanup attempted"))
            .context("failed to remove WireGuard inbound guard rule after three attempts")
    }

    #[cfg(target_os = "linux")]
    fn block_linux_wireguard_exit_if_strict(&mut self, enabled: bool) {
        if !enabled {
            return;
        }
        if let Err(error) = self.capture_linux_original_default_route(None) {
            eprintln!("fips: failed to capture WireGuard underlay default route: {error:#}");
        }
        if let Err(error) = self.persist_network_cleanup_ownership() {
            eprintln!(
                "fips: refusing to block the Linux default route without durable cleanup \
                 ownership: {error:#}"
            );
            return;
        }
        self.block_linux_original_default_route();
    }

    #[cfg(target_os = "linux")]
    fn cleanup_linux_wireguard_exit_upstream(&mut self) -> Result<()> {
        let iface = self.iface.clone();
        cleanup_linux_wireguard_state(&iface, &mut self.exit_node_runtime)
    }

    #[cfg(target_os = "linux")]
    fn cleanup_pending_linux_wireguard_exit_obligations(&mut self) -> Result<()> {
        let pending = std::mem::take(
            &mut self
                .exit_node_runtime
                .pending_wireguard_exit_cleanup,
        );
        let mut remaining = Vec::new();
        let mut failures = Vec::new();
        for mut obligation in pending {
            if let Err(error) =
                crate::cleanup_linux_wireguard_exit_obligation(&mut obligation)
            {
                failures.push(format!("{error:#}"));
                remaining.push(obligation);
            }
        }
        self.exit_node_runtime.pending_wireguard_exit_cleanup = remaining;
        if failures.is_empty() {
            Ok(())
        } else {
            Err(anyhow!(
                "retained WireGuard apply cleanup incomplete: {}",
                failures.join("; ")
            ))
        }
    }

    #[cfg(target_os = "linux")]
    fn cleanup_detached_linux_wireguard_exit_upstream(
        &self,
        runtime: &crate::LinuxWireGuardExitRuntime,
    ) -> Result<()> {
        let guard = self.cleanup_linux_wireguard_exit_inbound_guard(runtime);
        let network = crate::cleanup_linux_wireguard_exit_upstream(runtime);
        match (guard, network) {
            (Ok(()), Ok(())) => Ok(()),
            (Err(guard), Ok(())) => Err(guard),
            (Ok(()), Err(network)) => Err(network),
            (Err(guard), Err(network)) => Err(anyhow!(
                "inbound guard cleanup failed ({guard:#}); network cleanup failed ({network:#})"
            )),
        }
    }

    #[cfg(target_os = "linux")]
    fn cleanup_linux_exit_node_forwarding_rules(&mut self) -> Result<()> {
        let iface = self.iface.clone();
        cleanup_linux_forwarding_state(&iface, &mut self.exit_node_runtime)
    }

    #[cfg(target_os = "linux")]
    fn cleanup_linux_legacy_exit_node_forwarding_rules(&self) -> Result<()> {
        cleanup_linux_legacy_forwarding_rules(&self.iface)
    }

    #[cfg(target_os = "linux")]
    fn reconcile_linux_exit_node_forwarding_cleanup(&mut self) -> Result<()> {
        let iface = self.iface.clone();
        cleanup_linux_exit_node_state(&iface, &mut self.exit_node_runtime)
    }

    #[cfg(target_os = "linux")]
    fn cleanup_linux_network_state(&mut self) -> Result<()> {
        self.linux_network_state_initialized = false;
        cleanup_linux_network_state_with_actions(self)
    }
}

#[cfg(target_os = "linux")]
fn apply_linux_tun_tx_queue_len(iface: &str) -> Result<()> {
    let Some(queue_len) = linux_tun_tx_queue_len() else {
        return Ok(());
    };
    let queue_len = queue_len.to_string();
    crate::run_checked(
        ProcessCommand::new("ip")
            .arg("link")
            .arg("set")
            .arg("dev")
            .arg(iface)
            .arg("txqueuelen")
            .arg(&queue_len),
    )
    .with_context(|| format!("failed to set Linux tunnel txqueuelen on {iface}"))?;
    eprintln!("fips: Linux tunnel txqueuelen set on {iface}; txqueuelen={queue_len}");
    Ok(())
}
