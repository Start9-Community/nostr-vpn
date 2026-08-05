const DEFAULT_PAID_EXIT_WALLET_MINT: &str = "https://mint.minibits.cash/Bitcoin";

struct PaidRouteWalletTokenPreview {
    mint_url: String,
    amount_sat: u64,
    memo: String,
    state: &'static str,
    status_text: String,
    redeemable: bool,
}

impl NativeAppRuntime {
    pub(super) fn paid_exit_seller_state(
        &self,
        app: Option<&AppConfig>,
        port_mapping: Option<&PortMappingStatus>,
        mobile: bool,
    ) -> NativePaidExitSellerState {
        paid_exit_seller_state(
            app,
            port_mapping,
            paid_exit_seller_supported_for_current_target(mobile),
            &self.paid_route_store_path(),
        )
    }

    pub(super) fn paid_route_market_state(
        &self,
        app: Option<&AppConfig>,
    ) -> NativePaidRouteMarketState {
        paid_route_market_state(
            app,
            &self.paid_route_store_path(),
            &self.paid_route_market_filter,
            &self.paid_route_wallet_last_action,
            &self.paid_route_payment_last_action,
        )
    }

    fn paid_route_store_path(&self) -> PathBuf {
        paid_route_store_file_path(&self.config_path)
    }

    pub(super) fn active_paid_route_exit_ip(&self, selected_exit_node: &str) -> Option<String> {
        let selected_exit_node = normalize_nostr_pubkey(selected_exit_node).ok()?;
        let store = load_paid_route_store(&self.paid_route_store_path()).ok()?;
        let now_unix = unix_timestamp();
        store
            .sessions
            .values()
            .filter_map(|record| {
                let channel = store.channels.get(&record.session.payment.channel_id)?;
                let counterparty = normalize_nostr_pubkey(&channel.counterparty_npub).ok()?;
                (channel.role == PaidRouteChannelRole::Buyer
                    && counterparty == selected_exit_node
                    && store
                        .buyer_session_allows_routing(&record.session.session_id, now_unix)
                        .unwrap_or(false))
                .then(|| {
                    (
                        record.updated_at_unix,
                        record.session.realized_exit_ip.clone().unwrap_or_default(),
                    )
                })
            })
            .max_by_key(|(updated_at, _)| *updated_at)
            .map(|(_, realized_exit_ip)| realized_exit_ip)
    }

    fn mutate_paid_route_store(
        &mut self,
        mutate: impl FnOnce(&mut PaidRouteStore) -> bool,
    ) -> Result<()> {
        let path = self.paid_route_store_path();
        let mut store = load_paid_route_store(&path)?;
        if mutate(&mut store) {
            write_paid_route_store(&path, &store)?;
        }
        Ok(())
    }

    pub(super) fn add_paid_route_wallet_mint(
        &mut self,
        url: &str,
        label: Option<&str>,
    ) -> Result<()> {
        let url = normalize_paid_route_mint_url(url)?;
        let label = label.unwrap_or_default();
        self.mutate_paid_route_store(|store| {
            store.upsert_wallet_mint(&url, label, None, unix_timestamp())
        })
    }

    pub(super) fn remove_paid_route_wallet_mint(&mut self, url: &str) -> Result<()> {
        self.mutate_paid_route_store(|store| store.remove_wallet_mint(url))
    }

    pub(super) fn set_paid_route_default_mint(&mut self, url: &str) -> Result<()> {
        self.mutate_paid_route_store(|store| store.set_default_mint(url))
    }

