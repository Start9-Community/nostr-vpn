fn mobile_join_roster_destination(
    config: &MobileTunnelConfig,
    recipient: &str,
) -> Result<Option<PeerIdentity>> {
    let recipient = normalize_nostr_pubkey(recipient)?;
    config
        .peers
        .iter()
        .find(|peer| peer.participant_pubkey == recipient)
        .map(|peer| {
            PeerIdentity::from_npub(&peer.endpoint_npub)
                .with_context(|| format!("invalid FIPS endpoint identity {}", peer.endpoint_npub))
        })
        .transpose()
}

async fn deliver_mobile_queued_join_roster(
    state_control: &FipsControlTcpSender,
    destination: PeerIdentity,
    config_path: Option<&Path>,
    mut queued: QueuedJoinRoster,
) {
    // Keep one receipt subscription alive across the user-visible join
    // window. Short outer attempts leave a gap while retrying in which the
    // exact receipt can arrive unnoticed even though the joiner applied the
    // roster. The reliable sender retransmits internally while this continuous
    // subscription is open.
    const DELIVERY_ATTEMPT_TIMEOUT: Duration = Duration::from_secs(15);
    const DELIVERY_RETRY_DELAY: Duration = Duration::from_millis(250);

    let outbox_path = config_path.and_then(|config_path| {
        let event_id = queued.join_roster.signed_roster.artifact_hash();
        load_join_rosters(config_path)
            .into_iter()
            .find(|(_, candidate)| {
                candidate.recipient_npub == queued.recipient_npub
                    && candidate.join_roster.signed_roster.artifact_hash() == event_id
            })
            .map(|(path, _)| path)
    });

    loop {
        let now = unix_timestamp();
        if join_roster_delivery_expired(&queued, now) {
            if let Some(path) = outbox_path.as_deref()
                && let Err(error) = fs::remove_file(path)
            {
                tracing::warn!(?error, "mobile: failed to remove expired join approval");
            }
            return;
        }
        if let Some(path) = outbox_path.as_deref()
            && let Err(error) = record_join_roster_attempt(path, &mut queued, now)
        {
            tracing::warn!(?error, "mobile: failed to record join approval attempt");
        }
        match send_join_roster_with_receipt(
            state_control,
            destination,
            &queued.join_roster,
            DELIVERY_ATTEMPT_TIMEOUT,
        )
        .await
        {
            Ok(_) => {
                if let Some(path) = outbox_path.as_deref()
                    && let Err(error) = fs::remove_file(path)
                {
                    tracing::warn!(?error, "mobile: failed to consume delivered join approval");
                }
                return;
            }
            Err(error) => {
                tracing::warn!(
                    ?error,
                    recipient = %queued.recipient_npub,
                    "mobile: join approval not yet acknowledged; retrying"
                );
                tokio::time::sleep(DELIVERY_RETRY_DELAY).await;
            }
        }
    }
}

fn mobile_lan_discovery_scope(network_id: &str) -> String {
    nostr_vpn_core::fips_discovery::fips_lan_discovery_scope(network_id)
}

async fn push_mobile_wg_inbound_batch(
    batch: Vec<Vec<u8>>,
    packets: &mut Vec<Vec<u8>>,
    inbound_tx: &tokio_mpsc::Sender<Vec<Vec<u8>>>,
    wg_addr: Option<Ipv4Addr>,
    mesh_addr: Option<Ipv4Addr>,
    exit_dns_nat: Option<&MobileExitDnsNat>,
) -> bool {
    for mut packet in batch {
        if let Some(exit_dns_nat) = exit_dns_nat {
            exit_dns_nat.rewrite_response(&mut packet);
        }
        if let (Some(wg), Some(mesh)) = (wg_addr, mesh_addr) {
            rewrite_ipv4_destination(&mut packet, wg, mesh);
            nostr_vpn_core::packet_checksums::finalize_ipv4_transport_checksum(&mut packet);
        }
        packets.push(packet);
        if packets.len() == MOBILE_FIPS_RECV_BATCH
            && !flush_mobile_inbound_packets(inbound_tx, packets).await
        {
            return false;
        }
    }
    true
}

struct MobileTunnelStarted {
    endpoint: Arc<FipsEndpoint>,
    state_control: FipsControlTcpSender,
    mesh: MobileMesh,
    presence: Arc<RwLock<HashMap<String, MobilePeerPresence>>>,
    config: Arc<RwLock<MobileTunnelConfig>>,
    app_config: Arc<RwLock<AppConfig>>,
    app_config_dirty: Arc<AtomicBool>,
    pending_join_roster_receipts: PendingJoinRosterReceipts,
    tun_counters: Arc<MobileTunAtomicCounters>,
    secure_dns: Option<SecureDnsResolver>,
    #[cfg(any(test, target_os = "android", target_os = "ios"))]
    outbound_tx: tokio_mpsc::Sender<Vec<Vec<u8>>>,
    inbound_rx: tokio_mpsc::Receiver<Vec<Vec<u8>>>,
    tasks: Vec<JoinHandle<()>>,
    wg_upstream: Option<WgUpstreamRuntime>,
    #[cfg(target_os = "android")]
    wg_upstream_socket_fd: c_int,
}

#[cfg(test)]
impl MobileTunnelStarted {
    fn take_app_config_toml(&self) -> Result<String> {
        pending_app_config_toml(&self.app_config, &self.config, &self.app_config_dirty)
    }

    fn acknowledge_app_config_toml(&self, expected_toml: &str) -> Result<bool> {
        acknowledge_pending_app_config_toml(
            &self.app_config,
            &self.config,
            &self.app_config_dirty,
            &self.pending_join_roster_receipts,
            expected_toml,
        )
    }
}

