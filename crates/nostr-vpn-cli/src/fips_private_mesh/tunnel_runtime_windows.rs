#[cfg(target_os = "windows")]
impl FipsPrivateTunnelRuntime {
    pub(crate) async fn start(config: FipsPrivateTunnelConfig) -> Result<Self> {
        crate::pipeline_profile::maybe_spawn_reporter();
        let mesh = bind_fips_private_mesh(&config).await?;
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
        let (session, iface, interface_index) = start_windows_fips_wintun(&config)?;
        let peer_statuses = mesh.peer_statuses();
        let exit_route_ready = fips_exit_route_ready(&config, &peer_statuses);
        let effective_route_targets = effective_fips_route_targets(&config, &peer_statuses);
        let endpoint_bypass_routes = windows_fips_endpoint_bypass_targets(
            &config.endpoint_peers,
            &effective_route_targets,
        );
        let endpoint_bypass_underlay = if endpoint_bypass_routes.is_empty() {
            None
        } else {
            let underlay = windows_fips_underlay_default_route(interface_index)?;
            crate::windows_tunnel::apply_windows_routes_via(
                underlay.interface_index,
                &underlay.gateway,
                &endpoint_bypass_routes,
            )
            .context("failed to apply Windows FIPS endpoint bypass routes")?;
            Some(underlay)
        };
        let secure_dns = if config.secure_dns_required() {
            Some(
                crate::secure_dns_runtime::SecureDnsRuntime::start(
                    &iface,
                    Some(interface_index),
                    config.magic_dns_records.clone(),
                    config.exit_dns_resolver_config(false)?,
                    None,
                )
                .await?,
            )
        } else {
            None
        };
        let route_targets = match crate::windows_tunnel::apply_windows_routes(
            interface_index,
            &effective_route_targets,
        ) {
            Ok(route_targets) => route_targets,
            Err(error) => {
                if let Some(underlay) = endpoint_bypass_underlay.as_ref() {
                    let _ = crate::windows_tunnel::remove_windows_routes(
                        underlay.interface_index,
                        &endpoint_bypass_routes,
                    );
                }
                return Err(error);
            }
        };

        let stop = Arc::new(AtomicBool::new(false));
        let (event_tx, event_rx) = mpsc::channel::<FipsPrivateMeshEvent>(1024);
        let tun_read_thread =
            spawn_windows_fips_tun_read_thread(stop.clone(), session.clone(), Arc::clone(&mesh));
        let mesh_recv_task = spawn_windows_fips_mesh_recv_task(
            stop.clone(),
            Arc::clone(&mesh),
            session.clone(),
            event_tx,
        );

        let mut runtime = Self {
            iface,
            mesh,
            control_pubsub,
            state_control,
            secure_dns,
            config: config.clone(),
            session,
            stop,
            tun_read_thread,
            mesh_recv_task,
            event_rx,
            exit_route_ready,
            interface_index,
            route_targets,
            endpoint_bypass_underlay,
            endpoint_bypass_routes,
            wg_upstream: None,
        };
        // Reconcile the WG upstream against the initial config. Same
        // safe-by-construction guarantee as macOS: if the WG handshake
        // doesn't complete within the watchdog window, the routing
        // table stays untouched.
        runtime
            .reconcile_windows_wg_upstream(&config.wireguard_exit)
            .await;
        let wireguard_interface = runtime
            .wg_upstream
            .as_ref()
            .map(|upstream| upstream.iface.clone());
        let resolver_config = config.exit_dns_resolver_config(wireguard_interface.is_some())?;
        let servers = resolver_config.through_exit_servers().to_vec();
        if let Some(secure_dns) = runtime.secure_dns.as_mut() {
            secure_dns.update_config(config.magic_dns_records.clone(), resolver_config)?;
            secure_dns
                .update_windows_wireguard_dns(wireguard_interface.as_deref(), &servers)?;
        }
        Ok(runtime)
    }

