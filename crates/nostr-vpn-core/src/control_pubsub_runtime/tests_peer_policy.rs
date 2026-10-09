struct RejectAllPeers;

impl MeshPeerPolicy for RejectAllPeers {
    fn select_mesh_peer(&self, _peer_id: &str) -> nostr_pubsub::Result<Option<MeshPeer>> {
        Ok(None)
    }
}

#[test]
fn peer_policy_rejects_events_from_authenticated_udp_fips_peer() {
    run_async_test(
        "policy-fips-pubsub",
        peer_policy_rejects_events_from_authenticated_udp_fips_peer_run,
    );
}

async fn peer_policy_rejects_events_from_authenticated_udp_fips_peer_run() {
    let alice = Keys::generate();
    let bob = Keys::generate();
    let publisher = Keys::generate();
    let alice_npub = alice.public_key().to_bech32().expect("Alice npub");
    let bob_npub = bob.public_key().to_bech32().expect("Bob npub");
    let [alice_port, bob_port, _] = available_udp_ports();
    let alice_endpoint = endpoint(
        &alice,
        endpoint_config(alice_port, &[(&bob_npub, bob_port)]),
    )
    .await;
    let bob_endpoint = endpoint(
        &bob,
        endpoint_config(bob_port, &[(&alice_npub, alice_port)]),
    )
    .await;
    wait_connected(&alice_endpoint, &bob_npub).await;
    wait_connected(&bob_endpoint, &alice_npub).await;

    let tree_name = "releases/policy-test";
    let update_events = update_events(&publisher, tree_name);
    let alice_pubsub = start_pubsub(Arc::clone(&alice_endpoint), update_events.clone()).await;
    let bob_pubsub = ControlPubsubFipsRuntime::start_inner(
        Arc::clone(&bob_endpoint),
        NostrPubsubConfig {
            mode: NostrPubsubMode::Client,
            fanout: 8,
            max_hops: 4,
            max_event_bytes: CONTROL_PUBSUB_MAX_EVENT_BYTES,
        },
        Vec::new(),
        None,
        Some(Arc::new(RejectAllPeers)),
        Some(update_events),
        &[],
    )
    .await
    .expect("start policy-bound FIPS pubsub")
    .expect("FIPS pubsub enabled");
    wait_pubsub_transport_connected(&alice_pubsub).await;
    let root = signed_update_root(&publisher, tree_name, 1, "66");
    assert!(
        alice_pubsub
            .publish(root.clone())
            .await
            .expect("publish policy test event")
    );
    tokio::time::sleep(Duration::from_millis(750)).await;
    assert!(
        !bob_pubsub
            .events()
            .await
            .iter()
            .any(|event| event.id == root.id),
        "peer policy must reject stream records after FIPS authentication"
    );

    alice_pubsub.stop().await;
    bob_pubsub.stop().await;
    alice_endpoint.shutdown().await.expect("shutdown Alice");
    bob_endpoint.shutdown().await.expect("shutdown Bob");
}

#[test]
fn restarted_pubsub_resubscribes_after_tcp_fips_connection_loss() {
    run_async_test(
        "restarted-fips-pubsub",
        restarted_pubsub_resubscribes_after_connection_loss_run,
    );
}

async fn restarted_pubsub_resubscribes_after_connection_loss_run() {
    let alice = Keys::generate();
    let bob = Keys::generate();
    let publisher = Keys::generate();
    let alice_npub = alice.public_key().to_bech32().expect("Alice npub");
    let bob_npub = bob.public_key().to_bech32().expect("Bob npub");
    let [alice_port, bob_port, _] = available_udp_ports();
    let alice_config = endpoint_config(alice_port, &[(&bob_npub, bob_port)]);
    let alice_endpoint = endpoint(&alice, alice_config.clone()).await;
    let bob_endpoint = endpoint(
        &bob,
        endpoint_config(bob_port, &[(&alice_npub, alice_port)]),
    )
    .await;
    wait_connected(&alice_endpoint, &bob_npub).await;
    wait_connected(&bob_endpoint, &alice_npub).await;

    let tree_name = "releases/reconnect-test";
    let update_events = update_events(&publisher, tree_name);
    let alice_pubsub = start_pubsub(Arc::clone(&alice_endpoint), update_events.clone()).await;
    let bob_pubsub = start_pubsub(Arc::clone(&bob_endpoint), update_events.clone()).await;
    wait_pubsub_connected(&bob_pubsub).await;
    let first = signed_update_root(&publisher, tree_name, 1, "11");
    assert!(
        bob_pubsub
            .publish(first.clone())
            .await
            .expect("publish first update root")
    );
    wait_for_event(&alice_pubsub, first.id).await;

    alice_pubsub.stop().await;
    alice_endpoint
        .shutdown()
        .await
        .expect("stop Alice endpoint");
    drop(alice_endpoint);
    let restarted_alice_endpoint = endpoint(&alice, alice_config).await;
    wait_connected(&restarted_alice_endpoint, &bob_npub).await;
    wait_connected(&bob_endpoint, &alice_npub).await;
    let restarted_alice = start_pubsub(Arc::clone(&restarted_alice_endpoint), update_events).await;
    wait_pubsub_connected(&restarted_alice).await;
    let second = signed_update_root(&publisher, tree_name, 2, "22");
    assert!(
        bob_pubsub
            .publish(second.clone())
            .await
            .expect("publish across stale TCP/FIPS session")
    );
    wait_for_event(&restarted_alice, second.id).await;

    bob_pubsub.stop().await;
    restarted_alice.stop().await;
    restarted_alice_endpoint
        .shutdown()
        .await
        .expect("shutdown restarted Alice");
    bob_endpoint.shutdown().await.expect("shutdown Bob");
}