async fn run_pending_join_roster_receipt_delivery(
    state_control: FipsControlTcpSender,
    pending: PendingJoinRosterReceipts,
) {
    // A successful FIPS-TCP send means the authenticated peer acknowledged the
    // complete record. Multi-hop delivery can cross one second under load, so
    // do not cancel that acknowledgement after the peer has already received
    // the idempotent receipt and leave its durable sidecar queued.
    const ATTEMPT_TIMEOUT: Duration = Duration::from_secs(3);
    const RETRY_DELAY: Duration = Duration::from_millis(250);

    loop {
        let receipts = match pending.committed_snapshot() {
            Ok(receipts) => receipts,
            Err(error) => {
                tracing::warn!(?error, "mobile: pending join receipt queue unavailable");
                return;
            }
        };
        if receipts.is_empty() {
            pending.changed.notified().await;
            continue;
        }

        let mut retry_needed = false;
        for (roster_event_id, destination) in receipts {
            let frame = FipsControlFrame::JoinRosterAck {
                roster_event_id: roster_event_id.clone(),
            };
            let result =
                tokio::time::timeout(ATTEMPT_TIMEOUT, state_control.send(destination, &frame)).await;
            match result {
                Ok(Ok(_)) => {
                    if let Err(error) =
                        pending.remove_delivered(&roster_event_id, destination)
                    {
                        tracing::warn!(
                            ?error,
                            "mobile: delivered join receipt could not be removed"
                        );
                        return;
                    }
                }
                Ok(Err(error)) => {
                    retry_needed = true;
                    if let Err(queue_error) =
                        pending.record_failed_attempt(&roster_event_id, destination)
                    {
                        tracing::warn!(
                            ?queue_error,
                            "mobile: failed join receipt attempt could not be recorded"
                        );
                        return;
                    }
                    tracing::warn!(
                        ?error,
                        %roster_event_id,
                        recipient = %destination.npub(),
                        "mobile: committed join receipt delivery failed; retrying"
                    );
                }
                Err(_) => {
                    retry_needed = true;
                    if let Err(error) =
                        pending.record_failed_attempt(&roster_event_id, destination)
                    {
                        tracing::warn!(
                            ?error,
                            "mobile: timed-out join receipt attempt could not be recorded"
                        );
                        return;
                    }
                    tracing::warn!(
                        %roster_event_id,
                        recipient = %destination.npub(),
                        "mobile: committed join receipt delivery timed out; retrying"
                    );
                }
            }
        }

        if retry_needed {
            tokio::select! {
                () = tokio::time::sleep(RETRY_DELAY) => {}
                () = pending.changed.notified() => {}
            }
        }
    }
}

fn pending_app_config_toml(
    app_config: &Arc<RwLock<AppConfig>>,
    config: &Arc<RwLock<MobileTunnelConfig>>,
    app_config_dirty: &AtomicBool,
) -> Result<String> {
    if !app_config_dirty.load(Ordering::Acquire) {
        return Ok(String::new());
    }
    let app = app_config
        .read()
        .map_err(|_| anyhow!("mobile app config lock poisoned"))?;
    let config_path = config
        .read()
        .map_err(|_| anyhow!("mobile FIPS config lock poisoned"))?
        .config_path
        .clone();
    let config_path = non_empty_path(&config_path).unwrap_or_else(|| PathBuf::from(""));
    persisted_app_config_toml(&app, &config_path)
}

fn acknowledge_pending_app_config_toml(
    app_config: &Arc<RwLock<AppConfig>>,
    config: &Arc<RwLock<MobileTunnelConfig>>,
    app_config_dirty: &AtomicBool,
    pending_join_roster_receipts: &PendingJoinRosterReceiptQueue,
    expected_toml: &str,
) -> Result<bool> {
    if !app_config_dirty.load(Ordering::Acquire) {
        return Ok(false);
    }
    // Hold the read locks through the acknowledgement so a newer roster
    // cannot be applied between comparing the snapshot and clearing dirty.
    let app = app_config
        .read()
        .map_err(|_| anyhow!("mobile app config lock poisoned"))?;
    let config_path = config
        .read()
        .map_err(|_| anyhow!("mobile FIPS config lock poisoned"))?
        .config_path
        .clone();
    let config_path = non_empty_path(&config_path).unwrap_or_else(|| PathBuf::from(""));
    let current_toml = persisted_app_config_toml(&app, &config_path)?;
    let expected: toml::Value =
        toml::from_str(expected_toml).context("failed to decode acknowledged mobile app config")?;
    let current: toml::Value =
        toml::from_str(&current_toml).context("failed to decode current mobile app config")?;
    if current != expected {
        return Ok(false);
    }
    pending_join_roster_receipts.mark_committed()?;
    app_config_dirty.store(false, Ordering::Release);
    Ok(true)
}

impl Drop for MobileTunnel {
    fn drop(&mut self) {
        #[cfg(any(target_os = "android", target_os = "ios"))]
        let mut native_tun = self.native_tun.take();
        #[cfg(any(target_os = "android", target_os = "ios"))]
        if let Some(tun) = native_tun.as_mut() {
            tun.stop();
        }
        let _ = self.inbound_rx.take();
        for task in &self.tasks {
            task.abort();
        }
        let tasks = std::mem::take(&mut self.tasks);
        let endpoint = self.endpoint.take();
        let wg_upstream = self.wg_upstream.take();
        self.runtime.block_on(async move {
            for task in tasks {
                let _ = task.await;
            }
            if let Some(wg) = wg_upstream {
                wg.shutdown().await;
            }
            if let Some(endpoint) = endpoint {
                let _ = endpoint.shutdown().await;
            }
        });
        #[cfg(any(target_os = "android", target_os = "ios"))]
        if let Some(mut tun) = native_tun {
            tun.join();
        }
    }
}