    pub(crate) fn requires_endpoint_restart(&self, config: &FipsPrivateTunnelConfig) -> bool {
        self.config.iface != config.iface
            || self.config.local_address != config.local_address
            || fips_tunnel_requires_endpoint_restart(&self.config, config)
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
        if config.secure_dns_required() && self.secure_dns.is_none() {
            self.secure_dns = Some(
                crate::secure_dns_runtime::SecureDnsRuntime::start(
                    &self.iface,
                    Some(self.interface_index),
                    config.magic_dns_records.clone(),
                    config.exit_dns_resolver_config(false)?,
                    None,
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
        self.apply_windows_route_config(&config)?;
        if !config.secure_dns_required()
            && let Some(secure_dns) = self.secure_dns.take()
        {
            secure_dns.stop().await;
        }
        self.reconcile_windows_wg_upstream(&config.wireguard_exit)
            .await;
        let wireguard_interface = self
            .wg_upstream
            .as_ref()
            .map(|upstream| upstream.iface.clone());
        let resolver_config = config.exit_dns_resolver_config(wireguard_interface.is_some())?;
        let servers = resolver_config.through_exit_servers().to_vec();
        if let Some(secure_dns) = self.secure_dns.as_mut() {
            secure_dns.update_config(config.magic_dns_records.clone(), resolver_config)?;
            secure_dns
                .update_windows_wireguard_dns(wireguard_interface.as_deref(), &servers)?;
        }
        self.config = config;
        Ok(())
    }

    pub(crate) async fn refresh_peer_dependent_routes(&mut self) -> Result<()> {
        let exit_route_ready = fips_exit_route_ready(&self.config, &self.mesh.peer_statuses());
        if self.exit_route_ready != exit_route_ready {
            let config = self.config.clone();
            self.apply_windows_route_config(&config)?;
        }
        Ok(())
    }

    fn apply_windows_route_config(&mut self, config: &FipsPrivateTunnelConfig) -> Result<()> {
        let peer_statuses = self.mesh.peer_statuses();
        let exit_route_ready = fips_exit_route_ready(config, &peer_statuses);
        let effective_route_targets = effective_fips_route_targets(config, &peer_statuses);
        let desired_endpoint_routes = windows_fips_endpoint_bypass_targets(
            &config.endpoint_peers,
            &effective_route_targets,
        );
        let added_endpoint_routes = desired_endpoint_routes
            .iter()
            .filter(|route| !self.endpoint_bypass_routes.contains(*route))
            .cloned()
            .collect::<Vec<_>>();

        if !added_endpoint_routes.is_empty() {
            let underlay = match self.endpoint_bypass_underlay.clone() {
                Some(underlay) => underlay,
                None => windows_fips_underlay_default_route(self.interface_index)?,
            };
            crate::windows_tunnel::apply_windows_routes_via(
                underlay.interface_index,
                &underlay.gateway,
                &added_endpoint_routes,
            )
            .context("failed to apply Windows FIPS endpoint bypass routes")?;
            self.endpoint_bypass_underlay = Some(underlay);
        }

        if self.config.route_targets != config.route_targets
            || self.exit_route_ready != exit_route_ready
        {
            if let Err(error) = crate::windows_tunnel::remove_windows_routes(
                self.interface_index,
                &self.route_targets,
            ) {
                if let Some(underlay) = self.endpoint_bypass_underlay.as_ref() {
                    let _ = crate::windows_tunnel::remove_windows_routes(
                        underlay.interface_index,
                        &added_endpoint_routes,
                    );
                }
                return Err(error).context("failed to remove stale Windows FIPS routes");
            }
            match crate::windows_tunnel::apply_windows_routes(
                self.interface_index,
                &effective_route_targets,
            ) {
                Ok(route_targets) => self.route_targets = route_targets,
                Err(error) => {
                    if let Some(underlay) = self.endpoint_bypass_underlay.as_ref() {
                        let _ = crate::windows_tunnel::remove_windows_routes(
                            underlay.interface_index,
                            &added_endpoint_routes,
                        );
                    }
                    return Err(error).context("failed to apply Windows FIPS routes");
                }
            }
        }

        let stale_endpoint_routes = self
            .endpoint_bypass_routes
            .iter()
            .filter(|route| !desired_endpoint_routes.contains(*route))
            .cloned()
            .collect::<Vec<_>>();
        let mut active_endpoint_routes = desired_endpoint_routes;
        if let Some(underlay) = self.endpoint_bypass_underlay.as_ref()
            && let Err(error) = crate::windows_tunnel::remove_windows_routes(
                underlay.interface_index,
                &stale_endpoint_routes,
            )
        {
            eprintln!("fips: failed to remove stale Windows endpoint bypass routes: {error}");
            active_endpoint_routes.extend(stale_endpoint_routes);
            active_endpoint_routes.sort();
            active_endpoint_routes.dedup();
        }
        self.endpoint_bypass_routes = active_endpoint_routes;
        self.exit_route_ready = exit_route_ready;
        Ok(())
    }

    /// Same shape as the macOS reconcile: a no-op if the existing
    /// tunnel already matches, teardown-then-rebuild on config change,
    /// just teardown on disable. Handshake-first, watchdog-protected:
    /// the routing table is only modified after a successful WG
    /// handshake.
    async fn reconcile_windows_wg_upstream(&mut self, wg_config: &WireGuardExitConfig) {
        let want_up = wg_config.enabled && wg_config.configured();
        if want_up
            && self
                .wg_upstream
                .as_ref()
                .is_some_and(|existing| existing.matches(wg_config))
        {
            return;
        }
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
                eprintln!("fips: WG upstream not started: {error}");
            }
        }
    }

    pub(crate) async fn stop(self) -> Result<()> {
        let mut runtime = self;
        // Tear the WG upstream down BEFORE the FIPS bits so the route
        // revert lands while we still have a sane working tree.
        if let Some(handle) = runtime.wg_upstream.take() {
            handle.cleanup().await;
        }
        if let Some(control_pubsub) = runtime.control_pubsub.take() {
            control_pubsub.stop().await;
        }
        runtime.state_control.stop().await;
        runtime.stop.store(true, Ordering::Relaxed);
        let _ = runtime.session.shutdown();
        if let Err(error) = crate::windows_tunnel::remove_windows_routes(
            runtime.interface_index,
            &runtime.route_targets,
        ) {
            eprintln!("fips: failed to remove Windows FIPS routes: {error}");
        }
        if let Some(underlay) = runtime.endpoint_bypass_underlay.as_ref()
            && let Err(error) = crate::windows_tunnel::remove_windows_routes(
                underlay.interface_index,
                &runtime.endpoint_bypass_routes,
            )
        {
            eprintln!("fips: failed to remove Windows endpoint bypass routes: {error}");
        }
        if let Some(secure_dns) = runtime.secure_dns.take() {
            secure_dns.stop().await;
        }
        runtime.event_rx.close();
        let _ = runtime.tun_read_thread.join();
        runtime.mesh_recv_task.abort();
        let _ = runtime.mesh_recv_task.await;
        runtime
            .mesh
            .endpoint()
            .shutdown()
            .await
            .context("failed to stop FIPS endpoint")?;
        Ok(())
    }
}

#[cfg(target_os = "windows")]
fn windows_fips_underlay_default_route(
    tunnel_interface_index: u32,
) -> Result<crate::wg_upstream_runtime::WindowsDefaultRoute> {
    let underlay = crate::wg_upstream_runtime::capture_windows_default_route()
        .context("failed to capture Windows FIPS underlay default route")?;
    if underlay.interface_index == tunnel_interface_index {
        return Err(anyhow!(
            "captured Windows default route already points at the FIPS Wintun adapter (interface={tunnel_interface_index})"
        ));
    }
    Ok(underlay)
}

#[cfg(any(target_os = "windows", test))]
fn windows_fips_endpoint_bypass_targets(
    endpoint_peers: &[FipsEndpointPeerTransportConfig],
    route_targets: &[String],
) -> Vec<String> {
    let has_broad_ipv4_route = route_targets.iter().any(|route| {
        let Some((host, bits)) = route.trim().split_once('/') else {
            return false;
        };
        host.parse::<Ipv4Addr>().is_ok()
            && bits.parse::<u8>().is_ok_and(|prefix_len| prefix_len < 32)
    });
    if !has_broad_ipv4_route {
        return Vec::new();
    }

    let mut hosts = endpoint_peers
        .iter()
        .flat_map(|peer| peer.addresses.iter())
        .filter(|hint| hint.seen_at_ms.is_none())
        .filter_map(|hint| {
            let (transport, addr) = split_peer_transport_addr(&hint.addr);
            if transport != "udp" {
                return None;
            }
            match addr.parse::<SocketAddr>().ok()?.ip() {
                IpAddr::V4(host) => Some(host),
                IpAddr::V6(_) => None,
            }
        })
        .filter(|host| {
            !route_targets.iter().any(|route| {
                let Some((target, bits)) = route.trim().split_once('/') else {
                    return false;
                };
                bits == "32" && target.parse::<Ipv4Addr>() == Ok(*host)
            })
        })
        .collect::<Vec<_>>();
    hosts.sort_unstable();
    hosts.dedup();
    hosts.into_iter().map(|host| format!("{host}/32")).collect()
}

#[cfg(test)]
mod windows_endpoint_bypass_tests {
    use super::*;

