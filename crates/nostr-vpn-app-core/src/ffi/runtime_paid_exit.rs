#[cfg(feature = "paid-exit")]
mod paid_exit {
    use std::collections::HashSet;
    use std::io::Write as _;
    use std::process::Stdio;

    use nostr_sdk::prelude::ToBech32;
    use nostr_vpn_core::paid_route_store::{
        AttachPaidRouteBuyerSpilmanChannelRequest, BuildPaidRouteBuyerPaymentEnvelopeKind,
        BuildPaidRouteBuyerPaymentEnvelopeRequest, BuildPaidRouteBuyerSignedPaymentEnvelopeRequest,
        OpenPaidRouteBuyerSessionRequest, PaidRouteChannelRecord, PaidRouteChannelRole,
        PaidRouteLifecycleStatus, PaidRouteSellerCollectionState, PaidRouteStore, PaidRouteWalletState,
        UpdatePaidRouteSessionProbeRequest, load_paid_route_store, normalize_paid_route_mint_url,
        paid_route_store_file_path, write_paid_route_store,
    };
    use nostr_vpn_core::paid_routes::{
        PaidExitConfig, PaidExitUpstream, PaidRouteAccessState, PaidRouteCountryClaim,
        PaidRouteOffer, PaidRouteQualityMetrics, PaidRouteRoutingDecision,
        normalize_paid_route_country_code, paid_route_country_claim,
    };
    use serde_json::json;

    use crate::native_state::{
        NativePaidRouteChannelState, NativePaidRouteOfferState, NativePaidRouteSessionState,
        NativePaidRouteWalletMintState,
    };

    use super::{
        AppConfig, Command, CommandWindowExt, Context, DaemonRuntimeState, NVPN_BIN_ENV,
        NativeAppRuntime,
        NativePaidExitSellerState, NativePaidRouteMarketFilterState, NativePaidRouteMarketState,
        NativePaidRoutePaymentActionState, NativePaidRouteWalletActionState,
        NativePaidRouteWalletState, Output, PaidExitSellerEgress, Path, PathBuf,
        PortMappingStatus, Result, age_secs_since, anyhow, compact_age_text,
        effective_config_relays, ensure_success, extract_json_document, normalize_nostr_pubkey,
        peer_offers_exit_node, short_pubkey, unix_timestamp,
    };

    const PAID_ROUTE_WALLET_TOP_UP_POLL_CADENCE: std::time::Duration =
        std::time::Duration::from_secs(3);

    include!("paid_exit_wallet_runtime.rs");
    include!("paid_exit_actions.rs");
    include!("paid_exit_wallet_helpers.rs");
    include!("paid_exit_state.rs");
    include!("paid_exit_text.rs");
    include!("paid_exit_json.rs");

    #[cfg(test)]
    mod paid_route_offer_order_tests {
        use super::*;

        #[test]
        fn price_text_normalizes_to_gigabytes_and_purchasing_power() {
            assert_eq!(
                paid_route_price_text(25, 1_000_000),
                "25 sat / GB · 1 sat ≈ 40 MB"
            );
            assert_eq!(paid_route_price_text(0, 1_000_000), "free");
        }

        #[test]
        fn default_order_ranks_good_unknown_bad_ratings() {
            let mut offers = [
                offer("bad", Some(-80), 1),
                offer("unknown", None, 1),
                offer("good", Some(80), 1),
            ];

            offers.sort_by(|left, right| paid_route_offer_order(left, right, "quality"));

            assert_eq!(
                offers
                    .iter()
                    .map(|offer| offer.key.as_str())
                    .collect::<Vec<_>>(),
                vec!["good", "unknown", "bad"]
            );
        }

        #[test]
        fn price_order_uses_rating_as_tie_breaker() {
            let mut offers = [offer("bad", Some(-80), 10), offer("good", Some(80), 10)];

            offers.sort_by(|left, right| paid_route_offer_order(left, right, "price"));

            assert_eq!(
                offers
                    .iter()
                    .map(|offer| offer.key.as_str())
                    .collect::<Vec<_>>(),
                vec!["good", "bad"]
            );
        }

