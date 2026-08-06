use super::*;
use nostr_vpn_core::paid_routes::PaidRouteUsage;

#[path = "paid_exit/automatic.rs"]
mod automatic;
pub(crate) use automatic::*;
#[path = "paid_exit/refunds.rs"]
mod refunds;
pub(in crate::session_runtime) use refunds::PaidExitBuyerRefundRuntime;

pub(super) const PAID_EXIT_DAEMON_STREAM_PAYMENT_MIN_INCREMENT_MSAT: u64 = 1;
pub(super) const PAID_EXIT_DAEMON_STREAM_PAYMENT_LIMIT: usize = 4;
pub(super) const PAID_EXIT_SESSION_OPEN_RETRY_SECS: u64 = 5;
pub(super) const PAID_EXIT_OFFER_REFRESH_SECS: u64 =
    nostr_vpn_core::paid_routes::PAID_ROUTE_OFFER_TTL_SECS / 4;

pub(crate) fn refresh_paid_exit_offer_for_daemon(
    app: &AppConfig,
    config_path: &Path,
    now_unix: u64,
) -> Result<bool> {
    if !app.paid_exit.enabled {
        return Ok(false);
    }
    let local =
        build_local_paid_exit_offer(app, config_path, &default_paid_exit_offer_id(), now_unix)?;
    Ok(
        publish_paid_exit_offer_pubsub(app, config_path, &local.signed)?["nostr_pubsub_queued"]
            .as_bool()
            .unwrap_or_default(),
    )
}

#[derive(Debug, Default)]
pub(super) struct PaidExitApplySessionOpensResult {
    pub(super) received_count: usize,
    pub(super) applied_count: usize,
    pub(super) error_count: usize,
    pub(super) changed: bool,
    pub(super) acknowledgments: Vec<(String, String)>,
}

pub(super) async fn send_selected_paid_exit_session_open(
    runtime: &crate::fips_private_mesh::FipsPrivateTunnelRuntime,
    app: &AppConfig,
    config_path: &Path,
    now_unix: u64,
) -> Result<bool> {
    let Some(seller_pubkey) = app.public_paid_exit_node_pubkey_hex() else {
        return Ok(false);
    };
    let buyer_npub = app
        .nostr_keys()?
        .public_key()
        .to_bech32()
        .context("failed to encode paid route buyer npub")?;
    let buyer_tunnel_ip = derive_mesh_tunnel_ip(
        &app.effective_network_id(),
        &app.nostr_keys()?.public_key().to_hex(),
    )
    .ok_or_else(|| anyhow!("failed to derive paid route buyer tunnel IP"))?;
    let store = load_paid_route_store(&paid_route_store_file_path(config_path))?;
    let Some(open) = store.buyer_session_open_for_seller(
        &seller_pubkey,
        &buyer_npub,
        &buyer_tunnel_ip,
        now_unix,
    )?
    else {
        return Ok(false);
    };
    runtime
        .send_paid_route_session_open(&seller_pubkey, open)
        .await?;
    Ok(true)
}

pub(super) fn apply_paid_exit_session_opens(
    app: &AppConfig,
    config_path: &Path,
    opens: Vec<(String, PaidRouteSessionOpen)>,
) -> Result<PaidExitApplySessionOpensResult> {
    if opens.is_empty() {
        return Ok(PaidExitApplySessionOpensResult::default());
    }
    if !app.paid_exit.enabled {
        return Err(anyhow!("paid exit selling is disabled"));
    }
    let seller_npub = app
        .nostr_keys()?
        .public_key()
        .to_bech32()
        .context("failed to encode paid route seller npub")?;
    let store_path = paid_route_store_file_path(config_path);
    let mut store = load_paid_route_store(&store_path)?;
    let mut result = PaidExitApplySessionOpensResult {
        received_count: opens.len(),
        ..PaidExitApplySessionOpensResult::default()
    };
    for (buyer_pubkey, open) in opens {
        match store.apply_seller_session_open(ApplyPaidRouteSellerSessionOpenRequest {
            open,
            authenticated_buyer_pubkey: buyer_pubkey.clone(),
            seller_npub: seller_npub.clone(),
            config: app.paid_exit.clone(),
            now_unix: unix_timestamp(),
        }) {
            Ok(applied) => {
                result.applied_count += 1;
                result.changed |= applied.changed;
                result
                    .acknowledgments
                    .push((buyer_pubkey, applied.lease_id));
            }
            Err(error) => {
                result.error_count += 1;
                eprintln!(
                    "paid-exit: rejected authenticated free-probe open from {buyer_pubkey}: {error}"
                );
            }
        }
    }
    if result.changed {
        write_paid_route_store(&store_path, &store)?;
    }
    Ok(result)
}

