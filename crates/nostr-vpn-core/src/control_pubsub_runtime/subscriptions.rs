fn fips_subscription_filters(
    peer_ratings: &Filter,
    #[cfg(feature = "updater")] update_events: &UpdateEventCache,
) -> Vec<Filter> {
    #[cfg_attr(
        not(any(feature = "updater", feature = "paid-exit")),
        allow(unused_mut)
    )]
    let mut filters = rating_subscription_filters(peer_ratings, FIPS_REPLAY_LIMIT);
    #[cfg(feature = "paid-exit")]
    filters.push(
        Filter::new()
            .kind(Kind::Custom(PAID_EXIT_OFFER_KIND))
            .limit(FIPS_REPLAY_LIMIT),
    );
    #[cfg(feature = "updater")]
    if update_events.filter().kinds.is_some() {
        filters.push(update_events.filter().clone().limit(FIPS_REPLAY_LIMIT));
    }
    filters
}

fn rating_subscription_filters(peer_ratings: &Filter, replay_limit: usize) -> Vec<Filter> {
    vec![
        peer_ratings.clone().limit(replay_limit),
        #[cfg(feature = "paid-exit")]
        Filter::new()
            .kind(Kind::Custom(RATING_FACT_KIND))
            .custom_tag(
                nostr_sdk::prelude::SingleLetterTag::lowercase(nostr_sdk::prelude::Alphabet::I),
                crate::paid_route_ratings::EXIT_RATING_SCOPE,
            )
            .limit(replay_limit),
    ]
}

fn relay_advert_filters(
    nostr_advert_app: Option<&str>,
    target_peer_npubs: &[String],
) -> Vec<Filter> {
    // Mirror FIPS's advert_d_tag normalization. The endpoint's LAN scope can
    // differ from this public app tag, including for private Nostr VPN meshes.
    // Older public constructors do not know the Nostr app and retain their
    // broad query. Never infer it from endpoint metadata or a default value.
    let mut advert = Filter::new().kind(Kind::Custom(FIPS_PEER_ADVERT_KIND));
    if let Some(app) = nostr_advert_app {
        let app = app.trim();
        let identifier = if app.is_empty() {
            fips_core::discovery::nostr::ADVERT_IDENTIFIER
        } else {
            app
        };
        advert = advert.identifier(identifier);
    }
    let target_advert_authors = target_peer_npubs
        .iter()
        .filter_map(|peer| PublicKey::parse(peer).ok())
        .collect::<Vec<_>>();
    let mut filters = Vec::with_capacity(2);
    if !target_advert_authors.is_empty() {
        filters.push(
            advert
                .clone()
                .authors(target_advert_authors.iter().copied())
                .limit(target_advert_authors.len().min(MAX_PUBSUB_PEERS)),
        );
    }
    filters.push(advert.limit(RELAY_REPLAY_LIMIT));
    filters
}

fn relay_subscription_filters(
    peer_ratings: &Filter,
    #[cfg(feature = "updater")] update_events: &UpdateEventCache,
    mut filters: Vec<Filter>,
) -> Vec<Filter> {
    #[cfg(feature = "paid-exit")]
    filters.push(
        Filter::new()
            .kind(Kind::Custom(PAID_EXIT_OFFER_KIND))
            .limit(RELAY_REPLAY_LIMIT),
    );
    #[cfg(feature = "updater")]
    filters.push(update_events.filter().clone().limit(RELAY_REPLAY_LIMIT));
    filters.extend(rating_subscription_filters(
        peer_ratings,
        RELAY_REPLAY_LIMIT,
    ));
    filters
}

#[cfg(test)]
mod advert_scope_tests {
    use super::*;
    use nostr_pubsub::MatchEventOptions;
    use nostr_sdk::prelude::{EventBuilder, Tag, TagKind, Timestamp};

    fn advert(keys: &Keys, identifier: Option<&str>, protocol: &str, created_at: u64) -> Event {
        let mut tags = vec![Tag::custom(TagKind::Custom("protocol".into()), [protocol])];
        if let Some(identifier) = identifier {
            tags.push(Tag::identifier(identifier));
        }
        EventBuilder::new(
            Kind::Custom(FIPS_PEER_ADVERT_KIND),
            "unchanged advert payload",
        )
        .tags(tags)
        .custom_created_at(Timestamp::from(created_at))
        .sign_with_keys(keys)
        .unwrap()
    }

    #[test]
    fn relay_advert_scope_uses_configured_app_and_core_identifier_normalization() {
        let owner = Keys::generate();
        for (configured, identifier) in [
            ("fips-overlay-v1", "fips-overlay-v1"),
            ("custom-overlay", "custom-overlay"),
            (" custom-overlay ", "custom-overlay"),
            ("", "fips-overlay-v1"),
            ("   ", "fips-overlay-v1"),
        ] {
            let filters = relay_advert_filters(Some(configured), &[owner.public_key().to_hex()]);
            let matching = advert(&owner, Some(identifier), configured, 1);
            let foreign = advert(&owner, Some("another-overlay"), "another-overlay", 2);
            let missing = advert(&owner, None, configured, 3);
            for filter in filters {
                assert!(filter.match_event(&matching, MatchEventOptions::new()));
                assert!(!filter.match_event(&foreign, MatchEventOptions::new()));
                assert!(!filter.match_event(&missing, MatchEventOptions::new()));
            }
        }
    }

