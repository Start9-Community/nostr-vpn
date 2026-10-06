use super::*;

#[test]
fn daemon_vpn_idle_status_distinguishes_waiting_paused_and_server() {
    assert_eq!(
        daemon_vpn_idle_status(true, 0, false),
        crate::WAITING_FOR_PARTICIPANTS_STATUS
    );
    assert_eq!(
        daemon_vpn_idle_status(false, 0, true),
        "VPN paused; FIPS server active"
    );
    assert_eq!(daemon_vpn_idle_status(false, 0, false), "Paused");
    assert_eq!(daemon_vpn_idle_status(true, 2, false), "Paused");
}

#[test]
fn vpn_switch_controls_fips_with_no_active_network() {
    let mut app = AppConfig::generated();
    app.fips_host_tunnel_enabled = false;
    for network in &mut app.networks {
        network.listen_for_join_requests = false;
    }

    assert!(app.active_network_opt().is_none());
    assert!(fips_private_runtime_active(&app, true));

    let network_id = app.networks[0].id.clone();
    app.set_network_enabled(&network_id, true)
        .expect("enable network");
    app.set_network_join_requests_enabled(&network_id, true)
        .expect("enable join requests");
    assert!(!fips_private_runtime_active(&app, false));
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn enabled_fips_host_tunnel_activates_runtime_while_vpn_is_paused() {
    let mut app = AppConfig::generated();
    app.fips_host_tunnel_enabled = true;
    for network in &mut app.networks {
        network.listen_for_join_requests = false;
    }

    assert_eq!(expected_peer_count(&app), 0);
    assert!(fips_private_runtime_active(&app, false));
}

#[test]
fn pending_join_request_does_not_override_vpn_off() {
    let mut app = AppConfig::generated();
    app.fips_host_tunnel_enabled = false;
    for network in &mut app.networks {
        network.listen_for_join_requests = false;
    }

    assert!(app.active_network_opt().is_none());
    assert_eq!(expected_peer_count(&app), 0);
    assert!(app.pending_nostr_join_request.is_none());
    assert!(!fips_private_runtime_active(&app, false));

    app.ensure_pending_nostr_join_request(1_778_998_000)
        .expect("pending device-approval request");

    assert!(app.pending_nostr_join_request.is_some());
    assert!(!fips_private_runtime_active(&app, false));
    assert!(fips_private_runtime_active(&app, true));
}

#[test]
fn saved_discovery_and_static_peers_do_not_override_vpn_off() {
    let mut app = AppConfig::generated_without_networks();
    app.connect_to_non_roster_fips_peers = true;
    app.fips_nostr_discovery_enabled = true;
    app.fips_peer_endpoints.insert(
        Keys::generate().public_key().to_bech32().unwrap(),
        vec!["203.0.113.1:51820".into()],
    );
    assert!(app.has_fips_static_peer_endpoints());
    assert!(!fips_private_runtime_active(&app, false));
    assert!(fips_private_runtime_active(&app, true));
}

#[test]
fn explicit_websocket_listener_keeps_seed_running_while_vpn_is_paused() {
    let mut app = AppConfig::generated_without_networks();
    app.fips_websocket_public_url = "wss://seed.example/fips".into();
    assert!(!fips_private_runtime_active(&app, false));
    app.fips_websocket_bind_addr = "127.0.0.1:8765".into();
    assert!(fips_private_runtime_active(&app, false));
    app.fips_websocket_bind_addr.clear();
    assert!(!fips_private_runtime_active(&app, false));
}

#[cfg(feature = "paid-exit")]
#[test]
fn paid_exit_seller_keeps_private_fips_runtime_active_without_roster() {
    let mut app = AppConfig::generated();
    app.fips_host_tunnel_enabled = false;
    app.paid_exit.enabled = true;
    for network in &mut app.networks {
        network.listen_for_join_requests = false;
    }

    assert!(app.active_network_opt().is_none());
    assert_eq!(expected_peer_count(&app), 0);
    assert!(paid_exit_fips_runtime_active(&app));
    assert!(fips_private_runtime_active(&app, false));
}

#[cfg(feature = "paid-exit")]
#[test]
fn paid_automatic_requires_vpn_on_before_selecting_seller() {
    use nostr_vpn_core::config::InternetSource;

    let mut app = AppConfig::generated();
    app.fips_host_tunnel_enabled = false;
    for network in &mut app.networks {
        network.listen_for_join_requests = false;
    }

    app.set_internet_source(InternetSource::PaidAutomatic);
    assert!(app.public_paid_exit_node_pubkey_hex().is_none());
    assert!(paid_exit_fips_runtime_active(&app));
    assert!(!fips_private_runtime_active(&app, false));
    assert!(fips_private_runtime_active(&app, true));

    app.set_internet_source(InternetSource::Direct);
    assert!(!app.connect_to_non_roster_fips_peers);
    assert!(!paid_exit_fips_runtime_active(&app));

    assert!(app.enable_paid_exit_market_discovery());
    assert_eq!(app.internet_source, InternetSource::Direct);
    assert!(paid_exit_fips_runtime_active(&app));
    app.connect_to_non_roster_fips_peers = false;
    assert!(!paid_exit_fips_runtime_active(&app));
}

#[cfg(feature = "paid-exit")]
#[test]
fn remembered_manual_provider_does_not_override_vpn_off() {
    let provider = Keys::generate()
        .public_key()
        .to_bech32()
        .expect("provider npub");
    let mut app = AppConfig::generated();
    app.fips_host_tunnel_enabled = false;
    app.fips_nostr_discovery_enabled = false;
    app.fips_advertise_public_endpoint = false;
    for network in &mut app.networks {
        network.listen_for_join_requests = false;
    }

    app.set_manual_paid_exit_provider(&provider)
        .expect("manual provider");
    app.set_internet_source(InternetSource::PaidManual);
    app.set_internet_source(InternetSource::Direct);

    assert_eq!(app.internet_source, InternetSource::Direct);
    assert!(app.connect_to_non_roster_fips_peers);
    assert!(!app.fips_nostr_discovery_enabled);
    assert!(!app.fips_advertise_public_endpoint);
    assert!(paid_exit_fips_runtime_active(&app));
    assert!(!fips_private_runtime_active(&app, false));
    assert!(fips_private_runtime_active(&app, true));
}
