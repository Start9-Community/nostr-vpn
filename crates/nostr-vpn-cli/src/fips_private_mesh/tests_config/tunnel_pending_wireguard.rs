    #[test]
    fn pending_manual_join_preserves_independent_wireguard_exit_and_dns() {
        let joiner_keys = Keys::generate();
        let admin_keys = Keys::generate();
        let joiner_pubkey = joiner_keys.public_key().to_hex();
        let admin_pubkey = admin_keys.public_key().to_hex();
        let network_id = "desktop-manual-pending-wireguard";

        let mut joining = AppConfig::generated_without_networks();
        joining.nostr.secret_key = joiner_keys.secret_key().to_secret_hex();
        joining.nostr.public_key = joiner_pubkey.clone();
        joining
            .add_manual_join_network(&admin_pubkey, network_id)
            .expect("configure manual join");
        joining.set_internet_source(InternetSource::WireGuard);
        joining.wireguard_exit.address = "10.64.70.195/32".to_string();
        joining.wireguard_exit.private_key =
            "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=".to_string();
        joining.wireguard_exit.peer_public_key =
            "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=".to_string();
        joining.wireguard_exit.endpoint = "198.51.100.20:51820".to_string();
        joining.wireguard_exit.allowed_ips = vec!["0.0.0.0/0".to_string()];
        joining.exit_dns.mode = nostr_vpn_core::config::ExitDnsMode::ThroughExit;
        joining.exit_dns.through_exit_servers = vec!["9.9.9.9".to_string()];

        let config = FipsPrivateTunnelConfig::from_app(
            &joining,
            network_id,
            "utun-manual-pending-wireguard",
            Some(&joiner_pubkey),
            None,
            &[],
        )
        .expect("pending manual tunnel with WireGuard exit");

        assert!(config.network_id.is_empty());
        assert!(config.route_targets.is_empty());
        assert!(config.magic_dns_records.is_empty());
        assert!(config.advertise_on_nostr);
        assert_eq!(config.wireguard_exit, joining.wireguard_exit);
        assert!(config.secure_dns_required());
        assert_eq!(
            config.exit_dns_resolver_config(false).unwrap(),
            ExitDnsResolverConfig::FailClosed
        );
        assert_eq!(
            config.exit_dns_resolver_config(true).unwrap(),
            ExitDnsResolverConfig::ThroughExit {
                servers: vec!["9.9.9.9".parse::<std::net::IpAddr>().unwrap()]
            }
        );
    }

    #[cfg(feature = "paid-exit")]
    #[test]
    fn pending_manual_join_preserves_independent_paid_exit_and_protection() {
        use super::{effective_fips_route_targets, fips_exit_route_ready_for_connected};
        let joiner = Keys::generate();
        let admin = Keys::generate().public_key().to_hex();
        let seller = Keys::generate().public_key().to_hex();
        let own = joiner.public_key().to_hex();
        let mut app = AppConfig::generated_without_networks();
        app.nostr.secret_key = joiner.secret_key().to_secret_hex();
        app.nostr.public_key = own.clone();
        app.add_manual_join_network(&admin, "pending-paid").unwrap();
        app.select_public_paid_exit_node(&seller).unwrap();

        for mode in [InternetSource::PaidManual, InternetSource::PaidAutomatic] {
            app.internet_source = mode;
            for protected in [false, true] {
                app.exit_node_leak_protection = protected;
                let mut config = FipsPrivateTunnelConfig::from_app(
                    &app,
                    "pending-paid",
                    "utun-test",
                    Some(&own),
                    None,
                    &[],
                )
                .unwrap();
                assert!(config.network_id.is_empty());
                assert!(config.magic_dns_records.is_empty());
                assert!(config.local_advertised_routes.is_empty());
                assert!(!config.paid_exit.enabled);
                assert_eq!(
                    config.route_targets,
                    crate::runtime_exit_node_default_routes()
                );
                assert!(
                    config.peers.iter().any(
                        |peer| peer.participant_pubkey == seller && peer.advertises_default_route()
                    )
                );
                assert!(
                    config
                        .peers
                        .iter()
                        .filter(|peer| peer.participant_pubkey != seller)
                        .all(|peer| peer.allowed_ips.is_empty())
                );
                assert_eq!(config.paid_route_accounting_peers.len(), 1);
                assert_eq!(config.exit_node_leak_protection, protected);
                assert!(config.secure_dns_required());
                config.require_public_paid_exit_admission(false);
                assert_eq!(
                    effective_fips_route_targets(&config, &[])
                        .iter()
                        .any(|route| crate::is_exit_node_route(route)),
                    protected,
                    "unadmitted sellers must not bypass the selected fail-closed policy",
                );
                config.require_public_paid_exit_admission(true);
                assert!(fips_exit_route_ready_for_connected(
                    &config.route_targets,
                    &config.peers,
                    protected,
                    false,
                    config.public_paid_exit_waiting_for_admission,
                    &std::collections::HashSet::from([seller.as_str()]),
                ));
            }
        }

        app.exit_node.clear();
        app.exit_node_public_paid_exit = false;
        for mode in [
            InternetSource::PaidManual,
            InternetSource::PaidAutomatic,
            InternetSource::PrivateVpn,
        ] {
            app.internet_source = mode;
            for protected in [false, true] {
                app.exit_node_leak_protection = protected;
                let config = FipsPrivateTunnelConfig::from_app(
                    &app,
                    "pending-paid",
                    "utun-test",
                    Some(&own),
                    None,
                    &[],
                )
                .unwrap();
                assert_eq!(
                    config
                        .route_targets
                        .iter()
                        .any(|route| crate::is_exit_node_route(route)),
                    protected && mode != InternetSource::PrivateVpn,
                );
                assert!(config.peers.iter().all(|peer| peer.allowed_ips.is_empty()));
            }
        }
    }
