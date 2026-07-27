#[test]
fn participants_are_normalized_to_hex_pubkeys() {
    let keys = Keys::generate();
    let npub = keys.public_key().to_bech32().expect("npub");
    let hex = keys.public_key().to_hex();

    let mut config = AppConfig::generated();
    set_default_network_participants(&mut config, vec![npub, hex.clone()]);
    config.ensure_defaults();

    assert_eq!(config.participant_pubkeys_hex(), vec![hex]);
}

#[test]
fn normalize_accepts_npub() {
    let keys = Keys::generate();
    let npub = keys.public_key().to_bech32().expect("npub");

    let normalized = normalize_nostr_pubkey(&npub).expect("normalize npub");

    assert_eq!(normalized, keys.public_key().to_hex());
}

#[test]
fn derive_mesh_tunnel_ip_is_deterministic_for_participant_member() {
    let tunnel_ip = derive_mesh_tunnel_ip("mesh-a", "bb").expect("tunnel ip");
    assert_eq!(
        tunnel_ip,
        derive_mesh_tunnel_ip("mesh-a", "bb").expect("tunnel ip")
    );
    assert_ne!(
        tunnel_ip,
        derive_mesh_tunnel_ip("mesh-b", "bb").expect("different mesh id changes ip")
    );
}

#[test]
fn maybe_autoconfigure_node_assigns_tunnel_ip_from_participants() {
    let keys = Keys::generate();
    let own_hex = keys.public_key().to_hex();

    let mut config = AppConfig::generated();
    config.nostr.secret_key = keys.secret_key().to_secret_hex();
    config.nostr.public_key = own_hex.clone();
    set_default_network_participants(&mut config, vec!["0".repeat(64), own_hex.clone()]);
    config.node.tunnel_ip = "10.44.0.1/32".to_string();
    config.node.endpoint = "198.51.100.10:51820".to_string();

    maybe_autoconfigure_node(&mut config);

    assert_eq!(
        config.node.tunnel_ip,
        derive_mesh_tunnel_ip(&config.effective_network_id(), &own_hex).expect("derived ip")
    );
}

#[test]
fn explicit_active_network_id_is_preserved() {
    let keys = Keys::generate();
    let peer = Keys::generate();
    let own_hex = keys.public_key().to_hex();

    let mut config = AppConfig::generated();
    config.networks[0].network_id = "mesh-fixed".to_string();
    config.nostr.secret_key = keys.secret_key().to_secret_hex();
    config.nostr.public_key = own_hex;
    set_default_network_participants(&mut config, vec![peer.public_key().to_hex()]);

    config.ensure_defaults();

    assert_eq!(config.effective_network_id(), "mesh-fixed");
}

#[test]
fn join_requests_enabled_uses_enabled_networks() {
    let mut config = AppConfig::generated();
    assert!(!config.join_requests_enabled());

    config.networks[0].listen_for_join_requests = false;
    let network_id = config.add_network("Other");
    config
        .set_network_join_requests_enabled(&network_id, true)
        .expect("enable join requests");
    assert!(!config.join_requests_enabled());

    config
        .set_network_enabled(&network_id, true)
        .expect("enable network");
    assert!(config.join_requests_enabled());
}

#[test]
fn generated_network_defaults_local_identity_to_admin() {
    let mut config = AppConfig::generated();
    activate_first_network(&mut config);
    let own_pubkey = config.own_nostr_pubkey_hex().expect("own pubkey");

    assert_eq!(config.active_network_admin_pubkeys_hex(), vec![own_pubkey]);
}

#[test]
fn apply_admin_signed_shared_roster_replaces_members_from_known_admin() {
    let own = Keys::generate();
    let current_admin = Keys::generate();
    let new_admin = Keys::generate();
    let member = Keys::generate();
    let own_hex = own.public_key().to_hex();
    let current_admin_hex = current_admin.public_key().to_hex();
    let new_admin_hex = new_admin.public_key().to_hex();
    let member_hex = member.public_key().to_hex();

    let mut config = AppConfig::generated();
    config.nostr.secret_key = own.secret_key().to_secret_hex();
    config.nostr.public_key = own_hex.clone();
    config.networks[0].network_id = "mesh-home".to_string();
    config.networks[0].admins = vec![current_admin_hex.clone()];
    config.networks[0].devices = vec![current_admin_hex.clone()];
    config.ensure_defaults();

    let changed = config
        .apply_admin_signed_shared_roster(admin_signed_roster_update(
            "mesh-home",
            "Home",
            vec![
                current_admin_hex.clone(),
                member_hex.clone(),
                own_hex.clone(),
            ],
            vec![current_admin_hex.clone(), new_admin_hex.clone()],
            std::collections::HashMap::new(),
            1_726_000_000,
            &current_admin_hex,
        ))
        .expect("apply shared roster");

    assert!(changed);
    assert_eq!(config.networks[0].name, "Home");
    let mut expected_participants = vec![current_admin_hex.clone(), member_hex.clone()];
    expected_participants.sort();
    assert_eq!(config.networks[0].devices, expected_participants);
    let mut expected_admins = vec![new_admin_hex, current_admin.public_key().to_hex()];
    expected_admins.sort();
    assert_eq!(config.networks[0].admins, expected_admins);
    assert_eq!(config.networks[0].shared_roster_updated_at, 1_726_000_000);
}

