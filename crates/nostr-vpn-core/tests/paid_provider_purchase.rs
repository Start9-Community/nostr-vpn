#![cfg(feature = "paid-exit")]

use nostr_sdk::prelude::*;
use nostr_vpn_core::paid_route_store::{OpenPaidRouteBuyerSessionRequest, PaidRouteStore};
use nostr_vpn_core::paid_routes::{
    ManualPaidExitProvider, PaidExitConfig, signed_paid_exit_offer_from_config,
};

#[test]
fn provider_link_to_purchase_uses_an_affordable_channel_not_the_seller_maximum() {
    let seller = Keys::generate();
    let buyer = Keys::generate();
    let mut config = PaidExitConfig {
        enabled: true,
        ..Default::default()
    };
    config.pricing.price_msat_per_gb = 100_000;
    config.channel.max_channel_capacity_sat = 1_000;
    config.channel.accepted_mints = vec!["https://mint.example".into()];
    let link = ManualPaidExitProvider::seller_link(&seller.public_key().to_hex(), &config).unwrap();
    let provider =
        ManualPaidExitProvider::parse(&link.replace("paid-exit/npub", "paid-exit/@npub")).unwrap();
    let now = Timestamp::now().as_secs();
    let signed =
        signed_paid_exit_offer_from_config("internet-exit", &seller, &config, None, now).unwrap();
    let mut store = PaidRouteStore::default();
    store.upsert_wallet_mint(&provider.mint, "", Some(56_000), now);
    store.upsert_signed_offer(signed, vec![], now).unwrap();
    let result = store
        .open_buyer_session(OpenPaidRouteBuyerSessionRequest {
            offer_selector: provider.npub,
            buyer_npub: buyer.public_key().to_bech32().unwrap(),
            mint_url: Some(provider.mint),
            channel_capacity_sat: None,
            initial_paid_msat: 0,
            now_unix: now,
        })
        .unwrap();
    assert_eq!(result.channel_capacity_sat, 11);
    assert_eq!(store.channels[&result.channel_id].payment.capacity_sat, 11);
}
