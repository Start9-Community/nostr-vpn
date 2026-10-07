struct RelayProvider {
    bus: Arc<RelayEventBus>,
    notifications: mpsc::Receiver<QueryEvent>,
    _subscription: Box<dyn NostrEventSubscription>,
    #[cfg(feature = "paid-exit")]
    notification_tx: mpsc::Sender<QueryEvent>,
    #[cfg(feature = "paid-exit")]
    profile_subscription: Option<Box<dyn NostrEventSubscription>>,
    #[cfg(feature = "paid-exit")]
    profile_authors: Vec<PublicKey>,
    #[cfg(feature = "paid-exit")]
    profile_graph_authors: Vec<PublicKey>,
    #[cfg(feature = "paid-exit")]
    profile_inputs: Option<Vec<nostr_sdk::prelude::EventId>>,
}

impl RelayProvider {
    async fn start(
        mode: NostrPubsubMode,
        relays: Vec<String>,
        update_events: &UpdateEventCache,
        target_advert_authors: &[PublicKey],
        graph_root: PublicKey,
    ) -> Result<Option<Self>> {
        if mode != NostrPubsubMode::Relay || relays.is_empty() {
            return Ok(None);
        }
        let bus = Arc::new(
            RelayEventBus::new(relays, RELAY_QUERY_TIMEOUT)
                .await
                .context("failed to start configured Nostr pubsub relay provider")?,
        );
        let (notification_tx, notifications) = mpsc::channel(RELAY_REPLAY_LIMIT * 5);
        let ingress_tx = notification_tx.clone();
        let subscription = NostrEventSubscriber::subscribe(
            bus.as_ref(),
            {
                let mut filters = relay_subscription_filters(update_events, target_advert_authors);
                filters.push(exit_graph_filter(graph_root));
                filters
            },
            Arc::new(move |event| {
                if ingress_tx.try_send(event).is_err() {
                    tracing::warn!("dropping control pubsub relay event because the bounded ingress queue is full");
                }
            }),
        )
        .await
        .context("failed to subscribe through configured Nostr pubsub relay provider")?;
        Ok(Some(Self {
            bus,
            notifications,
            _subscription: subscription,
            #[cfg(feature = "paid-exit")]
            notification_tx,
            #[cfg(feature = "paid-exit")]
            profile_subscription: None,
            #[cfg(feature = "paid-exit")]
            profile_authors: Vec::new(),
            #[cfg(feature = "paid-exit")]
            profile_graph_authors: Vec::new(),
            #[cfg(feature = "paid-exit")]
            profile_inputs: None,
        }))
    }
}
