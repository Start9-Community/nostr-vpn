impl NativeAppRuntime {
    pub(super) fn refresh_paid_route_wallet_history(&mut self) -> Result<()> {
        use crate::native_state::NativePaidRouteWalletActivityState;
        use cashu_service::{CashuWalletActivityKind as Kind, CashuWalletActivityStatus as Status};

        // Read the daemon's local activity log without polling mints or replacing
        // the active receive invoice / send result.
        let activity = match self.cashu_wallet().and_then(|wallet| wallet.activity()) {
            Ok(activity) => activity,
            Err(error) => {
                self.paid_route_wallet_history.error = format!("{error:#}");
                return Err(error);
            }
        };
        let mut entries: Vec<_> = activity
            .into_iter()
            .map(|entry| NativePaidRouteWalletActivityState {
                id: entry.id,
                kind: match entry.kind {
                    Kind::TopUp => "top_up",
                    Kind::LightningPayment => "lightning_payment",
                    Kind::TokenSend => "token_send",
                    Kind::TokenReceive => "token_receive",
                    Kind::ChannelCollect => "channel_collect",
                }
                .to_string(),
                status: match entry.status {
                    Status::Pending => "pending",
                    Status::Complete => "complete",
                    Status::Reclaimed => "reclaimed",
                    Status::Expired => "expired",
                }
                .to_string(),
                mint_url: entry.mint_url,
                amount_sat: entry.amount_sat,
                fee_sat: entry.fee_sat.unwrap_or_default(),
                created_at_unix: entry.created_at_unix,
            })
            .collect();
        entries.sort_by(|left, right| {
            right
                .created_at_unix
                .cmp(&left.created_at_unix)
                .then_with(|| left.id.cmp(&right.id))
        });
        self.paid_route_wallet_history.entries = entries;
        self.paid_route_wallet_history.loaded = true;
        self.paid_route_wallet_history.error.clear();
        Ok(())
    }
}