    #[test]
    fn relay_advert_scope_preserves_targeted_replay_and_public_admission() {
        let target = Keys::generate();
        let ambient = Keys::generate();
        let filters = relay_advert_filters(Some("custom-overlay"), &[target.public_key().to_hex()]);
        let old_target = advert(&target, Some("custom-overlay"), "custom-overlay", 1);
        let new_ambient = advert(&ambient, Some("custom-overlay"), "custom-overlay", 2);
        assert_eq!(filters.len(), 2);
        assert_eq!(filters[0].limit, Some(1));
        assert_eq!(filters[1].limit, Some(RELAY_REPLAY_LIMIT));
        assert!(filters[0].match_event(&old_target, MatchEventOptions::new()));
        assert!(!filters[0].match_event(&new_ambient, MatchEventOptions::new()));
        assert!(filters[1].match_event(&old_target, MatchEventOptions::new()));
        assert!(filters[1].match_event(&new_ambient, MatchEventOptions::new()));
        assert!(filters[1].authors.is_none());
        // Only the query's app identifier is scoped. Existing core validation
        // still owns protocol/schema checks; no version or capability filter.
        let other_protocol = advert(&ambient, Some("custom-overlay"), "other-protocol", 3);
        assert!(filters[1].match_event(&other_protocol, MatchEventOptions::new()));
    }

    #[test]
    fn relay_advert_scope_keeps_unknown_public_api_scopes_broad() {
        let owner = Keys::generate();
        let filters = relay_advert_filters(None, &[owner.public_key().to_hex()]);
        for event in [
            advert(&owner, Some("fips-overlay-v1"), "fips-overlay-v1", 1),
            advert(&owner, Some("custom-overlay"), "custom-overlay", 2),
            advert(&owner, None, "custom-overlay", 3),
        ] {
            assert!(
                filters
                    .iter()
                    .all(|filter| filter.match_event(&event, MatchEventOptions::new()))
            );
        }
    }

    #[test]
    fn relay_advert_scope_leaves_other_control_filters_unchanged() {
        let owner = Keys::generate();
        let ratings = nostr_pubsub_social_graph::PeerReputation::new(
            &owner.public_key().to_hex(),
            Default::default(),
        )
        .unwrap()
        .0
        .rating_filter()
        .unwrap();
        #[cfg(feature = "updater")]
        let updates = {
            use nostr_sdk::prelude::ToBech32;
            UpdateEventCache::new(&crate::updater::UpdateRef {
                npub: owner.public_key().to_bech32().unwrap(),
                tree_name: "releases/filter-contract".into(),
                path: Some("latest".into()),
            })
            .unwrap()
        };
        let subscriptions = |scope| {
            relay_subscription_filters(
                &ratings,
                #[cfg(feature = "updater")]
                &updates,
                relay_advert_filters(scope, &[owner.public_key().to_hex()]),
            )
        };
        let broad = subscriptions(None);
        let scoped = subscriptions(Some("custom-overlay"));
        assert_eq!(&scoped[2..], &broad[2..]);
        let graph = exit_graph_filter(owner.public_key());
        let contacts = EventBuilder::new(Kind::ContactList, "")
            .sign_with_keys(&owner)
            .unwrap();
        assert!(graph.match_event(&contacts, MatchEventOptions::new()));
        assert!(graph.generic_tags.is_empty());
    }
}

fn is_control_event(
    event: &Event,
    #[cfg(feature = "updater")] update_events: &UpdateEventCache,
) -> bool {
    if u16::from(event.kind) == PAID_EXIT_OFFER_KIND {
        return cfg!(feature = "paid-exit");
    }
    if matches!(
        u16::from(event.kind),
        FIPS_PEER_ADVERT_KIND | RATING_FACT_KIND | 0 | 3 | 10_000
    ) {
        return true;
    }
    #[cfg(feature = "updater")]
    {
        update_events
            .filter()
            .match_event(event, MatchEventOptions::new())
    }
    #[cfg(not(feature = "updater"))]
    {
        false
    }
}