fn signed_update_root(
    publisher: &Keys,
    tree_name: &str,
    created_at: u64,
    hash_byte: &str,
) -> Event {
    EventBuilder::new(Kind::Custom(30_064), "")
        .tags([
            Tag::identifier(tree_name),
            Tag::custom(TagKind::Custom("l".into()), ["hashtree"]),
            Tag::custom(TagKind::Custom("hash".into()), [hash_byte.repeat(32)]),
        ])
        .custom_created_at(Timestamp::from(created_at))
        .sign_with_keys(publisher)
        .expect("signed update root")
}

fn signed_update_root_with_content(
    publisher: &Keys,
    tree_name: &str,
    created_at: u64,
    hash_byte: &str,
    content_bytes: usize,
) -> Event {
    EventBuilder::new(Kind::Custom(30_064), "x".repeat(content_bytes))
        .tags([
            Tag::identifier(tree_name),
            Tag::custom(TagKind::Custom("l".into()), ["hashtree"]),
            Tag::custom(TagKind::Custom("hash".into()), [hash_byte.repeat(32)]),
        ])
        .custom_created_at(Timestamp::from(created_at))
        .sign_with_keys(publisher)
        .expect("signed update root")
}

#[cfg(not(feature = "paid-exit"))]
#[test]
fn peerfinding_without_paid_exit_never_subscribes_to_or_retains_paid_offers() {
    let publisher = Keys::generate();
    let updates = update_events(&publisher, "releases/mobile-peerfinding");
    let offer = EventBuilder::new(Kind::Custom(PAID_EXIT_OFFER_KIND), "offer")
        .sign_with_keys(&publisher)
        .unwrap();
    for filter in relay_subscription_filters(&peer_rating_filter(&publisher), &updates, &[])
        .into_iter()
        .chain(fips_subscription_filters(
            &peer_rating_filter(&publisher),
            &updates,
        ))
    {
        assert!(!filter.match_event(&offer, MatchEventOptions::new()));
    }
    assert!(!is_control_event(&offer, &updates));
    let mut store = ControlEventStore::load(None, updates).unwrap();
    assert!(!store.insert(offer).unwrap());
    assert!(store.snapshot().is_empty());
}

#[test]
fn subscriptions_do_not_request_untrusted_machine_ratings() {
    let owner = Keys::generate();
    let stranger = Keys::generate();
    let updates = update_events(&owner, "releases/rating-scope");
    let rating = EventBuilder::new(Kind::Custom(RATING_FACT_KIND), "")
        .tag(Tag::custom(TagKind::Custom("i".into()), ["fips.peer"]))
        .sign_with_keys(&stranger)
        .unwrap();
    let own_rating = EventBuilder::new(Kind::Custom(RATING_FACT_KIND), "")
        .tag(Tag::custom(TagKind::Custom("i".into()), ["fips.peer"]))
        .sign_with_keys(&owner)
        .unwrap();
    let exit_rating = EventBuilder::new(Kind::Custom(RATING_FACT_KIND), "")
        .tag(Tag::custom(TagKind::Custom("i".into()), ["vpn.exit"]))
        .sign_with_keys(&stranger)
        .unwrap();
    for filters in [
        relay_subscription_filters(&peer_rating_filter(&owner), &updates, &[]),
        fips_subscription_filters(&peer_rating_filter(&owner), &updates),
    ] {
        for kind in [Kind::ContactList, Kind::MuteList] {
            let own = EventBuilder::new(kind, "").sign_with_keys(&owner).unwrap();
            let other = EventBuilder::new(kind, "")
                .sign_with_keys(&stranger)
                .unwrap();
            assert!(
                filters
                    .iter()
                    .any(|f| f.match_event(&own, MatchEventOptions::new()))
            );
            assert!(
                filters
                    .iter()
                    .all(|f| !f.match_event(&other, MatchEventOptions::new()))
            );
        }
        assert!(
            filters
                .iter()
                .any(|f| f.match_event(&own_rating, MatchEventOptions::new()))
        );
        assert_eq!(
            filters
                .iter()
                .any(|f| f.match_event(&exit_rating, MatchEventOptions::new())),
            cfg!(feature = "paid-exit")
        );
        assert!(
            filters
                .iter()
                .all(|f| !f.match_event(&rating, MatchEventOptions::new())),
            "untrusted machine ratings must not be requested from relays or peers"
        );
    }
}