    pub(super) fn refresh_paid_route_wallet(&mut self, refresh: bool) -> Result<()> {
        let pending_top_up = (self.paid_route_wallet_last_action.kind == "topup")
            .then(|| self.paid_route_wallet_last_action.clone());
        let (overview, activity) = {
            let wallet = self.cashu_wallet()?;
            let overview = wallet.overview(refresh)?;
            let activity = if refresh && pending_top_up.is_some() {
                wallet.activity()?
            } else {
                Vec::new()
            };
            (overview, activity)
        };
        self.sync_paid_route_wallet_overview(&overview)?;
        if let Some(mut top_up) = pending_top_up {
            let status = cashu_top_up_activity_status(&activity, &top_up.quote_id);
            if status == Some(PaidRouteTopUpActivityStatus::Complete) {
                top_up.kind = "topup_complete".to_string();
                top_up.status_text = format!("Received {} sat", top_up.amount_sat);
                top_up.payment_request.clear();
                self.paid_route_wallet_last_action = top_up;
                self.paid_route_wallet_next_refresh_at = None;
                return Ok(());
            }
            if status == Some(PaidRouteTopUpActivityStatus::Expired)
                || (top_up.expires_at_unix > 0 && top_up.expires_at_unix <= unix_timestamp())
            {
                top_up.kind = "topup_expired".to_string();
                top_up.status_text = "Invoice expired".to_string();
                top_up.payment_request.clear();
                self.paid_route_wallet_last_action = top_up;
                self.paid_route_wallet_next_refresh_at = None;
                return Ok(());
            }
            top_up.status_text = format!("Waiting for {} sat", top_up.amount_sat);
            self.paid_route_wallet_last_action = top_up;
            return Ok(());
        }
        self.paid_route_wallet_last_action = NativePaidRouteWalletActionState {
            kind: "refresh".to_string(),
            status_text: "Wallet refreshed".to_string(),
            ..NativePaidRouteWalletActionState::default()
        };
        Ok(())
    }

    pub(super) fn top_up_paid_route_wallet(
        &mut self,
        mint_url: Option<&str>,
        amount_sat: u64,
    ) -> Result<()> {
        let mint_url = self.paid_route_wallet_mint(mint_url)?;
        let quote = self
            .cashu_wallet()?
            .create_topup_quote(&mint_url, amount_sat)?;
        self.ensure_paid_route_wallet_mint(&quote.mint_url, None)?;
        self.paid_route_wallet_last_action = NativePaidRouteWalletActionState {
            kind: "topup".to_string(),
            status_text: format!("Top-up invoice for {amount_sat} sat"),
            mint_url: quote.mint_url,
            amount_sat: quote.amount,
            amount_text: paid_route_sat_text(amount_sat),
            quote_id: quote.quote_id,
            payment_request: quote.payment_request,
            expires_at_unix: quote.expiry_unix,
            ..NativePaidRouteWalletActionState::default()
        };
        self.paid_route_wallet_next_refresh_at =
            Some(std::time::Instant::now() + PAID_ROUTE_WALLET_TOP_UP_POLL_CADENCE);
        Ok(())
    }

    pub(super) fn refresh_pending_paid_route_wallet(&mut self) {
        if self.paid_route_wallet_last_action.kind != "topup" {
            self.paid_route_wallet_next_refresh_at = None;
            return;
        }
        let now = std::time::Instant::now();
        if self
            .paid_route_wallet_next_refresh_at
            .is_some_and(|next_refresh| now < next_refresh)
        {
            return;
        }
        self.paid_route_wallet_next_refresh_at = Some(now + PAID_ROUTE_WALLET_TOP_UP_POLL_CADENCE);
        let _ = self.refresh_paid_route_wallet(true);
    }

    pub(super) fn receive_paid_route_wallet_token(&mut self, token: &str) -> Result<()> {
        let token = token.trim();
        if token.is_empty() {
            return Err(anyhow!("Token is empty"));
        }
        let received = self.cashu_wallet()?.receive_token(token)?;
        let amount_sat = received.amount_sat;
        let overview = self.cashu_wallet()?.overview(false)?;
        self.sync_paid_route_wallet_overview(&overview)?;
        self.paid_route_wallet_last_action = NativePaidRouteWalletActionState {
            kind: "receive".to_string(),
            status_text: format!("Received {amount_sat} sat"),
            mint_url: received.mint_url,
            amount_sat,
            amount_text: paid_route_sat_text(amount_sat),
            ..NativePaidRouteWalletActionState::default()
        };
        Ok(())
    }

    pub(super) fn preview_paid_route_wallet_token(&mut self, token: &str) -> Result<()> {
        let token = token.trim();
        if token.is_empty() {
            return Err(anyhow!("Token is empty"));
        }
        self.paid_route_wallet_last_action = NativePaidRouteWalletActionState {
            kind: "preview_checking".to_string(),
            status_text: "Checking token".to_string(),
            ..NativePaidRouteWalletActionState::default()
        };
        let preview = inspect_paid_route_wallet_token(token)?;
        let amount_sat = preview.amount_sat;
        self.paid_route_wallet_last_action = NativePaidRouteWalletActionState {
            kind: "preview".to_string(),
            status_text: preview.status_text,
            mint_url: preview.mint_url,
            amount_sat,
            amount_text: paid_route_sat_text(amount_sat),
            token_state: preview.state.to_string(),
            token_redeemable: preview.redeemable,
            token_memo: preview.memo,
            ..NativePaidRouteWalletActionState::default()
        };
        Ok(())
    }

