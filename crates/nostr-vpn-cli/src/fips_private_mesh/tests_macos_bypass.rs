#[test]
fn macos_endpoint_bypass_keeps_connected_peers_on_link() {
    let mut lan = netdev::Interface::dummy();
    lan.name = "en0".to_string();
    lan.flags = libc::IFF_UP as u32;
    lan.ipv4 = vec![
        "192.0.2.10/25".parse().unwrap(),
        "192.168.50.10/24".parse().unwrap(),
    ];
    let mut other = netdev::Interface::dummy();
    other.name = "en7".to_string();
    other.flags = libc::IFF_UP as u32;
    other.ipv4 = vec!["198.51.100.10/24".parse().unwrap()];
    let mut bridge = netdev::Interface::dummy();
    bridge.name = "bridge100".to_string();
    bridge.flags = libc::IFF_UP as u32;
    bridge.ipv4 = vec!["203.0.113.1/25".parse().unwrap()];
    let mut down = netdev::Interface::dummy();
    down.name = "en8".to_string();
    down.ipv4 = vec!["203.0.113.129/25".parse().unwrap()];
    let mut tunnel = netdev::Interface::dummy();
    tunnel.name = "utun4".to_string();
    tunnel.flags = (libc::IFF_UP | libc::IFF_POINTOPOINT) as u32;
    tunnel.ipv4 = vec!["0.0.0.0/0".parse().unwrap()];
    let underlay = crate::MacosRouteSpec {
        gateway: Some("192.0.2.1".to_string()),
        interface: lan.name.clone(),
    };
    let hosts = [
        "127.0.0.1",
        "127.42.0.1",
        "192.0.2.20",
        "192.0.2.200",
        "192.0.2.1",
        "192.168.50.20",
        "198.51.100.8",
        "203.0.113.5",
        "203.0.113.200",
        "10.20.30.40",
    ]
    .map(|host| host.parse().unwrap());
    let desired = crate::macos_network::macos_endpoint_bypass_targets_for_hosts(
        &hosts,
        &[lan, other, bridge, down, tunnel],
    );
    let mut routes = Vec::new();
    let mut cached_underlay = None;
    let mut installed = Vec::new();
    let failures = super::apply_macos_endpoint_bypass_route_changes(
        &mut routes,
        &mut cached_underlay,
        &desired,
        Some(&underlay),
        false,
        |target, gateway| {
            installed.push((target.to_string(), gateway.map(str::to_string)));
            Ok(())
        },
    );
    assert!(failures.is_empty());
    assert_eq!(
        installed,
        vec![
            ("10.20.30.40/32".to_string(), underlay.gateway.clone()),
            ("192.0.2.200/32".to_string(), underlay.gateway.clone()),
            ("203.0.113.200/32".to_string(), underlay.gateway.clone()),
        ],
        "live LANs and bridges keep local paths; down and tunnel interfaces need bypasses"
    );
}

#[test]
fn macos_endpoint_bypass_handoff_uses_the_new_connected_prefixes_and_old_ownership() {
    let old_underlay = crate::MacosRouteSpec {
        gateway: Some("192.0.2.1".to_string()),
        interface: "en0".to_string(),
    };
    let new_underlay = crate::MacosRouteSpec {
        gateway: Some("198.51.100.1".to_string()),
        interface: "en1".to_string(),
    };
    let mut interface = netdev::Interface::dummy();
    interface.name = new_underlay.interface.clone();
    interface.flags = libc::IFF_UP as u32;
    interface.ipv4 = vec!["198.51.100.10/24".parse().unwrap()];
    let hosts = ["192.0.2.20", "198.51.100.8", "10.20.30.40"].map(|host| host.parse().unwrap());
    let desired = crate::macos_network::macos_endpoint_bypass_targets_for_hosts(
        &hosts,
        &[interface],
    );
    let old_routes = vec![
        "10.20.30.40/32".to_string(),
        "198.51.100.8/32".to_string(),
        "203.0.113.9/32".to_string(), // Removed from the peer set.
    ];
    let mut routes = old_routes.clone();
    let mut cached_underlay = Some(old_underlay.clone());
    let mut removed = Vec::new();
    super::remove_obsolete_macos_endpoint_bypasses(
        &mut routes,
        &mut cached_underlay,
        &desired,
        Some(&new_underlay),
        |target, owner| {
            assert_eq!(owner, Some(&old_underlay));
            removed.push(target.to_string());
            Ok(())
        },
    )
    .unwrap();
    assert_eq!(removed, old_routes);
    let mut installed = Vec::new();
    let failures = super::apply_macos_endpoint_bypass_route_changes(
        &mut routes,
        &mut cached_underlay,
        &desired,
        Some(&new_underlay),
        false,
        |target, gateway| {
            assert_eq!(gateway, new_underlay.gateway.as_deref());
            installed.push(target.to_string());
            Ok(())
        },
    );
    assert!(failures.is_empty());
    assert_eq!(installed, vec!["10.20.30.40/32", "192.0.2.20/32"]);
    assert_eq!(routes, desired);
    assert_eq!(cached_underlay, Some(new_underlay));
}

