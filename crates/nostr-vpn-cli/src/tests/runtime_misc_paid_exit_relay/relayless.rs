#[cfg(feature = "paid-exit")]
#[test]
fn enabled_paid_exit_daemon_queues_one_expiring_offer_without_relays() {
    use nostr_vpn_core::config::NostrPubsubMode;
    use nostr_vpn_core::paid_routes::{PAID_ROUTE_OFFER_KIND, PAID_ROUTE_OFFER_TTL_SECS};

    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    let directory = std::env::temp_dir().join(format!("nvpn-paid-exit-p2p-{nonce}"));
    let config_path = directory.join("config.toml");
    let mut app = AppConfig::generated();
    app.nostr.relays.clear();
    app.nostr.pubsub.mode = NostrPubsubMode::Client;
    app.paid_exit.enabled = true;
    app.paid_exit.pricing.price_msat = 100;
    app.paid_exit.pricing.per_units = 1_000_000;
    app.paid_exit.channel.accepted_mints = vec!["https://mint.example".to_string()];
    app.paid_exit.normalize();
    let now_unix = 1_000;

    assert!(
        crate::session_runtime::daemon_vpn_paid_exit::refresh_paid_exit_offer_for_daemon(
            &app,
            &config_path,
            now_unix,
        )
            .expect("refresh daemon offer")
    );
    assert!(
        !crate::session_runtime::daemon_vpn_paid_exit::refresh_paid_exit_offer_for_daemon(
            &app,
            &config_path,
            now_unix,
        )
            .expect("deduplicate identical refresh")
    );

    let paths = std::fs::read_dir(
        crate::control_pubsub_runtime::control_pubsub_outbox_directory(&config_path),
    )
        .expect("read offer outbox")
        .map(|entry| entry.expect("outbox entry").path())
        .collect::<Vec<_>>();
    assert_eq!(paths.len(), 1);
    let event: nostr_sdk::prelude::Event =
        serde_json::from_slice(&std::fs::read(&paths[0]).expect("read queued offer"))
            .expect("decode queued offer");
    assert_eq!(u16::from(event.kind), PAID_ROUTE_OFFER_KIND);
    assert_eq!(
        event.tags.expiration().map(|value| value.as_secs()),
        Some(now_unix + PAID_ROUTE_OFFER_TTL_SECS)
    );

    let _ = std::fs::remove_dir_all(directory);
}