#[test]
fn newer_stale_admin_snapshot_cannot_resurrect_locally_removed_device() {
    let own = Keys::generate();
    let other_admin = Keys::generate();
    let removed = Keys::generate();
    let unrelated_addition = Keys::generate();
    let own_hex = own.public_key().to_hex();
    let other_admin_hex = other_admin.public_key().to_hex();
    let removed_hex = removed.public_key().to_hex();
    let unrelated_hex = unrelated_addition.public_key().to_hex();

    let mut config = AppConfig::generated();
    config.nostr.secret_key = own.secret_key().to_secret_hex();
    config.nostr.public_key = own_hex.clone();
    config.networks[0].network_id = "mesh-home".to_string();
    config.networks[0].admins = vec![own_hex.clone(), other_admin_hex.clone()];
    config.networks[0].devices = vec![removed_hex.clone()];
    config.ensure_defaults();
    let network_id = config.networks[0].id.clone();

    config
        .remove_participant_from_network(&network_id, &removed_hex)
        .expect("remove device locally");
    let removed_at = config.networks[0].shared_roster_updated_at;

    let changed = config
        .apply_admin_signed_shared_roster(admin_signed_roster_update(
            "mesh-home",
            "Home",
            vec![
                own_hex.clone(),
                other_admin_hex.clone(),
                removed_hex.clone(),
                unrelated_hex.clone(),
            ],
            vec![own_hex.clone(), other_admin_hex.clone()],
            std::collections::HashMap::new(),
            removed_at + 1,
            &other_admin_hex,
        ))
        .expect("apply newer stale snapshot");

    assert!(changed);
    assert!(!config.networks[0].devices.contains(&removed_hex));
    assert!(config.networks[0].devices.contains(&unrelated_hex));
    assert!(config.networks[0].removed_devices.contains(&removed_hex));
    assert_eq!(config.networks[0].shared_roster_signed_by, own_hex);
    assert!(config.networks[0].shared_roster_updated_at > removed_at + 1);
}

#[test]
fn apply_verified_admin_signed_shared_roster_applies_newer_admin_event_name() {
    let own = Keys::generate();
    let current_admin = Keys::generate();
    let own_hex = own.public_key().to_hex();
    let current_admin_hex = current_admin.public_key().to_hex();

    let mut config = AppConfig::generated();
    config.nostr.secret_key = own.secret_key().to_secret_hex();
    config.nostr.public_key = own_hex.clone();
    config.networks[0].name = "Local nickname".to_string();
    config.networks[0].network_id = "mesh-home".to_string();
    config.networks[0].admins = vec![current_admin_hex.clone()];
    config.networks[0].devices = vec![own_hex.clone()];
    config.networks[0].shared_roster_updated_at = 1_726_000_000;
    config.networks[0].shared_roster_signed_by = current_admin_hex.clone();
    config.ensure_defaults();

    let roster = NetworkRoster {
        network_name: "Home Mesh".to_string(),
        devices: vec![own_hex],
        admins: vec![current_admin_hex],
        aliases: std::collections::HashMap::new(),
        signed_at: 1_726_000_001,
    };
    let signed = SignedRoster::sign("mesh-home", roster, &current_admin).expect("sign roster");

    let changed = config
        .apply_verified_admin_signed_shared_roster(&signed)
        .expect("apply same roster metadata");

    assert!(changed);
    assert_eq!(config.networks[0].name, "Home Mesh");
    assert_eq!(config.networks[0].shared_roster_updated_at, 1_726_000_001);
}

