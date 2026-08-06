    #[test]
    fn native_state_reports_active_exit_node_when_selected_peer_is_reachable() {
        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        let own_pubkey = runtime
            .config
            .own_nostr_pubkey_hex()
            .expect("generated config should have own pubkey");
        let exit_pubkey = "26525c442dd039de4e728b41ee8d7f717b267ab25b7c219d53a3249e1c9174cc";
        runtime.startup_error = None;
        runtime.daemon_running = true;
        runtime.vpn_enabled = true;
        runtime.vpn_active = true;
        runtime
            .config
            .set_internet_source(InternetSource::PrivateVpn);
        runtime.config.exit_node = exit_pubkey.to_string();
        runtime.config.exit_node_leak_protection = true;
        create_test_network(&mut runtime, "Home");
        runtime.config.networks[0].admins = vec![own_pubkey];
        runtime.config.networks[0].devices = vec![exit_pubkey.to_string()];
        runtime
            .config
            .set_peer_alias(exit_pubkey, "lab-exit")
            .unwrap();
        runtime.daemon_state = Some(DaemonRuntimeState {
            vpn_enabled: true,
            vpn_active: true,
            expected_peer_count: 1,
            connected_peer_count: 1,
            mesh_ready: true,
            peers: vec![DaemonPeerState {
                participant_pubkey: exit_pubkey.to_string(),
                advertised_routes: vec!["0.0.0.0/0".to_string()],
                reachable: true,
                ..DaemonPeerState::default()
            }],
            ..DaemonRuntimeState::default()
        });

        let state = runtime.state();
        assert!(!state.exit_node_blocked);
        assert!(state.exit_node_active);
        assert_eq!(
            state.exit_node_status_text,
            "Private exit · lab-exit.nvpn · Connected"
        );
    }

    #[test]
    fn native_state_flags_wireguard_exit_blocking_without_advertising_exit() {
        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.daemon_running = true;
        runtime.vpn_enabled = true;
        runtime.vpn_active = false;
        let own_pubkey = runtime
            .config
            .own_nostr_pubkey_hex()
            .expect("generated config should have own pubkey");
        create_test_network(&mut runtime, "Home");
        runtime.config.networks[0].admins = vec![own_pubkey];
        runtime.config.exit_node_leak_protection = true;
        runtime.config.node.advertise_exit_node = false;
        runtime
            .config
            .set_internet_source(InternetSource::WireGuard);
        runtime.config.wireguard_exit.address = "10.64.70.195/32".to_string();
        runtime.config.wireguard_exit.private_key = "client-private".to_string();
        runtime.config.wireguard_exit.peer_public_key = "provider-public".to_string();
        runtime.config.wireguard_exit.endpoint = "vpn.example.test:51820".to_string();
        runtime.config.wireguard_exit.allowed_ips = vec!["0.0.0.0/0".to_string()];

        let state = runtime.state();
        assert!(state.wireguard_exit_enabled);
        assert!(state.wireguard_exit_configured);
        assert!(!state.advertise_exit_node);
        assert!(state.exit_node_blocked);
        assert!(!state.exit_node_active);
        assert_eq!(
            state.exit_node_status_text,
            "WireGuard exit · Blocked"
        );

        runtime.vpn_active = true;
        let state = runtime.state();
        assert!(!state.exit_node_blocked);
        assert!(state.exit_node_active);
        assert_eq!(state.exit_node_status_text, "WireGuard exit · Connected");
    }

    #[test]
    fn native_state_only_blocks_pending_automatic_exit_when_leak_protection_is_enabled() {
        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.vpn_enabled = true;
        create_test_network(&mut runtime, "Home");
        runtime
            .config
            .set_internet_source(InternetSource::PaidAutomatic);

        let state = runtime.state();

        assert!(!state.exit_node_blocked);
        assert!(!state.exit_node_active);
        assert_eq!(state.exit_node_status_text, "Automatic paid exit · Pending");

        runtime.config.exit_node_leak_protection = true;
        let state = runtime.state();
        assert!(state.exit_node_blocked);
        assert!(!state.exit_node_active);
        assert_eq!(
            state.exit_node_status_text,
            "Automatic paid exit · Blocked"
        );
    }

    #[test]
    fn native_state_distinguishes_direct_and_manual_paid_internet() {
        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        create_test_network(&mut runtime, "Home");

        assert_eq!(runtime.state().exit_node_status_text, "Direct internet");

        runtime
            .config
            .set_internet_source(InternetSource::PaidManual);
        assert_eq!(
            runtime.state().exit_node_status_text,
            "Manual paid exit · Pending"
        );
    }
