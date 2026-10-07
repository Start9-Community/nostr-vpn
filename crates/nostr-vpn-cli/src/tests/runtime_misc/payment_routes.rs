use super::*;
use nostr_vpn_core::paid_route_store::update_paid_route_store;

#[cfg(target_os = "linux")]
#[test]
fn disabled_fips_traversal_does_not_install_stun_bypass_routes() {
    let mut app = AppConfig::generated();
    app.nostr.relays.clear();
    let stun_ip = Ipv4Addr::new(198, 51, 100, 45);
    app.nat.stun_servers = vec![format!("stun:{stun_ip}:3478")];
    for (discovery, webrtc) in [(false, false), (true, false), (false, true), (true, true)] {
        app.fips_nostr_discovery_enabled = discovery;
        app.fips_webrtc_enabled = webrtc;
        let hosts =
            crate::platform_routing::control_plane_bypass_ipv4_hosts_from_interfaces(&app, &[]);
        assert_eq!(hosts.contains(&stun_ip), discovery || webrtc);
    }
}

#[test]
fn paid_modes_keep_wallet_mints_reachable_outside_the_route_they_fund() {
    let dir = std::env::temp_dir().join(format!("nvpn-mint-routes-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let config_path = dir.join("config.toml");
    let mint = "https://198.51.100.42/Bitcoin";
    update_paid_route_store(&paid_route_store_file_path(&config_path), |store| {
        store.upsert_wallet_mint(mint, "Payment mint", Some(100_000), 1);
        store.upsert_wallet_mint("https://198.51.100.42/another", "Same host", None, 1);
        Ok(())
    })
    .unwrap();
    let mut app = AppConfig::generated();
    app.nostr.relays.clear();
    app.nat.stun_servers.clear();
    let network_id = app.networks[0].network_id.clone();
    let build = |app: &AppConfig| {
        fips_tunnel_config_from_app(FipsTunnelConfigInput {
            app,
            config_path: &config_path,
            network_id: &network_id,
            iface: "utun-test".to_string(),
            underlay_interface: Some("test-physical"),
            underlay_interface_mtu: None,
            own_pubkey: None,
            recent_peers: None,
            live_peer_endpoints: &[],
            ethernet_underlay: None,
        })
        .unwrap()
    };
    let mint_ip = Ipv4Addr::new(198, 51, 100, 42);
    for source in [
        InternetSource::PaidAutomatic,
        InternetSource::PaidManual,
        InternetSource::Direct,
        InternetSource::PrivateVpn,
        InternetSource::WireGuard,
    ] {
        app.set_internet_source(source);
        let config = build(&app);
        let expected = usize::from(matches!(
            source,
            InternetSource::PaidAutomatic | InternetSource::PaidManual
        ));
        assert_eq!(
            config
                .control_plane_bypass_hosts
                .iter()
                .filter(|&&ip| ip == mint_ip)
                .count(),
            expected,
            "payment reachability must follow the chosen Internet mode: {source:?}"
        );
    }
    update_paid_route_store(&paid_route_store_file_path(&config_path), |store| {
        store.wallet.mints.clear();
        store.wallet.default_mint.clear();
        Ok(())
    })
    .unwrap();
    app.set_internet_source(InternetSource::PaidAutomatic);
    assert!(
        !build(&app).control_plane_bypass_hosts.contains(&mint_ip),
        "removing a wallet mint must withdraw its bypass"
    );
    std::fs::remove_dir_all(dir).unwrap();
}
