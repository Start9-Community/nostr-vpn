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
    // The default policy's sole rating authority is the local owner. Share its
    // signed state filter with contacts/mutes to stay within legacy peers' four
    // filters per REQ while keeping unrelated machine ratings off the wire.
    let mut owner_state = peer_ratings.clone();
    owner_state.generic_tags.clear();
    vec![
        owner_state
            .kinds([Kind::ContactList, Kind::MuteList])
            .limit(replay_limit),
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

fn relay_subscription_filters(
    peer_ratings: &Filter,
    #[cfg(feature = "updater")] update_events: &UpdateEventCache,
    target_advert_authors: &[PublicKey],
) -> Vec<Filter> {
    let mut filters = Vec::with_capacity(5);
    if !target_advert_authors.is_empty() {
        filters.push(
            Filter::new()
                .kind(Kind::Custom(FIPS_PEER_ADVERT_KIND))
                .authors(target_advert_authors.iter().copied())
                .limit(target_advert_authors.len().min(MAX_PUBSUB_PEERS)),
        );
    }
    filters.extend([
        Filter::new()
            .kind(Kind::Custom(FIPS_PEER_ADVERT_KIND))
            .limit(RELAY_REPLAY_LIMIT),
        #[cfg(feature = "paid-exit")]
        Filter::new()
            .kind(Kind::Custom(PAID_EXIT_OFFER_KIND))
            .limit(RELAY_REPLAY_LIMIT),
        #[cfg(feature = "updater")]
        update_events.filter().clone().limit(RELAY_REPLAY_LIMIT),
    ]);
    filters.extend(rating_subscription_filters(
        peer_ratings,
        RELAY_REPLAY_LIMIT,
    ));
    filters
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
    for filter in relay_subscription_filters(&ratings, &[])
        .into_iter()
        .chain(fips_subscription_filters(&ratings))
    {
        assert!(!filter.match_event(&unrelated, nostr_pubsub::MatchEventOptions::new()));
    }

    assert!(
        relay_subscription_filters(&ratings, &[])
            .iter()
            .all(|filter| filter.kinds.is_some())
    );
    assert!(
        fips_subscription_filters(&ratings)
            .iter()
            .all(|filter| filter.kinds.is_some())
    );
}
