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
        |_route, _gateway| {
            attempts += 1;
            Err(anyhow::anyhow!("synthetic transient route-add failure"))
        },
    );
    assert_eq!(attempts, 1);
    assert_eq!(failures.len(), 1);
    assert_eq!(cached_routes, desired);
    assert_eq!(cached_underlay, None);
    assert!(
        super::macos_endpoint_bypass_underlay_refresh_required(
            &cached_routes,
            cached_underlay.as_ref(),
            &desired,
        )
    );

    let failures = super::apply_macos_endpoint_bypass_route_changes(
        &mut cached_routes,
        &mut cached_underlay,
        &desired,
        Some(&underlay),
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
        )
    );
}
