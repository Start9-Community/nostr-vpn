#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    #[test]
    fn prefer_nonself_tunnel_snapshot_ignores_tunnel_default_interface() {
        let tunnel_runtime = CliTunnelRuntime::new("utun100");
        let previous = crate::diagnostics::NetworkSnapshot {
            default_interface: Some("eth0".to_string()),
            default_interface_mtu: None,
            primary_ipv4: Some(Ipv4Addr::new(192, 168, 64, 2)),
            primary_ipv6: None,
            gateway_ipv4: Some(Ipv4Addr::new(192, 168, 64, 1)),
            gateway_ipv6: None,
        };
        let latest = crate::diagnostics::NetworkSnapshot {
            default_interface: Some("utun100".to_string()),
            default_interface_mtu: None,
            primary_ipv4: Some(Ipv4Addr::new(10, 44, 210, 253)),
            primary_ipv6: None,
            gateway_ipv4: None,
            gateway_ipv6: None,
        };

        let preferred =
            prefer_nonself_tunnel_snapshot(&tunnel_runtime, None, None, &previous, latest);

        assert_eq!(preferred.default_interface.as_deref(), Some("eth0"));
        assert_eq!(preferred.primary_ipv4, Some(Ipv4Addr::new(192, 168, 64, 2)));
    }

    #[test]
    fn prefer_nonself_tunnel_snapshot_keeps_same_iface_ipv4_underlay() {
        let tunnel_runtime = CliTunnelRuntime::new("utun100");
        let previous = crate::diagnostics::NetworkSnapshot {
            default_interface: Some("en0".to_string()),
            default_interface_mtu: None,
            primary_ipv4: Some(Ipv4Addr::new(192, 168, 64, 5)),
            primary_ipv6: None,
            gateway_ipv4: Some(Ipv4Addr::new(192, 168, 64, 1)),
            gateway_ipv6: None,
        };
        let latest = crate::diagnostics::NetworkSnapshot {
            default_interface: Some("en0".to_string()),
            default_interface_mtu: None,
            primary_ipv4: None,
            primary_ipv6: "fd18:89b8:ca8c:d693::1".parse().ok(),
            gateway_ipv4: None,
            gateway_ipv6: "fe80::1".parse().ok(),
        };

        let preferred =
            prefer_nonself_tunnel_snapshot(&tunnel_runtime, None, None, &previous, latest);

        assert_eq!(preferred.primary_ipv4, Some(Ipv4Addr::new(192, 168, 64, 5)));
        assert_eq!(preferred.gateway_ipv4, Some(Ipv4Addr::new(192, 168, 64, 1)));
        assert!(preferred.primary_ipv6.is_none());
    }

    #[test]
    fn prefer_nonself_tunnel_snapshot_ignores_managed_wireguard_exit() {
        let tunnel_runtime = CliTunnelRuntime::new("utun100");
        let previous = crate::diagnostics::NetworkSnapshot {
            default_interface: Some("eth0".to_string()),
            default_interface_mtu: Some(1500),
            primary_ipv4: Some(Ipv4Addr::new(10, 203, 0, 10)),
            primary_ipv6: None,
            gateway_ipv4: Some(Ipv4Addr::new(10, 203, 0, 1)),
            gateway_ipv6: None,
        };
        let latest = crate::diagnostics::NetworkSnapshot {
            default_interface: Some("nvpn-wg-exit".to_string()),
            default_interface_mtu: Some(1420),
            primary_ipv4: Some(Ipv4Addr::new(10, 99, 99, 2)),
            primary_ipv6: None,
            gateway_ipv4: None,
            gateway_ipv6: None,
        };

        let preferred = prefer_nonself_tunnel_snapshot(
            &tunnel_runtime,
            Some("nvpn-wg-exit"),
            Some(Ipv4Addr::new(10, 99, 99, 2)),
            &previous,
            latest,
        );

        assert_eq!(preferred, previous);
    }
    #[test]
    fn prefer_nonself_tunnel_snapshot_ignores_windows_wireguard_guid() {
        let tunnel_runtime = CliTunnelRuntime::new("nvpn");
        let previous = crate::diagnostics::NetworkSnapshot {
            default_interface: Some("{PHYSICAL-GUID}".to_string()),
            default_interface_mtu: Some(1500),
            primary_ipv4: Some(Ipv4Addr::new(192, 0, 2, 147)),
            primary_ipv6: None,
            gateway_ipv4: Some(Ipv4Addr::new(192, 0, 2, 1)),
            gateway_ipv6: None,
        };
        let latest = crate::diagnostics::NetworkSnapshot {
            default_interface: Some("{WIREGUARD-GUID}".to_string()),
            default_interface_mtu: Some(1420),
            primary_ipv4: Some(Ipv4Addr::new(10, 99, 99, 2)),
            primary_ipv6: None,
            gateway_ipv4: None,
            gateway_ipv6: None,
        };

        let preferred = prefer_nonself_tunnel_snapshot(
            &tunnel_runtime,
            Some("nvpn-wg-exit"),
            Some(Ipv4Addr::new(10, 99, 99, 2)),
            &previous,
            latest,
        );

        assert_eq!(preferred, previous);
    }
    #[test]
    fn endpoint_peer_signature_tracks_address_hint_metadata() {
        let static_config = vec![crate::fips_private_mesh::FipsEndpointPeerTransportConfig {
            npub: "peer".to_string(),
            addresses: vec![crate::fips_private_mesh::FipsPeerAddressHint {
                addr: "198.51.100.91:51830".to_string(),
                seen_at_ms: None,
                priority: 10,
            }],
            auto_reconnect: false,
            discovery_fallback_transit: true,
        }];
        let mut stamped_config = static_config.clone();
        stamped_config[0].addresses[0].seen_at_ms = Some(123_000);
        let mut reprioritized_config = static_config.clone();
        reprioritized_config[0].addresses[0].priority = 100;
        let mut reconnect_config = static_config.clone();
        reconnect_config[0].auto_reconnect = true;

        assert_ne!(
            endpoint_peer_signature(&static_config),
            endpoint_peer_signature(&stamped_config)
        );
        assert_ne!(
            endpoint_peer_signature(&static_config),
            endpoint_peer_signature(&reprioritized_config)
        );
        assert_ne!(
            endpoint_peer_signature(&static_config),
            endpoint_peer_signature(&reconnect_config)
        );
    }
    #[test]
    fn recent_peer_refresh_signature_ignores_freshness_but_tracks_topology() {
        let participant = fips_core::Identity::generate().npub();
        let local_npub = fips_core::Identity::generate().npub();
        let mut recent = nostr_vpn_core::recent_peers::RecentPeerEndpoints::new(
            local_npub,
            nostr_vpn_core::recent_peers::recent_peers_scope("signature-test"),
        )
        .unwrap();
        assert!(recent.note_success(&participant, "203.0.113.20:51820", 100));
        let first = recent_peer_refresh_signature(
            &recent,
            &[(
                participant.clone(),
                vec![("udp:203.0.113.20:51820".to_string(), 100_000)],
            )],
        );

        assert!(recent.note_success(&participant, "203.0.113.20:51820", 200));
        let refreshed = recent_peer_refresh_signature(
            &recent,
            &[(
                participant.clone(),
                vec![("udp:203.0.113.20:51820".to_string(), 200_000)],
            )],
        );
        assert_eq!(first, refreshed);

        let changed = recent_peer_refresh_signature(
            &recent,
            &[(
                participant,
                vec![
                    ("udp:203.0.113.20:51820".to_string(), 200_000),
                    ("tcp:203.0.113.21:443".to_string(), 200_000),
                ],
            )],
        );
        assert_ne!(first, changed);
    }
    #[test]
    fn link_event_refresh_classifies_restarts_and_path_refreshes() {
        let idle = fips_link_event_refresh(false, false, false, false);
        assert_eq!(idle, FipsLinkEventRefresh::None);

        for restart in [
            fips_link_event_refresh(false, true, false, false),
            fips_link_event_refresh(false, false, false, true),
        ] {
            assert_eq!(restart, FipsLinkEventRefresh::RestartEndpoint);
        }

        assert_eq!(
            fips_link_event_refresh(true, false, false, false),
            FipsLinkEventRefresh::RefreshPaths
        );
        assert_eq!(
            fips_link_event_refresh(false, false, true, false),
            FipsLinkEventRefresh::UpdatePeersAndRefreshPaths
        );
    }
    #[test]
    fn stale_participant_path_refresh_targets_only_matching_endpoint_peers() {
        use nostr_sdk::prelude::{Keys, ToBech32};

        let stale_key = Keys::generate();
        let other_key = Keys::generate();
        let stale_npub = stale_key.public_key().to_bech32().expect("stale npub");
        let other_npub = other_key.public_key().to_bech32().expect("other npub");
        let peers = vec![
            crate::fips_private_mesh::FipsEndpointPeerTransportConfig {
                npub: stale_npub.clone(),
                addresses: Vec::new(),
                auto_reconnect: true,
                discovery_fallback_transit: false,
            },
            crate::fips_private_mesh::FipsEndpointPeerTransportConfig {
                npub: other_npub,
                addresses: Vec::new(),
                auto_reconnect: true,
                discovery_fallback_transit: false,
            },
        ];

        let selected_from_hex =
            endpoint_peers_for_participant_refresh(&peers, &[stale_key.public_key().to_hex()]);
        assert_eq!(selected_from_hex.len(), 1);
        assert_eq!(selected_from_hex[0].npub, stale_npub);

        let selected_from_npub =
            endpoint_peers_for_participant_refresh(&peers, std::slice::from_ref(&stale_npub));
        assert_eq!(selected_from_npub.len(), 1);
        assert_eq!(selected_from_npub[0].npub, stale_npub);
    }
}
