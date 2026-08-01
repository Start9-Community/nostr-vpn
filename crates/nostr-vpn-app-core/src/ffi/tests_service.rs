    fn unique_service_test_dir(prefix: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock is after epoch")
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("{prefix}-{nonce}"));
        fs::create_dir_all(&dir).expect("create test dir");
        dir
    }

    #[cfg(unix)]
    fn write_starting_service_fake_nvpn(dir: &Path) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;

        let script_path = dir.join("nvpn");
        fs::write(
            &script_path,
            r#"#!/bin/sh
if [ "$1" = "service" ] && [ "$2" = "status" ]; then
  cat <<'JSON'
{"supported":true,"installed":true,"disabled":false,"loaded":true,"running":true,"pid":123,"label":"fi.siriusbusiness.nvpn.test","binary_version":"test"}
JSON
  exit 0
fi
if [ "$1" = "status" ]; then
  echo "control socket not ready" >&2
  exit 7
fi
exit 0
"#,
        )
        .expect("write fake nvpn");
        let mut permissions = fs::metadata(&script_path)
            .expect("fake nvpn metadata")
            .permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&script_path, permissions).expect("make fake nvpn executable");
        script_path
    }

    #[cfg(unix)]
    #[test]
    fn daemon_status_failure_during_startup_grace_is_not_ui_error() {
        let dir = unique_service_test_dir("nvpn-app-core-daemon-starting");
        let script_path = write_starting_service_fake_nvpn(&dir);
        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.last_error.clear();
        runtime.config_path = dir.join("config.toml");
        create_test_network(&mut runtime, "Home");
        runtime
            .config
            .save(&runtime.config_path)
            .expect("save test config");
        runtime.nvpn_bin = Some(script_path);
        runtime.daemon_status_grace_until = Some(Instant::now() + DAEMON_STARTUP_STATUS_GRACE);

        runtime.dispatch(NativeAppAction::Tick);
        let state = runtime.state();

        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        assert!(state.error.is_empty(), "{}", state.error);
        assert!(state.service_running);
        assert!(!state.daemon_running);
        assert_eq!(state.vpn_status, "Background service starting");

        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    #[test]
    fn config_edit_does_not_treat_starting_service_as_reloaded() {
        let dir = unique_service_test_dir("nvpn-app-core-config-while-starting");
        let script_path = write_starting_service_fake_nvpn(&dir);
        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.last_error.clear();
        runtime.config_path = dir.join("config.toml");
        create_test_network(&mut runtime, "Home");
        runtime
            .config
            .save(&runtime.config_path)
            .expect("save test config");
        runtime.nvpn_bin = Some(script_path);
        runtime.daemon_status_grace_until = Some(Instant::now() + DAEMON_STARTUP_STATUS_GRACE);
        runtime.config.node_name = "Pending edit".to_string();

        let error = runtime
            .save_reload_and_refresh()
            .expect_err("starting service must not report an unapplied edit as reloaded");

        assert!(error.to_string().contains("daemon status is unavailable"));
        assert_eq!(
            AppConfig::load(&runtime.config_path)
                .expect("load saved config")
                .node_name,
            "Pending edit"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    #[test]
    fn config_edit_preserves_cached_live_service_when_service_query_fails() {
        use std::os::unix::fs::PermissionsExt;

        let dir = unique_service_test_dir("nvpn-app-core-config-service-query-failure");
        let script_path = dir.join("nvpn");
        fs::write(
            &script_path,
            r#"#!/bin/sh
if [ "$1" = "service" ] && [ "$2" = "status" ]; then
  echo "service status unavailable" >&2
  exit 7
fi
if [ "$1" = "status" ]; then
  printf '%s\n' '{"daemon":{"running":false,"state":null}}'
  exit 0
fi
exit 0
"#,
        )
        .expect("write fake nvpn");
        let mut permissions = fs::metadata(&script_path)
            .expect("fake nvpn metadata")
            .permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&script_path, permissions).expect("make fake nvpn executable");

        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.config_path = dir.join("config.toml");
        create_test_network(&mut runtime, "Home");
        runtime.config.save(&runtime.config_path).expect("save config");
        runtime.nvpn_bin = Some(script_path);
        runtime.service_running = true;
        runtime.config.node_name = "Pending edit".to_string();

        let error = runtime
            .save_reload_and_refresh()
            .expect_err("failed live-service query must not report the edit as applied");

        assert!(runtime.service_running, "cached live state was discarded");
        assert!(error.to_string().contains("configuration was saved but not applied"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn daemon_status_failure_after_startup_grace_surfaces_error() {
        let dir = unique_service_test_dir("nvpn-app-core-daemon-startup-expired");
        let script_path = write_starting_service_fake_nvpn(&dir);
        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.last_error.clear();
        runtime.config_path = dir.join("config.toml");
        create_test_network(&mut runtime, "Home");
        runtime
            .config
            .save(&runtime.config_path)
            .expect("save test config");
        runtime.nvpn_bin = Some(script_path);
        runtime.daemon_status_grace_until = None;

        runtime.dispatch(NativeAppAction::Tick);
        let state = runtime.state();

        assert!(
            runtime.last_error.contains("control socket not ready"),
            "{}",
            runtime.last_error
        );
        assert!(state.error.contains("control socket not ready"), "{}", state.error);
        assert!(state.vpn_status.contains("nvpn status failed"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn native_state_hides_reachable_peers_when_vpn_is_paused() {
        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        let own_pubkey = runtime
            .config
            .own_nostr_pubkey_hex()
            .expect("generated config should have own pubkey");
        let peer_pubkey = "26525c442dd039de4e728b41ee8d7f717b267ab25b7c219d53a3249e1c9174cc";
        create_test_network(&mut runtime, "Home");
        runtime.config.networks[0].admins = vec![own_pubkey.clone()];
        runtime.config.networks[0].devices = vec![peer_pubkey.to_string()];
        runtime.daemon_running = true;
        runtime.vpn_enabled = false;
        runtime.vpn_active = false;
        runtime.daemon_state = Some(DaemonRuntimeState {
            vpn_enabled: false,
            vpn_active: false,
            expected_peer_count: 1,
            connected_peer_count: 1,
            peers: vec![DaemonPeerState {
                participant_pubkey: peer_pubkey.to_string(),
                tunnel_ip: "10.44.10.23".to_string(),
                reachable: true,
                ..DaemonPeerState::default()
            }],
            ..DaemonRuntimeState::default()
        });

        let state = runtime.state();
        let network = &state.networks[0];

        assert!(!state.vpn_active);
        assert_eq!(state.connected_peer_count, 0);
        assert_eq!(network.online_count, 0);
        assert!(
            network
                .participants
                .iter()
                .all(|participant| { !participant.reachable && participant.state == "off" })
        );
    }

    #[test]
    fn mobile_connect_reports_vpn_on_without_pending_placeholder() {
        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.mobile_runtime = true;
        let dir = unique_service_test_dir("nvpn-app-core-mobile-connect");
        runtime.config_path = dir.join("config.toml");
        create_test_network(&mut runtime, "Home");
        runtime
            .config
            .save(&runtime.config_path)
            .expect("save config");

        runtime.dispatch(NativeAppAction::ConnectVpn);
        let state = runtime.state();

        assert!(state.vpn_enabled);
        assert!(state.vpn_active);
        assert_eq!(state.vpn_status, "VPN on");
    }

    #[test]
    fn mobile_refresh_restores_fresh_runtime_state_after_app_recreation() {
        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.mobile_runtime = true;
        let dir = unique_service_test_dir("nvpn-app-core-mobile-refresh");
        runtime.config_path = dir.join("config.toml");
        let network_id = create_test_network(&mut runtime, "Home");
        let peer = Keys::generate().public_key().to_hex();
        runtime
            .config
            .add_participant_to_network(&network_id, &peer)
            .expect("add peer");
        runtime
            .config
            .save(&runtime.config_path)
            .expect("save config");
        let now = unix_timestamp();
        let runtime_state = DaemonRuntimeState {
            updated_at: now,
            binary_version: "test".to_string(),
            vpn_enabled: true,
            vpn_active: true,
            vpn_status: "VPN on (1/1 peers)".to_string(),
            expected_peer_count: 1,
            connected_peer_count: 1,
            mesh_ready: true,
            peers: vec![DaemonPeerState {
                participant_pubkey: peer.clone(),
                reachable: true,
                last_fips_seen_at: Some(now),
                ..DaemonPeerState::default()
            }],
            ..DaemonRuntimeState::default()
        };
        fs::write(
            dir.join(MOBILE_RUNTIME_STATE_FILE),
            serde_json::to_vec(&runtime_state).expect("encode runtime state"),
        )
        .expect("write runtime state");

        runtime.dispatch(NativeAppAction::Tick);
        let state = runtime.state();
        let participant = state.networks[0]
            .participants
            .iter()
            .find(|participant| participant.pubkey_hex == peer)
            .expect("peer participant");

        assert!(state.vpn_enabled);
        assert!(state.vpn_active);
        assert_eq!(state.connected_peer_count, 1);
        assert!(participant.reachable);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn mobile_refresh_rejects_far_future_runtime_state_file() {
        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.mobile_runtime = true;
        let dir = unique_service_test_dir("nvpn-app-core-mobile-future-refresh");
        runtime.config_path = dir.join("config.toml");
        let network_id = create_test_network(&mut runtime, "Home");
        let peer = Keys::generate().public_key().to_hex();
        runtime
            .config
            .add_participant_to_network(&network_id, &peer)
            .expect("add peer");
        runtime
            .config
            .save(&runtime.config_path)
            .expect("save config");
        let now = unix_timestamp();
        let runtime_state = DaemonRuntimeState {
            updated_at: now + 60,
            binary_version: "test".to_string(),
            vpn_enabled: true,
            vpn_active: true,
            vpn_status: "VPN on (1/1 peers)".to_string(),
            expected_peer_count: 1,
            connected_peer_count: 1,
            mesh_ready: true,
            peers: vec![DaemonPeerState {
                participant_pubkey: peer.clone(),
                reachable: true,
                last_fips_seen_at: Some(now + 60),
                ..DaemonPeerState::default()
            }],
            ..DaemonRuntimeState::default()
        };
        fs::write(
            dir.join(MOBILE_RUNTIME_STATE_FILE),
            serde_json::to_vec(&runtime_state).expect("encode runtime state"),
        )
        .expect("write runtime state");

        runtime.dispatch(NativeAppAction::Tick);
        let state = runtime.state();
        let participant = state.networks[0]
            .participants
            .iter()
            .find(|participant| participant.pubkey_hex == peer)
            .expect("peer participant");

        assert!(!state.vpn_active);
        assert_eq!(state.connected_peer_count, 0);
        assert!(!participant.reachable);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn mobile_disconnect_clears_persisted_runtime_state() {
        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.mobile_runtime = true;
        let dir = unique_service_test_dir("nvpn-app-core-mobile-disconnect");
        runtime.config_path = dir.join("config.toml");
        create_test_network(&mut runtime, "Home");
        runtime
            .config
            .save(&runtime.config_path)
            .expect("save config");
        let state_path = dir.join(MOBILE_RUNTIME_STATE_FILE);
        fs::write(
            &state_path,
            serde_json::to_vec(&DaemonRuntimeState {
                updated_at: unix_timestamp(),
                vpn_enabled: true,
                vpn_active: true,
                vpn_status: "VPN on".to_string(),
                ..DaemonRuntimeState::default()
            })
            .expect("encode runtime state"),
        )
        .expect("write runtime state");

        runtime.dispatch(NativeAppAction::DisconnectVpn);
        let state = runtime.state();

        assert!(!state_path.exists());
        assert!(!state.vpn_enabled);
        assert!(!state.vpn_active);

        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    #[allow(clippy::too_many_lines)]
    fn install_service_restores_vpn_after_refreshing_stale_state() {
        use std::os::unix::fs::PermissionsExt;

        #[cfg(target_os = "macos")]
        #[derive(Debug)]
        struct TestPrivilegedRunner {
            calls_path: PathBuf,
        }

        #[cfg(target_os = "macos")]
        impl PrivilegedCommandRunner for TestPrivilegedRunner {
            fn run(&self, executable: String, args: Vec<String>) -> PrivilegedCommandOutput {
                use std::io::Write;

                let mut command = vec![format!("privileged:{executable}")];
                command.extend(args);
                if let Ok(mut calls) = fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&self.calls_path)
                {
                    let _ = writeln!(calls, "{}", command.join(" "));
                }

                PrivilegedCommandOutput {
                    success: true,
                    cancelled: false,
                    stdout: Vec::new(),
                    stderr: Vec::new(),
                }
            }
        }

        let dir = unique_service_test_dir("nvpn-app-core-service-restore");
        let calls_path = dir.join("calls.txt");
        let resumed_path = dir.join("resumed");
        let script_path = dir.join("nvpn");
        let calls_literal = calls_path
            .to_string_lossy()
            .replace('\\', "\\\\")
            .replace('"', "\\\"");
        let resumed_literal = resumed_path
            .to_string_lossy()
            .replace('\\', "\\\\")
            .replace('"', "\\\"");
        let script = format!(
            r#"#!/bin/sh
CALLS="{calls_literal}"
RESUMED="{resumed_literal}"
printf '%s\n' "$*" >> "$CALLS"
if [ "$1" = "service" ] && [ "$2" = "install" ]; then
  exit 0
fi
if [ "$1" = "service" ] && [ "$2" = "status" ]; then
  cat <<'JSON'
{{"supported":true,"installed":true,"disabled":false,"loaded":true,"running":true,"pid":123,"label":"fi.siriusbusiness.nvpn.test","binary_version":"test"}}
JSON
  exit 0
fi
if [ "$1" = "status" ]; then
  if [ -f "$RESUMED" ]; then
    cat <<'JSON'
{{"daemon":{{"running":true,"state":{{"updated_at":2,"binary_version":"test","local_endpoint":"","advertised_endpoint":"","listen_port":0,"vpn_enabled":true,"vpn_active":true,"vpn_status":"VPN on","expected_peer_count":1,"connected_peer_count":1,"mesh_ready":true,"peers":[]}}}}}}
JSON
  else
    cat <<'JSON'
{{"daemon":{{"running":true,"state":{{"updated_at":1,"binary_version":"test","local_endpoint":"","advertised_endpoint":"","listen_port":0,"vpn_enabled":false,"vpn_active":false,"vpn_status":"Paused","expected_peer_count":1,"connected_peer_count":0,"mesh_ready":false,"peers":[]}}}}}}
JSON
  fi
  exit 0
fi
if [ "$1" = "resume" ]; then
  touch "$RESUMED"
  exit 0
fi
if [ "$1" = "start" ]; then
  echo "unexpected elevated start" >&2
  exit 42
fi
exit 0
"#
        );
        fs::write(&script_path, script).expect("write fake nvpn");
        let mut permissions = fs::metadata(&script_path)
            .expect("fake nvpn metadata")
            .permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&script_path, permissions).expect("make fake nvpn executable");

        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.last_error.clear();
        runtime.config_path = dir.join("config.toml");
        create_test_network(&mut runtime, "Home");
        runtime
            .config
            .save(&runtime.config_path)
            .expect("save test config");
        runtime.nvpn_bin = Some(script_path);
        runtime.daemon_running = true;
        runtime.vpn_enabled = true;
        runtime.vpn_active = true;
        runtime.daemon_state = Some(DaemonRuntimeState {
            vpn_enabled: true,
            vpn_active: true,
            vpn_status: "VPN on".to_string(),
            expected_peer_count: 1,
            connected_peer_count: 1,
            ..DaemonRuntimeState::default()
        });
        #[cfg(target_os = "macos")]
        {
            runtime.privileged_command_runner = Some(PrivilegedCommandRunnerHandle(Arc::new(
                TestPrivilegedRunner {
                    calls_path: calls_path.clone(),
                },
            )));
        }

        runtime.dispatch(NativeAppAction::InstallSystemService);

        let calls = fs::read_to_string(&calls_path).expect("read fake nvpn calls");
        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        assert!(resumed_path.exists(), "service reinstall should resume VPN");
        assert!(calls.contains(
            "status --json --include-join-request --discover-secs 0 --config"
        ));
        assert!(calls.contains("resume --config"));
        assert!(!calls.contains("start --daemon --connect"));
        assert!(runtime.vpn_enabled);
        assert!(runtime.vpn_active);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn settings_patch_persists_wireguard_exit_config() {
        let dir = unique_service_test_dir("nvpn-app-core-wireguard");

        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.mobile_runtime = true;
        runtime.config_path = dir.join("config.toml");

        runtime.dispatch(NativeAppAction::UpdateSettings {
            patch: SettingsPatch {
                wireguard_exit_enabled: Some(true),
                wireguard_exit_interface: Some("custom-wg".to_string()),
                wireguard_exit_address: Some("10.200.0.2/32".to_string()),
                wireguard_exit_private_key: Some("private".to_string()),
                wireguard_exit_peer_public_key: Some("peer".to_string()),
                wireguard_exit_peer_preshared_key: Some("psk".to_string()),
                wireguard_exit_endpoint: Some("198.51.100.20:51830".to_string()),
                wireguard_exit_allowed_ips: Some("0.0.0.0/0".to_string()),
                wireguard_exit_dns: Some("9.9.9.9".to_string()),
                wireguard_exit_mtu: Some(1380),
                wireguard_exit_persistent_keepalive_secs: Some(20),
                exit_node_leak_protection: Some(true),
                ..SettingsPatch::default()
            },
        });

        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        let saved = AppConfig::load(&runtime.config_path).expect("load persisted config");
        assert!(saved.wireguard_exit.enabled);
        assert_eq!(saved.wireguard_exit.interface, "custom-wg");
        assert_eq!(saved.wireguard_exit.address, "10.200.0.2/32");
        assert_eq!(saved.wireguard_exit.private_key, "private");
        assert_eq!(saved.wireguard_exit.peer_public_key, "peer");
        assert_eq!(saved.wireguard_exit.peer_preshared_key, "psk");
        assert_eq!(saved.wireguard_exit.endpoint, "198.51.100.20:51830");
        assert_eq!(saved.wireguard_exit.allowed_ips, vec!["0.0.0.0/0"]);
        assert_eq!(saved.wireguard_exit.dns, vec!["9.9.9.9"]);
        assert_eq!(saved.wireguard_exit.mtu, 1380);
        assert_eq!(saved.wireguard_exit.persistent_keepalive_secs, 20);
        assert!(saved.exit_node_leak_protection);

        let state = runtime.state();
        assert!(state.exit_node_leak_protection);
        assert!(state.wireguard_exit_enabled);
        assert!(state.wireguard_exit_configured);
        assert_eq!(state.wireguard_exit_interface, "custom-wg");
        assert_eq!(state.wireguard_exit_allowed_ips, "0.0.0.0/0");
        assert!(state.wireguard_exit_config.contains("[Interface]"));
        assert!(state.wireguard_exit_config.contains("[Peer]"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn settings_patch_persists_nostr_pubsub_config() {
        let dir = unique_service_test_dir("nvpn-app-core-pubsub");

        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.mobile_runtime = true;
        runtime.config_path = dir.join("config.toml");

        runtime.dispatch(NativeAppAction::UpdateSettings {
            patch: SettingsPatch {
                nostr_pubsub_mode: Some("relay".to_string()),
                nostr_pubsub_fanout: Some(3),
                nostr_pubsub_max_hops: Some(2),
                nostr_pubsub_max_event_bytes: Some(32 * 1024),
                ..SettingsPatch::default()
            },
        });

        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        let saved = AppConfig::load(&runtime.config_path).expect("load persisted config");
        assert_eq!(saved.nostr.pubsub.mode.as_str(), "relay");
        assert_eq!(saved.nostr.pubsub.fanout, 3);
        assert_eq!(saved.nostr.pubsub.max_hops, 2);
        assert_eq!(saved.nostr.pubsub.max_event_bytes, 32 * 1024);

        let state = runtime.state();
        assert_eq!(state.nostr_pubsub_mode, "relay");
        assert_eq!(state.nostr_pubsub_fanout, 3);
        assert_eq!(state.nostr_pubsub_max_hops, 2);
        assert_eq!(state.nostr_pubsub_max_event_bytes, 32 * 1024);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn settings_patch_persists_paid_exit_seller_config() {
        let dir = unique_service_test_dir("nvpn-app-core-paid-exit");

        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.mobile_runtime = true;
        runtime.config_path = dir.join("config.toml");

        runtime.dispatch(NativeAppAction::UpdateSettings {
            patch: SettingsPatch {
                paid_exit_enabled: Some(true),
                paid_exit_upstream: Some("wg".to_string()),
                paid_exit_price_msat: Some(2_500),
                paid_exit_per_units: Some(1_048_576),
                paid_exit_accepted_mints: Some(
                    "https://mint-b.example, https://mint-a.example".to_string(),
                ),
                paid_exit_max_channel_capacity_sat: Some(100),
                paid_exit_channel_expiry_secs: Some(3_600),
                paid_exit_free_probe_units: Some(65_536),
                paid_exit_grace_units: Some(131_072),
                paid_exit_country_code: Some("fi".to_string()),
                paid_exit_region: Some("Uusimaa".to_string()),
                paid_exit_asn: Some("AS12345".to_string()),
                paid_exit_network_class: Some("dc".to_string()),
                paid_exit_ipv4: Some(true),
                paid_exit_ipv6: Some(false),
                paid_exit_rating_file: Some(" ratings.json ".to_string()),
                paid_exit_rating_relays: Some(vec![
                    " wss://ratings-b.example ".to_string(),
                    "wss://ratings-a.example,wss://ratings-b.example".to_string(),
                ]),
                paid_exit_trusted_rating_authors: Some(vec![
                    " npub1authorb ".to_string(),
                    "npub1authora,npub1authorb".to_string(),
                ]),
                paid_exit_rating_scope: Some(" fips.peer.test ".to_string()),
                ..SettingsPatch::default()
            },
        });

        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        let saved = AppConfig::load(&runtime.config_path).expect("load persisted config");
        assert!(saved.paid_exit.enabled);
        assert_eq!(saved.paid_exit.access.upstream.as_str(), "wireguard_exit");
        assert_eq!(saved.paid_exit.pricing.price_msat, 2_500);
        assert_eq!(saved.paid_exit.pricing.per_units, 1_048_576);
        assert_eq!(
            saved.paid_exit.channel.accepted_mints,
            vec!["https://mint-a.example", "https://mint-b.example"]
        );
        assert_eq!(saved.paid_exit.channel.max_channel_capacity_sat, 100);
        assert_eq!(saved.paid_exit.channel.channel_expiry_secs, 3_600);
        assert_eq!(saved.paid_exit.channel.free_probe_units, 65_536);
        assert_eq!(saved.paid_exit.channel.grace_units, 131_072);
        assert_eq!(saved.paid_exit.location.country_code, "FI");
        assert_eq!(saved.paid_exit.location.region, "Uusimaa");
        assert_eq!(saved.paid_exit.location.asn, Some(12_345));
        assert_eq!(saved.paid_exit.location.network_class.as_str(), "datacenter");
        assert!(saved.paid_exit.ip_support.ipv4);
        assert!(!saved.paid_exit.ip_support.ipv6);
        assert_eq!(saved.paid_exit.rating_discovery.file, "ratings.json");
        assert_eq!(
            saved.paid_exit.rating_discovery.relays,
            vec![
                "wss://ratings-a.example".to_string(),
                "wss://ratings-b.example".to_string()
            ]
        );
        assert_eq!(
            saved.paid_exit.rating_discovery.trusted_authors,
            vec!["npub1authora".to_string(), "npub1authorb".to_string()]
        );
        assert_eq!(saved.paid_exit.rating_discovery.scope, "fips.peer.test");

        let raw = fs::read_to_string(&runtime.config_path).expect("read persisted config");
        assert!(raw.contains("rating_discovery"));
        assert!(raw.contains("trusted_authors"));
        assert!(raw.contains("scope = \"fips.peer.test\""));
        assert!(raw.contains("wss://ratings-a.example"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(all(unix, feature = "paid-exit"))]
    #[test]
    fn discover_paid_route_offers_passes_configured_rating_sources() {
        use std::os::unix::fs::PermissionsExt;

        let dir = unique_service_test_dir("nvpn-app-core-paid-rating-discover");
        let calls_path = dir.join("calls.txt");
        let script_path = dir.join("nvpn");
        let rating_path = dir.join("ratings.json");
        fs::write(&rating_path, r#"{"ratings":[]}"#).expect("write ratings file");
        let calls_literal = calls_path
            .to_string_lossy()
            .replace('\\', "\\\\")
            .replace('"', "\\\"");
        let script = format!(
            r#"#!/bin/sh
CALLS="{calls_literal}"
printf '%s\n' "$*" >> "$CALLS"
exit 0
"#
        );
        fs::write(&script_path, script).expect("write fake nvpn");
        let mut permissions = fs::metadata(&script_path)
            .expect("fake nvpn metadata")
            .permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&script_path, permissions).expect("make fake nvpn executable");

        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.last_error.clear();
        runtime.config_path = dir.join("config.toml");
        runtime.nvpn_bin = Some(script_path);
        runtime.config.paid_exit.rating_discovery.file = rating_path.display().to_string();
        runtime.config.paid_exit.rating_discovery.relays = vec![
            "wss://ratings-a.example".to_string(),
            "wss://ratings-b.example".to_string(),
        ];
        runtime.config.paid_exit.rating_discovery.trusted_authors =
            vec!["npub1author".to_string()];
        runtime.config.paid_exit.rating_discovery.scope = "fips.peer.test".to_string();

        runtime.dispatch(NativeAppAction::DiscoverPaidRouteOffers { duration_secs: 5 });

        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        let calls = fs::read_to_string(&calls_path).expect("read fake nvpn calls");
        assert!(calls.contains("paid-exit discover --config"));
        assert!(calls.contains("--duration-secs 5 --json"));
        assert!(calls.contains("--fips-peer-ratings"));
        assert!(calls.contains(rating_path.to_string_lossy().as_ref()));
        assert!(calls.contains("--fips-peer-ratings-relay wss://ratings-a.example"));
        assert!(calls.contains("--fips-peer-ratings-relay wss://ratings-b.example"));
        assert!(calls.contains("--trusted-rating-author npub1author"));
        assert!(calls.contains("--rating-scope fips.peer.test"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn gui_paid_automatic_selection_persists_the_daemon_buying_mode() {
        let dir = unique_service_test_dir("nvpn-app-core-paid-automatic");
        let error = anyhow!("test runtime");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.last_error.clear();
        runtime.mobile_runtime = true;
        runtime.config_path = dir.join("config.toml");
        create_test_network(&mut runtime, "Automatic paid route test");
        runtime.config.save(&runtime.config_path).expect("save config");

        runtime.dispatch(NativeAppAction::UpdateSettings {
            patch: SettingsPatch {
                internet_source: Some("paid_automatic".to_string()),
                ..SettingsPatch::default()
            },
        });

        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        assert_eq!(runtime.config.internet_source, InternetSource::PaidAutomatic);
        let saved = AppConfig::load(&runtime.config_path).expect("load saved config");
        assert_eq!(saved.internet_source, InternetSource::PaidAutomatic);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn settings_patch_enforces_exit_node_mutual_exclusion() {
        use nostr_sdk::prelude::{Keys, ToBech32};

        // Selecting a peer exit clears WG upstream, and selecting WG
        // upstream clears the peer exit — the daemon enforces this
        // so every UI can just push the new selection.
        let dir = unique_service_test_dir("nvpn-mutual-exit");

        let peer_npub = Keys::generate()
            .public_key()
            .to_bech32()
            .expect("peer npub");

        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.mobile_runtime = true;
        runtime.config_path = dir.join("config.toml");
        create_test_network(&mut runtime, "Home");
        // Add the peer as a participant in the active network so the
        // ensure_defaults pass at save time doesn't clear our chosen
        // exit_node as "not a participant".
        if let Some(network) = runtime.config.networks.first_mut() {
            network.devices.push(peer_npub.clone());
        }

        // Start with WG upstream enabled.
        runtime.dispatch(NativeAppAction::UpdateSettings {
            patch: SettingsPatch {
                wireguard_exit_enabled: Some(true),
                ..SettingsPatch::default()
            },
        });
        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        assert!(runtime.config.wireguard_exit.enabled);
        assert_eq!(runtime.config.exit_node, "");

        // Now push a peer exit. WG must clear.
        runtime.dispatch(NativeAppAction::UpdateSettings {
            patch: SettingsPatch {
                exit_node: Some(peer_npub.clone()),
                ..SettingsPatch::default()
            },
        });
        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        assert!(!runtime.config.wireguard_exit.enabled);
        assert!(!runtime.config.exit_node.is_empty());

        // Flip back to WG: peer exit must clear.
        runtime.dispatch(NativeAppAction::UpdateSettings {
            patch: SettingsPatch {
                wireguard_exit_enabled: Some(true),
                ..SettingsPatch::default()
            },
        });
        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        assert!(runtime.config.wireguard_exit.enabled);
        assert_eq!(runtime.config.exit_node, "");

        // Selecting Direct (clearing exit_node) leaves WG alone — the
        // user has to explicitly disable WG to go fully direct.
        runtime.dispatch(NativeAppAction::UpdateSettings {
            patch: SettingsPatch {
                exit_node: Some(String::new()),
                ..SettingsPatch::default()
            },
        });
        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        assert!(runtime.config.wireguard_exit.enabled);
        assert_eq!(runtime.config.exit_node, "");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn settings_patch_persists_fips_controls() {
        let dir = unique_service_test_dir("nvpn-app-core-fips-host");

        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.mobile_runtime = true;
        runtime.config_path = dir.join("config.toml");

        runtime.dispatch(NativeAppAction::UpdateSettings {
            patch: SettingsPatch {
                fips_host_tunnel_enabled: Some(false),
                connect_to_non_roster_fips_peers: Some(false),
                fips_webrtc_enabled: Some(true),
                fips_host_inbound_tcp_ports: Some("443, 22, 22".to_string()),
                ..SettingsPatch::default()
            },
        });

        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        let saved = AppConfig::load(&runtime.config_path).expect("load persisted config");
        assert!(!saved.fips_host_tunnel_enabled);
        assert!(!saved.connect_to_non_roster_fips_peers);
        assert!(saved.fips_webrtc_enabled);
        assert_eq!(saved.fips_host_inbound_tcp_ports, vec![22, 443]);

        let state = runtime.state();
        assert!(!state.fips_host_tunnel_enabled);
        assert!(!state.connect_to_non_roster_fips_peers);
        assert!(state.fips_webrtc_enabled);
        assert_eq!(state.fips_host_inbound_tcp_ports, "22, 443");

        let _ = fs::remove_dir_all(&dir);
    }

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
