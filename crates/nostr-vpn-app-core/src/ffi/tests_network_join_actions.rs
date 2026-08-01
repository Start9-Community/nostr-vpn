    #[test]
    fn accepting_join_request_uses_requester_node_name_as_alias() {
        let nonce = SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock is after epoch")
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("nvpn-app-core-accept-join-{nonce}"));
        fs::create_dir_all(&dir).expect("create test dir");

        let requester_npub = Keys::generate()
            .public_key()
            .to_bech32()
            .expect("requester npub");
        let requester_hex = normalize_nostr_pubkey(&requester_npub).expect("normalize requester");

        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.mobile_runtime = true;
        runtime.config_path = dir.join("config.toml");
        runtime.dispatch(NativeAppAction::AddNetwork {
            name: "Home".to_string(),
        });
        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        let network_id = runtime.config.networks[0].id.clone();
        runtime.config.networks[0]
            .inbound_join_requests
            .push(PendingInboundJoinRequest {
                requester: requester_hex.clone(),
                requester_node_name: "Linux Dev".to_string(),
                requested_at: 1_726_000_000,
            });

        runtime.dispatch(NativeAppAction::AcceptJoinRequest {
            network_id: network_id.clone(),
            requester_npub,
        });

        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        assert!(
            runtime.config.networks[0].devices
                .contains(&requester_hex)
        );
        assert!(runtime.config.networks[0].inbound_join_requests.is_empty());
        assert_eq!(
            runtime.config.peer_alias(&requester_hex).as_deref(),
            Some("linux-dev")
        );

        let saved = AppConfig::load(&runtime.config_path).expect("load persisted config");
        assert_eq!(
            saved.peer_alias(&requester_hex).as_deref(),
            Some("linux-dev")
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn adding_a_new_participant_queues_one_receipt_backed_manual_join_roster() {
        let nonce = SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock is after epoch")
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("nvpn-app-core-manual-outbox-{nonce}"));
        fs::create_dir_all(&dir).expect("create test dir");

        let joiner_keys = Keys::generate();
        let joiner_npub = joiner_keys
            .public_key()
            .to_bech32()
            .expect("joiner npub");
        let joiner_hex = joiner_keys.public_key().to_hex();
        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.mobile_runtime = true;
        runtime.config_path = dir.join("config.toml");
        runtime.dispatch(NativeAppAction::AddNetwork {
            name: "Home".to_string(),
        });
        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        let network_entry_id = runtime.config.networks[0].id.clone();
        let mesh_network_id = runtime.config.networks[0].network_id.clone();
        let admin = runtime.config.own_nostr_pubkey_hex().expect("admin pubkey");

        let action = NativeAppAction::AddParticipant {
            network_id: network_entry_id,
            npub: joiner_npub,
            alias: Some("iPhone".to_string()),
        };
        runtime.dispatch(action.clone());
        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        assert_eq!(runtime.queued_join_rosters.len(), 1);
        assert_eq!(
            runtime.queued_join_rosters[0]
                .signed_roster
                .signer_pubkey_hex()
                .expect("manual roster signer"),
            admin
        );
        assert!(
            runtime.queued_join_rosters[0]
                .signed_roster
                .roster()
                .expect("manual roster")
                .devices
                .contains(&joiner_hex)
        );

        runtime.dispatch(action);
        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        assert_eq!(
            runtime.queued_join_rosters.len(),
            1,
            "re-adding an existing participant must not create another delivery"
        );
        assert_eq!(runtime.config.networks[0].network_id, mesh_network_id);
        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn manual_admin_add_attempts_runtime_start_after_durable_roster_is_queued() {
        use std::os::unix::fs::PermissionsExt;

        let nonce = SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock is after epoch")
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("nvpn-app-core-manual-start-{nonce}"));
        fs::create_dir_all(&dir).expect("create test dir");
        let config_path = dir.join("config.toml");
        let outbox_path = nostr_vpn_core::join_delivery::join_roster_outbox_directory(&config_path);
        let calls_path = dir.join("calls.txt");
        let start_attempted_path = dir.join("start-attempted");
        let script_path = dir.join("nvpn");
        let joiner = Keys::generate();
        let joiner_npub = joiner.public_key().to_bech32().expect("joiner npub");
        let shell_literal = |path: &Path| {
            path.to_string_lossy()
                .replace('\\', "\\\\")
                .replace('"', "\\\"")
        };
        let script = format!(
            r#"#!/bin/sh
CALLS="{}"
START_ATTEMPTED="{}"
CONFIG="{}"
OUTBOX="{}"
JOINER="{}"
printf '%s\n' "$*" >> "$CALLS"
if [ "$1" = "service" ] && [ "$2" = "status" ]; then
  cat <<'JSON'
{{"supported":true,"installed":true,"disabled":false,"loaded":true,"running":true,"pid":123,"label":"fi.siriusbusiness.nvpn.test","binary_version":"test"}}
JSON
  exit 0
fi
if [ "$1" = "status" ]; then
  printf '%s\n' '{{"daemon":{{"running":false,"state":null}}}}'
  exit 0
fi
if [ "$1" = "start" ]; then
  grep -q "$JOINER" "$CONFIG" || exit 18
  find "$OUTBOX" -type f -name '*.json' | grep -q . || exit 19
  touch "$START_ATTEMPTED"
  exit 17
fi
exit 0
"#,
            shell_literal(&calls_path),
            shell_literal(&start_attempted_path),
            shell_literal(&config_path),
            shell_literal(&outbox_path),
            joiner_npub,
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
        runtime.mobile_runtime = false;
        runtime.config_path = config_path.clone();
        runtime.nvpn_bin = Some(script_path);
        let network_id = create_test_network(&mut runtime, "Home");
        let admin = runtime.config.own_nostr_pubkey_hex().expect("admin pubkey");
        runtime.config.networks[0].admins = vec![admin];
        runtime.config.autoconnect = false;
        runtime.config.save(&config_path).expect("save admin config");

        runtime.dispatch(NativeAppAction::AddParticipant {
            network_id,
            npub: joiner_npub,
            alias: Some("Pixel".to_string()),
        });

        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        assert!(
            start_attempted_path.exists(),
            "manual approval did not attempt to start networking"
        );
        assert_eq!(
            nostr_vpn_core::join_delivery::load_join_rosters(&config_path).len(),
            1,
            "manual approval must remain durably queued for receipt-backed delivery"
        );
        assert!(
            AppConfig::load(&config_path)
                .expect("load persisted admin config")
                .autoconnect,
            "manual approval must persist its explicit networking intent"
        );
        let calls = fs::read_to_string(&calls_path).expect("read fake nvpn calls");
        assert!(calls.contains("start --daemon --connect --config"), "{calls}");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn accepting_join_request_requires_pending_request() {
        let nonce = SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock is after epoch")
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("nvpn-app-core-accept-missing-{nonce}"));
        fs::create_dir_all(&dir).expect("create test dir");

        let requester_npub = Keys::generate()
            .public_key()
            .to_bech32()
            .expect("requester npub");
        let requester_hex = normalize_nostr_pubkey(&requester_npub).expect("normalize requester");

        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.mobile_runtime = true;
        runtime.config_path = dir.join("config.toml");
        create_test_network(&mut runtime, "Home");
        let network_id = runtime.config.networks[0].id.clone();

        runtime.dispatch(NativeAppAction::AcceptJoinRequest {
            network_id,
            requester_npub,
        });

        assert!(
            runtime.last_error.contains("no pending join request"),
            "{}",
            runtime.last_error
        );
        assert!(
            !runtime.config.networks[0].devices
                .contains(&requester_hex)
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn rejecting_join_request_removes_it_without_adding_participant() {
        let nonce = SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock is after epoch")
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("nvpn-app-core-reject-join-{nonce}"));
        fs::create_dir_all(&dir).expect("create test dir");

        let requester_npub = Keys::generate()
            .public_key()
            .to_bech32()
            .expect("requester npub");
        let requester_hex = normalize_nostr_pubkey(&requester_npub).expect("normalize requester");

        let error = anyhow!("boom");
        let mut runtime = NativeAppRuntime::from_startup_error(&error);
        runtime.startup_error = None;
        runtime.mobile_runtime = true;
        runtime.config_path = dir.join("config.toml");
        create_test_network(&mut runtime, "Home");
        let network_id = runtime.config.networks[0].id.clone();
        runtime.config.networks[0]
            .inbound_join_requests
            .push(PendingInboundJoinRequest {
                requester: requester_hex.clone(),
                requester_node_name: "Ubuntu Dev".to_string(),
                requested_at: 1_726_000_000,
            });

        runtime.dispatch(NativeAppAction::RejectJoinRequest {
            network_id,
            requester_npub,
        });

        assert!(runtime.last_error.is_empty(), "{}", runtime.last_error);
        assert!(
            !runtime.config.networks[0].devices
                .contains(&requester_hex)
        );
        assert!(runtime.config.networks[0].inbound_join_requests.is_empty());

        let saved = AppConfig::load(&runtime.config_path).expect("load persisted config");
        assert!(saved.networks[0].inbound_join_requests.is_empty());

        let _ = fs::remove_dir_all(&dir);
    }
