/// Keep an open, targeted subscription as the owner's graph changes. A quiet
/// relay or EOSE is never treated as proof that a profile does not exist.
async fn sync_provider_profiles(
    relay: &mut Option<RelayProvider>,
    events: &Arc<Mutex<ControlEventStore>>,
) {
    let Some(relay) = relay else { return };
    let (root, snapshot) = {
        let store = events.lock().await;
        let Some(root) = store.graph_root else { return };
        (root.to_hex(), store.snapshot())
    };
    let mut inputs = snapshot
        .iter()
        .filter(|e| matches!(e.kind, Kind::ContactList | Kind::MuteList))
        .map(|e| e.id)
        .collect::<Vec<_>>();
    inputs.sort();
    if relay.profile_inputs.as_ref() == Some(&inputs) {
        return;
    }
    let graph = crate::paid_provider_names::provider_name_graph(&root, &snapshot, now_ms() / 1_000);
    let mut authors = (0..=2)
        .flat_map(|distance| graph.get_users_by_follow_distance(distance))
        .filter(|key| !graph.is_overmuted(key, 1.0))
        .filter_map(|key| PublicKey::parse(&key).ok())
        .collect::<Vec<_>>();
    authors.sort();
    authors.dedup();
    authors.retain(|key| key.to_hex() != root);
    authors.truncate(511);
    if let Ok(root) = PublicKey::parse(&root) {
        authors.insert(0, root);
    }
    let graph_authors = authors
        .iter()
        .filter(|key| graph.get_follow_distance(&key.to_hex()) <= 1)
        .copied()
        .collect::<Vec<_>>();
    if authors == relay.profile_authors && graph_authors == relay.profile_graph_authors {
        relay.profile_inputs = Some(inputs);
        return;
    }
    let filters = vec![
        Filter::new()
            .authors(authors.iter().copied())
            .kind(Kind::Metadata)
            .limit(authors.len()),
        Filter::new()
            .authors(graph_authors.iter().copied())
            .kinds([Kind::ContactList, Kind::MuteList])
            .limit(graph_authors.len() * 2),
    ];
    match relay
        .bus
        .subscribe_with_admission(filters, Arc::clone(&relay.ingress))
        .await
    {
        Ok(subscription) => {
            relay.profile_subscription = Some(subscription);
            relay.profile_authors = authors;
            relay.profile_graph_authors = graph_authors;
            relay.profile_inputs = Some(inputs);
        }
        Err(error) => tracing::debug!(%error, "provider profile subscription deferred"),
    }
}
