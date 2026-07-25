    #[test]
    fn websocket_seed_propagates_admin_roster_to_manual_mobile_joiner() {
        std::thread::Builder::new()
            .name("mobile-wss-manual-join".to_string())
            .stack_size(8 * 1024 * 1024)
            .spawn(|| {
                tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("manual join test runtime")
                    .block_on(websocket_seed_manual_join_roundtrip());
            })
            .expect("spawn manual join test")
            .join()
            .expect("manual join test thread");
    }

    async fn bind_manual_join_seed() -> (Arc<FipsEndpoint>, String) {
        let seed_keys = Keys::generate();
        let seed_port = available_tcp_port();
        let seed_url = format!("ws://127.0.0.1:{seed_port}/fips");
        let mut seed_config = FipsConfig::new();
        seed_config.node.routing.mode = fips_endpoint::RoutingMode::ReplyLearned;
        seed_config.node.discovery.nostr.enabled = false;
        seed_config.node.discovery.nostr.advertise = false;
        seed_config.node.discovery.lan.enabled = false;
        seed_config.transports.websocket = TransportInstances::Single(WebSocketConfig {
            bind_addr: Some(format!("127.0.0.1:{seed_port}")),
            ..WebSocketConfig::default()
        });
        let seed = Arc::new(
            Box::pin(
                FipsEndpoint::builder()
                    .config(seed_config)
                    .identity_nsec(seed_keys.secret_key().to_bech32().expect("seed nsec"))
                    .without_system_tun()
                    .bind(),
            )
            .await
            .expect("bind manual join WebSocket seed"),
        );
        (seed, seed_url)
    }

    fn manual_join_apps(
        seed_url: &str,
        network_id: &str,
    ) -> (AppConfig, AppConfig, QueuedJoinRoster, String) {
        let admin_keys = Keys::generate();
        let admin_nsec = admin_keys.secret_key().to_bech32().expect("admin nsec");
        let admin_pubkey = admin_keys.public_key().to_hex();
        let joiner_keys = Keys::generate();
        let joiner_nsec = joiner_keys.secret_key().to_bech32().expect("joiner nsec");
        let joiner_pubkey = joiner_keys.public_key().to_hex();

        let mut admin_app = admin_join_request_app(&admin_nsec, &admin_pubkey, network_id);
        admin_app.fips_websocket_seed_urls = vec![seed_url.to_string()];
        admin_app.fips_nostr_discovery_enabled = false;
        admin_app.fips_webrtc_enabled = false;
        admin_app.lan_discovery_enabled = false;
        admin_app.fips_bootstrap_enabled = false;
        admin_app.fips_bootstrap_peers.clear();
        admin_app
            .add_participant_to_network("test", &joiner_pubkey)
            .expect("admin adds manual joiner");
        let join_roster =
            crate::join_approval::prepare_manual_join_delivery(&admin_app, "test", &joiner_pubkey)
                .expect("prepare receipt-backed manual join roster");
        let queued_delivery = QueuedJoinRoster {
            version: 1,
            recipient_npub: joiner_pubkey.clone(),
            join_roster,
            attempts: 0,
            last_attempt_at: 0,
        };

        let mut joiner_app = AppConfig::generated_without_networks();
        joiner_app.nostr.secret_key = joiner_nsec;
        joiner_app.nostr.public_key = joiner_pubkey;
        joiner_app.fips_websocket_seed_urls.clear();
        joiner_app.fips_nostr_discovery_enabled = true;
        joiner_app.fips_webrtc_enabled = false;
        joiner_app.lan_discovery_enabled = false;
        joiner_app.fips_bootstrap_enabled = false;
        joiner_app.fips_bootstrap_peers.clear();
        joiner_app
            .add_manual_join_network(&admin_pubkey, network_id)
            .expect("joiner configures admin and network id");
        let mut apply_probe = joiner_app.clone();
        assert_eq!(
            apply_probe
                .apply_manual_join_roster(&queued_delivery.join_roster, unix_timestamp())
                .expect("manual join roster validates against joiner config"),
            Some(network_id.to_string())
        );
        (admin_app, joiner_app, queued_delivery, admin_pubkey)
    }

    async fn start_manual_join_physical_edge(
        seed_url: String,
        joiner_app: AppConfig,
    ) -> (MobileTunnelStarted, Arc<FipsEndpoint>) {
        let mut joiner_mobile =
            MobileTunnelConfig::from_app(&joiner_app).expect("manual joiner config");
        joiner_mobile.listen_port = available_udp_port();
        let joiner_udp_addr = format!("127.0.0.1:{}", joiner_mobile.listen_port);
        let joiner = Box::pin(MobileTunnel::start_async(joiner_mobile, joiner_app))
            .await
            .expect("start manual joiner");

        let router_keys = Keys::generate();
        let router_port = available_udp_port();
        let mut router_config = FipsConfig::new();
        router_config.node.routing.mode = fips_endpoint::RoutingMode::ReplyLearned;
        router_config.node.discovery.nostr.enabled = false;
        router_config.node.discovery.nostr.advertise = false;
        router_config.node.discovery.lan.enabled = false;
        router_config.transports.websocket = TransportInstances::Single(WebSocketConfig {
            seed_urls: vec![seed_url],
            ..WebSocketConfig::default()
        });
        router_config.transports.udp = TransportInstances::Single(UdpConfig {
            bind_addr: Some(format!("127.0.0.1:{router_port}")),
            outbound_only: Some(false),
            accept_connections: Some(true),
            advertise_on_nostr: Some(false),
            public: Some(false),
            ..UdpConfig::default()
        });
        router_config.peers = vec![FipsPeerConfig::new(
            joiner.endpoint.npub().to_string(),
            "udp",
            joiner_udp_addr,
        )];
        let router = Arc::new(
            Box::pin(
                FipsEndpoint::builder()
                    .config(router_config)
                    .identity_nsec(router_keys.secret_key().to_bech32().expect("router nsec"))
                    .without_system_tun()
                    .bind(),
            )
            .await
            .expect("bind manual join router"),
        );
        (joiner, router)
    }

    async fn wait_for_manual_join_edge(
        seed: &FipsEndpoint,
        router: &FipsEndpoint,
        joiner: &MobileTunnelStarted,
    ) {
        let seed_npub = seed.npub().to_string();
        let router_npub = router.npub().to_string();
        let joiner_npub = joiner.endpoint.npub().to_string();
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let joiner_ready = joiner.endpoint.peers().await.is_ok_and(|peers| {
                    peers
                        .iter()
                        .any(|peer| peer.npub == router_npub && peer.connected)
                });
                let router_ready = router.peers().await.is_ok_and(|peers| {
                    peers.iter().any(|peer| peer.npub == seed_npub && peer.connected)
                        && peers
                            .iter()
                            .any(|peer| peer.npub == joiner_npub && peer.connected)
                });
                if joiner_ready && router_ready {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("manual join physical edge should authenticate before admin delivery");
    }

    async fn wait_for_manual_join_roster(
        network_id: &str,
        admin_pubkey: &str,
        seed: &FipsEndpoint,
        router: &FipsEndpoint,
        admin: &MobileTunnelStarted,
        joiner: &MobileTunnelStarted,
    ) {
        let seed_npub = seed.npub().to_string();
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                if admin.endpoint.peers().await.is_ok_and(|peers| {
                    peers
                        .iter()
                        .any(|peer| peer.npub == seed_npub && peer.connected)
                }) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("manual admin should authenticate to seed");

        let applied = tokio::time::timeout(Duration::from_secs(25), async {
            loop {
                if joiner.app_config.read().is_ok_and(|app| {
                    app.active_network_opt().is_some_and(|network| {
                        network.network_id == network_id
                            && network.shared_roster_updated_at > 0
                            && !network.shared_roster_signed_by.is_empty()
                            && network.admins.iter().any(|admin| admin == admin_pubkey)
                    })
                }) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await;
        assert!(
            applied.is_ok(),
            "manual joiner did not receive the receipt-backed signed roster; presence={:?}; dirty={}; admin={:?}; joiner={:?}; router={:?}; seed={:?}",
            joiner.presence.read(),
            joiner.app_config_dirty.load(Ordering::Relaxed),
            admin.endpoint.peers().await,
            joiner.endpoint.peers().await,
            router.peers().await,
            seed.peers().await,
        );
    }

    async fn websocket_seed_manual_join_roundtrip() {
        let network_id = "manual-mobile-roster";
        let (seed, seed_url) = bind_manual_join_seed().await;
        let (admin_app, joiner_app, queued_delivery, admin_pubkey) =
            manual_join_apps(&seed_url, network_id);
        let mut admin_mobile = MobileTunnelConfig::from_app(&admin_app).expect("admin config");
        admin_mobile.listen_port = available_udp_port();
        let admin = Box::pin(MobileTunnel::start_async_with_launch_state(
            admin_mobile,
            admin_app,
            vec![queued_delivery],
            None,
            None,
        ))
        .await
        .expect("start manual admin");
        tokio::time::sleep(Duration::from_millis(250)).await;
        let (joiner, router) = start_manual_join_physical_edge(seed_url, joiner_app).await;
        wait_for_manual_join_edge(&seed, &router, &joiner).await;
        wait_for_manual_join_roster(
            network_id,
            &admin_pubkey,
            &seed,
            &router,
            &admin,
            &joiner,
        )
        .await;

        shutdown_started_mobile_tunnel(admin).await;
        shutdown_started_mobile_tunnel(joiner).await;
        router.shutdown().await.expect("shutdown manual join router");
        seed.shutdown().await.expect("shutdown manual join seed");
    }
