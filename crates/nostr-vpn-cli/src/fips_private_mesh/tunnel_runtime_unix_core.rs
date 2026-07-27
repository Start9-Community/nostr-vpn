#[cfg(any(target_os = "linux", target_os = "macos"))]
impl FipsPrivateTunnelRuntime {
    pub(crate) async fn start(config: FipsPrivateTunnelConfig) -> Result<Self> {
        #[cfg(target_os = "linux")]
        if pending_linux_network_cleanup_state().is_some() {
            return Err(anyhow!(
                "refusing to start FIPS while prior Linux network cleanup remains pending"
            ));
        }
        let mesh = bind_fips_private_mesh(&config).await?;
        Self::start_with_mesh(config, mesh).await
    }

    async fn start_with_mesh(
        config: FipsPrivateTunnelConfig,
        mesh: Arc<FipsPrivateMeshRuntime>,
    ) -> Result<Self> {
        crate::pipeline_profile::maybe_spawn_reporter();
        #[cfg(target_os = "linux")]
        ensure_linux_tun_permissions(&config.iface)?;
        #[cfg(feature = "paid-exit")]
        mesh.set_paid_route_accounting_peers(config.paid_route_accounting_peers.clone())?;
        let control_pubsub = crate::control_pubsub_runtime::ControlPubsubFipsRuntime::start_for_peers(
            Arc::clone(mesh.endpoint()),
            config.nostr_pubsub.clone(),
            config.nostr_relays.clone(),
            Some(config.control_pubsub_store_path.clone()),
            &config
                .peers
                .iter()
                .map(|peer| peer.participant_pubkey.clone())
                .collect::<Vec<_>>(),
        )
        .await?;
        let state_control = FipsControlTcpRuntime::start(Arc::clone(mesh.endpoint())).await?;
        let tun = Arc::new(
            SystemTun::new(&config.iface)
                .with_context(|| fips_tun_create_context(&config.iface))?
                .set_non_blocking()
                .context("failed to set FIPS tunnel nonblocking")?,
        );
        let iface = tun.name().context("failed to read FIPS tunnel name")?;
        let tun_fd = BorrowedTunFd::new(tun.as_raw_fd());

        let (event_tx, event_rx) = mpsc::channel::<FipsPrivateMeshEvent>(1024);
        let tun_send_worker = spawn_tun_send_worker(
            Arc::clone(&tun),
            Arc::clone(&mesh),
            config.fips_host.is_some(),
        );
        let mesh_recv_worker = spawn_mesh_recv_worker(Arc::clone(&mesh), tun_fd, event_tx);
        let fips_host_recv_worker = config
            .fips_host
            .as_ref()
            .map(|_| spawn_fips_host_recv_worker(Arc::clone(mesh.endpoint()), tun_fd));
        let exit_route_ready = fips_exit_route_ready(&config, &mesh.peer_statuses());

        let mut runtime = Self {
            iface,
            mesh,
            control_pubsub,
            state_control,
            secure_dns: None,
            manages_secure_dns: true,
            config: config.clone(),
            _tun: tun,
            fips_host: None,
            fips_host_disabled_artifacts_cleaned: false,
            tun_send_worker,
            mesh_recv_worker,
            fips_host_recv_worker,
            event_rx,
            exit_route_ready,
            endpoint_bypass_routes: Vec::new(),
            #[cfg(target_os = "macos")]
            endpoint_bypass_underlay: None,
            #[cfg(target_os = "linux")]
            original_default_route: None,
            #[cfg(target_os = "linux")]
            original_default_ipv6_route: None,
            #[cfg(target_os = "linux")]
            linux_network_state_initialized: false,
            #[cfg(target_os = "linux")]
            exit_node_runtime: crate::LinuxExitNodeRuntime::default(),
            #[cfg(target_os = "macos")]
            exit_node_runtime: crate::MacosExitNodeRuntime::default(),
            #[cfg(target_os = "macos")]
            wg_upstream: None,
        };
        let startup = async {
            runtime.prepare_secure_dns(&config).await?;
            runtime.apply_interface_config(&config).await?;
            runtime.finish_secure_dns(&config).await;
            runtime
                .reconcile_fips_host_runtime(config.fips_host.clone())
                .await
        }
        .await;
        if let Err(error) = startup {
            let cleanup = runtime.stop().await;
            return Err(match cleanup {
                Ok(()) => error,
                Err(cleanup) => anyhow!(
                    "{error:#}; failed to clean partially-started FIPS runtime: {cleanup:#}"
                ),
            });
        }
        Ok(runtime)
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    async fn endpoint_bypass_ipv4_hosts(
        &self,
        config: &FipsPrivateTunnelConfig,
    ) -> Result<Vec<Ipv4Addr>> {
        let mut hosts = config.endpoint_hint_ipv4_hosts();
        hosts.extend(
            self.mesh
                .peer_transport_ipv4_hosts()
                .await?
                .into_iter()
                .filter(|host| !route_targets_include_ipv4_host(&config.route_targets, *host)),
        );
        hosts.sort_unstable();
        hosts.dedup();
        Ok(hosts)
    }

    pub(crate) fn requires_endpoint_restart(&self, config: &FipsPrivateTunnelConfig) -> bool {
        fips_tunnel_requires_endpoint_restart(&self.config, config)
    }

    pub(crate) async fn apply_config(&mut self, config: FipsPrivateTunnelConfig) -> Result<()> {
        self.mesh.replace_peers(
            config.peers.clone(),
            config.local_allowed_ips(),
            config.paid_route_admissions.clone(),
        )?;
        #[cfg(feature = "paid-exit")]
        self.mesh
            .set_paid_route_accounting_peers(config.paid_route_accounting_peers.clone())?;
        if let Err(error) = self.mesh.update_peers(&config.endpoint_peers).await {
            eprintln!("fips: update_peers during apply_config failed: {error}");
        }
        if self.config.nostr_relays != config.nostr_relays {
            self.mesh.update_relays(&config.nostr_relays).await?;
        }
        self.prepare_secure_dns(&config).await?;
        self.apply_interface_config(&config).await?;
        self.finish_secure_dns(&config).await;
        self.reconcile_fips_host_runtime(config.fips_host.clone())
            .await?;
        self.config = config;
        Ok(())
    }

    pub(crate) async fn refresh_peer_dependent_routes(&mut self) -> Result<()> {
        let exit_route_ready = fips_exit_route_ready(&self.config, &self.mesh.peer_statuses());
        if self.exit_route_ready != exit_route_ready {
            let config = self.config.clone();
            return self.apply_interface_config(&config).await;
        }

        #[cfg(target_os = "linux")]
        {
            if !linux_route_targets_require_ip_endpoint_bypass(&self.config.route_targets) {
                return Ok(());
            }

            let config = self.config.clone();
            let mut bypass_hosts = config.control_plane_bypass_hosts.clone();
            bypass_hosts.extend(self.endpoint_bypass_ipv4_hosts(&config).await?);
            if linux_endpoint_bypass_hosts_unchanged(
                &self.endpoint_bypass_routes,
                &bypass_hosts,
            ) {
                return Ok(());
            }
            return self.apply_interface_config(&config).await;
        }

        #[cfg(target_os = "macos")]
        {
            let config = self.config.clone();
            self.reconcile_macos_endpoint_bypass_for_config(&config)
                .await?;
            Ok(())
        }
    }

    pub(crate) async fn stop(self) -> Result<()> {
        #[cfg(any(target_os = "linux", target_os = "macos"))]
        let mut runtime = self;
        #[cfg(not(any(target_os = "linux", target_os = "macos")))]
        let runtime = self;
        #[cfg(target_os = "linux")]
        let network_cleanup = runtime.cleanup_linux_network_state();
        #[cfg(target_os = "linux")]
        record_linux_stop_cleanup_ownership(
            &network_cleanup,
            LinuxNetworkCleanupState::from_runtime(&runtime),
        );
        #[cfg(not(target_os = "linux"))]
        let network_cleanup: Result<()> = Ok(());
        #[cfg(target_os = "macos")]
        runtime.cleanup_macos_network_state();
        #[cfg(target_os = "macos")]
        runtime.cleanup_macos_exit_node_forwarding();
        #[cfg(target_os = "macos")]
        if let Some(handle) = runtime.wg_upstream.take() {
            handle.cleanup().await;
        }
        if let Some(secure_dns) = runtime.secure_dns.take() {
            secure_dns.stop().await;
        }
        runtime.stop_fips_host_runtime().await;
        if let Some(control_pubsub) = runtime.control_pubsub.take() {
            control_pubsub.stop().await;
        }
        runtime.state_control.stop().await;
        runtime.event_rx.close();
        stop_tun_send_worker(runtime.tun_send_worker).await;
        if let Some(worker) = runtime.fips_host_recv_worker.take() {
            stop_fips_host_recv_worker(worker).await;
        }
        stop_mesh_recv_worker(runtime.mesh_recv_worker, &runtime.mesh).await;
        let endpoint_cleanup = runtime
            .mesh
            .endpoint()
            .shutdown()
            .await
            .context("failed to stop FIPS endpoint");
        match (network_cleanup, endpoint_cleanup) {
            (Ok(()), Ok(())) => Ok(()),
            (Err(network), Ok(())) => Err(network),
            (Ok(()), Err(endpoint)) => Err(endpoint),
            (Err(network), Err(endpoint)) => Err(anyhow!(
                "network cleanup failed ({network:#}); endpoint shutdown failed ({endpoint:#})"
            )),
        }
    }

    async fn prepare_secure_dns(&mut self, config: &FipsPrivateTunnelConfig) -> Result<()> {
        if self.manages_secure_dns && config.secure_dns_required() && self.secure_dns.is_none() {
            self.secure_dns = Some(
                crate::secure_dns_runtime::SecureDnsRuntime::start(
                    &self.iface,
                    None,
                    config.magic_dns_records.clone(),
                    config.exit_dns_resolver_config(false)?,
                    config
                        .fips_host
                        .as_ref()
                        .map(|_| Arc::clone(self.mesh.endpoint())),
                )
                .await?,
            );
        }
        if let Some(secure_dns) = self.secure_dns.as_mut() {
            secure_dns.update_records(config.magic_dns_records.clone());
            secure_dns.update_config(
                config.magic_dns_records.clone(),
                config.exit_dns_resolver_config(false)?,
            )?;
        }
        Ok(())
    }

    async fn finish_secure_dns(&mut self, config: &FipsPrivateTunnelConfig) {
        if self.manages_secure_dns
            && config.secure_dns_required()
            && let Some(secure_dns) = self.secure_dns.as_mut()
        {
            let wireguard_active = {
                #[cfg(target_os = "linux")]
                {
                    self.exit_node_runtime.wireguard_exit.is_some()
                }
                #[cfg(target_os = "macos")]
                {
                    self.wg_upstream.is_some()
                }
            };
            let resolver_config = config.exit_dns_resolver_config(wireguard_active);
            if let Err(error) = resolver_config.and_then(|resolver_config| {
                secure_dns.update_config(config.magic_dns_records.clone(), resolver_config)
            })
            {
                eprintln!("fips: failed to update exit DNS resolver: {error:#}");
            }
        }
        if (!self.manages_secure_dns || !config.secure_dns_required())
            && let Some(secure_dns) = self.secure_dns.take()
        {
            secure_dns.stop().await;
        }
    }

    async fn apply_interface_config(&mut self, config: &FipsPrivateTunnelConfig) -> Result<()> {
        #[cfg(target_os = "linux")]
        {
            self.apply_linux_network_state(config).await?;
        }
        #[cfg(target_os = "macos")]
        {
            let previous_exit_requested = self
                .config
                .route_targets
                .iter()
                .any(|route| route == "0.0.0.0/0")
                || self.config.wireguard_exit.enabled;
            let next_exit_requested = config
                .route_targets
                .iter()
                .any(|route| route == "0.0.0.0/0")
                || config.wireguard_exit.enabled;
            if macos_direct_underlay_restore_needed(
                previous_exit_requested,
                next_exit_requested,
            ) {
                crate::macos_network::restore_macos_underlay_default_route_if_missing()?;
            }
            self.cleanup_stale_macos_wg_upstream(&config.wireguard_exit)
                .await;
            self.apply_macos_network_state(config).await?;
            self.reconcile_macos_wg_upstream(&config.wireguard_exit)
                .await;
            self.reconcile_macos_exit_node_forwarding(
                &config.local_address,
                &config.local_exit_forwarding_routes,
            );
        }
        self.exit_route_ready = fips_exit_route_ready(config, &self.mesh.peer_statuses());
        Ok(())
    }

    #[cfg(target_os = "macos")]
    fn macos_wg_upstream_needs_cleanup(want_up: bool, existing_matches: Option<bool>) -> bool {
        existing_matches.is_some_and(|matches| !want_up || !matches)
    }

    #[cfg(target_os = "macos")]
    async fn cleanup_stale_macos_wg_upstream(&mut self, wg_config: &WireGuardExitConfig) {
        let want_up = wg_config.enabled && wg_config.configured();
        let existing_matches = self
            .wg_upstream
            .as_ref()
            .map(|existing| existing.matches(wg_config));
        if Self::macos_wg_upstream_needs_cleanup(want_up, existing_matches)
            && let Some(existing) = self.wg_upstream.take()
        {
            existing.cleanup().await;
        }
    }

    #[cfg(target_os = "macos")]
    async fn apply_macos_network_state(&mut self, config: &FipsPrivateTunnelConfig) -> Result<()> {
        let requested_ipv4_exit = config
            .route_targets
            .iter()
            .any(|route| route == "0.0.0.0/0");
        let mut route_targets = effective_fips_route_targets(config, &self.mesh.peer_statuses());
        let pending_exit_without_peer = requested_ipv4_exit
            && !config.wireguard_exit.enabled
            && !config.peers.iter().any(|peer| {
                peer.allowed_ips
                    .iter()
                    .any(|route| crate::is_exit_node_route(route))
            });
        let original_route_targets_require_bypass =
            crate::route_targets_require_endpoint_bypass(&route_targets);

        // A config or platform-network refresh must restore routes the OS may have dropped.
        self.endpoint_bypass_underlay = None;
        let (has_peer_endpoint_hosts, underlay) = self
            .reconcile_macos_endpoint_bypass_for_config(config)
            .await?;

        if requested_ipv4_exit && !has_peer_endpoint_hosts && !pending_exit_without_peer {
            eprintln!(
                "fips: withholding macOS default route until the selected exit peer underlay endpoint is known"
            );
            route_targets.retain(|route| !crate::is_exit_node_route(route));
        } else if original_route_targets_require_bypass
            && underlay.is_none()
            && !pending_exit_without_peer
        {
            eprintln!(
                "fips: withholding macOS default route because no underlay default route is available"
            );
            route_targets.retain(|route| !crate::is_exit_node_route(route));
        }
        let active_ipv4_exit = route_targets.iter().any(|route| route == "0.0.0.0/0");
        if !active_ipv4_exit
            && let Err(error) = crate::delete_macos_default_route_for_interface(&self.iface)
            && !crate::daemon_runtime::macos_route_delete_error_is_absent(&error.to_string())
        {
            eprintln!(
                "fips: failed to remove stale macOS default routes on {}: {}",
                self.iface, error
            );
        }

        route_targets = config.interface_route_targets(route_targets);
        // FIPS mesh peer routes go in first. They're /32s for each peer's
        // tunnel IP, so even when we install split defaults below, mesh traffic
        // still wins on longest-prefix-match and stays inside the FIPS tunnel.
        crate::apply_local_interface_network_with_mtu_and_addresses(
            &self.iface,
            &config.interface_addresses(),
            &route_targets,
            config.interface_mtu(),
        )
        .with_context(|| format!("failed to configure FIPS tunnel interface {}", self.iface))?;
        Ok(())
    }

    #[cfg(target_os = "macos")]
    async fn reconcile_macos_endpoint_bypass_for_config(
        &mut self,
        config: &FipsPrivateTunnelConfig,
    ) -> Result<(bool, Option<crate::MacosRouteSpec>)> {
        let hosts = self.endpoint_bypass_ipv4_hosts(config).await?;
        let routes = crate::macos_network::macos_endpoint_bypass_targets_for_hosts(&hosts);
        // Peer events are frequent and normally leave both bypasses and the
        // physical underlay unchanged. Reuse that populated cache here;
        // `apply_macos_network_state` clears it before real config or platform
        // route refreshes so routes dropped by the OS are still reinstalled.
        if !macos_endpoint_bypass_underlay_refresh_required(
            &self.endpoint_bypass_routes,
            self.endpoint_bypass_underlay.as_ref(),
            &routes,
        ) {
            return Ok((!hosts.is_empty(), self.endpoint_bypass_underlay.clone()));
        }
        let underlay = match crate::macos_network::
            macos_underlay_default_route_from_system_for_interface(
                config.underlay_interface.as_deref(),
            )
        {
            Ok(underlay) => underlay,
            Err(error) => {
                eprintln!("fips: failed to resolve macOS endpoint underlay route: {error}");
                None
            }
        };
        self.reconcile_macos_endpoint_bypass_routes(
            underlay.as_ref().map_or(&[], |_| routes.as_slice()),
            underlay.as_ref(),
        );
        Ok((!hosts.is_empty(), underlay))
    }

    #[cfg(target_os = "macos")]
    fn reconcile_macos_endpoint_bypass_routes(
        &mut self,
        routes: &[String],
        underlay: Option<&crate::MacosRouteSpec>,
    ) {
        let desired = routes
            .iter()
            .cloned()
            .collect::<std::collections::HashSet<_>>();

        let stale = self
            .endpoint_bypass_routes
            .iter()
            .filter(|route| !desired.contains(*route))
            .cloned()
            .collect::<Vec<_>>();
        for route in stale {
            if let Err(error) = crate::delete_macos_managed_route(&route, None, None)
                && !crate::daemon_runtime::macos_route_delete_error_is_absent(&error.to_string())
            {
                eprintln!("fips: failed to remove macOS endpoint bypass route {route}: {error}");
            }
        }

        for (route, error) in apply_macos_endpoint_bypass_route_changes(
            &mut self.endpoint_bypass_routes,
            &mut self.endpoint_bypass_underlay,
            routes,
            underlay,
            |route, gateway| crate::apply_macos_route_spec(route, gateway, None),
        ) {
            eprintln!(
                "fips: failed to install macOS endpoint bypass route {}: {}",
                route, error
            );
        }
    }

    #[cfg(target_os = "macos")]
    fn cleanup_macos_network_state(&mut self) {
        self.reconcile_macos_endpoint_bypass_routes(&[], None);
        if let Err(error) = crate::delete_macos_default_route_for_interface(&self.iface)
            && !crate::daemon_runtime::macos_route_delete_error_is_absent(&error.to_string())
        {
            eprintln!(
                "fips: failed to remove macOS default routes on {}: {}",
                self.iface, error
            );
        }
    }

    async fn reconcile_fips_host_runtime(
        &mut self,
        config: Option<FipsHostTunnelConfig>,
    ) -> Result<()> {
        let was_running = self.fips_host.is_some();
        let needs_restart = match (&self.fips_host, &config) {
            (Some(runtime), Some(config)) => runtime.requires_restart(&self.iface, config),
            (Some(_), None) => true,
            (None, Some(_)) => true,
            (None, None) => false,
        };
        if needs_restart {
            self.stop_fips_host_runtime().await;
        }

        match config {
            Some(config) if self.fips_host.is_none() => {
                self.fips_host_disabled_artifacts_cleaned = false;
                let runtime = crate::fips_host_tunnel::FipsHostTunnelRuntime::start(
                    &self.iface,
                    config,
                )?;
                eprintln!("fips-host: integrated .fips IPv6 resolver active on {}", self.iface);
                self.fips_host = Some(runtime);
            }
            None
                if fips_host_disabled_cleanup_due(
                    was_running,
                    self.fips_host_disabled_artifacts_cleaned,
                ) =>
            {
                crate::fips_host_tunnel::FipsHostTunnelRuntime::cleanup_disabled_artifacts();
                self.fips_host_disabled_artifacts_cleaned = true;
            }
            None => self.fips_host_disabled_artifacts_cleaned = true,
            Some(_) => {}
        }
        Ok(())
    }

    async fn stop_fips_host_runtime(&mut self) {
        if let Some(runtime) = self.fips_host.take() {
            runtime.stop();
        }
    }

    /// Bring the WG upstream tunnel up / down to match `wireguard_exit`.
    ///
    /// Called on every `apply_interface_config` (which fires on
    /// startup, on every config change, and on the periodic
    /// peer-dependent route refresh). The function is idempotent: a
    /// no-op if the existing tunnel already matches the config, a
    /// teardown-then-bring-up if the config changed, just a teardown
    /// if WG is now disabled. Stale WG routing is normally removed by
    /// `cleanup_stale_macos_wg_upstream` before FIPS routes are applied;
    /// the cleanup below is a defensive fallback.
    ///
    /// **Safe-by-construction**: if the WG handshake doesn't complete
    /// within the watchdog window (10s), nothing modifies the routing
    /// table. The host's default route only ever swaps to the WG tun
    /// after we've seen a real handshake from the upstream.
    #[cfg(target_os = "macos")]
    async fn reconcile_macos_wg_upstream(&mut self, wg_config: &WireGuardExitConfig) {
        let want_up = wg_config.enabled && wg_config.configured();

        // Already up with matching config → nothing to do.
        if want_up
            && self
                .wg_upstream
                .as_ref()
                .is_some_and(|existing| existing.matches(wg_config))
        {
            return;
        }

        // If we have a stale tunnel (config changed, or now disabled),
        // tear it down before doing anything else. This restores the
        // original default route + deletes the bypass.
        if let Some(existing) = self.wg_upstream.take() {
            existing.cleanup().await;
        }

        if !want_up {
            return;
        }

        match crate::wg_upstream_runtime::apply_daemon_wg_upstream(
            wg_config,
            crate::wg_upstream_runtime::DAEMON_WG_UPSTREAM_HANDSHAKE_TIMEOUT,
        )
        .await
        {
            Ok(handle) => {
                eprintln!(
                    "fips: WG upstream up on {} via {} (default route swapped)",
                    handle.iface, handle.upstream
                );
                self.wg_upstream = Some(handle);
            }
            Err(error) => {
                // The watchdog fired or another error occurred. The
                // routing table was deliberately left untouched, so
                // the host's internet is still fine — surface the
                // error for the GUI / status page and try again on
                // the next reconcile tick.
                eprintln!("fips: WG upstream not started: {error}");
            }
        }
    }

    #[cfg(target_os = "macos")]
    fn reconcile_macos_exit_node_forwarding(&mut self, local_address: &str, routes: &[String]) {
        let route_families = crate::linux_exit_node_default_route_families(routes);
        if !route_families.ipv4 {
            self.cleanup_macos_exit_node_forwarding();
            return;
        }
        if route_families.ipv6 {
            eprintln!(
                "fips: IPv6 exit-node forwarding is disabled on macOS until nvpn has IPv6 PF source filtering"
            );
        }

        let Some(tunnel_source_cidr) = crate::linux_exit_node_source_cidr(local_address) else {
            eprintln!("fips: invalid IPv4 tunnel address '{local_address}'");
            self.cleanup_macos_exit_node_forwarding();
            return;
        };

        let outbound_iface = match crate::macos_underlay_default_route_from_system() {
            Ok(Some(route)) => route.interface,
            Ok(None) => {
                eprintln!("fips: failed to resolve macOS underlay default route for exit NAT");
                self.cleanup_macos_exit_node_forwarding();
                return;
            }
            Err(error) => {
                eprintln!("fips: failed to resolve macOS underlay default route: {error}");
                self.cleanup_macos_exit_node_forwarding();
                return;
            }
        };

        let already_configured = self.exit_node_runtime.outbound_iface.as_deref()
            == Some(outbound_iface.as_str())
            && self.exit_node_runtime.tunnel_source_cidr.as_deref()
                == Some(tunnel_source_cidr.as_str())
            && self.exit_node_runtime.ipv4_forward_was_enabled.is_some();
        if already_configured {
            return;
        }

        self.cleanup_macos_exit_node_forwarding();
        match crate::read_macos_ipv4_forwarding() {
            Ok(previous) => {
                self.exit_node_runtime.ipv4_forward_was_enabled = Some(previous);
                if !previous && let Err(error) = crate::write_macos_ipv4_forwarding(true) {
                    eprintln!("fips: failed to enable macOS IPv4 forwarding: {error}");
                    self.cleanup_macos_exit_node_forwarding();
                    return;
                }
            }
            Err(error) => {
                eprintln!("fips: failed to read macOS IPv4 forwarding state: {error}");
                self.cleanup_macos_exit_node_forwarding();
                return;
            }
        }
        match crate::macos_pf_enabled() {
            Ok(enabled) => {
                self.exit_node_runtime.pf_was_enabled = Some(enabled);
                if !enabled && let Err(error) = crate::enable_macos_pf() {
                    eprintln!("fips: failed to enable macOS PF for exit NAT: {error}");
                    self.cleanup_macos_exit_node_forwarding();
                    return;
                }
            }
            Err(error) => {
                eprintln!("fips: failed to read macOS PF state: {error}");
                self.cleanup_macos_exit_node_forwarding();
                return;
            }
        }

        if let Err(error) =
            crate::apply_macos_exit_node_pf_rules(&self.iface, &outbound_iface, &tunnel_source_cidr)
        {
            eprintln!("fips: failed to install macOS exit PF rules: {error}");
            self.cleanup_macos_exit_node_forwarding();
            return;
        }

        self.exit_node_runtime.outbound_iface = Some(outbound_iface);
        self.exit_node_runtime.tunnel_source_cidr = Some(tunnel_source_cidr);
    }

    #[cfg(target_os = "macos")]
    fn cleanup_macos_exit_node_forwarding(&mut self) {
        if self.exit_node_runtime.pf_was_enabled.is_some()
            && let Err(error) = crate::cleanup_macos_pf_nat()
        {
            eprintln!("fips: failed to remove macOS exit PF rules: {error}");
        }

        if self.exit_node_runtime.pf_was_enabled == Some(false)
            && let Err(error) = crate::run_checked(ProcessCommand::new("pfctl").arg("-d"))
        {
            eprintln!("fips: failed to restore macOS PF enabled state: {error}");
        }
        if self.exit_node_runtime.ipv4_forward_was_enabled == Some(false)
            && let Err(error) = crate::write_macos_ipv4_forwarding(false)
        {
            eprintln!("fips: failed to restore macOS IPv4 forwarding state: {error}");
        }

        self.exit_node_runtime = crate::MacosExitNodeRuntime::default();
    }
}

#[cfg(any(target_os = "macos", test))]
fn macos_endpoint_bypass_underlay_refresh_required(
    current_routes: &[String],
    current_underlay: Option<&crate::MacosRouteSpec>,
    desired_routes: &[String],
) -> bool {
    current_underlay.is_none() || current_routes != desired_routes
}

#[cfg(target_os = "macos")]
fn macos_direct_underlay_restore_needed(
    previous_exit_requested: bool,
    next_exit_requested: bool,
) -> bool {
    previous_exit_requested && !next_exit_requested
}

#[cfg(all(test, target_os = "macos"))]
mod macos_wg_transition_tests {
    use super::{FipsPrivateTunnelRuntime, macos_direct_underlay_restore_needed};

