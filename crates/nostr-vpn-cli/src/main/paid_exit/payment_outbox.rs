const PAID_EXIT_PAYMENT_OUTBOX_BATCH: usize = 16;

struct QueuedPaidExitPayment {
    id: String,
    envelope: StreamingRoutePaymentEnvelope,
}

fn paid_exit_payment_outbox_directory(config_path: &Path) -> PathBuf {
    paid_route_store_file_path(config_path)
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("paid-exit-payment-outbox")
}

fn queue_paid_exit_payment(
    app: &AppConfig,
    config_path: &Path,
    envelope: &StreamingRoutePaymentEnvelope,
) -> Result<bool> {
    use sha2::{Digest, Sha256};

    let buyer = normalize_nostr_pubkey(&envelope.buyer)
        .context("invalid paid route payment buyer")?;
    if buyer != app.nostr_keys()?.public_key().to_hex() {
        return Err(anyhow!(
            "paid route payment buyer does not match local FIPS identity"
        ));
    }
    let seller = normalize_nostr_pubkey(&envelope.seller)
        .context("invalid paid route payment seller")?;
    let closes_historical_channel = matches!(
        &envelope.payload,
        StreamingRoutePaymentPayload::CooperativeClose(_)
    );
    if !closes_historical_channel
        && app.public_paid_exit_node_pubkey_hex().as_deref() != Some(&seller)
    {
        return Err(anyhow!(
            "paid route payment seller is not the selected public exit"
        ));
    }
    let bytes = serde_json::to_vec(envelope)
        .context("failed to encode paid route payment envelope")?;
    let id = hex::encode(Sha256::digest(&bytes));
    let frame = nostr_vpn_core::fips_control::FipsControlFrame::PaidRoutePayment {
        id: id.clone(),
        envelope: envelope.clone(),
    };
    nostr_vpn_core::fips_control::encode_fips_control_frame(&frame)
        .context("paid route payment does not fit the FIPS control envelope")?;
    let directory = paid_exit_payment_outbox_directory(config_path);
    fs::create_dir_all(&directory)
        .with_context(|| format!("failed to create {}", directory.display()))?;
    #[cfg(unix)]
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
        .with_context(|| format!("failed to secure {}", directory.display()))?;
    let destination = directory.join(format!("{id}.json"));
    if destination.exists() {
        return Ok(false);
    }
    let temporary = directory.join(format!(".{id}.{}.tmp", std::process::id()));
    let mut options = OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&temporary)
        .with_context(|| format!("failed to create {}", temporary.display()))?;
    use std::io::Write;
    if let Err(error) = file.write_all(&bytes).and_then(|()| file.sync_all()) {
        let _ = fs::remove_file(&temporary);
        return Err(error).with_context(|| format!("failed to write {}", temporary.display()));
    }
    drop(file);
    if let Err(error) = fs::rename(&temporary, &destination) {
        let _ = fs::remove_file(&temporary);
        return Err(error).with_context(|| format!("failed to queue {}", destination.display()));
    }
    Ok(true)
}

fn load_paid_exit_payment_outbox(config_path: &Path) -> Vec<QueuedPaidExitPayment> {
    let directory = paid_exit_payment_outbox_directory(config_path);
    let entries = match fs::read_dir(&directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Vec::new(),
        Err(error) => {
            eprintln!(
                "paid-exit: failed to scan payment outbox {}: {error}",
                directory.display()
            );
            return Vec::new();
        }
    };
    let mut paths = entries
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_file()))
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "json"))
        .collect::<Vec<_>>();
    paths.sort();
    paths.truncate(PAID_EXIT_PAYMENT_OUTBOX_BATCH);
    paths
        .into_iter()
        .filter_map(|path| match fs::read(&path)
            .with_context(|| format!("failed to read {}", path.display()))
            .and_then(|bytes| {
                serde_json::from_slice(&bytes)
                    .with_context(|| format!("failed to decode {}", path.display()))
            }) {
            Ok(envelope) => {
                let id = path.file_stem()?.to_str()?.to_string();
                if !valid_paid_exit_payment_id(&id) {
                    let _ = fs::remove_file(path);
                    return None;
                }
                Some(QueuedPaidExitPayment { id, envelope })
            }
            Err(error) => {
                eprintln!("paid-exit: discarding invalid payment outbox entry: {error}");
                let _ = fs::remove_file(path);
                None
            }
        })
        .collect()
}

#[derive(Default)]
struct PaidExitPaymentOutboxFlushResult {
    sent: usize,
    errors: usize,
}

async fn flush_paid_exit_payment_outbox(
    runtime: &crate::fips_private_mesh::FipsPrivateTunnelRuntime,
    config_path: &Path,
) -> PaidExitPaymentOutboxFlushResult {
    let mut result = PaidExitPaymentOutboxFlushResult::default();
    let connected_sellers = runtime
        .peer_statuses()
        .into_iter()
        .filter(|peer| peer.connected)
        .map(|peer| peer.pubkey)
        .collect::<HashSet<_>>();
    for queued in load_paid_exit_payment_outbox(config_path) {
        let seller = queued.envelope.seller.clone();
        // FIPS-TCP waits for its destination to become reachable. The durable
        // outbox is retried every daemon tick, so waiting here for an offline
        // historical seller only starves config reloads and liveness work.
        if !connected_sellers.contains(&seller) {
            continue;
        }
        match runtime
            .send_paid_route_payment(&seller, queued.id, queued.envelope)
            .await
        {
            Ok(()) => result.sent += 1,
            Err(error) => {
                result.errors += 1;
                eprintln!("paid-exit: direct FIPS payment send failed: {error}");
            }
        }
    }
    result
}

fn acknowledge_paid_exit_payment(
    config_path: &Path,
    seller_pubkey: &str,
    id: &str,
) -> Result<bool> {
    if !valid_paid_exit_payment_id(id) {
        return Err(anyhow!("invalid paid route payment acknowledgment id"));
    }
    let path = paid_exit_payment_outbox_directory(config_path).join(format!("{id}.json"));
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    let envelope: StreamingRoutePaymentEnvelope = serde_json::from_slice(&bytes)
        .with_context(|| format!("failed to decode {}", path.display()))?;
    if normalize_nostr_pubkey(&envelope.seller).ok().as_deref() != Some(seller_pubkey) {
        return Err(anyhow!(
            "paid route payment acknowledgment source does not match seller"
        ));
    }
    let store_path = paid_route_store_file_path(config_path);
    let mut store = load_paid_route_store(&store_path)?;
    let admission_changed = store.acknowledge_buyer_session_open(
        seller_pubkey,
        &envelope.lease_id,
        unix_timestamp(),
    )?;
    if admission_changed {
        write_paid_route_store(&store_path, &store)?;
    }
    fs::remove_file(&path).with_context(|| format!("failed to remove {}", path.display()))?;
    Ok(true)
}

fn valid_paid_exit_payment_id(id: &str) -> bool {
    id.len() == 64
        && id
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