#[test]
fn rename_network_requires_local_admin() {
    let own = Keys::generate();
    let current_admin = Keys::generate();
    let own_hex = own.public_key().to_hex();
    let current_admin_hex = current_admin.public_key().to_hex();

    let mut config = AppConfig::generated();
    config.nostr.secret_key = own.secret_key().to_secret_hex();
    config.nostr.public_key = own_hex.clone();
    config.networks[0].name = "Home Mesh".to_string();
    config.networks[0].network_id = "mesh-home".to_string();
    config.networks[0].admins = vec![current_admin_hex.clone()];
    config.networks[0].devices = vec![own_hex];
    config.networks[0].shared_roster_updated_at = 1_726_000_000;
    config.networks[0].shared_roster_signed_by = current_admin_hex;
    config.ensure_defaults();
    let network_id = config.networks[0].id.clone();

    let error = config
        .rename_network(&network_id, "Local nickname")
        .expect_err("joined non-admin rename must be rejected");

    assert!(
        error.to_string().contains("network admin"),
        "unexpected error: {error:#}"
    );
    assert_eq!(config.networks[0].name, "Home Mesh");
}

#[test]
fn apply_admin_signed_shared_roster_clears_join_request_when_own_key_is_added() {
    let own = Keys::generate();
    let current_admin = Keys::generate();
    let own_hex = own.public_key().to_hex();
    let current_admin_hex = current_admin.public_key().to_hex();

    let mut config = AppConfig::generated();
    config.nostr.secret_key = own.secret_key().to_secret_hex();
    config.nostr.public_key = own_hex.clone();
    config.networks[0].network_id = "mesh-home".to_string();
    config.networks[0].admins = vec![current_admin_hex.clone()];
    config.networks[0].devices = Vec::new();
    config.networks[0].outbound_join_request = Some(PendingOutboundJoinRequest {
        recipient: current_admin_hex.clone(),
        requested_at: 1_725_999_999,
    });
    config.ensure_defaults();

    let changed = config
        .apply_admin_signed_shared_roster(admin_signed_roster_update(
            "mesh-home",
            "Home",
            vec![current_admin_hex.clone(), own_hex],
            vec![current_admin_hex.clone()],
            std::collections::HashMap::new(),
            1_726_000_000,
            &current_admin_hex,
        ))
        .expect("apply accepted roster");

    assert!(changed);
    assert!(config.networks[0].outbound_join_request.is_none());
}

#[test]
fn apply_admin_signed_shared_roster_drops_network_when_own_key_is_evicted() {
    let own = Keys::generate();
    let current_admin = Keys::generate();
    let other_member = Keys::generate();
    let own_hex = own.public_key().to_hex();
    let current_admin_hex = current_admin.public_key().to_hex();
    let other_member_hex = other_member.public_key().to_hex();

    let mut config = AppConfig::generated();
    config.nostr.secret_key = own.secret_key().to_secret_hex();
    config.nostr.public_key = own_hex.clone();
    config.networks[0].network_id = "mesh-home".to_string();
    config.networks[0].admins = vec![current_admin_hex.clone()];
    config.networks[0].shared_roster_updated_at = 0;
    config.networks[0].shared_roster_signed_by.clear();
    config.networks[0].enabled = true;
    config.networks[0].outbound_join_request = Some(PendingOutboundJoinRequest {
        recipient: current_admin_hex.clone(),
        requested_at: 1_725_999_999,
    });
    config.ensure_defaults();

    config
        .apply_admin_signed_shared_roster(admin_signed_roster_update(
            "mesh-home",
            "Home",
            vec![own_hex, other_member_hex.clone()],
            vec![current_admin_hex.clone()],
            std::collections::HashMap::new(),
            1_726_000_000,
            &current_admin_hex,
        ))
        .expect("apply accepted roster");
    assert!(config.active_network_has_confirmed_local_identity());

    let changed = config
        .apply_admin_signed_shared_roster(admin_signed_roster_update(
            "mesh-home",
            "Home",
            vec![current_admin_hex.clone(), other_member_hex],
            vec![current_admin_hex.clone()],
            std::collections::HashMap::new(),
            1_726_000_001,
            &current_admin_hex,
        ))
        .expect("apply removal roster");

    assert!(changed);
    assert!(
        !config
            .networks
            .iter()
            .any(|network| network.network_id == "mesh-home"),
        "evicted network should be removed from local config"
    );
}

