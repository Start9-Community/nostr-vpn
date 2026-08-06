#[cfg(feature = "paid-exit")]
#[test]
fn paid_exit_offer_follows_listener_and_upstream_readiness_without_relays() {
    use nostr_vpn_core::config::NostrPubsubMode;
    use nostr_vpn_core::paid_routes::{PAID_ROUTE_OFFER_KIND, PAID_ROUTE_OFFER_TTL_SECS};
    use crate::session_runtime::daemon_vpn_paid_exit::{
        PaidExitOfferPublication, PaidExitOfferPublisher,
    };

    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    let directory = std::env::temp_dir().join(format!("nvpn-paid-exit-p2p-{nonce}"));
    std::fs::create_dir_all(&directory).expect("create test directory");
    let config_path = directory.join("config.toml");
    let mut app = AppConfig::generated();
    app.nostr.relays.clear();
    app.nostr.pubsub.mode = NostrPubsubMode::Client;
    app.paid_exit.enabled = true;
    app.paid_exit.pricing.price_msat = 100;
    app.paid_exit.pricing.per_units = 1_000_000;
    app.paid_exit.channel.accepted_mints = vec!["https://mint.example".to_string()];
    app.paid_exit.normalize();
    let now_unix = PAID_ROUTE_OFFER_TTL_SECS + 1_000;
    let keys = app.nostr_keys().expect("seller keys");
    let stale_signed_at = now_unix - PAID_ROUTE_OFFER_TTL_SECS;
    let stale_offer = signed_paid_exit_offer_from_config(
        "internet-exit",
        &keys,
        &app.paid_exit,
        None,
        stale_signed_at,
    )
    .expect("sign stale offer")
    .offer()
    .expect("decode stale offer");
    let stale = SignedPaidRouteOffer::sign_expiring_at(
        stale_offer,
        &keys,
        stale_signed_at,
        now_unix + 100,
    )
    .expect("sign stale offer with misleading long expiration");
    assert!(!stale.is_live_at(now_unix));
    persist_paid_exit_offer_snapshot(
        &paid_route_store_file_path(&config_path),
        &stale,
        &[],
        &stale.offer().expect("stale offer"),
        stale_signed_at,
    )
    .expect("store stale offer");

    let mut publisher = PaidExitOfferPublisher::load(&app, &config_path, now_unix);
    assert_eq!(
        publisher
            .reconcile(&app, &config_path, now_unix, false, false)
            .expect("keep unready seller hidden"),
        PaidExitOfferPublication::None
    );
    assert!(!crate::control_pubsub_runtime::control_pubsub_outbox_directory(&config_path).exists());

    assert_eq!(
        publisher
            .reconcile(&app, &config_path, now_unix, true, false)
            .expect("publish ready seller"),
        PaidExitOfferPublication::Published
    );
    assert_eq!(
        publisher
            .reconcile(&app, &config_path, now_unix, false, false)
            .expect("withdraw on listener or upstream loss"),
        PaidExitOfferPublication::Withdrawn(1)
    );
    assert_eq!(
        publisher
            .reconcile(&app, &config_path, now_unix + 1, true, false)
            .expect("republish after readiness returns"),
        PaidExitOfferPublication::Published
    );
    app.paid_exit.enabled = false;
    assert_eq!(
        publisher
            .reconcile(&app, &config_path, now_unix + 1, true, false)
            .expect("withdraw when seller is disabled"),
        PaidExitOfferPublication::Withdrawn(1)
    );

    let mut events = std::fs::read_dir(
        crate::control_pubsub_runtime::control_pubsub_outbox_directory(&config_path),
    )
    .expect("read offer outbox")
    .map(|entry| {
        serde_json::from_slice::<nostr_sdk::prelude::Event>(
            &std::fs::read(entry.expect("outbox entry").path()).expect("read queued offer"),
        )
        .expect("decode queued offer")
    })
    .collect::<Vec<_>>();
    events.sort_by_key(|event| event.created_at);
    assert!(
        events
            .iter()
            .all(|event| u16::from(event.kind) == PAID_ROUTE_OFFER_KIND)
    );
    assert_eq!(
        events
            .iter()
            .map(|event| (
                event.created_at.as_secs(),
                event.tags.expiration().expect("offer expiry").as_secs()
                    - event.created_at.as_secs(),
            ))
            .collect::<Vec<_>>(),
        vec![
            (now_unix, PAID_ROUTE_OFFER_TTL_SECS),
            (now_unix + 1, 0),
            (now_unix + 2, PAID_ROUTE_OFFER_TTL_SECS),
            (now_unix + 3, 0),
        ]
    );

    let _ = std::fs::remove_dir_all(directory);
}