#[cfg(all(test, not(feature = "updater")))]
#[test]
fn control_pubsub_without_updater_retains_discovery_and_rejects_update_events() {
    use nostr_sdk::prelude::EventBuilder;

    let keys = Keys::generate();
    let ratings = nostr_pubsub_social_graph::PeerReputation::new(
        &keys.public_key().to_hex(),
        Default::default(),
    )
    .unwrap()
    .0
    .rating_filter()
    .unwrap();
    let advert = EventBuilder::new(Kind::Custom(FIPS_PEER_ADVERT_KIND), "peer discovery")
        .sign_with_keys(&keys)
        .expect("signed peer advert");
    let update = EventBuilder::new(Kind::Custom(30_078), "release update")
        .sign_with_keys(&keys)
        .expect("signed update event");
    let mut store = ControlEventStore::load(None).expect("control event store");
    assert!(verify_control_event(advert.clone()).is_ok());
    assert!(store.insert(advert.clone()).expect("retain peer advert"));
    assert!(verify_control_event(update.clone()).is_err());
    assert!(!store.insert(update).expect("reject update event"));
    assert_eq!(store.snapshot(), vec![advert]);

    let unrelated = EventBuilder::new(Kind::Custom(RATING_FACT_KIND), "")
        .tag(nostr_sdk::prelude::Tag::custom(
            nostr_sdk::prelude::TagKind::Custom("i".into()),
            ["fips.peer"],
        ))
        .sign_with_keys(&Keys::generate())
        .unwrap();
    for filter in relay_subscription_filters(&ratings, relay_advert_filters(None, &[]))
        .into_iter()
        .chain(fips_subscription_filters(&ratings))
    {
        assert!(!filter.match_event(&unrelated, nostr_pubsub::MatchEventOptions::new()));
    }

    assert!(
        relay_subscription_filters(&ratings, relay_advert_filters(None, &[]))
            .iter()
            .all(|filter| filter.kinds.is_some())
    );
    assert!(
        fips_subscription_filters(&ratings)
            .iter()
            .all(|filter| filter.kinds.is_some())
    );
}

// Keep independent replay budgets for ratings and owner graph state. Combining
// them can hide an older contact/mute list behind a busy owner's recent ratings.
fn exit_graph_filter(root: PublicKey) -> Filter {
    Filter::new()
        .author(root)
        .kinds([Kind::ContactList, Kind::MuteList])
        .limit(2)
}

#[derive(Default)]
struct FipsSubscriptionState {
    subscription: Option<FipsPubsubSubscription>,
    owner_subscription: Option<FipsPubsubSubscription>,
}

impl FipsSubscriptionState {
    async fn recv(&mut self) -> Option<QueryEvent> {
        tokio::select! {
            event = fips_notification(&mut self.subscription) => event,
            event = fips_notification(&mut self.owner_subscription) => event,
        }
    }
}

async fn sync_fips_subscription(
    endpoint: &FipsEndpoint,
    fips_pubsub: &FipsPubsubClient,
    peer_policy: &dyn MeshPeerPolicy,
    events: &Arc<Mutex<ControlEventStore>>,
    rating_filter: &Filter,
    #[cfg(feature = "updater")] update_events: &UpdateEventCache,
    state: &mut FipsSubscriptionState,
) {
    // FIPS replays an active REQ onto newly connected/replacement links.
    // Recreating it on peer churn would replay retained events to all peers.
    if state.subscription.is_some() && state.owner_subscription.is_some() {
        return;
    }
    let peers = connected_peers(endpoint, peer_policy).await;
    if peers.is_empty() {
        return;
    }
    // Each stream owns its admitted bodies. A terminal ratings stream must
    // not discard owner graph records waiting on the other stream.
    if state.owner_subscription.is_none() {
        let Ok(root) = PublicKey::parse(endpoint.npub()) else {
            return;
        };
        match fips_pubsub.subscribe(vec![exit_graph_filter(root)]).await {
            Ok(subscription) => state.owner_subscription = Some(subscription),
            Err(error) => {
                tracing::debug!(%error, "owner graph subscription deferred");
                return;
            }
        }
    }
    if !should_create_fips_subscription(state.subscription.is_some(), peers.len()) {
        return;
    }
    let filters = fips_subscription_filters(
        rating_filter,
        #[cfg(feature = "updater")]
        update_events,
    );
    match fips_pubsub.subscribe(filters).await {
        Ok(subscription) => state.subscription = Some(subscription),
        Err(error) => {
            tracing::debug!(%error, "standard FIPS pubsub subscription deferred");
            return;
        }
    }

    for event in bounded_fips_replay(events.lock().await.snapshot(), rating_filter) {
        let event_id = event.id;
        let Ok(event) = VerifiedEvent::try_from(event) else {
            continue;
        };
        if let Err(error) = fips_pubsub
            .publish(event, EventSource::local_index(endpoint.npub().to_string()))
            .await
        {
            tracing::debug!(%error, %event_id, "stored FIPS pubsub replay deferred");
        }
    }
}

async fn fips_notification(
    subscription: &mut Option<FipsPubsubSubscription>,
) -> Option<QueryEvent> {
    let Some(active) = subscription.as_mut() else {
        return std::future::pending().await;
    };
    let delivery = active.recv().await;
    if delivery.is_none() {
        // Terminal subscriptions drain their admitted bodies before EOF.
        // Disable this select branch until the existing maintenance tick can
        // restore live delivery; reopening is not a missed-history recovery.
        subscription.take();
    }
    delivery
}