        #[test]
        fn empty_wallet_reports_a_known_zero_balance_without_nav_badge() {
            let state = paid_route_wallet_state(
                &PaidRouteWalletState::default(),
                &NativePaidRouteWalletActionState::default(),
            );

            assert!(state.balance_known);
            assert_eq!(state.total_balance_msat, 0);
            assert_eq!(state.total_balance_text, "0 sat");
            assert!(state.navigation_balance_text.is_empty());
        }

        #[test]
        fn unchecked_mint_omits_unknown_balance_copy() {
            let mut store = PaidRouteStore::default();
            assert!(store.upsert_wallet_mint(
                "https://mint.example",
                "Example",
                None,
                0,
            ));

            let state = paid_route_wallet_state(
                &store.wallet,
                &NativePaidRouteWalletActionState::default(),
            );

            assert!(!state.balance_known);
            assert!(state.total_balance_text.is_empty());
            assert!(state.mints[0].balance_text.is_empty());
        }

        #[test]
        fn native_wallet_state_keeps_multiple_mints_for_gui_rows() {
            let mut store = PaidRouteStore::default();
            assert!(store.upsert_wallet_mint(
                "https://mint-one.example",
                "One",
                None,
                1,
            ));
            assert!(store.upsert_wallet_mint(
                "https://mint-two.example",
                "Two",
                None,
                2,
            ));

            let state = paid_route_wallet_state(
                &store.wallet,
                &NativePaidRouteWalletActionState::default(),
            );

            assert_eq!(state.mints.len(), 2);
            assert_ne!(state.mints[0].url, state.mints[1].url);
            assert_eq!(state.mints.iter().filter(|mint| mint.is_default).count(), 1);
        }

        #[test]
        fn top_up_activity_matches_the_pending_quote() {
            let value = json!({
                "activity": [
                    {"kind": "top_up", "quote_id": "other", "status": "expired"},
                    {"kind": "top_up", "quote_id": "wanted", "status": "complete"}
                ]
            });

            assert_eq!(
                paid_route_top_up_activity_status(&value, "wanted"),
                Some(PaidRouteTopUpActivityStatus::Complete)
            );
            assert_eq!(paid_route_top_up_activity_status(&value, "missing"), None);
        }

        fn offer(
            key: &str,
            rating_score: Option<i64>,
            price_msat: u64,
        ) -> NativePaidRouteOfferState {
            NativePaidRouteOfferState {
                key: key.to_string(),
                has_rating: rating_score.is_some(),
                rating_score: rating_score.unwrap_or_default(),
                price_msat,
                per_units: 1,
                ..NativePaidRouteOfferState::default()
            }
        }
    }
}

#[cfg(not(feature = "paid-exit"))]
const PAID_EXIT_NOT_BUILT_STATUS: &str = "Paid exit support was not built into this app";

#[cfg(not(feature = "paid-exit"))]
impl NativeAppRuntime {
    fn paid_exit_seller_state(
        &self,
        _app: Option<&AppConfig>,
        _port_mapping: Option<&PortMappingStatus>,
        _mobile: bool,
    ) -> NativePaidExitSellerState {
        NativePaidExitSellerState {
            supported: false,
            status_text: self.paid_exit_not_built_status_text(),
            ..NativePaidExitSellerState::default()
        }
    }

    fn paid_route_market_state(&self, _app: Option<&AppConfig>) -> NativePaidRouteMarketState {
        NativePaidRouteMarketState {
            supported: false,
            status_text: self.paid_exit_not_built_status_text(),
            wallet: NativePaidRouteWalletState {
                last_action: self.paid_route_wallet_last_action.clone(),
                ..NativePaidRouteWalletState::default()
            },
            last_payment_action: self.paid_route_payment_last_action.clone(),
            filter: self.paid_route_market_filter.clone(),
            ..NativePaidRouteMarketState::default()
        }
    }

    fn active_paid_route_exit_ip(&self, _selected_exit_node: &str) -> Option<String> {
        let _ = self;
        None
    }