    fn address(addr: &str) -> FipsPeerAddressHint {
        FipsPeerAddressHint {
            addr: addr.to_string(),
            seen_at_ms: None,
            priority: 0,
        }
    }

    #[test]
    fn configured_udp_endpoint_bypasses_are_deterministic() {
        let peers = vec![FipsEndpointPeerTransportConfig {
            npub: "peer".to_string(),
            addresses: vec![
                address("udp:203.0.113.7:2121"),
                address("65.109.48.91:2121"),
                address("udp:65.109.48.91:2121"),
                address("tcp:192.0.2.9:8443"),
                address("udp:[2001:db8::7]:2121"),
                FipsPeerAddressHint {
                    addr: "udp:192.0.2.10:2121".to_string(),
                    seen_at_ms: Some(1),
                    priority: 0,
                },
            ],
            connect_on_start: true,
            auto_reconnect: true,
            discovery_fallback_transit: false,
        }];

        assert_eq!(
            windows_fips_endpoint_bypass_targets(
                &peers,
                &["0.0.0.0/0".to_string(), "203.0.113.7/32".to_string()],
            ),
            vec!["65.109.48.91/32"]
        );
        assert!(
            windows_fips_endpoint_bypass_targets(&peers, &["10.44.0.2/32".to_string()]).is_empty()
        );
    }
}