#[test]
fn apply_admin_signed_shared_roster_keeps_network_when_own_key_was_never_in_roster() {
    let own = Keys::generate();
    let current_admin = Keys::generate();
    let other_member = Keys::generate();
    let own_hex = own.public_key().to_hex();
    let current_admin_hex = current_admin.public_key().to_hex();
    let other_member_hex = other_member.public_key().to_hex();

    let mut config = AppConfig::generated();
    config.nostr.secret_key = own.secret_key().to_secret_hex();
    config.nostr.public_key = own_hex;
    config.networks[0].network_id = "mesh-home".to_string();
    config.networks[0].admins = vec![current_admin_hex.clone()];
    config.networks[0].devices = vec![current_admin_hex.clone(), other_member_hex.clone()];
    config.ensure_defaults();

    let changed = config
        .apply_admin_signed_shared_roster(admin_signed_roster_update(
            "mesh-home",
            "Home",
            vec![current_admin_hex.clone(), other_member_hex],
            vec![current_admin_hex.clone()],
            std::collections::HashMap::new(),
            1_726_000_000,
            &current_admin_hex,
        ))
        .expect("apply roster with own absent");

    assert!(changed);
    assert!(
        config
            .networks
            .iter()
            .any(|network| network.network_id == "mesh-home"),
        "join-pending network should be preserved"
    );
}

#[test]
fn manual_join_stays_pending_until_a_signed_roster_contains_this_device() {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system time")
        .as_secs();
    let joiner_keys = Keys::generate();
    let admin_keys = Keys::generate();
    let joiner_hex = joiner_keys.public_key().to_hex();
    let admin_hex = admin_keys.public_key().to_hex();
    let network_id = "manual-pending-mesh";

    let mut joining = AppConfig::generated_without_networks();
    joining.nostr.secret_key = joiner_keys.secret_key().to_secret_hex();
    joining.nostr.public_key = joiner_hex.clone();
    joining
        .add_manual_join_network(&admin_hex, network_id)
        .expect("seed manual join");
    assert!(!joining.active_network_has_confirmed_local_identity());
    let current_toml = joining.plaintext_toml().expect("encode manual join");
    let legacy_toml =
        current_toml.replace("local_identity_confirmation_pending = true\n", "");
    assert_ne!(
        current_toml, legacy_toml,
        "test fixture must remove the new persisted marker"
    );
    let mut legacy_joining: AppConfig =
        toml::from_str(&legacy_toml).expect("decode legacy manual join");
    legacy_joining.ensure_defaults();
    assert!(
        legacy_joining
            .active_network()
            .local_identity_confirmation_pending,
        "loading a pre-marker manual join must recover its pending acceptance state"
    );

    let roster_without_joiner = SignedRoster::sign(
        network_id,
        NetworkRoster {
            network_name: "Manual mesh".to_string(),
            devices: Vec::new(),
            admins: vec![admin_hex.clone()],
            aliases: std::collections::HashMap::new(),
            signed_at: now,
        },
        &admin_keys,
    )
    .expect("sign pre-acceptance roster");
    assert!(
        joining
            .apply_verified_admin_signed_shared_roster(&roster_without_joiner)
            .expect("apply configured admin roster")
    );
    assert!(
        !joining.active_network_has_confirmed_local_identity(),
        "a configured admin's roster must not confirm a manual join until it contains this device"
    );

    let path = unique_temp_config_path("manual-join-confirmation");
    joining.save(&path).expect("persist pending manual join");
    let mut reloaded = AppConfig::load(&path).expect("reload pending manual join");
    assert!(
        !reloaded.active_network_has_confirmed_local_identity(),
        "manual-join pending state must survive save/load"
    );

    let mut admin = AppConfig::generated();
    admin.nostr.secret_key = admin_keys.secret_key().to_secret_hex();
    admin.nostr.public_key = admin_hex.clone();
    let admin_network_entry_id = admin.networks[0].id.clone();
    admin.networks[0].network_id = network_id.to_string();
    admin.networks[0].name = "Manual mesh".to_string();
    admin.networks[0].admins = vec![admin_hex];
    admin.networks[0].devices = vec![joiner_hex.clone()];
    admin.networks[0].shared_roster_updated_at = now + 1;
    admin.networks[0].shared_roster_signed_by =
        admin.own_nostr_pubkey_hex().expect("admin pubkey");
    let accepted = prepare_manual_join_delivery(&admin, &admin_network_entry_id, &joiner_hex)
        .expect("prepare receipt-backed accepted roster");
    assert_eq!(
        reloaded
            .apply_manual_join_roster(&accepted, now + 1)
            .expect("apply receipt-backed accepted roster"),
        Some(network_id.to_string())
    );
    assert!(reloaded.active_network_has_confirmed_local_identity());
    reloaded.save(&path).expect("persist accepted manual join");
    assert!(
        AppConfig::load(&path)
            .expect("reload accepted manual join")
            .active_network_has_confirmed_local_identity(),
        "manual-join acceptance must survive save/load"
    );

    let _ = fs::remove_file(path);
}