pub(super) struct PaidExitMeshEventContext<'a> {
    pub(super) runtime: &'a mut crate::fips_private_mesh::FipsPrivateTunnelRuntime,
    pub(super) app: &'a AppConfig,
    pub(super) config_path: &'a Path,
    pub(super) network_id: &'a str,
    pub(super) underlay_interface: Option<&'a str>,
    pub(super) underlay_interface_mtu: Option<u32>,
    pub(super) own_pubkey: Option<&'a str>,
    pub(super) vpn_status: &'a mut String,
    pub(super) spilman_receiver: Option<&'a FileSpilmanPaymentReceiver>,
    pub(super) spilman_receiver_error: Option<&'a str>,
}

pub(super) async fn handle_paid_exit_mesh_events(
    context: PaidExitMeshEventContext<'_>,
    drained: &mut DrainedFipsMeshEvents,
) {
    let PaidExitMeshEventContext {
        runtime,
        app,
        config_path,
        network_id,
        underlay_interface,
        underlay_interface_mtu,
        own_pubkey,
        vpn_status,
        spilman_receiver,
        spilman_receiver_error,
    } = context;

    let session_opens = std::mem::take(&mut drained.paid_route_session_opens);
    if !session_opens.is_empty() {
        match apply_paid_exit_session_opens(app, config_path, session_opens) {
            Ok(result) => {
                eprintln!(
                    "paid-exit: authenticated session opens received={} applied={} errors={} changed={}",
                    result.received_count, result.applied_count, result.error_count, result.changed
                );
                if result.changed
                    && let Err(error) = refresh_fips_tunnel_config(
                        runtime,
                        app,
                        config_path,
                        network_id,
                        underlay_interface,
                        underlay_interface_mtu,
                        own_pubkey,
                    )
                    .await
                {
                    *vpn_status =
                        format!("paid-exit free-probe admission refresh failed ({error})");
                }
                for (buyer_pubkey, lease_id) in result.acknowledgments {
                    if let Err(error) = runtime
                        .send_paid_route_session_open_ack(&buyer_pubkey, lease_id.clone())
                        .await
                    {
                        eprintln!(
                            "paid-exit: failed to acknowledge session open {lease_id}: {error}"
                        );
                    }
                }
            }
            Err(error) => {
                eprintln!("paid-exit: failed to apply authenticated session open: {error}")
            }
        }
    }

    for (seller_pubkey, lease_id) in std::mem::take(&mut drained.paid_route_session_open_acks) {
        match acknowledge_paid_exit_session_open(config_path, &seller_pubkey, &lease_id) {
            Ok(true) => {
                eprintln!("paid-exit: seller admitted session {lease_id}");
                if let Err(error) = refresh_fips_tunnel_config(
                    runtime,
                    app,
                    config_path,
                    network_id,
                    underlay_interface,
                    underlay_interface_mtu,
                    own_pubkey,
                )
                .await
                {
                    *vpn_status =
                        format!("paid-exit admission acknowledgment refresh failed ({error})");
                }
            }
            Ok(false) => {}
            Err(error) => eprintln!(
                "paid-exit: rejected session acknowledgment from {seller_pubkey}: {error}"
            ),
        }
    }

    for (seller_pubkey, id) in std::mem::take(&mut drained.paid_route_payment_acks) {
        match acknowledge_paid_exit_payment(config_path, &seller_pubkey, &id) {
            Ok(true) => {
                eprintln!("paid-exit: seller acknowledged direct FIPS payment {id}");
                if let Err(error) = refresh_fips_tunnel_config(
                    runtime,
                    app,
                    config_path,
                    network_id,
                    underlay_interface,
                    underlay_interface_mtu,
                    own_pubkey,
                )
                .await
                {
                    *vpn_status =
                        format!("paid-exit payment acknowledgment refresh failed ({error})");
                }
            }
            Ok(false) => {}
            Err(error) => {
                eprintln!("paid-exit: rejected direct FIPS payment acknowledgment: {error}")
            }
        }
    }

    let payments = std::mem::take(&mut drained.paid_route_payments);
    if payments.is_empty() {
        return;
    }
    match paid_exit_apply_fips_payments(
        app,
        config_path,
        payments,
        spilman_receiver,
        spilman_receiver_error,
    ) {
        Ok(result) => {
            eprintln!(
                "paid-exit: direct FIPS payments received={} applied={} errors={} changed={} receiver={}",
                result.received_count,
                result.applied_count,
                result.error_count,
                result.changed,
                result.spilman_receiver_processing
            );
            if result.changed
                && let Err(error) = refresh_fips_tunnel_config(
                    runtime,
                    app,
                    config_path,
                    network_id,
                    underlay_interface,
                    underlay_interface_mtu,
                    own_pubkey,
                )
                .await
            {
                *vpn_status = format!("paid-exit payment refresh failed ({error})");
            }
            for (buyer_pubkey, id) in result.acknowledgments {
                if let Err(error) = runtime
                    .send_paid_route_payment_ack(&buyer_pubkey, id.clone())
                    .await
                {
                    eprintln!("paid-exit: failed to acknowledge direct FIPS payment {id}: {error}");
                }
            }
        }
        Err(error) => eprintln!("paid-exit: failed to apply direct FIPS payment: {error}"),
    }
}