    pub(super) fn send_paid_route_wallet_token(
        &mut self,
        mint_url: Option<&str>,
        amount_sat: u64,
    ) -> Result<()> {
        let mint_url = self.paid_route_wallet_mint(mint_url)?;
        let sent = self.cashu_wallet()?.send_token(&mint_url, amount_sat)?;
        let amount_sat = sent.amount_sat;
        let fee_sat = sent.send_fee_sat;
        let overview = self.cashu_wallet()?.overview(false)?;
        self.sync_paid_route_wallet_overview(&overview)?;
        self.paid_route_wallet_last_action = NativePaidRouteWalletActionState {
            kind: "send".to_string(),
            status_text: format!("Created token for {amount_sat} sat"),
            mint_url: sent.mint_url,
            amount_sat,
            amount_text: paid_route_sat_text(amount_sat),
            fee_sat,
            fee_text: paid_route_fee_text(fee_sat),
            operation_id: sent.operation_id,
            token: sent.token,
            ..NativePaidRouteWalletActionState::default()
        };
        Ok(())
    }

    pub(super) fn withdraw_paid_route_wallet_lightning(
        &mut self,
        mint_url: Option<&str>,
        invoice: &str,
    ) -> Result<()> {
        let invoice = invoice.trim();
        if invoice.is_empty() {
            return Err(anyhow!("Lightning invoice is empty"));
        }
        let mint_url = self.paid_route_wallet_mint(mint_url)?;
        let withdrawal = self.cashu_wallet()?.pay_lightning(&mint_url, invoice)?;
        let amount_sat = withdrawal.amount_sat;
        let fee_sat = withdrawal.fee_paid_sat;
        let overview = self.cashu_wallet()?.overview(false)?;
        self.sync_paid_route_wallet_overview(&overview)?;
        self.paid_route_wallet_last_action = NativePaidRouteWalletActionState {
            kind: "withdraw".to_string(),
            status_text: format!("Paid Lightning invoice for {amount_sat} sat"),
            mint_url: withdrawal.mint_url,
            amount_sat,
            amount_text: paid_route_sat_text(amount_sat),
            fee_sat,
            fee_text: paid_route_fee_text(fee_sat),
            quote_id: withdrawal.quote_id,
            preimage: withdrawal.preimage,
            ..NativePaidRouteWalletActionState::default()
        };
        Ok(())
    }

    fn cashu_wallet(&self) -> Result<&PaidRouteWalletRuntime> {
        self.cashu_wallet_runtime
            .as_ref()
            .ok_or_else(|| anyhow!("Cashu wallet runtime is unavailable"))
    }

    fn wallet_data_dir(&self) -> PathBuf {
        self.config_path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .map_or_else(|| PathBuf::from("."), Path::to_path_buf)
    }

    fn paid_route_wallet_mint(&self, explicit: Option<&str>) -> Result<String> {
        if let Some(mint) = explicit.map(str::trim).filter(|mint| !mint.is_empty()) {
            return normalize_paid_route_mint_url(mint);
        }
        let store = load_paid_route_store(&self.paid_route_store_path())?;
        if !store.wallet.default_mint.trim().is_empty() {
            return normalize_paid_route_mint_url(&store.wallet.default_mint);
        }
        Err(anyhow!(
            "No mint configured; add a mint before using the Cashu wallet"
        ))
    }

    fn ensure_paid_route_wallet_mint(
        &mut self,
        mint_url: &str,
        balance_msat: Option<u64>,
    ) -> Result<()> {
        let mint_url = normalize_paid_route_mint_url(mint_url)?;
        self.mutate_paid_route_store(|store| {
            let label = store
                .wallet
                .mints
                .iter()
                .find(|mint| mint.url == mint_url)
                .map_or_else(
                    || {
                        if mint_url == DEFAULT_PAID_EXIT_WALLET_MINT {
                            "Minibits".to_string()
                        } else {
                            String::new()
                        }
                    },
                    |mint| mint.label.clone(),
                );
            store.upsert_wallet_mint(&mint_url, label, balance_msat, unix_timestamp())
        })
    }

