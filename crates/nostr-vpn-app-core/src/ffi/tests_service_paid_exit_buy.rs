    #[cfg(feature = "paid-exit")]
    #[test]
    fn gui_buy_paid_route_offer_selects_and_activates_the_exit_route() {
        use nostr_vpn_core::paid_route_store::{
            PaidRouteStore, load_paid_route_store, paid_route_offer_store_key,
            paid_route_store_file_path, write_paid_route_store,
        };
        use nostr_vpn_core::paid_routes::{
            PaidExitConfig, signed_paid_exit_offer_from_config,
        };

        let dir = unique_service_test_dir("nvpn-app-core-paid-route-buy");
        let error = anyhow!("test runtime");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.last_error.clear();
        runtime.mobile_runtime = true;
        runtime.config_path = dir.join("config.toml");
        create_test_network(&mut runtime, "Paid route test");
        runtime.config.save(&runtime.config_path).expect("save config");

        let seller = Keys::generate();
        let seller_npub = seller.public_key().to_bech32().expect("seller npub");
        let mint = "https://mint.minibits.cash/Bitcoin";
        let mut offer_config = PaidExitConfig {
            enabled: true,
            ..PaidExitConfig::default()
        };
        offer_config.pricing.price_msat = 25;
        offer_config.pricing.per_units = 1_000_000;
        offer_config.channel.accepted_mints = vec![mint.to_string()];
        offer_config.channel.free_probe_units = 1_048_576;
        let signed = signed_paid_exit_offer_from_config(
            "internet-exit",
            &seller,
            &offer_config,
            None,
            unix_timestamp(),
        )
        .expect("sign offer");
        let store_path = paid_route_store_file_path(&runtime.config_path);
        let mut store = PaidRouteStore::default();
        store.upsert_wallet_mint(mint, "Minibits", Some(0), unix_timestamp());
        store
            .upsert_signed_offer(signed, vec!["wss://relay.example".to_string()], unix_timestamp())
            .expect("store offer");
        let offer_key = paid_route_offer_store_key(&seller_npub, "internet-exit");
        write_paid_route_store(&store_path, &store).expect("persist store");

        runtime.dispatch(NativeAppAction::BuyPaidRouteOffer {
            offer_key,
            mint_url: None,
            channel_capacity_sat: None,
        });

        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        assert_eq!(runtime.config.internet_source, InternetSource::PaidManual);
        assert!(runtime.config.exit_node_public_paid_exit);
        assert_eq!(
            runtime.config.exit_node,
            seller.public_key().to_hex()
        );
        assert!(runtime.vpn_enabled);
        assert!(runtime.vpn_active);
        let saved = AppConfig::load(&runtime.config_path).expect("load saved config");
        assert_eq!(saved.internet_source, InternetSource::PaidManual);
        assert_eq!(saved.exit_node, seller.public_key().to_hex());
        let store = load_paid_route_store(&store_path).expect("load paid route store");
        let session = store.sessions.values().next().expect("buyer session");
        assert!(
            store
                .buyer_session_allows_routing(&session.session.session_id, unix_timestamp())
                .expect("route decision")
        );
        assert_eq!(
            store
                .buyer_session_seller_npub(&session.session.session_id)
                .expect("session seller"),
            seller_npub
        );
        let state = runtime.state();
        assert!(state.exit_node_active);
        assert!(!state.exit_node_blocked);
        assert!(
            state
                .exit_node_status_text
                .starts_with("Manual paid exit · "),
            "{}",
            state.exit_node_status_text
        );

        let _ = fs::remove_dir_all(&dir);
    }
    #[cfg(feature = "paid-exit")]
    #[test]
    fn gui_buy_paid_route_offer_failure_reaches_the_ui_error_state() {
        let dir = unique_service_test_dir("nvpn-app-core-paid-route-buy-error");
        let error = anyhow!("test runtime");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.last_error.clear();
        runtime.mobile_runtime = true;
        runtime.config_path = dir.join("config.toml");
        create_test_network(&mut runtime, "Paid route error test");
        runtime.config.save(&runtime.config_path).expect("save config");

        runtime.dispatch(NativeAppAction::BuyPaidRouteOffer {
            offer_key: "missing-seller:internet-exit".to_string(),
            mint_url: None,
            channel_capacity_sat: None,
        });

        let state = runtime.state();
        assert!(state.error.contains("was not found"), "{}", state.error);

        let _ = fs::remove_dir_all(&dir);
    }
