    #[test]
    fn macos_wireguard_cleanup_never_touches_the_physical_default() {
        let commands = macos_wg_default_route_cleanup_args("utun9");
        assert_eq!(commands.len(), 2);
        assert!(
            commands
                .iter()
                .all(|args| args.contains(&"-net".to_string()))
        );
        assert!(
            commands
                .iter()
                .all(|args| !args.contains(&"default".to_string()))
        );
        assert!(
            commands
                .iter()
                .all(|args| args.last().is_some_and(|arg| arg == "utun9"))
        );
    }

    #[test]
    fn macos_wireguard_ignores_a_foreign_utun_default_when_finding_underlay() {
        let tunnel_only = "\
Destination        Gateway            Flags               Netif Expire\n\
default            link#23            UCSIg               utun5\n";
        assert_eq!(
            macos_underlay_gateway_interface_from_netstat(tunnel_only),
            None
        );

        let with_physical = "\
Destination        Gateway            Flags               Netif Expire\n\
default            link#23            UCSIg               utun5\n\
default            192.168.64.1       UGScg                 en0\n";
        assert_eq!(
            macos_underlay_gateway_interface_from_netstat(with_physical),
            Some(("192.168.64.1".to_string(), "en0".to_string()))
        );
    }

    #[test]
    fn ipv4_only_wireguard_route_swap_leaves_ipv6_endpoint_on_underlay() {
        let ipv4 = "198.51.100.7".parse::<IpAddr>().expect("IPv4 endpoint");
        let ipv6 = "2001:db8::7".parse::<IpAddr>().expect("IPv6 endpoint");

        assert_eq!(ipv4_default_swap_bypass_target(ipv4), Some(ipv4));
        assert_eq!(ipv4_default_swap_bypass_target(ipv6), None);
    }