    fn sync_paid_route_wallet_overview(
        &mut self,
        overview: &cashu_service::CashuWalletOverview,
    ) -> Result<()> {
        self.mutate_paid_route_store(|store| {
            let mut changed = false;
            for entry in &overview.entries {
                if entry.unit != "sat" {
                    continue;
                }
                let label = store
                    .wallet
                    .mints
                    .iter()
                    .find(|mint| mint.url == entry.mint_url)
                    .map_or_else(
                        || {
                            if entry.mint_url == DEFAULT_PAID_EXIT_WALLET_MINT {
                                "Minibits".to_string()
                            } else {
                                String::new()
                            }
                        },
                        |mint| mint.label.clone(),
                    );
                changed |= store.upsert_wallet_mint(
                    &entry.mint_url,
                    label,
                    Some(entry.balance.saturating_mul(1000)),
                    unix_timestamp(),
                );
            }
            changed
        })
    }

    pub(super) fn buy_paid_route_offer(
        &mut self,
        offer_key: &str,
        mint_url: Option<&str>,
        channel_capacity_sat: Option<u64>,
    ) -> Result<()> {
        let buyer_npub = self
            .config
            .nostr_keys()?
            .public_key()
            .to_bech32()
            .context("failed to encode buyer npub")?;
        let path = self.paid_route_store_path();
        let mut store = load_paid_route_store(&path)?;
        let result = store.open_buyer_session(OpenPaidRouteBuyerSessionRequest {
            offer_selector: offer_key.to_string(),
            buyer_npub,
            mint_url: mint_url.map(ToOwned::to_owned),
            channel_capacity_sat,
            initial_paid_msat: 0,
            now_unix: unix_timestamp(),
        })?;
        if result.changed {
            write_paid_route_store(&path, &store)?;
        }

        let wallet_can_fund = paid_route_wallet_can_fund_channel(
            &store.wallet,
            &result.mint_url,
            result.channel_capacity_sat,
        );
        let free_probe_ready = store
            .buyer_session_allows_routing(&result.session_id, unix_timestamp())?;
        if !wallet_can_fund && !free_probe_ready {
            return Err(anyhow!(
                "Paid route created but is not ready: the selected mint needs at least {} sat to fund it",
                result.channel_capacity_sat
            ));
        }

        // Payment delivery is authenticated against the selected public exit.
        // Persist the seller before queuing the first payment, but let the daemon
        // install public routes only after the seller acknowledges admission.
        self.select_paid_route_session(&result.session_id, false)?;

        if wallet_can_fund {
            self.open_paid_route_channel_from_wallet(
                &result.session_id,
                Some(&result.mint_url),
                None,
                None,
                None,
            )?;
            let envelope_json = self.paid_route_payment_last_action.envelope_json.clone();
            if !envelope_json.trim().is_empty() {
                self.send_paid_route_payment_envelope(&envelope_json)?;
            }
        }

        let store = load_paid_route_store(&path)?;
        if store.buyer_session_allows_routing(&result.session_id, unix_timestamp())? {
            self.select_paid_route_session(&result.session_id, true)?;
        } else {
            return Err(anyhow!(
                "Paid route created but is not ready: the selected mint needs at least {} sat to fund it",
                result.channel_capacity_sat
            ));
        }

        Ok(())
    }

    pub(super) fn buy_best_paid_route_offer(
        &mut self,
        mint_url: Option<&str>,
        channel_capacity_sat: Option<u64>,
    ) -> Result<()> {
        let store = load_paid_route_store(&self.paid_route_store_path())?;
        let offer_key = store.best_rated_offer_key()?;
        self.buy_paid_route_offer(&offer_key, mint_url, channel_capacity_sat)
    }

