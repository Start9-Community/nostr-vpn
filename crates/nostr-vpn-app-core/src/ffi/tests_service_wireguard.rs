    #[test]
    fn settings_patch_imports_wireguard_exit_config_block() {
        let dir = unique_service_test_dir("nvpn-app-core-wireguard-import");

        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.mobile_runtime = true;
        runtime.config_path = dir.join("config.toml");
        runtime.config.wireguard_exit.enabled = true;

        runtime.dispatch(NativeAppAction::UpdateSettings {
            patch: SettingsPatch {
                wireguard_exit_config: Some(format!(
                    r"
                    [Interface]
                    PrivateKey = {TEST_WG_PRIVATE_KEY}
                    Address = 10.64.70.195/32
                    DNS = 10.64.0.1
                    MTU = 1380

                    [Peer]
                    PublicKey = {TEST_WG_PUBLIC_KEY}
                    AllowedIPs = 0.0.0.0/0
                    Endpoint = vpn.example.test:51820
                    PersistentKeepalive = 20
                    "
                )),
                ..SettingsPatch::default()
            },
        });

        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        let saved = AppConfig::load(&runtime.config_path).expect("load persisted config");
        assert!(saved.wireguard_exit.enabled);
        assert_eq!(saved.wireguard_exit.address, "10.64.70.195/32");
        assert_eq!(saved.wireguard_exit.private_key, TEST_WG_PRIVATE_KEY);
        assert_eq!(saved.wireguard_exit.peer_public_key, TEST_WG_PUBLIC_KEY);
        assert_eq!(saved.wireguard_exit.endpoint, "vpn.example.test:51820");
        assert_eq!(saved.wireguard_exit.mtu, 1380);
        assert_eq!(saved.wireguard_exit.persistent_keepalive_secs, 20);

        let state = runtime.state();
        assert!(
            state
                .wireguard_exit_config
                .contains("Endpoint = vpn.example.test:51820")
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn settings_patch_rejects_bad_wireguard_exit_config_without_replacing_saved_config() {
        let dir = unique_service_test_dir("nvpn-app-core-wireguard-bad-import");

        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.mobile_runtime = true;
        runtime.config_path = dir.join("config.toml");
        runtime.config.wireguard_exit.enabled = true;

        runtime.dispatch(NativeAppAction::UpdateSettings {
            patch: SettingsPatch {
                wireguard_exit_config: Some(format!(
                    r"
                    [Interface]
                    PrivateKey = {TEST_WG_PRIVATE_KEY}
                    Address = 10.64.70.195/32

                    [Peer]
                    PublicKey = {TEST_WG_PUBLIC_KEY}
                    AllowedIPs = 0.0.0.0/0
                    Endpoint = vpn.example.test:51820
                    "
                )),
                ..SettingsPatch::default()
            },
        });
        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        let saved_before = AppConfig::load(&runtime.config_path).expect("load saved config");

        runtime.dispatch(NativeAppAction::UpdateSettings {
            patch: SettingsPatch {
                wireguard_exit_enabled: Some(false),
                wireguard_exit_config: Some(
                    r"
                    [Interface]
                    PrivateKey = not-a-wireguard-key
                    Address = 10.64.70.200/32

                    [Peer]
                    PublicKey = also-bad
                    AllowedIPs = 0.0.0.0/0
                    Endpoint = bad.example.test:51820
                    "
                    .to_string(),
                ),
                ..SettingsPatch::default()
            },
        });

        assert!(
            runtime.last_error.contains("PrivateKey"),
            "{}",
            runtime.last_error
        );
        let state = runtime.state();
        assert!(state.error.contains("PrivateKey"), "{}", state.error);
        assert!(runtime.config.wireguard_exit.enabled);
        assert_eq!(runtime.config.wireguard_exit.address, "10.64.70.195/32");
        assert_eq!(
            runtime.config.wireguard_exit.endpoint,
            "vpn.example.test:51820"
        );
        let saved_after = AppConfig::load(&runtime.config_path).expect("load saved config");
        assert_eq!(saved_before.wireguard_exit, saved_after.wireguard_exit);

        let _ = fs::remove_dir_all(&dir);
    }