    #[test]
    fn stale_wireguard_is_removed_before_fips_routes_change() {
        assert!(FipsPrivateTunnelRuntime::macos_wg_upstream_needs_cleanup(
            false,
            Some(true)
        ));
        assert!(FipsPrivateTunnelRuntime::macos_wg_upstream_needs_cleanup(
            true,
            Some(false)
        ));
        assert!(!FipsPrivateTunnelRuntime::macos_wg_upstream_needs_cleanup(
            true,
            Some(true)
        ));
        assert!(!FipsPrivateTunnelRuntime::macos_wg_upstream_needs_cleanup(
            false, None
        ));
    }

    #[test]
    fn only_an_exit_to_direct_transition_repairs_the_underlay_default() {
        assert!(macos_direct_underlay_restore_needed(true, false));
        assert!(!macos_direct_underlay_restore_needed(false, false));
        assert!(!macos_direct_underlay_restore_needed(true, true));
    }
}

#[cfg(any(target_os = "linux", target_os = "macos", test))]
fn fips_host_disabled_cleanup_due(runtime_running: bool, cleanup_complete: bool) -> bool {
    !runtime_running && !cleanup_complete
}

#[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
impl FipsPrivateTunnelRuntime {
    pub(crate) fn iface(&self) -> &str {
        &self.iface
    }

