#[test]
fn connected_device_stays_joining_until_its_roster_receipt_arrives() {
    let dir = std::env::temp_dir().join(format!(
        "nvpn-join-confirmation-{}",
        Keys::generate().public_key().to_hex()
    ));
    std::fs::create_dir(&dir).unwrap();
    let mut runtime = NativeAppRuntime::from_startup_error(&anyhow!("fixture"));
    runtime.startup_error = None;
    runtime.config_path = dir.join("config.toml");
    create_test_network(&mut runtime, "Home");
    let own = runtime.config.own_nostr_pubkey_hex().unwrap();
    let peer = Keys::generate().public_key().to_hex();
    runtime.config.networks[0].admins = vec![own.clone()];
    runtime.config.networks[0].devices = vec![peer.clone()];
    runtime.config.networks[0].shared_roster_updated_at = unix_timestamp();
    let network = runtime.config.networks[0].clone();
    let roster = nostr_vpn_core::join_requests::prepare_manual_join_delivery(
        &runtime.config,
        &network.id,
        &peer,
    )
    .unwrap();
    let path =
        nostr_vpn_core::join_delivery::queue_join_roster(&runtime.config_path, &peer, &roster)
            .unwrap();
    runtime.daemon_state = Some(DaemonRuntimeState {
        peers: vec![DaemonPeerState {
            participant_pubkey: peer.clone(),
            reachable: true,
            last_fips_seen_at: Some(unix_timestamp()),
            ..Default::default()
        }],
        ..Default::default()
    });
    let assert_joining = |runtime: &NativeAppRuntime| {
        let state = runtime.network_state(&network, &own, true, &runtime.current_join_request_link());
        let device = state
            .participants
            .iter()
            .find(|p| p.pubkey_hex == peer)
            .unwrap();
        assert!(device.reachable, "transport is connected during onboarding");
        assert!(!device.roster_accepted, "transport is not a roster receipt");
        assert_eq!(device.state, "pending");
        assert_eq!(
            device.status_text,
            "Waiting for this device to confirm the network"
        );
        assert_eq!(
            state.online_count, 1,
            "only the admin has confirmed membership"
        );
    };
    assert_joining(&runtime);
    let delivery = nostr_vpn_core::join_delivery::load_join_rosters(&runtime.config_path)
        .remove(0)
        .1;
    std::fs::remove_file(&path).unwrap(); // The old delivery retry budget expires.
    assert_joining(&runtime);
    nostr_vpn_core::join_delivery::complete_join_roster_delivery(&path, &delivery).unwrap();
    let state = runtime.network_state(&network, &own, true, &runtime.current_join_request_link());
    let device = state
        .participants
        .iter()
        .find(|p| p.pubkey_hex == peer)
        .unwrap();
    assert!(device.roster_accepted);
    assert_eq!(device.state, "online");
    assert_eq!(state.online_count, 2);
    std::fs::remove_dir_all(dir).unwrap();
}
