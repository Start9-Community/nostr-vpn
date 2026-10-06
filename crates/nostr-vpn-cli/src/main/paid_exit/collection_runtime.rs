use super::*;
use std::collections::HashMap;
use std::sync::mpsc::{self, Receiver, TryRecvError};

const SCAN_INTERVAL: Duration = Duration::from_secs(5);
const RETRY_INTERVAL: Duration = Duration::from_secs(60);
const ATTEMPT_TIMEOUT: Duration = Duration::from_secs(30);

/// One bounded collection at a time, off the daemon's control/dataplane thread.
/// The receiver's durable close receipt and idempotent wallet import make a
/// timeout or process restart retryable without issuing another payment.
pub(crate) struct PaidExitSellerCollector {
    active: Option<(String, Receiver<Result<PaidExitCollectChannelOutcome>>)>,
    retry_after: HashMap<String, (Instant, Duration)>,
    next_scan: Instant,
}

impl PaidExitSellerCollector {
    pub(crate) fn new() -> Self {
        Self {
            active: None,
            retry_after: HashMap::new(),
            next_scan: Instant::now(),
        }
    }

    pub(crate) fn poll(
        &mut self,
        app: &AppConfig,
        config_path: &Path,
        allow_start: bool,
    ) -> Result<bool> {
        let mut changed = false;
        if let Some((channel_id, result_rx)) = &self.active {
            let result = match result_rx.try_recv() {
                Ok(result) => Some(result),
                Err(TryRecvError::Empty) => None,
                Err(TryRecvError::Disconnected) => Some(Err(anyhow!("collection worker stopped"))),
            };
            if let Some(result) = result {
                let channel_id = channel_id.clone();
                self.active = None;
                match result {
                    Ok(outcome) => {
                        self.retry_after.remove(&channel_id);
                        changed |= outcome.changed;
                        eprintln!(
                            "paid-exit: automatically collected seller channel receiver_sat={}",
                            outcome.close.receiver_sum
                        );
                    }
                    Err(error) => {
                        let delay = self
                            .retry_after
                            .get(&channel_id)
                            .map_or(RETRY_INTERVAL, |(_, previous)| {
                                (*previous * 2).min(Duration::from_secs(3600))
                            });
                        self.retry_after
                            .insert(channel_id.clone(), (Instant::now() + delay, delay));
                        update_paid_route_store(
                            &paid_route_store_file_path(config_path),
                            |store| {
                                if let Some(channel) = store.channels.get_mut(&channel_id) {
                                    channel.error = format!("Automatic collection failed: {error}");
                                }
                                Ok(())
                            },
                        )?;
                        // Details remain in the private channel status; never log proofs.
                        eprintln!(
                            "paid-exit: automatic seller collection failed; retained for retry"
                        );
                    }
                }
            }
        }
        if !allow_start || self.active.is_some() || Instant::now() < self.next_scan {
            return Ok(changed);
        }
        self.next_scan = Instant::now() + SCAN_INTERVAL;
        let store = load_paid_route_store(&paid_route_store_file_path(config_path))?;
        let due = store.seller_collection_states(&app.paid_exit, unix_timestamp());
        self.retry_after
            .retain(|id, _| due.iter().any(|state| state.channel_id == *id));
        let Some(state) = due.iter().find(|state| {
            state.auto_collect_due
                && self
                    .retry_after
                    .get(&state.channel_id)
                    .is_none_or(|(at, _)| Instant::now() >= *at)
        }) else {
            return Ok(changed);
        };
        let channel_id = state.channel_id.clone();
        // Settle an already accepted channel even if selling or that mint's
        // admission has since been disabled. Never enable sales or fund a channel.
        let mint_url = store.channels[&channel_id].mint_url.clone();
        let config_path = config_path.to_path_buf();
        let (tx, rx) = mpsc::sync_channel(1);
        let worker_channel = channel_id.clone();
        std::thread::Builder::new()
            .name("nvpn-seller-collect".into())
            .spawn(move || {
                let result = (|| {
                    let runtime = tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()?;
                    runtime.block_on(async {
                        tokio::time::timeout(
                            ATTEMPT_TIMEOUT,
                            collect_seller_channel(&config_path, &worker_channel, &mint_url),
                        )
                        .await
                        .context("seller collection timed out")?
                    })
                })();
                let _ = tx.send(result);
            })
            .context("start seller collection worker")?;
        self.active = Some((channel_id, rx));
        Ok(changed)
    }
}

async fn collect_seller_channel(
    config_path: &Path,
    channel_id: &str,
    mint_url: &str,
) -> Result<PaidExitCollectChannelOutcome> {
    let directory = paid_exit_wallet_data_dir(config_path);
    anyhow::ensure!(
        cashu_service::spilman_receiver_key_path(&directory).is_file()
            && cashu_service::spilman_receiver_store_path(&directory).is_file(),
        "existing seller receiver is missing; refusing to create a new identity"
    );
    // Cached keysets and completed close receipts must remain usable during a
    // mint outage. A blind keyset refresh would block offline wallet recovery.
    let receiver = FileSpilmanPaymentReceiver::load(
        &directory,
        FileSpilmanPaymentReceiverConfig::new([mint_url.to_owned()]),
    )
    .map_err(|error| anyhow!("{error}"))?;
    let close = receiver
        .close_cashu_spilman_channel(channel_id)
        .await
        .map_err(|error| anyhow!("{error}"))?;
    paid_exit_finish_seller_collection(
        close,
        config_path,
        &paid_route_store_file_path(config_path),
        true,
    )
    .await
}