    pub(super) fn select_paid_route_session(
        &mut self,
        session_id: &str,
        connect: bool,
    ) -> Result<()> {
        let session_id = session_id.trim();
        if session_id.is_empty() {
            return Err(anyhow!("paid route session id is empty"));
        }
        let store = load_paid_route_store(&self.paid_route_store_path())?;
        let seller_npub = store.buyer_session_seller_npub(session_id)?;
        if connect && !store.buyer_session_allows_routing(session_id, unix_timestamp())? {
            return Err(anyhow!(
                "paid route session is not ready to route yet; fund it or wait for seller admission"
            ));
        }
        self.config.select_public_paid_exit_node(&seller_npub)?;
        self.save_reload_and_refresh()?;
        if connect && !self.vpn_enabled {
            self.connect_vpn()?;
        }
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn record_paid_route_probe(
        &mut self,
        session_id: &str,
        realized_exit_ip: Option<&str>,
        observed_country_code: Option<&str>,
        observed_asn: Option<u32>,
        latency_ms: Option<u32>,
        jitter_ms: Option<u32>,
        packet_loss_ppm: Option<u32>,
        down_bps: Option<u64>,
        up_bps: Option<u64>,
        uptime_secs: Option<u64>,
        last_seen_unix: Option<u64>,
    ) -> Result<()> {
        let quality = PaidRouteQualityMetrics {
            latency_ms,
            jitter_ms,
            packet_loss_ppm,
            down_bps,
            up_bps,
            uptime_secs,
            last_seen_unix,
        };
        let path = self.paid_route_store_path();
        let mut store = load_paid_route_store(&path)?;
        let result = store.update_session_probe(UpdatePaidRouteSessionProbeRequest {
            session_id: session_id.to_string(),
            realized_exit_ip: realized_exit_ip.map(ToOwned::to_owned),
            observed_country_code: observed_country_code.map(ToOwned::to_owned),
            observed_asn,
            quality: (!quality.is_empty()).then_some(quality),
            now_unix: unix_timestamp(),
        })?;
        if result.changed {
            write_paid_route_store(&path, &store)?;
        }
        Ok(())
    }

    pub(super) fn probe_paid_route_session(
        &mut self,
        session_id: &str,
        timeout_secs: u64,
    ) -> Result<()> {
        let args = vec![
            "paid-exit".to_string(),
            "probe".to_string(),
            "--config".to_string(),
            self.config_path_str()?.to_string(),
            "--json".to_string(),
            session_id.trim().to_string(),
            "--timeout-secs".to_string(),
            timeout_secs.max(1).to_string(),
        ];
        let output = self.run_nvpn_vec(&args)?;
        let value = decode_paid_route_command_json_output(output, "nvpn paid-exit probe")?;
        self.paid_route_payment_last_action = paid_route_probe_action_state(&value);
        Ok(())
    }

    pub(super) fn create_paid_route_payment_envelope(
        &mut self,
        session_id: &str,
        kind: &str,
        payment_json: &str,
        delivered_units: Option<u64>,
        paid_msat: Option<u64>,
    ) -> Result<()> {
        let mut args = vec![
            "paid-exit".to_string(),
            "create-payment".to_string(),
            "--config".to_string(),
            self.config_path_str()?.to_string(),
            "--json".to_string(),
            session_id.trim().to_string(),
            "--kind".to_string(),
            kind.trim().to_string(),
            "--payment-stdin".to_string(),
        ];
        if let Some(delivered_units) = delivered_units {
            args.push("--delivered-units".to_string());
            args.push(delivered_units.to_string());
        }
        if let Some(paid_msat) = paid_msat {
            args.push("--paid-msat".to_string());
            args.push(paid_msat.to_string());
        }

        let output = self.run_nvpn_vec_with_stdin(&args, payment_json.as_bytes())?;
        let value = decode_paid_route_command_json_output(output, "nvpn paid-exit create-payment")?;
        self.paid_route_payment_last_action = paid_route_payment_action_state("create", &value)?;
        Ok(())
    }

    pub(super) fn open_paid_route_channel_from_wallet(
        &mut self,
        session_id: &str,
        mint_url: Option<&str>,
        paid_msat: Option<u64>,
        max_amount_per_output: Option<u64>,
        keyset_id: Option<&str>,
    ) -> Result<()> {
        let session_id = session_id.trim();
        if session_id.is_empty() {
            return Err(anyhow!("paid route session id is empty"));
        }
        let buyer_npub = self
            .config
            .nostr_keys()?
            .public_key()
            .to_bech32()
            .context("failed to encode buyer npub")?;
        let store_path = self.paid_route_store_path();
        let mut store = load_paid_route_store(&store_path)?;
        let request = paid_route_wallet_channel_open_request(
            &store,
            session_id,
            mint_url,
            paid_msat,
            max_amount_per_output,
            keyset_id,
        )?;
        let opened = self.cashu_wallet()?.open_spilman_channel(request)?;
        let attach =
            store.attach_buyer_spilman_channel(AttachPaidRouteBuyerSpilmanChannelRequest {
                session_id: session_id.to_string(),
                channel_id: opened.channel.channel_id.clone(),
                cashu_unit: opened.channel.unit.clone(),
                capacity_sat: opened.channel.capacity_sat,
                paid_msat: Some(opened.channel.opening_paid_msat),
                payment: opened.channel.payment.clone(),
                now_unix: unix_timestamp(),
            })?;
        let payment =
            store.build_buyer_payment_envelope(BuildPaidRouteBuyerPaymentEnvelopeRequest {
                session_id: session_id.to_string(),
                buyer_npub,
                kind: BuildPaidRouteBuyerPaymentEnvelopeKind::ChannelOpen,
                payment: opened.channel.payment.clone(),
                delivered_units: None,
                paid_msat: Some(opened.channel.opening_paid_msat),
                now_unix: unix_timestamp(),
            })?;
        if attach.changed || payment.changed {
            write_paid_route_store(&store_path, &store)?;
        }
        self.paid_route_payment_last_action =
            paid_route_payment_action_state("open_channel", &json!({ "payment": payment }))?;
        let amount_sat = opened.wallet_send.amount_sat;
        let fee_sat = opened.wallet_send.send_fee_sat;
        self.paid_route_wallet_last_action = NativePaidRouteWalletActionState {
            kind: "open_channel".to_string(),
            status_text: format!("Opened payment channel with {amount_sat} sat"),
            mint_url: opened.wallet_send.mint_url,
            amount_sat,
            amount_text: paid_route_sat_text(amount_sat),
            fee_sat,
            fee_text: paid_route_fee_text(fee_sat),
            operation_id: opened.wallet_send.operation_id,
            ..NativePaidRouteWalletActionState::default()
        };
        Ok(())
    }

    pub(super) fn sign_paid_route_payment_envelope_from_wallet(
        &mut self,
        session_id: &str,
        kind: &str,
        delivered_units: Option<u64>,
        paid_msat: Option<u64>,
    ) -> Result<()> {
        let kind = match kind.trim() {
            "channel-open" | "channel_open" => BuildPaidRouteBuyerPaymentEnvelopeKind::ChannelOpen,
            "balance-update" | "balance_update" => {
                BuildPaidRouteBuyerPaymentEnvelopeKind::BalanceUpdate
            }
            "cooperative-close" | "cooperative_close" => {
                BuildPaidRouteBuyerPaymentEnvelopeKind::CooperativeClose
            }
            other => return Err(anyhow!("unsupported paid route payment kind {other:?}")),
        };
        let buyer_npub = self
            .config
            .nostr_keys()?
            .public_key()
            .to_bech32()
            .context("failed to encode buyer npub")?;
        let signer = cashu_service::FileSpilmanPaymentSigner::load(&self.wallet_data_dir())
            .map_err(|error| anyhow!(error))?;
        let store_path = self.paid_route_store_path();
        let mut store = load_paid_route_store(&store_path)?;
        let result = store.build_buyer_signed_payment_envelope(
            &signer,
            BuildPaidRouteBuyerSignedPaymentEnvelopeRequest {
                session_id: session_id.trim().to_string(),
                buyer_npub,
                kind,
                delivered_units,
                paid_msat,
                now_unix: unix_timestamp(),
            },
        )?;
        if result.changed {
            write_paid_route_store(&store_path, &store)?;
        }
        self.paid_route_payment_last_action =
            paid_route_payment_action_state("sign", &json!({ "payment": result }))?;
        Ok(())
    }

    pub(super) fn close_paid_route_channel_from_wallet(
        &mut self,
        session_id: &str,
        publish: bool,
    ) -> Result<()> {
        let buyer_npub = self
            .config
            .nostr_keys()?
            .public_key()
            .to_bech32()
            .context("failed to encode buyer npub")?;
        let signer = cashu_service::FileSpilmanPaymentSigner::load(&self.wallet_data_dir())
            .map_err(|error| anyhow!(error))?;
        let store_path = self.paid_route_store_path();
        let mut store = load_paid_route_store(&store_path)?;
        let result = store.build_buyer_signed_payment_envelope(
            &signer,
            BuildPaidRouteBuyerSignedPaymentEnvelopeRequest {
                session_id: session_id.trim().to_string(),
                buyer_npub,
                kind: BuildPaidRouteBuyerPaymentEnvelopeKind::CooperativeClose,
                delivered_units: None,
                paid_msat: None,
                now_unix: unix_timestamp(),
            },
        )?;
        let envelope_json = serde_json::to_string(&result.envelope)
            .context("failed to encode paid route cooperative close envelope")?;
        if publish {
            self.send_paid_route_payment_envelope(&envelope_json)?;
            if result.changed {
                write_paid_route_store(&store_path, &store)?;
            }
        }
        self.paid_route_payment_last_action =
            paid_route_payment_action_state("settle", &json!({ "payment": result }))?;
        Ok(())
    }

    pub(super) fn apply_paid_route_payment_envelope(&mut self, envelope_json: &str) -> Result<()> {
        let args = vec![
            "paid-exit".to_string(),
            "apply-payment".to_string(),
            "--config".to_string(),
            self.config_path_str()?.to_string(),
            "--json".to_string(),
            "--envelope-stdin".to_string(),
        ];
        let output = self.run_nvpn_vec_with_stdin(&args, envelope_json.as_bytes())?;
        let value = decode_paid_route_command_json_output(output, "nvpn paid-exit apply-payment")?;
        self.paid_route_payment_last_action = paid_route_payment_action_state("apply", &value)?;
        Ok(())
    }

    pub(super) fn send_paid_route_payment_envelope(&mut self, envelope_json: &str) -> Result<()> {
        let value = self.send_paid_route_payment_envelope_value(envelope_json)?;
        self.paid_route_payment_last_action = paid_route_payment_send_action_state(&value);
        Ok(())
    }

    fn send_paid_route_payment_envelope_value(
        &mut self,
        envelope_json: &str,
    ) -> Result<serde_json::Value> {
        let args = vec![
            "paid-exit".to_string(),
            "send-payment".to_string(),
            "--config".to_string(),
            self.config_path_str()?.to_string(),
            "--json".to_string(),
            "--envelope-stdin".to_string(),
        ];
        let output = self.run_nvpn_vec_with_stdin(&args, envelope_json.as_bytes())?;
        decode_paid_route_command_json_output(output, "nvpn paid-exit send-payment")
    }

    pub(super) fn stream_paid_route_payments(
        &mut self,
        publish: bool,
        min_increment_msat: u64,
        limit: u64,
    ) -> Result<()> {
        let mut args = vec![
            "paid-exit".to_string(),
            "stream-payments".to_string(),
            "--config".to_string(),
            self.config_path_str()?.to_string(),
            "--json".to_string(),
            "--min-increment-msat".to_string(),
            min_increment_msat.to_string(),
        ];
        if publish {
            args.push("--publish".to_string());
        }
        if limit > 0 {
            args.push("--limit".to_string());
            args.push(limit.to_string());
        }
        let output = self.run_nvpn_vec(&args)?;
        let value =
            decode_paid_route_command_json_output(output, "nvpn paid-exit stream-payments")?;
        self.paid_route_payment_last_action = paid_route_payment_stream_action_state(&value)?;
        Ok(())
    }

    pub(super) fn receive_paid_route_payments(&mut self, duration_secs: u64) -> Result<()> {
        let duration_secs = duration_secs.clamp(1, 30).to_string();
        let output = self.run_nvpn([
            "paid-exit",
            "receive-payments",
            "--config",
            self.config_path_str()?,
            "--duration-secs",
            &duration_secs,
            "--json",
        ])?;
        let value =
            decode_paid_route_command_json_output(output, "nvpn paid-exit receive-payments")?;
        self.paid_route_payment_last_action = paid_route_payment_receive_action_state(&value)?;
        Ok(())
    }

    pub(super) fn collect_paid_exit_channel(&mut self, channel_id: &str) -> Result<()> {
        let channel_id = channel_id.trim();
        if channel_id.is_empty() {
            return Err(anyhow!("paid exit channel id is empty"));
        }
        let output = self.run_nvpn([
            "paid-exit",
            "collect",
            "--config",
            self.config_path_str()?,
            "--json",
            channel_id,
        ])?;
        let value = decode_paid_route_command_json_output(output, "nvpn paid-exit collect")?;
        self.paid_route_payment_last_action = paid_route_payment_collect_action_state(&value);
        if let Some(wallet_collect) = value
            .get("wallet_collect")
            .filter(|wallet_collect| !wallet_collect.is_null())
        {
            let amount_sat = json_u64(wallet_collect, "amount_sat");
            self.paid_route_wallet_last_action = NativePaidRouteWalletActionState {
                kind: "collect".to_string(),
                status_text: if amount_sat > 0 {
                    format!("Added {} to wallet", paid_route_sat_text(amount_sat))
                } else {
                    "Channel funds already in wallet".to_string()
                },
                mint_url: json_string(wallet_collect, "mint_url"),
                amount_sat,
                amount_text: paid_route_sat_text(amount_sat),
                ..NativePaidRouteWalletActionState::default()
            };
        }
        Ok(())
    }

    pub(super) fn collect_due_paid_exit_channels(&mut self) -> Result<()> {
        let output = self.run_nvpn([
            "paid-exit",
            "collect-due",
            "--config",
            self.config_path_str()?,
            "--json",
        ])?;
        let value = decode_paid_route_command_json_output(output, "nvpn paid-exit collect-due")?;
        self.paid_route_payment_last_action = paid_route_payment_collect_due_action_state(&value);
        let amount_sat = value
            .get("collected")
            .and_then(serde_json::Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|entry| entry.get("wallet_collect"))
            .map(|wallet_collect| json_u64(wallet_collect, "amount_sat"))
            .fold(0_u64, u64::saturating_add);
        if amount_sat > 0 {
            self.paid_route_wallet_last_action = NativePaidRouteWalletActionState {
                kind: "collect".to_string(),
                status_text: format!("Added {} to wallet", paid_route_sat_text(amount_sat)),
                amount_sat,
                amount_text: paid_route_sat_text(amount_sat),
                ..NativePaidRouteWalletActionState::default()
            };
        }
        Ok(())
    }

    pub(super) fn publish_paid_exit_offer(&mut self) -> Result<()> {
        self.config.paid_exit.access.upstream = selected_paid_exit_upstream(&self.config);
        self.save_config()?;
        let output = self.run_nvpn([
            "paid-exit",
            "run",
            "--config",
            self.config_path_str()?,
            "--publish",
            "--json",
        ])?;
        ensure_success("nvpn paid-exit offer --publish", &output)
    }

    pub(super) fn discover_paid_route_offers(&mut self, _duration_secs: u64) -> Result<()> {
        let rating_discovery = &self.config.paid_exit.rating_discovery;
        let mut args = vec![
            "paid-exit".to_string(),
            "discover".to_string(),
            "--config".to_string(),
            self.config_path_str()?.to_string(),
            "--json".to_string(),
        ];
        if !rating_discovery.file.trim().is_empty() {
            args.push("--fips-peer-ratings".to_string());
            args.push(rating_discovery.file.clone());
        }
        for author in &rating_discovery.trusted_authors {
            args.push("--trusted-rating-author".to_string());
            args.push(author.clone());
        }
        if rating_discovery.configured() {
            args.push("--rating-scope".to_string());
            args.push(rating_discovery.scope.clone());
        }
        let output = self.run_nvpn_vec(&args)?;
        ensure_success("nvpn paid-exit discover", &output)
    }

    fn run_nvpn_vec(&self, args: &[String]) -> Result<Output> {
        let Some(nvpn_bin) = &self.nvpn_bin else {
            return Err(anyhow!(
                "nvpn CLI binary not found; set {NVPN_BIN_ENV} or install nvpn"
            ));
        };
        Command::new(nvpn_bin)
            .args(args)
            .hide_console_window()
            .output()
            .with_context(|| format!("failed to execute {}", nvpn_bin.display()))
    }

    fn run_nvpn_vec_with_stdin(&self, args: &[String], stdin_bytes: &[u8]) -> Result<Output> {
        let Some(nvpn_bin) = &self.nvpn_bin else {
            return Err(anyhow!(
                "nvpn CLI binary not found; set {NVPN_BIN_ENV} or install nvpn"
            ));
        };
        let mut child = Command::new(nvpn_bin)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .hide_console_window()
            .spawn()
            .with_context(|| format!("failed to execute {}", nvpn_bin.display()))?;
        {
            let stdin = child
                .stdin
                .as_mut()
                .ok_or_else(|| anyhow!("failed to open nvpn stdin"))?;
            stdin
                .write_all(stdin_bytes)
                .context("failed to write nvpn stdin")?;
        }
        child
            .wait_with_output()
            .with_context(|| format!("failed to wait for {}", nvpn_bin.display()))
    }
}
