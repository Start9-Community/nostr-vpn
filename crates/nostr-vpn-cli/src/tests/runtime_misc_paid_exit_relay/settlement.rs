#[cfg(feature = "paid-exit")]
#[tokio::test]
async fn paid_exit_settle_signs_manual_cooperative_close_from_wallet() {
    use cashu_service::{CashuSpilmanPayment, CashuSpilmanPaymentSigner};
    use nostr_sdk::prelude::{Keys, ToBech32};
    use nostr_vpn_core::paid_route_store::{
        OpenPaidRouteBuyerSessionRequest, PaidRouteBuyerPaymentUpdatesDueRequest,
        PaidRouteLifecycleStatus, PaidRouteStore, RecordPaidRouteBuyerUsageRequest,
    };
    use nostr_vpn_core::paid_routes::{
        PaidExitConfig, PaidRouteUsage, signed_paid_exit_offer_from_config,
    };
    use serde_json::json;

    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("clock is after epoch")
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("nvpn-paid-exit-settle-{nonce}"));
    std::fs::create_dir_all(&dir).expect("create test dir");

    let mut app = AppConfig::generated();
    let buyer_keys = app.nostr_keys().expect("buyer keys");
    let buyer_npub = buyer_keys.public_key().to_bech32().expect("buyer npub");
    let seller = Keys::generate();
    app.select_public_paid_exit_node(&seller.public_key().to_hex())
        .expect("select seller");
    let mut offer_config = PaidExitConfig {
        enabled: true,
        ..PaidExitConfig::default()
    };
    offer_config.pricing.price_msat = 1_000;
    offer_config.pricing.per_units = 100;
    offer_config.channel.accepted_mints = vec!["https://mint.example".to_string()];
    offer_config.channel.free_probe_units = 0;
    offer_config.channel.grace_units = 0;
    let signed_offer =
        signed_paid_exit_offer_from_config("internet-exit", &seller, &offer_config, None, 123)
            .expect("sign offer");

    let mut store = PaidRouteStore::default();
    store.upsert_wallet_mint("https://mint.example", "Example", None, 122);
    store
        .upsert_signed_offer(signed_offer, vec!["wss://relay.example".to_string()], 124)
        .expect("store offer");
    let session = store
        .open_buyer_session(OpenPaidRouteBuyerSessionRequest {
            offer_selector: "internet-exit".to_string(),
            buyer_npub,
            mint_url: Some("https://mint.example".to_string()),
            channel_capacity_sat: Some(10),
            initial_paid_msat: 0,
            now_unix: 125,
        })
        .expect("open buyer session");
    store
        .record_buyer_usage(RecordPaidRouteBuyerUsageRequest {
            seller_pubkey: seller.public_key().to_hex(),
            usage_delta: PaidRouteUsage {
                rx_bytes: 60,
                tx_bytes: 50,
                billable_bytes: 110,
                ..PaidRouteUsage::default()
            },
            now_unix: 126,
        })
        .expect("record buyer usage")
        .expect("matched buyer session");

    let wallet_data_dir = dir.join("wallet");
    let result = paid_exit_settle_with_signer(PaidExitSettleRequest {
        app: &app,
        config_path: &dir.join("config.toml"),
        store: &mut store,
        signer: &RuntimeFakePaymentSigner,
        session_id: &session.session_id,
        dry_run: false,
        wallet_data_dir: &wallet_data_dir,
        now_unix: 128,
    })
    .expect("settle channel");

    assert!(result.payment.changed);
    assert_eq!(result.payment.payload_type, "cooperative_close");
    assert_eq!(result.payment.session_id, session.session_id);
    assert_eq!(result.payment.channel_id, session.channel_id);
    assert_eq!(result.payment.lease_id, session.lease_id);
    assert_eq!(result.payment.delivered_units, 110);
    assert_eq!(result.payment.amount_due_msat, 1_100);
    assert_eq!(result.payment.paid_msat, 2_000);
    assert!(!result.dry_run);
    assert_eq!(result.queued, Some(true));
    assert!(result.persisted);

    let channel = store.channels.get(&session.channel_id).expect("channel");
    assert_eq!(channel.status, PaidRouteLifecycleStatus::Closing);
    assert_eq!(channel.payment.paid_msat, 2_000);
    assert_eq!(
        channel
            .payment
            .cashu_spilman_payment
            .as_ref()
            .map(|payment| payment.balance),
        Some(2)
    );
    let expected_signature = format!("closed-{}-2", session.channel_id);
    assert_eq!(
        channel
            .payment
            .cashu_spilman_payment
            .as_ref()
            .map(|payment| payment.signature.as_str()),
        Some(expected_signature.as_str())
    );
    let lease = store.leases.get(&session.lease_id).expect("lease");
    assert_eq!(lease.status, PaidRouteLifecycleStatus::Closing);
    assert!(
        store
            .buyer_payment_updates_due(PaidRouteBuyerPaymentUpdatesDueRequest {
                now_unix: 129,
                min_increment_msat: 1,
            })
            .is_empty()
    );

    app.set_internet_source(InternetSource::Direct);
    let seller_npub = seller.public_key().to_bech32().expect("seller npub");
    let mut recent_peers = nostr_vpn_core::recent_peers::RecentPeerEndpoints::default();
    assert!(recent_peers.note_success(&seller.public_key().to_hex(), "203.0.113.40:51821", 128,));
    let network_id = app.effective_network_id();
    let own_pubkey = app.own_nostr_pubkey_hex().expect("buyer pubkey");
    let config = fips_tunnel_config_from_app(FipsTunnelConfigInput {
        app: &app,
        config_path: &dir.join("config.toml"),
        network_id: &network_id,
        iface: "utun-test".to_string(),
        underlay_interface_mtu: None,
        own_pubkey: Some(&own_pubkey),
        recent_peers: Some(&recent_peers),
        live_peer_endpoints: &[],
        ethernet_underlay: None,
    })
    .expect("build direct-mode config with pending close");
    let seller_control_peer = config
        .endpoint_peers
        .iter()
        .find(|peer| peer.npub == seller_npub)
        .expect("pending close keeps seller as a control peer");
    assert!(seller_control_peer.auto_reconnect);
    assert!(
        seller_control_peer
            .addresses
            .iter()
            .any(|hint| hint.addr == "203.0.113.40:51821")
    );
    assert!(
        config
            .peers
            .iter()
            .all(|peer| peer.participant_pubkey != seller.public_key().to_hex()),
        "pending close must not restore the seller as an exit route"
    );

    let _ = std::fs::remove_dir_all(&dir);

    struct RuntimeFakePaymentSigner;

    impl CashuSpilmanPaymentSigner for RuntimeFakePaymentSigner {
        fn sign_cashu_spilman_payment(
            &self,
            channel_id: &str,
            balance: u64,
            include_funding: bool,
        ) -> std::result::Result<CashuSpilmanPayment, String> {
            Ok(CashuSpilmanPayment {
                channel_id: channel_id.to_string(),
                balance,
                signature: format!("signed-{channel_id}-{balance}"),
                params: include_funding.then(|| json!({"channel": channel_id})),
                funding_proofs: include_funding.then(|| json!({"proofs": []})),
            })
        }

        fn sign_cashu_spilman_close(
            &self,
            channel_id: &str,
            final_balance: u64,
        ) -> std::result::Result<CashuSpilmanPayment, String> {
            Ok(CashuSpilmanPayment {
                channel_id: channel_id.to_string(),
                balance: final_balance,
                signature: format!("closed-{channel_id}-{final_balance}"),
                params: None,
                funding_proofs: None,
            })
        }
    }
}
