#[test]
fn apply_config_file_writes_target_config() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock is after epoch")
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("nvpn-apply-config-test-{nonce}"));
    fs::create_dir_all(&dir).expect("create temp dir");

    let source = dir.join("source.toml");
    let target = dir.join("target.toml");
    let mut config = AppConfig::generated();
    activate_first_network(&mut config);
    config.node_name = "windows-box".to_string();
    config.networks[0].devices = vec!["ab".repeat(32)];
    config.save(&source).expect("save source config");

    apply_config_file(&source, &target).expect("apply config should succeed");

    let loaded = AppConfig::load(&target).expect("load target config");
    assert_eq!(loaded.node_name, "windows-box");
    assert_eq!(loaded.participant_pubkeys_hex(), vec!["ab".repeat(32)]);

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn load_or_default_config_migrates_plaintext_config_secrets() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock is after epoch")
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("nvpn-load-config-secrets-{nonce}"));
    fs::create_dir_all(&dir).expect("create temp dir");
    let path = dir.join("config.toml");
    let mut config = AppConfig::generated();
    config.wireguard_exit.private_key = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=".to_string();
    config.wireguard_exit.peer_public_key =
        "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=".to_string();
    config.wireguard_exit.peer_preshared_key =
        "AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM=".to_string();
    let nostr_secret = config.nostr.secret_key.clone();
    let wireguard_private_key = config.wireguard_exit.private_key.clone();
    let wireguard_peer_preshared_key = config.wireguard_exit.peer_preshared_key.clone();
    fs::write(
        &path,
        config.plaintext_toml().expect("encode plaintext config"),
    )
    .expect("write plaintext config");

    let loaded = load_or_default_config(&path).expect("load config");
    let raw = fs::read_to_string(&path).expect("read migrated config");
    AppConfig::delete_persisted_secrets_for_path(&path).expect("delete migrated secrets");

    assert_eq!(loaded.nostr.secret_key, nostr_secret);
    assert_eq!(loaded.wireguard_exit.private_key, wireguard_private_key);
    assert_eq!(
        loaded.wireguard_exit.peer_preshared_key,
        wireguard_peer_preshared_key
    );
    assert!(!raw.contains(&nostr_secret));
    assert!(!raw.contains(&wireguard_private_key));
    assert!(!raw.contains(&wireguard_peer_preshared_key));

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn stage_daemon_config_apply_writes_staged_file() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock is after epoch")
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("nvpn-stage-config-test-{nonce}"));
    fs::create_dir_all(&dir).expect("create temp dir");

    let source = dir.join("source.toml");
    let target = dir.join("config.toml");
    let mut config = AppConfig::generated();
    config.node_name = "staged-node".to_string();
    config.save(&source).expect("save source config");

    stage_daemon_config_apply(&target, &source).expect("stage config should succeed");

    let staged = daemon_staged_config_file_path(&target);
    let loaded = AppConfig::load(&staged).expect("load staged config");
    assert_eq!(loaded.node_name, "staged-node");

    AppConfig::delete_persisted_secrets_for_path(&source).expect("delete source secrets");
    AppConfig::delete_persisted_secrets_for_path(&staged).expect("delete staged secrets");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn daemon_control_readiness_is_bound_to_the_current_process() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock is after epoch")
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("nvpn-control-ready-test-{nonce}"));
    fs::create_dir_all(&dir).expect("create temp dir");
    let config = dir.join("config.toml");

    write_daemon_control_ready(&config, 41).expect("write stale ready marker");
    assert!(
        !daemon_control_ready_for_pid(&config, 42),
        "a marker from a previous daemon must not make a new daemon controllable"
    );
    assert!(
        wait_for_daemon_control_ready(&config, 42, Duration::from_millis(20)).is_err(),
        "a caller must wait while only a stale daemon marker exists"
    );

    write_daemon_control_ready(&config, 42).expect("write current ready marker");
    wait_for_daemon_control_ready(&config, 42, Duration::from_millis(20))
        .expect("current daemon should be ready");
    clear_daemon_control_ready(&config);
    assert!(
        !daemon_control_ready_file_path(&config).exists(),
        "shutdown must remove the readiness marker"
    );

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn daemon_instance_lock_rejects_a_second_process_until_release() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock is after epoch")
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("nvpn-daemon-lock-test-{nonce}"));
    fs::create_dir_all(&dir).expect("create temp dir");
    let config = dir.join("config.toml");

    let first = acquire_daemon_instance_lock(&config).expect("acquire first daemon lock");
    let second = acquire_daemon_instance_lock(&config);
    assert!(
        second.is_err(),
        "a second daemon must not acquire the same config lock"
    );
    drop(first);
    acquire_daemon_instance_lock(&config).expect("released daemon lock should be reusable");

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn update_daemon_config_from_staged_request_replaces_target_and_cleans_up() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock is after epoch")
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("nvpn-stage-apply-test-{nonce}"));
    fs::create_dir_all(&dir).expect("create temp dir");

    let source = dir.join("source.toml");
    let target = dir.join("config.toml");
    let mut source_config = AppConfig::generated();
    source_config.node_name = "service-owned".to_string();
    source_config.save(&source).expect("save source config");

    let mut target_config = AppConfig::generated();
    target_config.node_name = "old-name".to_string();
    target_config.save(&target).expect("save target config");

    stage_daemon_config_apply(&target, &source).expect("stage config should succeed");
    update_daemon_config_from_staged_request(&target).expect("apply staged config");

    let loaded = AppConfig::load(&target).expect("load target config");
    assert_eq!(loaded.node_name, "service-owned");
    assert!(
        !daemon_staged_config_file_path(&target).exists(),
        "staged config should be cleaned up"
    );

    AppConfig::delete_persisted_secrets_for_path(&source).expect("delete source secrets");
    AppConfig::delete_persisted_secrets_for_path(&target).expect("delete target secrets");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn kill_error_fallback_matcher_detects_permission_denied() {
    assert!(kill_error_requires_control_fallback(
        "kill -TERM 123 failed\nstderr: Operation not permitted"
    ));
    assert!(kill_error_requires_control_fallback(
        "kill -TERM 123 failed\nstderr: permission denied"
    ));
    assert!(!kill_error_requires_control_fallback(
        "kill -TERM 123 failed\nstderr: no such process"
    ));
}