#[test]
fn macos_endpoint_bypass_withdraws_a_newly_connected_peer_without_repinning_it() {
    let underlay = crate::MacosRouteSpec {
        gateway: Some("192.0.2.1".to_string()),
        interface: "en0".to_string(),
    };
    // A new bridge can make a former off-link endpoint local without changing
    // the selected internet interface or its default gateway.
    let mut interface = netdev::Interface::dummy();
    interface.name = "bridge100".to_string();
    interface.flags = libc::IFF_UP as u32;
    interface.ipv4 = vec![
        "192.0.2.10/24".parse().unwrap(),
        "198.51.100.10/24".parse().unwrap(),
    ];
    let desired = crate::macos_network::macos_endpoint_bypass_targets_for_hosts(
        &["198.51.100.8".parse().unwrap()],
        &[interface],
    );
    assert!(desired.is_empty());
    let old_routes = vec!["198.51.100.8/32".to_string()];
    let mut routes = old_routes.clone();
    let mut cached_underlay = Some(underlay.clone());
    assert!(
        super::remove_obsolete_macos_endpoint_bypasses(
            &mut routes,
            &mut cached_underlay,
            &desired,
            Some(&underlay),
            |target, owner| {
                assert_eq!(target, "198.51.100.8/32");
                assert_eq!(owner, Some(&underlay));
                Err(anyhow::anyhow!("synthetic transient cleanup failure"))
            },
        )
        .is_err()
    );
    assert_eq!(routes, old_routes, "failed cleanup must retain ownership");
    assert_eq!(cached_underlay, Some(underlay.clone()));
    super::remove_obsolete_macos_endpoint_bypasses(
        &mut routes,
        &mut cached_underlay,
        &desired,
        Some(&underlay),
        |target, owner| {
            assert_eq!(target, "198.51.100.8/32");
            assert_eq!(owner, Some(&underlay));
            Ok(())
        },
    )
    .unwrap();
    let failures = super::apply_macos_endpoint_bypass_route_changes(
        &mut routes,
        &mut cached_underlay,
        &desired,
        Some(&underlay),
        false,
        |_, _| panic!("an on-link peer must not be re-pinned"),
    );
    assert!(failures.is_empty());
    assert!(routes.is_empty());
    assert_eq!(cached_underlay, Some(underlay.clone()));
    assert!(
        !super::macos_endpoint_bypass_underlay_refresh_required(
            &routes,
            cached_underlay.as_ref(),
            &desired,
            true,
        ),
        "an all-LAN peer set must reuse the cached physical underlay"
    );
}

#[test]
fn failed_macos_endpoint_bypass_install_is_retried_by_production_reconciler() {
    let desired = vec!["203.0.113.8".to_string()];
    let underlay = crate::MacosRouteSpec {
        gateway: Some("192.0.2.1".to_string()),
        interface: "en0".to_string(),
    };
    let mut cached_routes = Vec::new();
    let mut cached_underlay = None;
    let mut attempts = 0;

    let failures = super::apply_macos_endpoint_bypass_route_changes(
        &mut cached_routes,
        &mut cached_underlay,
        &desired,
        Some(&underlay),
        false,
        |_route, _gateway| {
            attempts += 1;
            Err(anyhow::anyhow!("synthetic transient route-add failure"))
        },
    );
    assert_eq!(attempts, 1);
    assert_eq!(failures.len(), 1);
    assert!(cached_routes.is_empty());
    assert_eq!(cached_underlay, Some(underlay.clone()));
    assert!(
        super::macos_endpoint_bypass_underlay_refresh_required(
            &cached_routes,
            cached_underlay.as_ref(),
            &desired,
            false,
        )
    );

    let failures = super::apply_macos_endpoint_bypass_route_changes(
        &mut cached_routes,
        &mut cached_underlay,
        &desired,
        Some(&underlay),
        false,
        |_route, _gateway| {
            attempts += 1;
            Ok(())
        },
    );
    assert!(failures.is_empty());
    assert_eq!(attempts, 2);
    assert_eq!(cached_underlay, Some(underlay.clone()));
    assert!(
        !super::macos_endpoint_bypass_underlay_refresh_required(
            &cached_routes,
            cached_underlay.as_ref(),
            &desired,
            true,
        )
    );

    assert!(
        super::macos_endpoint_bypass_underlay_refresh_required(
            &cached_routes,
            cached_underlay.as_ref(),
            &desired,
            false,
        ),
        "a matching in-memory cache must not hide a route removed by macOS"
    );

    let mut reassertions = 0;
    let failures = super::apply_macos_endpoint_bypass_route_changes(
        &mut cached_routes,
        &mut cached_underlay,
        &desired,
        Some(&underlay),
        true,
        |_route, _gateway| {
            reassertions += 1;
            Ok(())
        },
    );
    assert!(failures.is_empty());
    assert_eq!(reassertions, 1, "missing live route must be reasserted");
}
