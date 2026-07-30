#[test]
fn windows_route_delete_is_scoped_to_exact_gateway_tuple() {
    let route = WindowsRouteSpec::endpoint(
        "203.0.113.11".parse().expect("endpoint"),
        &windows_underlay(11, "192.0.2.1", "192.0.2.44"),
    );
    assert_eq!(
        windows_route_add_args(&route),
        vec![
            "interface".to_string(),
            "ipv4".to_string(),
            "add".to_string(),
            "route".to_string(),
            "203.0.113.11/32".to_string(),
            "interface=11".to_string(),
            "nexthop=192.0.2.1".to_string(),
            "metric=1".to_string(),
            "store=active".to_string(),
        ]
    );
    assert_eq!(
        windows_route_delete_args(&route),
        vec![
            "interface".to_string(),
            "ipv4".to_string(),
            "delete".to_string(),
            "route".to_string(),
            "203.0.113.11/32".to_string(),
            "interface=11".to_string(),
            "nexthop=192.0.2.1".to_string(),
            "store=active".to_string(),
        ]
    );
    let set = windows_route_set_args(&route);
    assert_eq!(set[2], "set");
    assert_eq!(set[4], "203.0.113.11/32");
    assert!(set.contains(&"metric=1".to_string()));
}
