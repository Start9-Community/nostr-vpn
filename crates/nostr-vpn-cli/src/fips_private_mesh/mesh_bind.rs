async fn bind_fips_private_mesh(
    config: &FipsPrivateTunnelConfig,
) -> Result<Arc<FipsPrivateMeshRuntime>> {
    let scope = config
        .ethernet_underlay
        .is_none()
        .then(|| {
            config
                .nostr_discovery_enabled
                .then(|| fips_lan_discovery_scope(&config.network_id))
        })
        .flatten();
    let transport = FipsEndpointTransportConfig {
        listen_port: config.listen_port,
        bind_interface: config.underlay_interface.clone(),
        advertised_endpoint: config.advertised_endpoint.clone(),
        advertise_public_endpoint: config.advertise_public_endpoint,
        nostr_discovery_enabled: config.nostr_discovery_enabled,
        webrtc_enabled: config.webrtc_enabled,
        stun_servers: config.stun_servers.clone(),
        nostr_relays: config.nostr_relays.clone(),
        websocket: config.websocket.clone(),
        share_local_candidates: config.share_local_candidates,
    };
    let endpoint_config = match config.ethernet_underlay.as_ref() {
        Some(ethernet) => fips_endpoint_config_for_ethernet(
            &config.endpoint_peers,
            Some(&transport),
            ethernet,
            config.mesh_mtu,
            config.nostr_discovery_policy,
            config.open_discovery_max_pending,
        ),
        None => fips_endpoint_config_with_open_discovery_limit(
            &config.endpoint_peers,
            Some(&transport),
            config.mesh_mtu,
            config.nostr_discovery_policy,
            config.open_discovery_max_pending,
        ),
    };
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    let local_tunnel_ips = config.local_tunnel_ips();
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    let local_tunnel_ips = Vec::new();

    Ok(Arc::new(
        FipsPrivateMeshRuntime::bind_with_config_scoped(
            config.identity_nsec.clone(),
            scope,
            config.peers.clone(),
            endpoint_config,
            config.local_allowed_ips(),
            local_tunnel_ips,
            config.paid_route_admissions.clone(),
        )
        .await?,
    ))
}