    pub(crate) fn ethernet_underlay(&self) -> Option<&FipsEthernetUnderlayConfig> {
        self.config.ethernet_underlay.as_ref()
    }

    pub(crate) fn peer_statuses(&self) -> Vec<MeshPeerStatus> {
        self.mesh.peer_statuses()
    }

    #[cfg(feature = "paid-exit")]
    pub(crate) fn drain_paid_route_usage(&self, participant: &str) -> Result<PaidRouteUsage> {
        self.mesh.drain_paid_route_usage(participant)
    }

    pub(crate) fn stale_participants_needing_path_refresh(&self, now: u64) -> Vec<String> {
        self.mesh.stale_participants_needing_path_refresh(now)
    }

    pub(crate) async fn relay_statuses(&self) -> Result<Vec<FipsRelayStatus>> {
        self.mesh.relay_statuses().await
    }

    pub(crate) async fn local_advertised_endpoints(&self) -> Result<Vec<OverlayEndpointAdvert>> {
        self.mesh.local_advertised_endpoints().await
    }

    pub(crate) fn peer_pubkeys(&self) -> Vec<String> {
        self.mesh.peer_pubkeys()
    }

    pub(crate) async fn authenticated_endpoint_peers(&self) -> Result<Vec<FipsEndpointPeer>> {
        self.mesh.authenticated_endpoint_peers().await
    }