pub(super) fn acknowledge_paid_exit_session_open(
    config_path: &Path,
    seller_pubkey: &str,
    lease_id: &str,
) -> Result<bool> {
    let store_path = paid_route_store_file_path(config_path);
    let mut store = load_paid_route_store(&store_path)?;
    let changed =
        store.acknowledge_buyer_session_open(seller_pubkey, lease_id, unix_timestamp())?;
    if changed {
        write_paid_route_store(&store_path, &store)?;
    }
    Ok(changed)
}

pub(super) fn flush_fips_paid_route_usage(
    runtime: &crate::fips_private_mesh::FipsPrivateTunnelRuntime,
    app: &AppConfig,
    config_path: &Path,
    now_unix: u64,
    active_millis_delta: u64,
) -> Result<PaidExitUsageFlush> {
    let store_path = paid_route_store_file_path(config_path);
    let mut store = load_paid_route_store(&store_path)?;
    let mut changed = false;
    let seller_admission_routing_before = if app.paid_exit.enabled {
        paid_route_seller_admission_routing_signature(
            &store.seller_admissions(&app.paid_exit, now_unix),
        )
    } else {
        Vec::new()
    };

    let mut buyer_delta = PaidRouteUsage::default();
    if let Some(seller_pubkey) = app.public_paid_exit_node_pubkey_hex() {
        let mut usage_delta = runtime.drain_paid_route_usage(&seller_pubkey)?;
        usage_delta.active_millis = usage_delta
            .active_millis
            .saturating_add(active_millis_delta);
        buyer_delta = usage_delta.clone();
        if !usage_delta.is_empty() {
            changed |= store
                .record_buyer_usage(RecordPaidRouteBuyerUsageRequest {
                    seller_pubkey,
                    usage_delta,
                    now_unix,
                })?
                .is_some_and(|result| result.changed);
        }
    }

    if app.paid_exit.enabled {
        for admission in store.seller_admissions(&app.paid_exit, now_unix) {
            let mut usage_delta = runtime.drain_paid_route_usage(&admission.buyer_pubkey)?;
            if admission.allow_routing {
                usage_delta.active_millis = usage_delta
                    .active_millis
                    .saturating_add(active_millis_delta);
            }
            if usage_delta.is_empty() {
                continue;
            }
            changed |= store
                .record_seller_usage(RecordPaidRouteSellerUsageRequest {
                    buyer_pubkey: admission.buyer_pubkey,
                    config: app.paid_exit.clone(),
                    usage_delta,
                    now_unix,
                })?
                .is_some_and(|result| result.changed);
        }
    }

    if changed {
        write_paid_route_store(&store_path, &store)?;
    }
    let seller_admission_routing_after = if changed && app.paid_exit.enabled {
        paid_route_seller_admission_routing_signature(
            &store.seller_admissions(&app.paid_exit, now_unix),
        )
    } else {
        seller_admission_routing_before.clone()
    };
    Ok(PaidExitUsageFlush {
        seller_admission_changed: seller_admission_routing_after != seller_admission_routing_before,
        buyer_delta,
    })
}

fn paid_route_seller_admission_routing_signature(
    admissions: &[nostr_vpn_core::paid_route_store::PaidRouteSellerAdmission],
) -> Vec<(String, String, bool)> {
    admissions
        .iter()
        .map(|admission| {
            (
                admission.buyer_pubkey.clone(),
                admission.session_id.clone(),
                admission.allow_routing,
            )
        })
        .collect()
}
