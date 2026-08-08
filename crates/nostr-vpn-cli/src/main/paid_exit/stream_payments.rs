
#[derive(Debug, Default)]
struct PaidExitStreamPaymentUpdatesResult {
    signed: Vec<serde_json::Value>,
    errors: Vec<serde_json::Value>,
    changed: bool,
}

impl PaidExitStreamPaymentUpdatesResult {
    fn persisted_count(&self) -> usize {
        self.signed
            .iter()
            .filter(|entry| entry["persisted"].as_bool().unwrap_or_default())
            .count()
    }
}

#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct PaidExitDaemonStreamPaymentsResult {
    pub(crate) total_due_count: usize,
    pub(crate) processed_due_count: usize,
    pub(crate) signed_count: usize,
    pub(crate) persisted_count: usize,
    pub(crate) error_count: usize,
    pub(crate) changed: bool,
}

struct PaidExitStreamPaymentUpdatesRequest<'a, S: CashuSpilmanPaymentSigner> {
    app: &'a AppConfig,
    config_path: &'a Path,
    store: &'a mut PaidRouteStore,
    signer: &'a S,
    buyer_npub: &'a str,
    due: Vec<PaidRouteBuyerPaymentUpdateDue>,
    queue: bool,
    now_unix: u64,
}

fn paid_exit_stream_payment_updates_with_signer<S: CashuSpilmanPaymentSigner>(
    request: PaidExitStreamPaymentUpdatesRequest<'_, S>,
) -> PaidExitStreamPaymentUpdatesResult {
    let PaidExitStreamPaymentUpdatesRequest {
        app,
        config_path,
        store,
        signer,
        buyer_npub,
        due,
        queue,
        now_unix,
    } = request;
    let mut result = PaidExitStreamPaymentUpdatesResult::default();

    for update_due in due {
        let signed_update = store.build_buyer_signed_payment_envelope_for_due(
            signer,
            buyer_npub,
            &update_due,
            now_unix,
        );
        let signed_update = match signed_update {
            Ok(signed_update) => signed_update,
            Err(error) => {
                result.errors.push(json!({
                    "due": update_due.clone(),
                    "error": error.to_string(),
                }));
                continue;
            }
        };
        let next_store = signed_update.store;
        let payment = signed_update.payment;
        let payment_changed = payment.changed;

        let mut persisted = false;
        let queued = if queue {
            match queue_paid_exit_payment(app, config_path, &payment.envelope) {
                Ok(created) => {
                    persisted = true;
                    Some(created)
                }
                Err(error) => {
                    result.errors.push(json!({
                        "due": update_due.clone(),
                        "session_id": payment.session_id,
                        "error": error.to_string(),
                    }));
                    None
                }
            }
        } else {
            None
        };

        if persisted {
            result.changed |= payment_changed;
            *store = next_store;
        }
        result.signed.push(json!({
            "due": update_due,
            "payment": payment,
            "queued": queued,
            "persisted": persisted,
        }));
    }

    result
}

pub(crate) fn paid_exit_stream_due_payments_for_daemon(
    app: &AppConfig,
    config_path: &Path,
    min_increment_msat: u64,
    limit: usize,
) -> Result<PaidExitDaemonStreamPaymentsResult> {
    if app.public_paid_exit_node_pubkey_hex().is_none() {
        return Ok(PaidExitDaemonStreamPaymentsResult::default());
    }

    let buyer_npub = app
        .nostr_keys()?
        .public_key()
        .to_bech32()
        .context("failed to encode buyer npub")?;
    let store_path = paid_route_store_file_path(config_path);
    let now_unix = unix_timestamp();
    let due = load_paid_route_store(&store_path)?.buyer_payment_updates_due(
        PaidRouteBuyerPaymentUpdatesDueRequest {
            now_unix,
            min_increment_msat,
        },
    );
    let total_due_count = due.len();
    if due.is_empty() {
        return Ok(PaidExitDaemonStreamPaymentsResult::default());
    }
    let Some(signer) = FileSpilmanPaymentSigner::try_load(&paid_exit_wallet_data_dir(config_path))
        .map_err(|error| anyhow!("{error}"))?
    else {
        return Ok(PaidExitDaemonStreamPaymentsResult {
            total_due_count,
            ..Default::default()
        });
    };
    let (total_due_count, processed_due_count, result) =
        update_paid_route_store(&store_path, |store| {
            let mut due = store.buyer_payment_updates_due(
                PaidRouteBuyerPaymentUpdatesDueRequest {
                    now_unix,
                    min_increment_msat,
                },
            );
            let total_due_count = due.len();
            if limit > 0 && due.len() > limit {
                due.truncate(limit);
            }
            let processed_due_count = due.len();
            let result = paid_exit_stream_payment_updates_with_signer(
                PaidExitStreamPaymentUpdatesRequest {
                    app,
                    config_path,
                    store,
                    signer: &signer,
                    buyer_npub: &buyer_npub,
                    due,
                    queue: true,
                    now_unix,
                },
            );
            Ok((total_due_count, processed_due_count, result))
        })?;

    Ok(PaidExitDaemonStreamPaymentsResult {
        total_due_count,
        processed_due_count,
        signed_count: result.signed.len(),
        persisted_count: result.persisted_count(),
        error_count: result.errors.len(),
        changed: result.changed,
    })
}

