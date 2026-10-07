#[test]
fn bonjour_candidate_is_only_a_hint_for_an_approved_device() {
    let peer = Keys::generate();
    let peer_hex = peer.public_key().to_hex();
    let identity = PeerIdentity::from_npub(&peer.public_key().to_bech32().unwrap()).unwrap();
    let mobile = MobileTunnelConfig {
        share_local_candidates: true,
        ..empty_config()
    };
    let config = RwLock::new(mobile);
    let addresses = vec!["192.168.50.24:51820".into()];
    assert!(!record_mobile_lan_peer(&config, identity, &addresses));
    assert!(config.read().unwrap().peer_hints.is_empty());
    config
        .write()
        .unwrap()
        .peers
        .push(FipsMeshPeerConfig::from_participant_pubkey(&peer_hex, Vec::new()).unwrap());
    assert!(record_mobile_lan_peer(&config, identity, &addresses));
    assert!(!record_mobile_lan_peer(&config, identity, &addresses));
    assert!(!record_mobile_lan_peer(
        &config,
        identity,
        &[
            "127.0.0.1:51820".into(),
            "0.0.0.0:51820".into(),
            "[fe80::1]:51820".into(),
        ]
    ));
    let observed = config.read().unwrap();
    let hints = observed.peer_hints.get(&peer_hex).unwrap();
    assert_eq!(hints.len(), 1);
    assert_eq!(hints[0].addr, addresses[0]);
    assert!(hints[0].seen_at_ms.is_some());
    assert!(observed.peers[0].allowed_ips.is_empty());
}

#[test]
fn onboarding_and_joined_mobile_endpoints_share_lan_discovery_scope() {
    let mobile = MobileTunnelConfig {
        share_local_candidates: true,
        nostr_discovery_enabled: true,
        nostr_relays: vec!["wss://relay.example.org".into()],
        device_approval_pending: true,
        ..empty_config()
    };
    let onboarding =
        fips_endpoint_config_for_platform("onboarding", &mobile, RuntimePlatform::Android);
    let joined =
        fips_endpoint_config_for_platform("private-network", &mobile, RuntimePlatform::Android);
    assert!(onboarding.node.discovery.lan.enabled);
    assert_eq!(
        onboarding.node.discovery.lan.scope.as_deref(),
        Some("nostr-vpn")
    );
    assert_eq!(
        onboarding.node.discovery.lan.scope,
        joined.node.discovery.lan.scope
    );
}

#[test]
fn capability_refresh_preserves_the_discovered_lan_path() {
    let peer = Keys::generate();
    let participant = peer.public_key().to_hex();
    let identity = PeerIdentity::from_npub(&peer.public_key().to_bech32().unwrap()).unwrap();
    let mobile = MobileTunnelConfig {
        share_local_candidates: true,
        peers: vec![FipsMeshPeerConfig::from_participant_pubkey(&participant, Vec::new()).unwrap()],
        ..empty_config()
    };
    let config = Arc::new(RwLock::new(mobile));
    assert!(record_mobile_lan_peer(
        &config,
        identity,
        &["192.168.50.24:51820".into()]
    ));
    let hints = Arc::new(RwLock::new(config.read().unwrap().peer_hints.clone()));
    let capabilities = PeerCapabilities {
        endpoint_hints: vec![PeerEndpointHint::udp("192.168.51.24:51820")],
        ..PeerCapabilities::default()
    };
    assert!(update_mobile_peer_hints(&hints, &participant, &capabilities).unwrap());
    sync_mobile_config_peer_hints(&config, &hints).unwrap();
    let current = config.read().unwrap();
    let addresses = &current.peer_hints[&participant];
    assert!(
        addresses
            .iter()
            .any(|hint| hint.addr == "192.168.50.24:51820")
    );
    assert!(
        addresses
            .iter()
            .any(|hint| hint.addr == "192.168.51.24:51820")
    );
}
