    #[test]
    fn tunnel_config_caps_bootstrap_transit_peers_without_exhausting_open_discovery() {
        let alice_keys = Keys::generate();
        let bob_keys = Keys::generate();
        let alice_nsec = alice_keys.secret_key().to_bech32().expect("alice nsec");
        let alice_pubkey = alice_keys.public_key().to_hex();
        let bob_pubkey = bob_keys.public_key().to_hex();
        let network_id = "fips-bootstrap-transit-cap-test";

        let mut app = AppConfig::default();
        app.nostr.secret_key = alice_nsec;
        app.connect_to_non_roster_fips_peers = true;
        app.fips_bootstrap_enabled = true;
        app.networks[0].enabled = true;
        app.networks[0].network_id = network_id.to_string();
        app.networks[0].devices = vec![alice_pubkey.clone(), bob_pubkey.clone()];
        app.fips_bootstrap_peers.clear();

        let mut bootstrap_npubs = Vec::new();
        for i in 0..(FIPS_NOSTR_OPEN_DISCOVERY_MAX_PENDING + 2) {
            let keys = Keys::generate();
            let npub = keys.public_key().to_bech32().expect("bootstrap npub");
            app.fips_bootstrap_peers.insert(
                npub.clone(),
                vec![format!("[2001:db8::{:x}]:51820", i + 10)],
            );
            bootstrap_npubs.push(npub);
        }
        assert_eq!(
            app.fips_bootstrap_peer_endpoints().len(),
            FIPS_NOSTR_OPEN_DISCOVERY_MAX_PENDING + 2,
        );

        let config = FipsPrivateTunnelConfig::from_app(
            &app,
            network_id,
            "utun-test",
            Some(&alice_pubkey),
            None,
            &[],
        )
        .expect("fips tunnel config");

        let seeded_bootstrap = config
            .endpoint_peers
            .iter()
            .filter(|peer| bootstrap_npubs.iter().any(|npub| npub == &peer.npub))
            .collect::<Vec<_>>();
        assert_eq!(
            seeded_bootstrap.len(),
            FIPS_STATIC_NON_ROSTER_TRANSIT_MAX_SEEDS,
            "bootstrap transit peers should not consume the whole open-discovery cap"
        );
        assert_eq!(
            config.open_discovery_max_pending,
            FIPS_NOSTR_OPEN_DISCOVERY_MAX_PENDING
                - FIPS_STATIC_NON_ROSTER_TRANSIT_MAX_SEEDS,
            "bounded bootstrap transit should leave a nonzero fresh open-discovery budget"
        );
        assert!(config.open_discovery_max_pending > 0);
    }

    #[test]
    fn tunnel_config_keeps_public_native_seeds_inside_static_cap() {
        let alice_keys = Keys::generate();
        let bob_keys = Keys::generate();
        let alice_nsec = alice_keys.secret_key().to_bech32().expect("alice nsec");
        let alice_pubkey = alice_keys.public_key().to_hex();
        let bob_pubkey = bob_keys.public_key().to_hex();
        let network_id = "fips-public-bootstrap-priority-test";

        let mut app = AppConfig::default();
        app.nostr.secret_key = alice_nsec;
        app.connect_to_non_roster_fips_peers = true;
        app.fips_bootstrap_enabled = true;
        app.networks[0].enabled = true;
        app.networks[0].network_id = network_id.to_string();
        app.networks[0].devices = vec![alice_pubkey.clone(), bob_pubkey];
        for i in 0..2 {
            let npub = Keys::generate()
                .public_key()
                .to_bech32()
                .expect("custom bootstrap npub");
            app.fips_bootstrap_peers
                .insert(npub, vec![format!("[2001:db8::{:x}]:51820", i + 10)]);
        }

        let config = FipsPrivateTunnelConfig::from_app(
            &app,
            network_id,
            "utun-test",
            Some(&alice_pubkey),
            None,
            &[],
        )
        .expect("fips tunnel config");

        let endpoint_npubs = config
            .endpoint_peers
            .iter()
            .map(|peer| peer.npub.as_str())
            .collect::<HashSet<_>>();
        for (npub, _) in nostr_vpn_core::config::DEFAULT_FIPS_BOOTSTRAP_PEERS {
            assert!(
                endpoint_npubs.contains(npub),
                "public native seed {npub} must survive the static transit cap"
            );
        }
        assert_eq!(
            config
                .endpoint_peers
                .iter()
                .filter(|peer| {
                    nostr_vpn_core::config::DEFAULT_FIPS_BOOTSTRAP_PEERS
                        .iter()
                        .any(|(npub, _)| peer.npub == *npub)
                })
                .count(),
            FIPS_STATIC_NON_ROSTER_TRANSIT_MAX_SEEDS
        );
    }
