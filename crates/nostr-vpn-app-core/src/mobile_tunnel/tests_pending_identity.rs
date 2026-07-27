    #[test]
    fn explicit_pending_identity_marker_fails_closed_despite_malformed_join_fields() {
        let admin = Keys::generate().public_key().to_hex();
        let replacement = Keys::generate().public_key().to_hex();
        let mut app = AppConfig::generated_without_networks();
        app.add_manual_join_network(&admin, "manual-mesh")
            .expect("configure manual join");
        {
            let network = app.active_network_mut();
            assert!(network.local_identity_confirmation_pending);
            network.join_request_admin.clear();
            network.outbound_join_request = Some(PendingOutboundJoinRequest {
                recipient: replacement,
                requested_at: unix_timestamp(),
            });
        }

        let config =
            MobileTunnelConfig::from_app(&app).expect("malformed pending manual bootstrap config");

        assert!(config.network_id.is_empty());
        assert!(config.peers.is_empty());
        assert!(config.route_targets.is_empty());
        assert!(config.dns_servers.is_empty());
        assert!(config.magic_dns_server.is_empty());
        assert!(config.dns_match_domains.is_empty());
    }