    fn add_paid_route_wallet_mint(&mut self, _url: &str, _label: Option<&str>) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn remove_paid_route_wallet_mint(&mut self, _url: &str) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn set_paid_route_default_mint(&mut self, _url: &str) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn refresh_paid_route_wallet(&mut self, _refresh: bool) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn top_up_paid_route_wallet(
        &mut self,
        _mint_url: Option<&str>,
        _amount_sat: u64,
    ) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn receive_paid_route_wallet_token(&mut self, _token: &str) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn preview_paid_route_wallet_token(&mut self, _token: &str) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn send_paid_route_wallet_token(
        &mut self,
        _mint_url: Option<&str>,
        _amount_sat: u64,
    ) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn withdraw_paid_route_wallet_lightning(
        &mut self,
        _mint_url: Option<&str>,
        _invoice: &str,
    ) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn buy_paid_route_offer(
        &mut self,
        _offer_key: &str,
        _mint_url: Option<&str>,
        _channel_capacity_sat: Option<u64>,
    ) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn buy_best_paid_route_offer(
        &mut self,
        _mint_url: Option<&str>,
        _channel_capacity_sat: Option<u64>,
    ) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn select_paid_route_session(&mut self, _session_id: &str, _connect: bool) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn probe_paid_route_session(&mut self, _session_id: &str, _timeout_secs: u64) -> Result<()> {
        self.paid_exit_not_built()
    }

    #[allow(clippy::too_many_arguments)]
    fn record_paid_route_probe(
        &mut self,
        _session_id: &str,
        _realized_exit_ip: Option<&str>,
        _observed_country_code: Option<&str>,
        _observed_asn: Option<u32>,
        _latency_ms: Option<u32>,
        _jitter_ms: Option<u32>,
        _packet_loss_ppm: Option<u32>,
        _down_bps: Option<u64>,
        _up_bps: Option<u64>,
        _uptime_secs: Option<u64>,
        _last_seen_unix: Option<u64>,
    ) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn create_paid_route_payment_envelope(
        &mut self,
        _session_id: &str,
        _kind: &str,
        _payment_json: &str,
        _delivered_units: Option<u64>,
        _paid_msat: Option<u64>,
    ) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn open_paid_route_channel_from_wallet(
        &mut self,
        _session_id: &str,
        _mint_url: Option<&str>,
        _paid_msat: Option<u64>,
        _max_amount_per_output: Option<u64>,
        _keyset_id: Option<&str>,
    ) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn sign_paid_route_payment_envelope_from_wallet(
        &mut self,
        _session_id: &str,
        _kind: &str,
        _delivered_units: Option<u64>,
        _paid_msat: Option<u64>,
    ) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn close_paid_route_channel_from_wallet(
        &mut self,
        _session_id: &str,
        _publish: bool,
    ) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn apply_paid_route_payment_envelope(&mut self, _envelope_json: &str) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn send_paid_route_payment_envelope(&mut self, _envelope_json: &str) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn stream_paid_route_payments(
        &mut self,
        _publish: bool,
        _min_increment_msat: u64,
        _limit: u64,
    ) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn receive_paid_route_payments(&mut self, _duration_secs: u64) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn collect_paid_exit_channel(&mut self, _channel_id: &str) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn collect_due_paid_exit_channels(&mut self) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn publish_paid_exit_offer(&mut self) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn discover_paid_route_offers(&mut self, _duration_secs: u64) -> Result<()> {
        self.paid_exit_not_built()
    }

    fn paid_exit_not_built<T>(&mut self) -> Result<T> {
        let status_text = self.paid_exit_not_built_status_text();
        self.paid_route_wallet_last_action = NativePaidRouteWalletActionState {
            kind: "unsupported".to_string(),
            status_text: status_text.clone(),
            ..NativePaidRouteWalletActionState::default()
        };
        self.paid_route_payment_last_action = NativePaidRoutePaymentActionState {
            kind: "unsupported".to_string(),
            status_text,
            ..NativePaidRoutePaymentActionState::default()
        };
        Err(paid_exit_not_built_error())
    }

    fn paid_exit_not_built_status_text(&self) -> String {
        if self.startup_error.is_some() {
            "Paid exit support is unavailable while app startup is incomplete".to_string()
        } else {
            PAID_EXIT_NOT_BUILT_STATUS.to_string()
        }
    }
}

#[cfg(not(feature = "paid-exit"))]
fn paid_exit_not_built_error() -> anyhow::Error {
    anyhow!("paid exit support was not built into this app")
}
