use super::*;

pub(super) async fn fund_automatic_paid_exit(
    app: &AppConfig,
    config_path: &Path,
    session_id: &str,
    now_unix: u64,
) -> Result<StreamingRoutePaymentEnvelope> {
    if !PaidExitAutomaticBuyer::enabled(app) {
        return Err(anyhow!(
            "automatic paid exit funding cancelled by internet mode"
        ));
    }
    let store_path = paid_route_store_file_path(config_path);
    let mut store = load_paid_route_store(&store_path)?;
    let session = store
        .sessions
        .get(session_id)
        .cloned()
        .ok_or_else(|| anyhow!("automatic paid exit session {session_id} does not exist"))?;
    let lease = store
        .leases
        .get(&session.session.lease_id)
        .cloned()
        .ok_or_else(|| anyhow!("automatic paid exit session has no lease"))?;
    let channel = store
        .channels
        .get(&session.session.payment.channel_id)
        .cloned()
        .ok_or_else(|| anyhow!("automatic paid exit session has no channel"))?;
    let quote = store
        .quotes
        .get(&lease.lease.quote_id)
        .cloned()
        .ok_or_else(|| anyhow!("automatic paid exit session has no quote"))?;
    let opened = open_streaming_route_cashu_spilman_channel_from_wallet(
        &paid_exit_wallet_data_dir(config_path),
        StreamingRouteOpenCashuSpilmanChannelFromWalletRequest {
            mint_url: channel.mint_url,
            receiver_pubkey_hex: quote.quote.receiver_pubkey_hex,
            capacity_sat: session.session.payment.capacity_sat,
            expiry_unix: channel.expires_at_unix,
            max_amount_per_output: 0,
            unit: "sat".to_string(),
            opening_paid_msat: 0,
            keyset_id: None,
            keyset_info_json: None,
        },
    )
    .await?;
    store.attach_buyer_spilman_channel(AttachPaidRouteBuyerSpilmanChannelRequest {
        session_id: session_id.to_string(),
        channel_id: opened.channel.channel_id.clone(),
        cashu_unit: opened.channel.unit.clone(),
        capacity_sat: opened.channel.capacity_sat,
        paid_msat: Some(opened.channel.opening_paid_msat),
        payment: opened.channel.payment.clone(),
        now_unix,
    })?;
    let buyer_npub = app
        .nostr_keys()?
        .public_key()
        .to_bech32()
        .context("failed to encode automatic paid exit buyer npub")?;
    let payment =
        store.build_buyer_payment_envelope(BuildPaidRouteBuyerPaymentEnvelopeRequest {
            session_id: session_id.to_string(),
            buyer_npub,
            kind: BuildPaidRouteBuyerPaymentEnvelopeKind::ChannelOpen,
            payment: opened.channel.payment,
            delivered_units: None,
            paid_msat: Some(opened.channel.opening_paid_msat),
            now_unix,
        })?;
    write_paid_route_store(&store_path, &store)?;
    Ok(payment.envelope)
}

pub(crate) async fn finalize_automatic_paid_exit(
    automatic: &PaidExitAutomaticBuyer,
    runtime: &crate::fips_private_mesh::FipsPrivateTunnelRuntime,
    app: &AppConfig,
    config_path: &Path,
    now_unix: u64,
) -> Result<()> {
    let Some(candidate) = automatic.candidate.as_ref() else {
        return Ok(());
    };
    drain_paid_exit_buyer_usage(runtime, config_path, &candidate.seller_pubkey, now_unix)?;
    if candidate.funded {
        let _client_store_guard = try_lock_paid_exit_cashu_client_store(config_path)
            .ok_or_else(|| anyhow!("Cashu channel storage is busy; retry finalization"))?;
        let wallet_data_dir = paid_exit_wallet_data_dir(config_path);
        let signer =
            FileSpilmanPaymentSigner::load(&wallet_data_dir).map_err(|error| anyhow!("{error}"))?;
        let store_path = paid_route_store_file_path(config_path);
        let mut store = load_paid_route_store(&store_path)?;
        let result = paid_exit_settle_with_signer(PaidExitSettleRequest {
            app,
            config_path,
            store: &mut store,
            signer: &signer,
            session_id: &candidate.session_id,
            dry_run: false,
            wallet_data_dir: &wallet_data_dir,
            now_unix,
        })?;
        if result.persisted && result.payment.changed {
            write_paid_route_store(&store_path, &store)?;
        }
        let flushed = flush_paid_exit_payment_outbox(runtime, config_path).await;
        if flushed.errors > 0 {
            eprintln!(
                "paid-exit: automatic seller finalization queued with {} send error(s)",
                flushed.errors
            );
        }
    }
    Ok(())
}

pub(super) fn suspend_automatic_paid_exit(
    automatic: &PaidExitAutomaticBuyer,
    runtime: &crate::fips_private_mesh::FipsPrivateTunnelRuntime,
    config_path: &Path,
    now_unix: u64,
) -> Result<()> {
    let Some(candidate) = automatic.candidate.as_ref() else {
        return Ok(());
    };
    drain_paid_exit_buyer_usage(runtime, config_path, &candidate.seller_pubkey, now_unix)?;
    Ok(())
}

pub(super) fn queue_recovered_automatic_channel_open(
    app: &AppConfig,
    config_path: &Path,
    store: &mut PaidRouteStore,
    session_id: &str,
    now_unix: u64,
) -> Result<()> {
    let signer = FileSpilmanPaymentSigner::load(&paid_exit_wallet_data_dir(config_path))
        .map_err(|error| anyhow!("{error}"))?;
    let buyer_npub = app
        .nostr_keys()?
        .public_key()
        .to_bech32()
        .context("failed to encode automatic paid exit buyer npub")?;
    let payment = store.build_buyer_signed_payment_envelope(
        &signer,
        BuildPaidRouteBuyerSignedPaymentEnvelopeRequest {
            session_id: session_id.to_string(),
            buyer_npub,
            kind: BuildPaidRouteBuyerPaymentEnvelopeKind::ChannelOpen,
            delivered_units: None,
            paid_msat: None,
            now_unix,
        },
    )?;
    if payment.changed {
        write_paid_route_store(&paid_route_store_file_path(config_path), store)?;
    }
    queue_paid_exit_payment(app, config_path, &payment.envelope)?;
    Ok(())
}

fn drain_paid_exit_buyer_usage(
    runtime: &crate::fips_private_mesh::FipsPrivateTunnelRuntime,
    config_path: &Path,
    seller_pubkey: &str,
    now_unix: u64,
) -> Result<PaidRouteUsage> {
    let delta = runtime.drain_paid_route_usage(seller_pubkey)?;
    if delta.is_empty() {
        return Ok(delta);
    }
    let store_path = paid_route_store_file_path(config_path);
    let mut store = load_paid_route_store(&store_path)?;
    let changed = store
        .record_buyer_usage(RecordPaidRouteBuyerUsageRequest {
            seller_pubkey: seller_pubkey.to_string(),
            usage_delta: delta.clone(),
            now_unix,
        })?
        .is_some_and(|result| result.changed);
    if changed {
        write_paid_route_store(&store_path, &store)?;
    }
    Ok(delta)
}