#[test]
fn daemon_control_stop_request_roundtrip() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock is after epoch")
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("nvpn-control-test-{nonce}"));
    fs::create_dir_all(&dir).expect("create temp dir");
    let config = dir.join("config.toml");
    fs::write(&config, "node_name = \"test\"").expect("write config");

    request_daemon_stop(&config).expect("write stop request");
    assert!(
        take_daemon_control_request(&config) == Some(crate::DaemonControlRequest::Stop),
        "daemon should read stop request"
    );
    request_daemon_reload(&config).expect("write reload request");
    assert!(
        take_daemon_control_request(&config) == Some(crate::DaemonControlRequest::Reload),
        "daemon should read reload request"
    );
    write_daemon_control_request(&config, crate::DaemonControlRequest::Pause)
        .expect("write pause control request");
    assert!(
        take_daemon_control_request(&config) == Some(crate::DaemonControlRequest::Pause),
        "daemon should read pause request"
    );
    write_daemon_control_request(&config, crate::DaemonControlRequest::Resume)
        .expect("write resume control request");
    assert!(
        take_daemon_control_request(&config) == Some(crate::DaemonControlRequest::Resume),
        "daemon should read resume request"
    );
    let _ = fs::remove_file(daemon_control_file_path(&config));
    assert!(
        take_daemon_control_request(&config).is_none(),
        "without control file there should be no stop request"
    );

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn daemon_control_timeout_errors_use_generic_service_wording() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock is after epoch")
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("nvpn-control-timeout-test-{nonce}"));
    fs::create_dir_all(&dir).expect("create temp dir");
    let config = dir.join("config.toml");
    fs::write(&config, "node_name = \"test\"").expect("write config");

    let ack_error = crate::wait_for_daemon_control_ack(&config, Duration::from_millis(0))
        .expect_err("ack wait should time out");
    assert!(
        ack_error
            .to_string()
            .contains("background service may be busy or stuck")
    );
    assert!(!ack_error.to_string().contains("newer nvpn binary"));

    let result_error = crate::wait_for_daemon_control_result(
        &config,
        crate::DaemonControlRequest::Reload,
        Duration::from_millis(0),
    )
    .expect_err("result wait should time out");
    assert!(
        result_error
            .to_string()
            .contains("background service may be busy or stuck")
    );
    assert!(!result_error.to_string().contains("newer nvpn binary"));

    let vpn_error = crate::wait_for_daemon_vpn_enabled(&config, true, Duration::from_millis(0))
        .expect_err("vpn wait should time out");
    assert!(
        vpn_error
            .to_string()
            .contains("background service may be busy or stuck")
    );
    assert!(
        !vpn_error
            .to_string()
            .contains("older nvpn daemon binary is still running")
    );

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn daemon_control_wait_timeouts_allow_longer_mac_recovery_windows() {
    assert_eq!(
        crate::daemon_control_ack_timeout(crate::DaemonControlRequest::Reload),
        Duration::from_secs(10)
    );
    assert_eq!(
        crate::daemon_control_result_timeout(crate::DaemonControlRequest::Reload),
        Duration::from_secs(15)
    );
    assert_eq!(
        crate::daemon_control_vpn_transition_timeout(crate::DaemonControlRequest::Reload),
        Duration::ZERO
    );

    if cfg!(target_os = "macos") {
        assert_eq!(
            crate::daemon_control_ack_timeout(crate::DaemonControlRequest::Resume),
            Duration::from_secs(15)
        );
        assert_eq!(
            crate::daemon_control_result_timeout(crate::DaemonControlRequest::Resume),
            Duration::from_secs(30)
        );
        assert_eq!(
            crate::daemon_control_vpn_transition_timeout(crate::DaemonControlRequest::Resume),
            Duration::from_secs(30)
        );
    } else {
        assert_eq!(
            crate::daemon_control_ack_timeout(crate::DaemonControlRequest::Resume),
            Duration::from_secs(10)
        );
        assert_eq!(
            crate::daemon_control_result_timeout(crate::DaemonControlRequest::Resume),
            Duration::from_secs(15)
        );
        assert_eq!(
            crate::daemon_control_vpn_transition_timeout(crate::DaemonControlRequest::Resume),
            Duration::from_secs(2)
        );
    }
}