async fn paid_exit_stream_payments_command(args: PaidExitStreamPaymentsArgs) -> Result<()> {
    let config_path = args.config.unwrap_or_else(default_config_path);
    let app = load_or_default_config(&config_path)?;
    let buyer_npub = app
        .nostr_keys()?
        .public_key()
        .to_bech32()
        .context("failed to encode buyer npub")?;
    let store_path = paid_route_store_file_path(&config_path);
    let now_unix = unix_timestamp();
    let mut due = load_paid_route_store(&store_path)?.buyer_payment_updates_due(
        PaidRouteBuyerPaymentUpdatesDueRequest {
        now_unix,
        min_increment_msat: args.min_increment_msat,
        },
    );
    let total_due_count = due.len();
    if args.limit > 0 && due.len() > args.limit {
        due.truncate(args.limit);
    }
    let selected_due_count = due.len();

    let (total_due_count, selected_due_count, result) = if due.is_empty() {
        (
            total_due_count,
            selected_due_count,
            PaidExitStreamPaymentUpdatesResult::default(),
        )
    } else {
        let signer = FileSpilmanPaymentSigner::load(&paid_exit_wallet_data_dir(&config_path))
            .map_err(|error| anyhow!("{error}"))?;
        update_paid_route_store(&store_path, |store| {
            let mut due = store.buyer_payment_updates_due(
                PaidRouteBuyerPaymentUpdatesDueRequest {
                    now_unix,
                    min_increment_msat: args.min_increment_msat,
                },
            );
            let total_due_count = due.len();
            if args.limit > 0 && due.len() > args.limit {
                due.truncate(args.limit);
            }
            let selected_due_count = due.len();
            let result = paid_exit_stream_payment_updates_with_signer(
                PaidExitStreamPaymentUpdatesRequest {
                    app: &app,
                    config_path: &config_path,
                    store,
                    signer: &signer,
                    buyer_npub: &buyer_npub,
                    due,
                    queue: !args.dry_run,
                    now_unix,
                },
            );
            Ok((total_due_count, selected_due_count, result))
        })?
    };
    let changed = result.changed;

    if args.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "store_path": store_path.display().to_string(),
                "wallet_sign": {
                    "source": "spilman-client-store",
                    "data_dir": paid_exit_wallet_data_dir(&config_path).display().to_string(),
                },
                "dry_run": args.dry_run,
                "outbox": paid_exit_payment_outbox_directory(&config_path),
                "total_due_count": total_due_count,
                "processed_due_count": selected_due_count,
                "signed_count": result.signed.len(),
                "persisted_count": result.persisted_count(),
                "error_count": result.errors.len(),
                "changed": changed,
                "signed": result.signed,
                "errors": result.errors,
            }))?
        );
    } else {
        println!(
            "paid_exit_stream_payments: signed={} errors={} due={} changed={}",
            result.signed.len(),
            result.errors.len(),
            total_due_count,
            changed
        );
        println!(
            "delivery: {}",
            if args.dry_run {
                "dry-run"
            } else {
                "queued for direct FIPS delivery"
            }
        );
        for entry in &result.signed {
            let payment = &entry["payment"];
            let paid_msat = payment["paid_msat"].as_u64().unwrap_or_default();
            let due_msat = payment["amount_due_msat"].as_u64().unwrap_or_default();
            let unpaid_msat = payment["unpaid_msat"].as_u64().unwrap_or_default();
            println!(
                "session: {} seller: {} paid={} due={} unpaid={}",
                payment["session_id"].as_str().unwrap_or_default(),
                payment["seller_npub"].as_str().unwrap_or_default(),
                paid_exit_msat_text(paid_msat),
                paid_exit_msat_text(due_msat),
                paid_exit_msat_text(unpaid_msat)
            );
            println!(
                "persisted: {}",
                entry["persisted"].as_bool().unwrap_or_default()
            );
            println!(
                "envelope: {}",
                serde_json::to_string(&payment["envelope"])
                    .context("failed to encode paid route payment envelope")?
            );
            println!(
                "queued: {}",
                entry["queued"].as_bool().unwrap_or_default()
            );
        }
        for entry in &result.errors {
            println!(
                "error: session={} {}",
                entry["due"]["session_id"].as_str().unwrap_or_default(),
                entry["error"].as_str().unwrap_or_default()
            );
        }
        println!("store: {}", store_path.display());
    }

    Ok(())
}
