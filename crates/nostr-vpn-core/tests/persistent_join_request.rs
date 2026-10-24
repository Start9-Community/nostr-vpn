use nostr_sdk::prelude::Keys;
use nostr_vpn_core::config::AppConfig;
use nostr_vpn_core::fips_control::{JoinRosterControl, NetworkRoster, SignedRoster};
use nostr_vpn_core::identity_bridge::{
    CreateNostrIdentityDeviceApprovalRequestOptions, create_nostr_identity_device_approval_request,
};
use nostr_vpn_core::join_requests::{NOSTR_VPN_JOIN_REQUEST_TYPE, PendingNostrJoinRequest};

#[test]
fn old_qr_joins_once_then_cannot_authorize_another_network() {
    check_persistent_qr(false);
}

#[test]
fn legacy_qr_keeps_its_secret_after_its_old_expiry() {
    check_persistent_qr(true);
}

fn check_persistent_qr(legacy: bool) {
    let approved_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let created_at = approved_at - 30 * 24 * 60 * 60;
    let mut app = AppConfig::generated_without_networks();
    app.ensure_pending_nostr_join_request(created_at).unwrap();
    if legacy {
        // Produce the signed request that the old version would have saved.
        let local = create_nostr_identity_device_approval_request(
            &app.nostr_keys().unwrap(),
            CreateNostrIdentityDeviceApprovalRequestOptions {
                request_keys: None,
                request_secret: None,
                requested_at: created_at.try_into().unwrap(),
                request_type: Some(NOSTR_VPN_JOIN_REQUEST_TYPE.into()),
                resources: Vec::new(),
                expires_at: Some((created_at + 15 * 60).try_into().unwrap()),
                profile_id: app.nostr.identity_profile_id,
                admin_app_key_pubkey: None,
                label: None,
            },
        )
        .unwrap();
        app.pending_nostr_join_request = Some(PendingNostrJoinRequest {
            version: 1,
            request: local.request,
            request_private_key: local.request_keys.secret_key().to_secret_hex(),
        });
    }
    let qr = app
        .pending_nostr_join_request_link("nvpn://join-request/")
        .unwrap();
    let secret = app
        .pending_nostr_join_request
        .as_ref()
        .unwrap()
        .request
        .request_secret
        .clone();
    assert!(!app.ensure_pending_nostr_join_request(approved_at).unwrap());
    assert_eq!(
        qr,
        app.pending_nostr_join_request_link("nvpn://join-request/")
            .unwrap()
    );

    let admin = Keys::generate();
    let roster = NetworkRoster {
        network_name: "Home".into(),
        devices: vec![app.own_nostr_pubkey_hex().unwrap()],
        admins: vec![admin.public_key().to_hex()],
        aliases: Default::default(),
        signed_at: approved_at,
    };
    let control = JoinRosterControl::new(
        SignedRoster::sign("home", roster.clone(), &admin).unwrap(),
        &secret,
    )
    .unwrap();
    assert!(
        app.apply_nostr_join_roster(&control, approved_at)
            .unwrap()
            .is_some()
    );
    let next = app.pending_nostr_join_request.as_ref().unwrap();
    assert_ne!(next.request.request_secret, secret);
    assert_eq!(next.request.expires_at, None);
    let another = JoinRosterControl::new(
        SignedRoster::sign("another", roster, &admin).unwrap(),
        &secret,
    )
    .unwrap();
    assert!(app.apply_nostr_join_roster(&another, approved_at).is_err());
    assert_eq!(app.networks.len(), 1);
}
