    #[derive(Default)]
    struct FakeLinuxNetworkCleanupActions {
        events: Vec<&'static str>,
        forwarding_failures_remaining: usize,
        ipv4_restore_pending: bool,
        ipv6_restore_pending: bool,
        fail_route_cache_flush: bool,
    }

    impl super::LinuxNetworkCleanupActions for FakeLinuxNetworkCleanupActions {
        fn cleanup_endpoint_bypass_routes(&mut self) -> anyhow::Result<()> {
            self.events.push("endpoint");
            Ok(())
        }

        fn cleanup_forwarding_and_wireguard(&mut self) -> anyhow::Result<()> {
            self.events.push("forwarding-wireguard");
            if self.forwarding_failures_remaining > 0 {
                self.forwarding_failures_remaining -= 1;
                return Err(anyhow::anyhow!("synthetic forwarding cleanup failure"));
            }
            Ok(())
        }

        fn restore_original_ipv4_default(&mut self) {
            self.events.push("restore-ipv4");
            self.ipv4_restore_pending = false;
        }

        fn restore_original_ipv6_default(&mut self) {
            self.events.push("restore-ipv6");
            self.ipv6_restore_pending = false;
        }

        fn ipv4_default_restore_pending(&self) -> bool {
            self.ipv4_restore_pending
        }

        fn ipv6_default_restore_pending(&self) -> bool {
            self.ipv6_restore_pending
        }

        fn flush_route_cache(&mut self) -> anyhow::Result<()> {
            self.events.push("flush-route-cache");
            if self.fail_route_cache_flush {
                Err(anyhow::anyhow!("synthetic route cache flush failure"))
            } else {
                Ok(())
            }
        }
    }

    #[test]
    fn linux_cleanup_restores_defaults_after_forwarding_cleanup_exhausts_retries() {
        let mut actions = FakeLinuxNetworkCleanupActions {
            forwarding_failures_remaining: 3,
            ipv4_restore_pending: true,
            ipv6_restore_pending: true,
            fail_route_cache_flush: true,
            ..FakeLinuxNetworkCleanupActions::default()
        };

        let error = super::cleanup_linux_network_state_with_actions(&mut actions)
            .expect_err("forwarding and route-cache failures remain reportable");

        assert_eq!(
            actions.events,
            vec![
                "endpoint",
                "forwarding-wireguard",
                "forwarding-wireguard",
                "forwarding-wireguard",
                "restore-ipv4",
                "restore-ipv6",
                "flush-route-cache",
            ]
        );
        assert!(!actions.ipv4_restore_pending);
        assert!(!actions.ipv6_restore_pending);
        let message = format!("{error:#}");
        assert!(message.contains("forwarding/WireGuard cleanup failed after three attempts"));
        assert!(message.contains("synthetic route cache flush failure"));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_failed_start_cleanup_is_persisted_without_a_live_runtime() {
        let prior = super::take_pending_linux_network_cleanup_state();
        assert!(
            prior.is_none(),
            "failed-start persistence test requires an empty in-process registry"
        );

        let expected_default = "default via 192.0.2.1 dev eth0 metric 100".to_string();
        super::retain_pending_linux_network_cleanup_state(crate::LinuxNetworkCleanupState {
            iface: "nvpn-start-failure".to_string(),
            original_default_route: Some(expected_default.clone()),
            ..crate::LinuxNetworkCleanupState::default()
        });

        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock is after epoch")
            .as_nanos();
        let directory =
            std::env::temp_dir().join(format!("nvpn-linux-start-cleanup-test-{nonce}"));
        std::fs::create_dir_all(&directory).expect("create temp directory");
        let config_path = directory.join("config.toml");
        crate::persist_fips_daemon_network_cleanup_state(&config_path, None)
            .expect("persist retained failed-start ownership");
        let cleanup_path = crate::daemon_network_cleanup_file_path(&config_path);
        let saved = crate::read_daemon_network_cleanup_state(&cleanup_path)
            .expect("read cleanup ownership")
            .expect("cleanup ownership exists");
        assert_eq!(saved.iface, "nvpn-start-failure");
        assert_eq!(saved.original_default_route, Some(expected_default));

        super::take_pending_linux_network_cleanup_state();
        let _ = std::fs::remove_dir_all(directory);
    }
