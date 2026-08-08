async fn import_mobile_manual_paid_exit_offer(
    endpoint: Arc<FipsEndpoint>,
    provider: nostr_vpn_core::paid_routes::ManualPaidExitProvider,
    store_path: PathBuf,
) -> Result<()> {
    use nostr_sdk::prelude::{Filter, Kind, Timestamp};
    use nostr_vpn_core::paid_route_store::update_paid_route_store;
    use nostr_vpn_core::paid_routes::{
        PAID_ROUTE_OFFER_KIND, PAID_ROUTE_OFFER_TTL_SECS, SignedPaidRouteOffer,
    };
    use nostr_pubsub_fips::{FipsPubsubClient, FipsPubsubClientOptions};

    let seller = PublicKey::parse(&provider.npub).context("invalid manual paid exit seller")?;
    let client = FipsPubsubClient::start(endpoint, FipsPubsubClientOptions::default())
        .await
        .context("failed to start mobile paid exit pubsub")?;
    let result = async {
        let since = unix_timestamp().saturating_sub(PAID_ROUTE_OFFER_TTL_SECS);
        let mut subscription = client
            .subscribe(vec![
                Filter::new()
                    .author(seller)
                    .kind(Kind::Custom(PAID_ROUTE_OFFER_KIND))
                    .since(Timestamp::from(since))
                    .limit(32),
            ])
            .await
            .context("failed to subscribe to the manual paid exit offer")?;

        while let Some(delivery) = subscription.recv().await {
            let signed = match SignedPaidRouteOffer::from_event(delivery.event.into_event()) {
                Ok(signed) if signed.is_live_at(unix_timestamp()) => signed,
                Ok(_) => continue,
                Err(error) => {
                    tracing::warn!(?error, "mobile: rejected invalid paid exit offer");
                    continue;
                }
            };
            let offer = signed.offer()?;
            if let Err(error) = provider.accepts(&offer) {
                tracing::warn!(?error, "mobile: paid exit offer violates provider link limits");
                continue;
            }

            let now_unix = unix_timestamp();
            update_paid_route_store(&store_path, |store| {
                store.upsert_signed_offer(signed, Vec::new(), now_unix)?;
                Ok(())
            })?;
            return Ok(());
        }
        Err(anyhow!("manual paid exit offer subscription closed"))
    }
    .await;
    client.shutdown().await;
    result
}