    pub(crate) fn peer_endpoint_hints(&self) -> Vec<(String, Vec<(String, u64)>)> {
        self.mesh.peer_endpoint_hints()
    }

    /// Forward a refreshed peer roster + address hints to fips without
    /// restarting the endpoint. Daemon heartbeat path: when the
    /// recent-peers cache or active-network roster changes, build the
    /// merged hint list and call this so fips can diff + apply.
    pub(crate) async fn update_peers(
        &self,
        endpoint_peers: &[FipsEndpointPeerTransportConfig],
    ) -> Result<fips_endpoint::UpdatePeersOutcome> {
        self.mesh.update_peers(endpoint_peers).await
    }

    pub(crate) async fn refresh_peer_paths(
        &self,
        endpoint_peers: &[FipsEndpointPeerTransportConfig],
    ) -> Result<usize> {
        self.mesh.refresh_peer_paths(endpoint_peers).await
    }

    pub(crate) async fn rebind_network_transports(
        &self,
        bind_interface: Option<String>,
    ) -> Result<usize> {
        self.mesh.rebind_network_transports(bind_interface).await
    }

    pub(crate) async fn ping_peers(&self, network_id: &str, now: u64) -> Result<usize> {
        self.mesh.ping_peers(network_id, now).await
    }

    pub(crate) async fn refresh_link_statuses(&self) -> Result<()> {
        self.mesh.refresh_link_statuses().await
    }