#[test]
fn apply_admin_signed_shared_roster_ignores_unknown_signer() {
    let known_admin = Keys::generate();
    let unknown_admin = Keys::generate();
    let mut config = AppConfig::generated();
    config.networks[0].network_id = "mesh-home".to_string();
    config.networks[0].admins = vec![known_admin.public_key().to_hex()];
    config.ensure_defaults();

    let changed = config
        .apply_admin_signed_shared_roster(admin_signed_roster_update(
            "mesh-home",
            "Home",
            vec![known_admin.public_key().to_hex()],
            vec![known_admin.public_key().to_hex()],
            std::collections::HashMap::new(),
            1_726_000_000,
            &unknown_admin.public_key().to_hex(),
        ))
        .expect("ignore unknown signer");

    assert!(!changed);
}

#[test]
fn apply_verified_admin_signed_shared_roster_rejects_tampered_event() {
    let current_admin = Keys::generate();
    let member = Keys::generate();
    let current_admin_hex = current_admin.public_key().to_hex();
    let member_hex = member.public_key().to_hex();

    let mut config = AppConfig::generated();
    config.networks[0].network_id = "mesh-home".to_string();
    config.networks[0].admins = vec![current_admin_hex.clone()];
    config.ensure_defaults();

    let roster = NetworkRoster {
        network_name: "Home".to_string(),
        devices: vec![member_hex],
        admins: vec![current_admin_hex],
        aliases: std::collections::HashMap::new(),
        signed_at: 1_726_000_000,
    };
    let signed = SignedRoster::sign("mesh-home", roster, &current_admin).expect("sign roster");
    let mut event = signed.event.clone();
    event
        .tags
        .push(nostr_sdk::prelude::Tag::parse(["name", "Office"]).expect("tag"));
    let tampered = SignedRoster { event };

    let error = config
        .apply_verified_admin_signed_shared_roster(&tampered)
        .expect_err("tampered roster event must be rejected");

    assert!(
        error.to_string().contains("invalid roster event signature"),
        "unexpected error: {error:#}"
    );
    assert_eq!(config.networks[0].shared_roster_updated_at, 0);
}

#[test]
fn apply_verified_admin_signed_shared_roster_ignores_non_admin_author() {
    let known_admin = Keys::generate();
    let outsider = Keys::generate();
    let member = Keys::generate();
    let known_admin_hex = known_admin.public_key().to_hex();
    let outsider_hex = outsider.public_key().to_hex();
    let member_hex = member.public_key().to_hex();

    let mut config = AppConfig::generated();
    config.networks[0].network_id = "mesh-home".to_string();
    config.networks[0].admins = vec![known_admin_hex.clone()];
    config.ensure_defaults();

    let roster = NetworkRoster {
        network_name: "Home".to_string(),
        devices: vec![member_hex],
        admins: vec![known_admin_hex, outsider_hex],
        aliases: std::collections::HashMap::new(),
        signed_at: 1_726_000_000,
    };
    let signed = SignedRoster::sign("mesh-home", roster, &outsider).expect("sign roster");
    let changed = config
        .apply_verified_admin_signed_shared_roster(&signed)
        .expect("valid signature by non-admin author should be ignored");

    assert!(!changed);
    assert_eq!(config.networks[0].shared_roster_updated_at, 0);
}

#[test]
fn apply_admin_signed_shared_roster_clears_data_peers_when_own_key_is_removed() {
    let own = Keys::generate();
    let current_admin = Keys::generate();
    let other_member = Keys::generate();
    let own_hex = own.public_key().to_hex();
    let current_admin_hex = current_admin.public_key().to_hex();
    let other_member_hex = other_member.public_key().to_hex();

    let mut config = AppConfig::generated();
    config.nostr.secret_key = own.secret_key().to_secret_hex();
    config.nostr.public_key = own_hex.clone();
    config.networks[0].network_id = "mesh-home".to_string();
    config.networks[0].admins = vec![current_admin_hex.clone()];
    config.networks[0].devices = vec![current_admin_hex.clone(), other_member_hex.clone()];
    config.ensure_defaults();

    let changed = config
        .apply_admin_signed_shared_roster(admin_signed_roster_update(
            "mesh-home",
            "Home",
            vec![current_admin_hex.clone(), other_member_hex],
            vec![current_admin_hex.clone()],
            std::collections::HashMap::new(),
            1_726_000_000,
            &current_admin_hex,
        ))
        .expect("apply removal roster");

    assert!(changed);
    assert!(config.networks[0].devices.is_empty());
    assert_eq!(config.networks[0].admins, vec![current_admin_hex]);
}
