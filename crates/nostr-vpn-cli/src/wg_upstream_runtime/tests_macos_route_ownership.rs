    #[test]
    fn macos_wireguard_cleanup_never_touches_the_physical_default() {
        assert_eq!(
            MACOS_WG_DEFAULT_ROUTE_TARGETS,
            &["0.0.0.0/1", "128.0.0.0/1"]
        );
        assert!(!MACOS_WG_DEFAULT_ROUTE_TARGETS.contains(&"0.0.0.0/0"));
    }