    pub(crate) async fn send_join_request(
        &self,
        participant: &str,
        requested_at: u64,
        request: MeshJoinRequest,
    ) -> Result<()> {
        self.mesh
            .send_join_request(&self.state_control, participant, requested_at, request)
            .await
    }

    pub(crate) fn enqueue_roster(
        &self,
        participant: &str,
        signed_roster: SignedRoster,
    ) -> Result<()> {
        self.mesh
            .enqueue_roster(&self.state_control.sender(), participant, signed_roster)
    }

    pub(crate) fn join_roster_delivery(
        &self,
        participant: String,
        join_roster: JoinRosterControl,
    ) -> Result<FipsJoinRosterDelivery> {
        self.mesh.join_roster_delivery(
            self.state_control.sender(),
            participant,
            join_roster,
        )
    }

    pub(crate) async fn send_join_roster_ack(
        &self,
        participant: &str,
        roster_event_id: String,
    ) -> Result<()> {
        self.mesh
            .send_join_roster_ack(&self.state_control, participant, roster_event_id)
            .await
    }
    pub(crate) fn enqueue_capabilities(
        &self,
        participant: &str,
        network_id: &str,
        capabilities: PeerCapabilities,
    ) -> Result<()> {
        self.mesh.enqueue_capabilities(
            &self.state_control.sender(),
            participant,
            network_id,
            capabilities,
        )
    }

