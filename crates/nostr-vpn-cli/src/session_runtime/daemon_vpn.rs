pub(crate) async fn daemon_vpn(args: DaemonArgs) -> Result<()> {
    let startup = initialize_daemon_vpn(&args).await?;
    let mut magic_dns_runtime = start_split_magic_dns(&startup.app);
    let (mut announce_interval, mut recent_peer_refresh_interval) = daemon_refresh_intervals(&args);
    let mut intervals = daemon_vpn_intervals();
    #[cfg(feature = "paid-exit")]
    let mut last_paid_exit_usage_flush_at = Instant::now();
    let mut last_runtime_heartbeat_at = WallTimeJumpObserver::new(unix_timestamp());
    let mut platform_network_change_rx = spawn_platform_network_change_monitor();
    #[cfg(unix)]
    let mut terminate_signal =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .context("failed to install SIGTERM handler")?;
    #[cfg(unix)]
    let terminate_wait = async move {
        let _ = terminate_signal.recv().await;
    };
    #[cfg(not(unix))]
    let terminate_wait = std::future::pending::<()>();
    tokio::pin!(terminate_wait);
    let loop_state = initialize_daemon_vpn_loop(&args, &startup).await?;
    let DaemonVpnStartup {
        config_path,
        pid_file,
        network_override,
        participants_override,
        mut app,
        mut network_id,
        mut own_pubkey,
        mut expected_peers,
        state_file,
        recent_peers_path,
        mut recent_peers,
        mut fips_join_request_sends,
        mut pending_fips_roster_recipients,
        mut fips_roster_sync_state,
        mut last_fips_stale_participant_restart_at,
        mut fips_pending_roster_restart_state,
        iface,
        ethernet_underlay,
        mut tunnel_runtime,
        mut network_snapshot,
        mut network_changed_at,
        mut captive_portal,
        timeout,
        mut port_mapping_runtime,
        mut vpn_enabled,
        mut fips_tunnel_runtime,
        mut last_fips_endpoint_peer_signature,
    } = startup;
    let DaemonVpnLoopState {
        mut vpn_status,
        mut last_log_compact_check,
        mut last_state_persisted_at,
        daemon_state_persist_interval,
        mut platform_network_event_pending,
        mut platform_network_event_suppressed_until,
        supervised_service_executable,
    } = loop_state;
    #[cfg(feature = "paid-exit")]
    let (mut paid_exit_spilman_receiver, mut paid_exit_spilman_receiver_error) =
        try_load_paid_exit_spilman_receiver(&config_path, &app.paid_exit).await;
    #[cfg(feature = "paid-exit")]
    let mut automatic_paid_exit = PaidExitAutomaticBuyer::default();
    #[cfg(feature = "paid-exit")]
    let mut last_paid_exit_session_open_at =
        Instant::now() - Duration::from_secs(PAID_EXIT_SESSION_OPEN_RETRY_SECS);
    let mut last_recent_peer_refresh_signature = None;
    let mut last_recent_peer_cache_persisted_at = 0;
    let (join_request_ipc_tx, mut join_request_ipc_rx) =
        tokio::sync::mpsc::unbounded_channel::<DaemonJoinRequestIpcRequest>();
    #[cfg(unix)]
    let _join_request_ipc = crate::join_request_ipc::JoinRequestIpcServer::spawn(
        &config_path,
        join_request_ipc_tx,
    )?;
    #[cfg(not(unix))]
    let _join_request_ipc_keepalive = join_request_ipc_tx;
    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                break;
            }
            _ = &mut terminate_wait => {
                break;
            }
            Some(request) = join_request_ipc_rx.recv() => {
                respond_to_join_request(&mut app, request);
            }
            _ = announce_interval.tick() => {
                if let Some(runtime) = fips_tunnel_runtime.as_ref() {
                    if let Err(error) = publish_fips_active_network_roster(
                        runtime,
                        &app,
                        &config_path,
                        &mut pending_fips_roster_recipients,
                    ) {
                        eprintln!("fips: roster publish failed: {error}");
                    }
                    if let Err(error) = broadcast_local_fips_capabilities(runtime, &app).await {
                        eprintln!("fips: capabilities broadcast failed: {error}");
                    }
                }
            }
            _ = recent_peer_refresh_interval.tick() => {
                if let Some(runtime) = fips_tunnel_runtime.as_ref() {
                    update_recent_peers_from_runtime(
                        runtime,
                        &app,
                        &network_id,
                        own_pubkey.as_deref(),
                        RecentPeerRefresh {
                            recent_peers: &mut recent_peers,
                            recent_peers_path: &recent_peers_path,
                            last_endpoint_peer_signature: &mut last_fips_endpoint_peer_signature,
                            last_refresh_signature: &mut last_recent_peer_refresh_signature,
                            last_cache_persisted_at: &mut last_recent_peer_cache_persisted_at,
                            force_rebuild: false,
                        },
                        unix_timestamp(),
                    )
                    .await;
                }
            }
            _ = intervals.tunnel_heartbeat.tick() => {
                if observe_wall_time_jump(
                    &mut last_runtime_heartbeat_at,
                    unix_timestamp(),
                    MAJOR_LINK_CHANGE_TIME_JUMP_SECS,
                ) {
                    intervals.runtime_resume_pending = true;
                    intervals.network.reset_immediately();
                }
                let vpn_active = daemon_vpn_active(vpn_enabled, expected_peers);
                let maintain_fips = if vpn_active {
                    fips_tunnel_runtime.is_some()
                } else {
                    fips_private_runtime_active(&app, vpn_enabled, expected_peers)
                };
                if maintain_fips {
                    maintain_fips_heartbeat(FipsHeartbeatContext {
                        runtime: &mut fips_tunnel_runtime,
                        app: &app,
                        config_path: &config_path,
                        network_id: &network_id,
                        fallback_iface: &iface,
                        underlay_interface: network_snapshot.default_interface.as_deref(),
                        underlay_interface_mtu: network_snapshot.default_interface_mtu,
                        own_pubkey: own_pubkey.as_deref(),
                        recent_peers: &recent_peers,
                        ethernet_underlay: ethernet_underlay.as_ref(),
                        expected_peers,
                        last_endpoint_peer_signature: &mut last_fips_endpoint_peer_signature,
                        last_stale_participant_restart_at:
                            &mut last_fips_stale_participant_restart_at,
                        pending_roster_restart_state: &mut fips_pending_roster_restart_state,
                        roster_sync_state: &mut fips_roster_sync_state,
                        pending_roster_recipients: &mut pending_fips_roster_recipients,
                        join_request_sends: &mut fips_join_request_sends,
                    })
                    .await;
                    if let Some(runtime) = fips_tunnel_runtime.as_ref() {
                        start_queued_join_roster_deliveries(runtime, &app, &config_path);
                    }
                }
                if !vpn_active {
                    continue;
                }
            }
            platform_network_change = recv_platform_network_change(&mut platform_network_change_rx) => {
                if platform_network_change.is_none() {
                    platform_network_change_rx = None;
                    continue;
                }
                drain_platform_network_changes(&mut platform_network_change_rx);
                if reschedule_suppressed_platform_network_event(
                    &mut intervals.network,
                    platform_network_event_suppressed_until,
                ) {
                    continue;
                }
                platform_network_event_pending = true;
                intervals.network.reset_after(Duration::from_millis(
                    DAEMON_NETWORK_EVENT_DEBOUNCE_MILLIS,
                ));
            }
            _ = intervals.network.tick() => {
                let now = unix_timestamp();
                let resumed_after_sleep = std::mem::take(&mut intervals.runtime_resume_pending);
                if resumed_after_sleep {
                    eprintln!("daemon: sleep/wake detected; refreshing FIPS endpoint state");
                }
                let latest_snapshot = prefer_nonself_tunnel_snapshot(
                    &tunnel_runtime,
                    (app.wireguard_exit.enabled && app.wireguard_exit.configured())
                        .then_some(app.wireguard_exit.interface.trim()),
                    (app.wireguard_exit.enabled && app.wireguard_exit.configured())
                        .then(|| {
                            strip_cidr(&app.wireguard_exit.address)
                                .parse::<Ipv4Addr>()
                                .ok()
                        })
                        .flatten(),
                    &network_snapshot,
                    capture_network_snapshot_for_daemon().await,
                );
                let network_changed = latest_snapshot.changed_since(&network_snapshot);
                if network_changed || resumed_after_sleep {
                    captive_portal = detect_captive_portal(timeout).await;
                }
                let platform_network_event = std::mem::take(&mut platform_network_event_pending);
                let runtime_listen_port =
                    tunnel_runtime.active_listen_port.unwrap_or(app.node.listen_port);
                let vpn_active = daemon_vpn_active(vpn_enabled, expected_peers);
                let endpoint_changed = if network_changed {
                    network_snapshot = latest_snapshot.clone();
                    network_changed_at = Some(unix_timestamp());
                    if vpn_active {
                        refresh_port_mapping(
                            &app,
                            &network_snapshot,
                            runtime_listen_port,
                            &mut port_mapping_runtime,
                        )
                        .await;
                        true
                    } else {
                        port_mapping_runtime.stop().await;
                        false
                    }
                } else if resumed_after_sleep {
                    network_changed_at = Some(now);
                    if vpn_active {
                        refresh_port_mapping(
                            &app,
                            &network_snapshot,
                            runtime_listen_port,
                            &mut port_mapping_runtime,
                        )
                        .await;
                        true
                    } else {
                        port_mapping_runtime.stop().await;
                        false
                    }
                } else if vpn_active {
                    match port_mapping_runtime
                        .renew_if_due(&network_snapshot, runtime_listen_port, timeout)
                        .await
                    {
                        Ok(changed) => changed,
                        Err(error) => {
                            eprintln!("daemon: port mapping renew failed: {error}");
                            false
                        }
                    }
                } else {
                    false
                };
                if !platform_network_event
                    && !network_changed
                    && !endpoint_changed
                    && !resumed_after_sleep
                {
                    continue;
                }
                let fips_refresh = fips_link_event_refresh(
                    platform_network_event,
                    network_changed,
                    endpoint_changed,
                    resumed_after_sleep,
                );
                if platform_network_event
                    || network_changed
                    || resumed_after_sleep
                    || endpoint_changed
                {
                    let refresh_reason = if network_changed {
                        "network change"
                    } else if resumed_after_sleep {
                        "sleep/wake"
                    } else if platform_network_event {
                        "platform route event"
                    } else {
                        "endpoint change"
                    };
                    if network_changed {
                        network_snapshot = latest_snapshot;
                        network_changed_at = Some(unix_timestamp());
                        eprintln!("daemon: network change detected; refreshing FIPS endpoint state");
                    } else if resumed_after_sleep {
                        network_snapshot = latest_snapshot;
                        network_changed_at = Some(now);
                        eprintln!("daemon: sleep/wake detected; refreshing FIPS endpoint state");
                    } else if platform_network_event {
                        eprintln!(
                            "daemon: platform route event detected; refreshing FIPS endpoint state"
                        );
                    } else {
                        eprintln!("daemon: endpoint changed; refreshing FIPS endpoint state");
                    }
                    let fips_result = match fips_refresh {
                        FipsLinkEventRefresh::RestartEndpoint
                        | FipsLinkEventRefresh::UpdatePeersAndRefreshPaths
                        | FipsLinkEventRefresh::RefreshPaths => {
                            if fips_tunnel_runtime.is_some()
                                || fips_private_runtime_active(&app, vpn_enabled, expected_peers)
                            {
                                refresh_fips_tunnel_runtime_after_link_event(
                                    &mut fips_tunnel_runtime,
                                    FipsRestartContext {
                                        app: &app,
                                        config_path: &config_path,
                                        network_id: &network_id,
                                        fallback_iface: &iface,
                                        underlay_interface: network_snapshot
                                            .default_interface
                                            .as_deref(),
                                        underlay_interface_mtu: network_snapshot
                                            .default_interface_mtu,
                                        own_pubkey: own_pubkey.as_deref(),
                                        // Authenticated dial hints retained across link churn.
                                        recent_peers: Some(&recent_peers),
                                        ethernet_underlay: ethernet_underlay.as_ref(),
                                        last_endpoint_peer_signature:
                                            &mut last_fips_endpoint_peer_signature,
                                    },
                                    refresh_reason,
                                    fips_refresh,
                                )
                                .await
                            } else {
                                Ok(())
                            }
                        }
                        FipsLinkEventRefresh::None => Ok(()),
                    };
                    if let Err(error) = fips_result {
                        vpn_status = format!("Network route refresh failed ({error})");
                    } else {
                        if !matches!(fips_refresh, FipsLinkEventRefresh::None) {
                            platform_network_event_pending = false;
                            drain_platform_network_changes(&mut platform_network_change_rx);
                            platform_network_event_suppressed_until =
                                Some(
                                    Instant::now()
                                        + Duration::from_secs(
                                            DAEMON_NETWORK_SETTLE_RECHECK_SECS,
                                        ),
                                );
                            schedule_platform_network_settle_recheck(
                                &mut intervals.network,
                                platform_network_event,
                            );
                        }
                        if let Some(runtime) = fips_tunnel_runtime.as_ref() {
                            if let Err(error) = runtime.ping_peers(&network_id, now).await {
                                eprintln!("fips: peer ping failed after network refresh: {error}");
                            }
                            if let Err(error) = runtime.refresh_link_statuses().await {
                                eprintln!(
                                    "fips: peer link snapshot failed after network refresh: {error}"
                                );
                            }
                            update_recent_peers_from_runtime(
                                runtime,
                                &app,
                                &network_id,
                                own_pubkey.as_deref(),
                                RecentPeerRefresh {
                                    recent_peers: &mut recent_peers,
                                    recent_peers_path: &recent_peers_path,
                                    last_endpoint_peer_signature:
                                        &mut last_fips_endpoint_peer_signature,
                                    last_refresh_signature:
                                        &mut last_recent_peer_refresh_signature,
                                    last_cache_persisted_at:
                                        &mut last_recent_peer_cache_persisted_at,
                                    force_rebuild: true,
                                },
                                now,
                            )
                            .await;
                        }
                        vpn_status = if daemon_vpn_active(vpn_enabled, expected_peers) {
                            "Connected (network refresh)".to_string()
                        } else {
                            daemon_vpn_idle_status(
                                vpn_enabled,
                                expected_peers,
                                app.join_requests_enabled(),
                            )
                            .to_string()
                        };
                    }
                    if let Some(runtime) = fips_tunnel_runtime.as_ref()
                        && let Err(error) = broadcast_local_fips_capabilities(runtime, &app).await
                    {
                        eprintln!("fips: capabilities broadcast failed after network refresh: {error}");
                    }
                }
            }
            _ = intervals.state.tick() => {
                // Taking the request removes the control file, which is the CLI's
                // acknowledgement. Do this before any maintenance that may await
                // tunnel I/O or a route refresh; the request is still applied at
                // the normal point below, before the runtime configuration sync.
                let pending_control_request = take_daemon_control_request(&config_path);
                if let Err(error) = app.ensure_pending_nostr_join_request(unix_timestamp()) {
                    eprintln!("daemon: failed to rotate expired join request: {error}");
                }
                if daemon_log_compact_check_due(&mut last_log_compact_check)
                    && let Err(error) = compact_daemon_log_if_needed(&config_path)
                {
                    eprintln!("daemon: failed to compact service log: {error}");
                }
                #[cfg(feature = "paid-exit")]
                match reconcile_automatic_paid_exit_selection(
                    &mut automatic_paid_exit,
                    &mut app,
                    &config_path,
                    unix_timestamp(),
                ) {
                    Ok(true) => {
                        if let Err(error) = sync_fips_private_runtime(
                            &mut fips_tunnel_runtime,
                            SyncFipsPrivateRuntimeContext {
                                app: &app,
                                config_path: &config_path,
                                network_id: &network_id,
                                iface: &iface,
                                underlay_interface: network_snapshot
                                    .default_interface
                                    .as_deref(),
                                underlay_interface_mtu: network_snapshot.default_interface_mtu,
                                own_pubkey: own_pubkey.as_deref(),
                                recent_peers: Some(&recent_peers),
                                ethernet_underlay: ethernet_underlay.as_ref(),
                                vpn_enabled,
                                expected_peers,
                            },
                        )
                        .await
                        {
                            vpn_status = format!("automatic paid-exit FIPS selection failed ({error})");
                        }
                    }
                    Ok(false) => {}
                    Err(error) => {
                        eprintln!("paid-exit: automatic selection failed: {error}");
                    }
                }
                #[cfg(feature = "paid-exit")]
                let mut automatic_paid_exit_route_changed = false;
                if let Some(runtime) = fips_tunnel_runtime.as_mut() {
                    #[cfg(feature = "paid-exit")]
                    if last_paid_exit_session_open_at.elapsed()
                        >= Duration::from_secs(PAID_EXIT_SESSION_OPEN_RETRY_SECS)
                    {
                        last_paid_exit_session_open_at = Instant::now();
                        if let Err(error) = send_selected_paid_exit_session_open(
                            runtime,
                            &app,
                            &config_path,
                            unix_timestamp(),
                        )
                        .await
                        {
                            eprintln!("paid-exit: free-probe session open send failed: {error}");
                        }
                    }
                    match drain_fips_mesh_events(
                        runtime,
                        &mut app,
                        &config_path,
                        &mut vpn_status,
                    ) {
                        Ok(drained) => {
                            #[cfg(feature = "paid-exit")]
                            let mut drained = drained;
                            if drained.roster_changed {
                                let reload = build_daemon_reload_config(
                                    app.clone(),
                                    app.effective_network_id(),
                                );
                                app = reload.app;
                                network_id = reload.network_id;
                                expected_peers = reload.expected_peers;
                                own_pubkey = reload.own_pubkey;
                                fips_join_request_sends.clear();
                                if let Err(error) = refresh_fips_tunnel_config(
                                    runtime,
                                    &app,
                                    &config_path,
                                    &network_id,
                                    network_snapshot.default_interface.as_deref(),
                                    network_snapshot.default_interface_mtu,
                                    own_pubkey.as_deref(),
                                )
                                .await
                                {
                                    vpn_status =
                                        format!("Roster applied, but FIPS reload failed ({error})");
                                }
                                if let Some(rt) = magic_dns_runtime.as_ref() {
                                    rt.refresh_records(&app);
                                }
                            }
                            if !drained.endpoint_hint_participants.is_empty()
                                && let Err(error) =
                                    refresh_fips_tunnel_runtime_peer_paths_in_place(
                                        runtime,
                                        FipsRestartContext {
                                            app: &app,
                                            config_path: &config_path,
                                            network_id: &network_id,
                                            fallback_iface: &iface,
                                            underlay_interface: network_snapshot
                                                .default_interface
                                                .as_deref(),
                                            underlay_interface_mtu: network_snapshot
                                                .default_interface_mtu,
                                            own_pubkey: own_pubkey.as_deref(),
                                            recent_peers: Some(&recent_peers),
                                            ethernet_underlay: ethernet_underlay.as_ref(),
                                            last_endpoint_peer_signature:
                                                &mut last_fips_endpoint_peer_signature,
                                        },
                                        &drained.endpoint_hint_participants,
                                        "fresh endpoint capability",
                                    )
                                    .await
                            {
                                vpn_status =
                                    format!("FIPS endpoint hint refresh failed ({error})");
                            }
                            #[cfg(feature = "paid-exit")]
                            handle_paid_exit_mesh_events(
                                PaidExitMeshEventContext {
                                    runtime,
                                    app: &app,
                                    config_path: &config_path,
                                    network_id: &network_id,
                                    underlay_interface: network_snapshot
                                        .default_interface
                                        .as_deref(),
                                    underlay_interface_mtu: network_snapshot.default_interface_mtu,
                                    own_pubkey: own_pubkey.as_deref(),
                                    vpn_status: &mut vpn_status,
                                    spilman_receiver: paid_exit_spilman_receiver.as_ref(),
                                    spilman_receiver_error: paid_exit_spilman_receiver_error.as_deref(),
                                },
                                &mut drained,
                            )
                            .await;
                        }
                        Err(error) => {
                            vpn_status = format!("FIPS event handling failed ({error})");
                        }
                    }
                    if let Err(error) = runtime.refresh_peer_dependent_routes().await {
                        vpn_status = format!("FIPS route refresh failed ({error})");
                    }
                    #[cfg(feature = "paid-exit")]
                    {
                        let observed_at = Instant::now();
                        let active_millis_delta = u64::try_from(
                            observed_at
                                .saturating_duration_since(last_paid_exit_usage_flush_at)
                                .as_millis(),
                        )
                        .unwrap_or(u64::MAX);
                        last_paid_exit_usage_flush_at = observed_at;
                        match flush_fips_paid_route_usage(
                            runtime,
                            &app,
                            &config_path,
                            unix_timestamp(),
                            active_millis_delta,
                        ) {
                            Ok(flush) => {
                                if flush.seller_admission_changed
                                    && let Err(error) = refresh_fips_tunnel_config(
                                        runtime,
                                        &app,
                                        &config_path,
                                        &network_id,
                                        network_snapshot.default_interface.as_deref(),
                                        network_snapshot.default_interface_mtu,
                                        own_pubkey.as_deref(),
                                    )
                                    .await
                                {
                                    vpn_status =
                                        format!("paid-exit admission refresh failed ({error})");
                                }
                                match update_automatic_paid_exit(
                                    &mut automatic_paid_exit,
                                    runtime,
                                    &mut app,
                                    &config_path,
                                    &flush.buyer_delta,
                                    unix_timestamp(),
                                )
                                .await
                                {
                                    Ok(changed) => automatic_paid_exit_route_changed |= changed,
                                    Err(error) => eprintln!(
                                        "paid-exit: automatic buyer update failed: {error}"
                                    ),
                                }
                            }
                            Err(error) => {
                                eprintln!("paid-exit: failed to record FIPS usage: {error}");
                            }
                        }
                        if app.public_paid_exit_node_pubkey_hex().is_some()
                            && automatic_paid_exit.payments_allowed(&app, unix_timestamp())
                        {
                                match paid_exit_stream_due_payments_for_daemon(
                                    &app,
                                    &config_path,
                                    PAID_EXIT_DAEMON_STREAM_PAYMENT_MIN_INCREMENT_MSAT,
                                    PAID_EXIT_DAEMON_STREAM_PAYMENT_LIMIT,
                                ) {
                                    Ok(result)
                                        if result.signed_count > 0 || result.error_count > 0 =>
                                    {
                                        eprintln!(
                                            "paid-exit: streamed buyer payments signed={} persisted={} errors={} due={} processed={} changed={}",
                                            result.signed_count,
                                            result.persisted_count,
                                            result.error_count,
                                            result.total_due_count,
                                            result.processed_due_count,
                                            result.changed
                                        );
                                    }
                                    Ok(_) => {}
                                    Err(error) => {
                                        eprintln!(
                                            "paid-exit: failed to stream buyer payment update: {error}"
                                        );
                                    }
                                }
                        }
                        let flushed = flush_paid_exit_payment_outbox(runtime, &config_path).await;
                        if flushed.sent > 0 || flushed.errors > 0 {
                            eprintln!(
                                "paid-exit: direct FIPS payment outbox sent={} errors={}",
                                flushed.sent, flushed.errors
                            );
                        }
                    }
                }
                #[cfg(feature = "paid-exit")]
                if automatic_paid_exit_route_changed
                    && let Err(error) = sync_fips_private_runtime(
                        &mut fips_tunnel_runtime,
                        SyncFipsPrivateRuntimeContext {
                            app: &app,
                            config_path: &config_path,
                            network_id: &network_id,
                            iface: &iface,
                            underlay_interface: network_snapshot.default_interface.as_deref(),
                            underlay_interface_mtu: network_snapshot.default_interface_mtu,
                            own_pubkey: own_pubkey.as_deref(),
                            recent_peers: Some(&recent_peers),
                            ethernet_underlay: ethernet_underlay.as_ref(),
                            vpn_enabled,
                            expected_peers,
                        },
                    )
                    .await
                {
                    vpn_status = format!("automatic paid-exit failover failed ({error})");
                }
                if let Some(request) = pending_control_request {
                    let publish_fips_roster_after_control =
                        matches!(request, DaemonControlRequest::Reload | DaemonControlRequest::Resume);
                    let control_result = match request {
                        DaemonControlRequest::Stop => break,
                        DaemonControlRequest::Pause => {
                            vpn_enabled = false;
                            let persist_result =
                                persist_desired_daemon_vpn_enabled_in_config(
                                    &mut app,
                                    &config_path,
                                    vpn_enabled,
                                );
                            let join_requests_active = app.join_requests_enabled();
                            port_mapping_runtime.stop().await;
                            vpn_status = daemon_vpn_idle_status(
                                vpn_enabled,
                                expected_peers,
                                join_requests_active,
                            )
                            .to_string();
                            persist_result.map(|_| ())
                        }
                        DaemonControlRequest::Resume => {
                            vpn_enabled = true;
                            let persist_result =
                                persist_desired_daemon_vpn_enabled_in_config(
                                    &mut app,
                                    &config_path,
                                    vpn_enabled,
                                );
                            if daemon_vpn_active(vpn_enabled, expected_peers) {
                                let runtime_listen_port = tunnel_runtime
                                    .active_listen_port
                                    .unwrap_or(app.node.listen_port);
                                refresh_port_mapping(
                                    &app,
                                    &network_snapshot,
                                    runtime_listen_port,
                                    &mut port_mapping_runtime,
                                )
                                .await;
                                vpn_status = "VPN on".to_string();
                            } else {
                                port_mapping_runtime.stop().await;
                                vpn_status = daemon_vpn_idle_status(
                                    vpn_enabled,
                                    expected_peers,
                                    app.join_requests_enabled(),
                                )
                                .to_string();
                            }
                            persist_result.map(|_| ())
                        }
                        DaemonControlRequest::Reload => {
                            match update_daemon_config_from_staged_request(&config_path) {
                                Ok(staged_config_applied) => {
                                    match load_config_with_overrides(
                                        &config_path,
                                        network_override.clone(),
                                        participants_override.clone(),
                                        ConfigLoadMode::Persist,
                                    ) {
                                        Ok((mut reloaded_app, reloaded_network_id)) => {
                                            reloaded_app.pending_nostr_join_request =
                                                app.pending_nostr_join_request.clone();
                                            if let Err(error) = reloaded_app
                                                .ensure_pending_nostr_join_request(unix_timestamp())
                                            {
                                                let _ = write_daemon_control_result(
                                                    &config_path,
                                                    request,
                                                    Err(error.context(
                                                        "failed to preserve daemon join request",
                                                    )),
                                                );
                                                continue;
                                            }
                                            let reload = build_daemon_reload_config(
                                                reloaded_app,
                                                reloaded_network_id,
                                            );
                                            #[cfg(feature = "paid-exit")]
                                            if PaidExitAutomaticBuyer::enabled(&app)
                                                && !PaidExitAutomaticBuyer::enabled(&reload.app)
                                            {
                                                if let Some(runtime) = fips_tunnel_runtime.as_ref()
                                                    && let Err(error) = finalize_automatic_paid_exit(
                                                        &automatic_paid_exit,
                                                        runtime,
                                                        &app,
                                                        &config_path,
                                                        unix_timestamp(),
                                                    )
                                                    .await
                                                {
                                                    eprintln!(
                                                        "paid-exit: automatic mode-exit finalization failed: {error}"
                                                    );
                                                }
                                                automatic_paid_exit.cancel_if_disabled(&reload.app);
                                            }
                                            app = reload.app;
                                            #[cfg(feature = "paid-exit")]
                                            {
                                                (
                                                    paid_exit_spilman_receiver,
                                                    paid_exit_spilman_receiver_error,
                                                ) = try_load_paid_exit_spilman_receiver(
                                                    &config_path,
                                                    &app.paid_exit,
                                                )
                                                .await;
                                            }
                                            network_id = reload.network_id;
                                            expected_peers = reload.expected_peers;
                                            own_pubkey = reload.own_pubkey;
                                            if secure_exit_dns_required(&app) {
                                                magic_dns_runtime.take();
                                            }
                                            if let Some(rt) = magic_dns_runtime.as_ref() {
                                                rt.refresh_records(&app);
                                            }
                                            let join_requests_active = app.join_requests_enabled();
                                            let vpn_active =
                                                daemon_vpn_active(vpn_enabled, expected_peers);
                                            vpn_status = if vpn_active {
                                                "Config reloaded".to_string()
                                            } else if vpn_enabled {
                                                daemon_vpn_idle_status(
                                                    vpn_enabled,
                                                    expected_peers,
                                                    join_requests_active,
                                                )
                                                .to_string()
                                            } else {
                                                "Config reloaded (paused)".to_string()
                                            };
                                            if vpn_active {
                                                let runtime_listen_port = tunnel_runtime
                                                    .active_listen_port
                                                    .unwrap_or(app.node.listen_port);
                                                refresh_port_mapping(
                                                    &app,
                                                    &network_snapshot,
                                                    runtime_listen_port,
                                                    &mut port_mapping_runtime,
                                                )
                                                .await;
                                            }
                                            Ok(())
                                        }
                                        Err(error) => {
                                            vpn_status = if staged_config_applied {
                                                format!("Config apply failed (reload: {error})")
                                            } else {
                                                format!("Config reload failed ({error})")
                                            };
                                            Err(error)
                                        }
                                    }
                                }
                                Err(error) => {
                                    vpn_status = format!("Config apply failed ({error})");
                                    Err(error)
                                }
                            }
                        }
                    };
                    let _ = write_daemon_control_result(&config_path, request, control_result);
                    let pre_sync_fips_roster_recipients = if publish_fips_roster_after_control {
                        fips_tunnel_runtime
                            .as_ref()
                            .map(|runtime| runtime.peer_pubkeys())
                            .unwrap_or_default()
                    } else {
                        Vec::new()
                    };
                    if publish_fips_roster_after_control
                        && let Some(runtime) = fips_tunnel_runtime.as_ref()
                        && let Err(error) = publish_fips_active_network_roster_to(
                            runtime,
                            &app,
                            &config_path,
                            &pre_sync_fips_roster_recipients,
                            &mut pending_fips_roster_recipients,
                        )
                    {
                        eprintln!(
                            "fips: roster publish failed before peer-set refresh: {error}"
                        );
                    }
                    let fips_sync_succeeded = match sync_fips_private_runtime(
                        &mut fips_tunnel_runtime,
                        SyncFipsPrivateRuntimeContext {
                            app: &app,
                            config_path: &config_path,
                            network_id: &network_id,
                            iface: &iface,
                            underlay_interface: network_snapshot.default_interface.as_deref(),
                            underlay_interface_mtu: network_snapshot.default_interface_mtu,
                            own_pubkey: own_pubkey.as_deref(),
                            recent_peers: Some(&recent_peers),
                            ethernet_underlay: ethernet_underlay.as_ref(),
                            vpn_enabled,
                            expected_peers,
                        },
                    )
                    .await
                    {
                        Ok(()) => true,
                        Err(error) => {
                            vpn_status = format!("FIPS private mesh update failed ({error})");
                            false
                        }
                    };
                    if (!fips_sync_succeeded || !secure_exit_dns_required(&app))
                        && magic_dns_runtime.is_none()
                    {
                        magic_dns_runtime = ConnectMagicDnsRuntime::start(&app);
                    }
                    if publish_fips_roster_after_control
                        && let Some(runtime) = fips_tunnel_runtime.as_ref()
                    {
                        publish_fips_control_updates(
                            runtime,
                            &app,
                            &config_path,
                            &mut pending_fips_roster_recipients,
                            fips_sync_succeeded,
                        )
                        .await;
                    }
                    let fips_peer_statuses = current_fips_peer_statuses!(fips_tunnel_runtime);
                    let fips_relay_statuses =
                        current_fips_relay_statuses!(&fips_tunnel_runtime).await;
                    let fips_endpoint_peer_states =
                        current_fips_endpoint_peer_states!(&last_fips_endpoint_peer_signature);
                    let fips_advertised_routes =
                        current_fips_advertised_routes!(fips_tunnel_runtime, &app);
                    let network = network_snapshot.summary(network_changed_at, captive_portal);
                    let port_mapping = port_mapping_runtime.status();
                    if persist_daemon_runtime_and_cleanup_state_async(
                        &state_file,
                        &config_path,
                        DaemonRuntimeStateInput {
                            app: &app,
                            vpn_enabled,
                            vpn_active: daemon_vpn_active(vpn_enabled, expected_peers),
                            expected_peers,
                            tunnel_runtime: &tunnel_runtime,
                            fips_peer_statuses: &fips_peer_statuses,
                            fips_relay_statuses: &fips_relay_statuses,
                            fips_endpoint_peers: &fips_endpoint_peer_states,
                            advertised_routes_by_participant: &fips_advertised_routes,
                            vpn_status: &vpn_status,
                            network: &network,
                            port_mapping: &port_mapping,
                        },
                    )
                    .await
                    {
                        last_state_persisted_at = Instant::now();
                    }
                }
                if let Some((executable, launched_fingerprint)) =
                    supervised_service_executable.as_ref()
                {
                    match service_supervisor_restart_due(executable, launched_fingerprint) {
                        Ok(true) => {
                            eprintln!(
                                "daemon: service executable changed on disk; exiting so the supervisor restarts the updated binary"
                            );
                            break;
                        }
                        Ok(false) => {}
                        Err(error) => {
                            eprintln!(
                                "daemon: failed to check service executable fingerprint: {error}"
                            );
                        }
                    }
                }
                if vpn_status == "Connected (network refresh)"
                    && daemon_vpn_active(vpn_enabled, expected_peers)
                {
                    vpn_status = "VPN on".to_string();
                }
                if last_state_persisted_at.elapsed() >= daemon_state_persist_interval {
                    let fips_peer_statuses = current_fips_peer_statuses!(fips_tunnel_runtime);
                    let fips_relay_statuses =
                        current_fips_relay_statuses!(&fips_tunnel_runtime).await;
                    let fips_endpoint_peer_states =
                        current_fips_endpoint_peer_states!(&last_fips_endpoint_peer_signature);
                    let fips_advertised_routes =
                        current_fips_advertised_routes!(fips_tunnel_runtime, &app);
                    let network = network_snapshot.summary(network_changed_at, captive_portal);
                    let port_mapping = port_mapping_runtime.status();
                    if persist_daemon_runtime_and_cleanup_state_async(
                        &state_file,
                        &config_path,
                        DaemonRuntimeStateInput {
                            app: &app,
                            vpn_enabled,
                            vpn_active: daemon_vpn_active(vpn_enabled, expected_peers),
                            expected_peers,
                            tunnel_runtime: &tunnel_runtime,
                            fips_peer_statuses: &fips_peer_statuses,
                            fips_relay_statuses: &fips_relay_statuses,
                            fips_endpoint_peers: &fips_endpoint_peer_states,
                            advertised_routes_by_participant: &fips_advertised_routes,
                            vpn_status: &vpn_status,
                            network: &network,
                            port_mapping: &port_mapping,
                        },
                    )
                    .await
                    {
                        last_state_persisted_at = Instant::now();
                    }
                }
            }
        }
    }
    shutdown_daemon_vpn(DaemonVpnShutdown {
        port_mapping_runtime: &mut port_mapping_runtime,
        fips_tunnel_runtime,
        tunnel_runtime: &mut tunnel_runtime,
        config_path: &config_path,
        state_file: &state_file,
        pid_file: &pid_file,
        expected_peers,
        network_snapshot: &network_snapshot,
        network_changed_at,
        captive_portal,
    })
    .await
}