    #[cfg(feature = "paid-exit")]
    pub(crate) async fn send_paid_route_session_open(
        &self,
        seller: &str,
        open: PaidRouteSessionOpen,
    ) -> Result<()> {
        self.mesh
            .send_paid_route_session_open(&self.state_control, seller, open)
            .await
    }

    #[cfg(feature = "paid-exit")]
    pub(crate) async fn send_paid_route_session_open_ack(
        &self,
        buyer: &str,
        lease_id: String,
    ) -> Result<()> {
        self.mesh
            .send_paid_route_session_open_ack(&self.state_control, buyer, lease_id)
            .await
    }

    #[cfg(feature = "paid-exit")]
    pub(crate) async fn send_paid_route_payment(
        &self,
        seller: &str,
        id: String,
        envelope: StreamingRoutePaymentEnvelope,
    ) -> Result<()> {
        self.mesh
            .send_paid_route_payment(&self.state_control, seller, id, envelope)
            .await
    }

    #[cfg(feature = "paid-exit")]
    pub(crate) async fn send_paid_route_payment_ack(&self, buyer: &str, id: String) -> Result<()> {
        self.mesh
            .send_paid_route_payment_ack(&self.state_control, buyer, id)
            .await
    }

    pub(crate) fn peer_advertised_routes(&self, participant: &str) -> Vec<String> {
        self.mesh.peer_advertised_routes(participant)
    }

    pub(crate) fn drain_events(&mut self) -> Vec<FipsPrivateMeshEvent> {
        let mut events = drain_event_batch(&mut self.event_rx, FIPS_MESH_EVENT_DRAIN_LIMIT);
        let remaining = FIPS_MESH_EVENT_DRAIN_LIMIT.saturating_sub(events.len());
        for received in self.state_control.drain().into_iter().take(remaining) {
            match self.mesh.received_stateful_control_frame(received) {
                Ok(Some(event)) => events.push(event),
                Ok(None) => {}
                Err(error) => eprintln!("discarding invalid FIPS-TCP control record: {error}"),
            }
        }
        events
    }
}
