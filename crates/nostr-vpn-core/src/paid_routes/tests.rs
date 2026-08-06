use super::events::{paid_route_offer_tags, paid_route_tag};
use super::*;

#[test]
fn paid_exit_config_normalizes_operator_hints() {
    let mut config = PaidExitConfig {
        enabled: true,
        access: PaidRouteAccessPolicy {
            upstream: PaidExitUpstream::WireGuardExit,
            private_vpn_access: PaidRoutePrivateVpnAccess::Denied,
        },
        pricing: PaidRoutePricing {
            price_msat: 25,
            per_units: 0,
            connection_minimum_msat_per_day: 0,
        },
        channel: PaidRouteChannelTerms {
            accepted_mints: vec![
                " https://mint.example ".to_string(),
                "https://mint.example".to_string(),
                "https://mint2.example, https://mint3.example".to_string(),
            ],
            max_channel_capacity_sat: 0,
            channel_expiry_secs: 0,
            free_probe_units: 100,
            grace_units: 20,
        },
        location: PaidRouteLocationHint {
            country_code: "fi".to_string(),
            region: " Uusimaa ".to_string(),
            asn: Some(12_345),
            network_class: ExitNetworkClass::Residential,
        },
        ip_support: PaidRouteIpSupport::default(),
        rating_discovery: PaidExitRatingDiscoveryConfig {
            file: " ratings.json ".to_string(),
            relays: vec![
                " wss://ratings-b.example ".to_string(),
                "wss://ratings-a.example,wss://ratings-b.example".to_string(),
            ],
            trusted_authors: vec![
                " npub1authorb ".to_string(),
                "npub1authora,npub1authorb".to_string(),
            ],
            scope: " ".to_string(),
        },
    };

    config.normalize();

    assert_eq!(config.pricing.per_units, 1);
    assert_eq!(config.channel.max_channel_capacity_sat, 1);
    assert_eq!(config.channel.channel_expiry_secs, 1);
    assert_eq!(
        config.channel.accepted_mints,
        vec![
            "https://mint.example",
            "https://mint2.example",
            "https://mint3.example"
        ]
    );
    assert_eq!(config.location.country_code, "FI");
    assert!(config.location.region.is_empty());
    assert_eq!(config.location.network_class, ExitNetworkClass::Unknown);
    assert_eq!(config.rating_discovery.file, "ratings.json");
    assert_eq!(
        config.rating_discovery.relays,
        vec!["wss://ratings-a.example", "wss://ratings-b.example"]
    );
    assert_eq!(
        config.rating_discovery.trusted_authors,
        vec!["npub1authora", "npub1authorb"]
    );
    assert_eq!(
        config.rating_discovery.scope,
        DEFAULT_FIPS_PEER_RATING_SCOPE
    );
}

#[test]
fn paid_exit_country_is_exactly_two_ascii_letters() {
    assert_eq!(normalize_paid_route_country_code(" fi "), "FI");
    assert!(normalize_paid_route_country_code("FIN").is_empty());
    assert!(normalize_paid_route_country_code("F1").is_empty());
    assert!(normalize_paid_route_country_code("ÅX").is_empty());
}

#[test]
fn paid_route_channel_default_expires_next_day() {
    assert_eq!(PaidRouteChannelTerms::default().channel_expiry_secs, 86_400);
}

#[test]
fn country_claim_status_compares_claimed_and_observed_exit_country() {
    let no_claim = paid_route_country_claim("", Some("FI"));
    assert_eq!(no_claim.status, PaidRouteCountryClaimStatus::NoClaim);
    assert_eq!(no_claim.matches_claim(), None);

    let unknown = paid_route_country_claim("fi", None);
    assert_eq!(unknown.claimed_country_code, "FI");
    assert_eq!(unknown.status, PaidRouteCountryClaimStatus::Unknown);
    assert_eq!(unknown.matches_claim(), None);

    let matched = paid_route_country_claim("fi", Some(" FI "));
    assert_eq!(matched.status, PaidRouteCountryClaimStatus::Match);
    assert_eq!(matched.matches_claim(), Some(true));

    let mismatch = paid_route_country_claim("FI", Some("DE"));
    assert_eq!(mismatch.status, PaidRouteCountryClaimStatus::Mismatch);
    assert_eq!(mismatch.matches_claim(), Some(false));
}

#[test]
fn route_usage_accounting_uses_cashu_service_spilman_policy() {
    let config = PaidExitConfig {
        enabled: true,
        pricing: PaidRoutePricing {
            price_msat: 25,
            per_units: 10,
            ..PaidRoutePricing::default()
        },
        channel: PaidRouteChannelTerms {
            free_probe_units: 100,
            grace_units: 20,
            ..PaidRouteChannelTerms::default()
        },
        ..PaidExitConfig::default()
    };

    let usage = PaidRouteUsage {
        rx_bytes: 90,
        tx_bytes: 40,
        billable_bytes: 130,
        ..PaidRouteUsage::default()
    };

    assert_eq!(config.amount_due_msat(&usage), 75);
    assert!(config.can_continue_routing(&usage, 25));
    assert!(!config.can_continue_routing(&usage, 24));
}

#[test]
fn route_pricing_prorates_fractional_units_before_rounding() {
    let config = PaidExitConfig {
        enabled: true,
        pricing: PaidRoutePricing {
            price_msat: 25,
            per_units: 10,
            ..PaidRoutePricing::default()
        },
        channel: PaidRouteChannelTerms {
            free_probe_units: 0,
            grace_units: 0,
            ..PaidRouteChannelTerms::default()
        },
        ..PaidExitConfig::default()
    };

    assert_eq!(config.amount_due_msat(&usage_bytes(1)), 3);
    assert_eq!(config.amount_due_msat(&usage_bytes(10)), 25);
    assert_eq!(config.amount_due_msat(&usage_bytes(11)), 28);

    let grace = config.routing_decision(&usage_bytes(11), 25);
    assert_eq!(grace.amount_due_msat, 28);
    assert_eq!(grace.unpaid_msat, 3);
}

#[test]
fn connection_minimum_is_prorated_and_acts_as_floor() {
    let config = PaidExitConfig {
        enabled: true,
        pricing: PaidRoutePricing {
            price_msat: 100,
            per_units: 10,
            connection_minimum_msat_per_day: 86_400,
        },
        channel: PaidRouteChannelTerms {
            free_probe_units: 0,
            grace_units: 0,
            ..PaidRouteChannelTerms::default()
        },
        ..PaidExitConfig::default()
    };

    let idle = PaidRouteUsage {
        active_millis: 1_000,
        ..PaidRouteUsage::default()
    };
    assert_eq!(config.amount_due_msat(&idle), 1);

    let below_floor = PaidRouteUsage {
        active_millis: 1_000,
        billable_bytes: 1,
        ..PaidRouteUsage::default()
    };
    assert_eq!(config.amount_due_msat(&below_floor), 10);

    let above_floor = PaidRouteUsage {
        active_millis: 1_000,
        billable_bytes: 20,
        ..PaidRouteUsage::default()
    };
    assert_eq!(config.amount_due_msat(&above_floor), 200);
}

#[test]
fn connection_minimum_due_can_tolerate_active_time_skew_without_discounting_traffic() {
    let config = PaidExitConfig {
        enabled: true,
        pricing: PaidRoutePricing {
            price_msat: 100,
            per_units: 10,
            connection_minimum_msat_per_day: 86_400,
        },
        channel: PaidRouteChannelTerms {
            free_probe_units: 0,
            grace_units: 0,
            ..PaidRouteChannelTerms::default()
        },
        ..PaidExitConfig::default()
    };
    let usage = PaidRouteUsage {
        active_millis: 2_000,
        billable_bytes: 2,
        ..PaidRouteUsage::default()
    };

    assert_eq!(config.amount_due_msat(&usage), 20);
    assert_eq!(
        config.amount_due_msat_with_connection_minimum_skew(&usage, 1_000),
        20
    );

    let idle = PaidRouteUsage {
        active_millis: 2_000,
        ..PaidRouteUsage::default()
    };
    assert_eq!(config.amount_due_msat(&idle), 2);
    assert_eq!(
        config.amount_due_msat_with_connection_minimum_skew(&idle, 1_000),
        1
    );
}

#[test]
fn connection_minimum_participates_in_routing_decision() {
    let config = PaidExitConfig {
        enabled: true,
        pricing: PaidRoutePricing {
            price_msat: 0,
            connection_minimum_msat_per_day: 86_400,
            ..PaidRoutePricing::default()
        },
        channel: PaidRouteChannelTerms {
            free_probe_units: 1_000,
            grace_units: 1_000,
            ..PaidRouteChannelTerms::default()
        },
        ..PaidExitConfig::default()
    };
    let usage = PaidRouteUsage {
        active_millis: 1_000,
        ..PaidRouteUsage::default()
    };

    let paid = config.routing_decision(&usage, 1);
    assert_eq!(paid.state, PaidRouteAccessState::Paid);
    assert!(paid.allow_routing);
    assert_eq!(paid.amount_due_msat, 1);

    let suspended = config.routing_decision(&usage, 0);
    assert_eq!(suspended.state, PaidRouteAccessState::Suspended);
    assert!(!suspended.allow_routing);
    assert_eq!(suspended.unpaid_msat, 1);
}

#[test]
fn route_decision_reports_free_paid_grace_and_suspended_states() {
    let config = PaidExitConfig {
        enabled: true,
        pricing: PaidRoutePricing {
            price_msat: 25,
            per_units: 10,
            ..PaidRoutePricing::default()
        },
        channel: PaidRouteChannelTerms {
            free_probe_units: 100,
            grace_units: 20,
            ..PaidRouteChannelTerms::default()
        },
        ..PaidExitConfig::default()
    };

    let free = config.routing_decision(&usage_bytes(100), 0);
    assert_eq!(free.state, PaidRouteAccessState::FreeProbe);
    assert!(free.allow_routing);
    assert_eq!(free.amount_due_msat, 0);
    assert_eq!(free.free_probe_remaining_units, 0);

    let paid = config.routing_decision(&usage_bytes(130), 75);
    assert_eq!(paid.state, PaidRouteAccessState::Paid);
    assert!(paid.allow_routing);
    assert_eq!(paid.unpaid_msat, 0);

    let grace = config.routing_decision(&usage_bytes(130), 25);
    assert_eq!(grace.state, PaidRouteAccessState::Grace);
    assert!(grace.allow_routing);
    assert_eq!(grace.amount_due_msat, 75);
    assert_eq!(grace.enforced_amount_due_msat, 25);
    assert_eq!(grace.unpaid_msat, 50);

    let suspended = config.routing_decision(&usage_bytes(130), 24);
    assert_eq!(suspended.state, PaidRouteAccessState::Suspended);
    assert!(!suspended.allow_routing);
    assert_eq!(suspended.unpaid_msat, 51);
}

#[test]
fn session_routing_decision_bills_bytes() {
    let config = PaidExitConfig {
        enabled: true,
        pricing: PaidRoutePricing {
            price_msat: 100,
            per_units: 1_000_000,
            connection_minimum_msat_per_day: 0,
        },
        channel: PaidRouteChannelTerms {
            free_probe_units: 0,
            grace_units: 0,
            ..PaidRouteChannelTerms::default()
        },
        ..PaidExitConfig::default()
    };

    let session = PaidRouteSession {
        session_id: "session-1".to_string(),
        lease_id: "lease-1".to_string(),
        usage: PaidRouteUsage {
            rx_bytes: 2_000_000,
            tx_bytes: 1_000_000,
            rx_packets: 2,
            tx_packets: 3,
            billable_bytes: 3_000_000,
            ..PaidRouteUsage::default()
        },
        payment: PaidRoutePaymentState {
            paid_msat: 300,
            ..PaidRoutePaymentState::default()
        },
        realized_exit_ip: None,
        observed_country_code: None,
        observed_asn: None,
        quality: None,
    };

    let decision = session.routing_decision(&config);

    assert_eq!(decision.state, PaidRouteAccessState::Paid);
    assert_eq!(decision.delivered_units, 3_000_000);
    assert_eq!(decision.amount_due_msat, 300);
    assert!(session.can_continue_routing(&config));
}

#[test]
fn offer_json_does_not_publish_raw_exit_ip() {
    let offer = PaidRouteOffer {
        offer_id: "offer-1".to_string(),
        seller_npub: "npub1seller".to_string(),
        receiver_pubkey_hex: String::new(),
        service: PaidRouteServiceKind::InternetExit,
        access: PaidRouteAccessPolicy {
            upstream: PaidExitUpstream::WireGuardExit,
            private_vpn_access: PaidRoutePrivateVpnAccess::Denied,
        },
        pricing: PaidRoutePricing::default(),
        channel: PaidRouteChannelTerms::default(),
        location: PaidRouteLocationHint {
            country_code: "FI".to_string(),
            network_class: ExitNetworkClass::Satellite,
            ..PaidRouteLocationHint::default()
        },
        ip_support: PaidRouteIpSupport::default(),
        quality: None,
    };

    let json = serde_json::to_string(&offer).expect("serialize offer");
    assert!(json.contains("country_code"));
    assert!(json.contains("satellite"));
    assert!(!json.contains("public_ip"));
    assert!(!json.contains("publicIp"));
    assert!(!json.contains("realized_exit_ip"));
    assert!(json.contains("wireguard_exit"));
    assert!(json.contains("denied"));
    assert!(!json.contains("private_routes"));
}

#[test]
fn enum_parsers_accept_user_friendly_spellings() {
    assert_eq!(
        "community-mesh".parse::<ExitNetworkClass>(),
        Ok(ExitNetworkClass::CommunityMesh)
    );
    assert_eq!(
        "wg".parse::<PaidExitUpstream>(),
        Ok(PaidExitUpstream::WireGuardExit)
    );
}

#[test]
fn signed_offer_event_roundtrips_without_raw_exit_endpoint() {
    let seller = Keys::generate();
    let offer = sample_paid_exit_offer(&seller);

    let signed =
        SignedPaidRouteOffer::sign(offer.clone(), &seller, 123).expect("sign paid route offer");

    assert_eq!(u16::from(signed.event.kind), PAID_ROUTE_OFFER_KIND);
    assert_eq!(signed.event.created_at.as_secs(), 123);
    assert_eq!(signed.offer().expect("decode offer"), offer);
    SignedPaidRouteOffer::from_event(signed.event.clone()).expect("verify signed offer");
    assert!(signed.is_live_at(123));
    assert!(signed.is_live_at(123 + PAID_ROUTE_OFFER_TTL_SECS - 1));
    assert!(!signed.is_live_at(123 + PAID_ROUTE_OFFER_TTL_SECS));

    let tags = signed
        .event
        .tags
        .iter()
        .map(Tag::as_slice)
        .collect::<Vec<_>>();
    assert!(tags.contains(&vec!["d".to_string(), "paid-exit-fi".to_string()].as_slice()));
    assert!(tags.contains(&vec!["app".to_string(), PAID_ROUTE_OFFER_APP.to_string()].as_slice()));
    assert!(tags.contains(&vec!["v".to_string(), PAID_ROUTE_OFFER_VERSION.to_string()].as_slice()));
    assert!(
        tags.contains(
            &vec![
                "expiration".to_string(),
                (123 + PAID_ROUTE_OFFER_TTL_SECS).to_string(),
            ]
            .as_slice()
        )
    );
    assert!(tags.contains(&vec!["service".to_string(), "internet_exit".to_string()].as_slice()));
    assert!(tags.contains(&vec!["payment".to_string(), "cashu_spilman".to_string()].as_slice()));
    assert_eq!(PAID_ROUTE_OFFER_VERSION, "3");
    assert!(
        !tags
            .iter()
            .any(|tag| tag.first().is_some_and(|name| name == "meter"))
    );
    assert!(tags.contains(&vec!["price_msat".to_string(), "2500".to_string()].as_slice()));
    assert!(tags.contains(&vec!["per_units".to_string(), "1000000".to_string()].as_slice()));
    assert!(
        tags.contains(
            &vec![
                "connection_minimum_msat_per_day".to_string(),
                "86400".to_string()
            ]
            .as_slice()
        )
    );
    assert!(
        tags.contains(&vec!["max_channel_capacity_sat".to_string(), "100".to_string()].as_slice())
    );
    assert!(tags.contains(&vec!["channel_expiry_secs".to_string(), "600".to_string()].as_slice()));
    assert!(tags.contains(&vec!["free_probe_units".to_string(), "1048576".to_string()].as_slice()));
    assert!(tags.contains(&vec!["grace_units".to_string(), "262144".to_string()].as_slice()));
    assert!(tags.contains(&vec!["upstream".to_string(), "wireguard_exit".to_string()].as_slice()));
    assert!(
        tags.contains(&vec!["private_vpn_access".to_string(), "denied".to_string()].as_slice())
    );
    assert!(tags.contains(&vec!["country".to_string(), "FI".to_string()].as_slice()));
    assert!(!tags.iter().any(|tag| {
        tag.first()
            .is_some_and(|name| name == "region" || name == "network_class")
    }));
    assert!(tags.contains(&vec!["ip".to_string(), "ipv4".to_string()].as_slice()));
    assert!(
        tags.contains(
            &vec![
                "mint".to_string(),
                "https://mint.minibits.cash/Bitcoin".to_string()
            ]
            .as_slice()
        )
    );
    assert!(tags.contains(&vec!["latency_ms".to_string(), "42".to_string()].as_slice()));
    assert!(tags.contains(&vec!["jitter_ms".to_string(), "7".to_string()].as_slice()));
    assert!(tags.contains(&vec!["packet_loss_ppm".to_string(), "500".to_string()].as_slice()));
    assert!(tags.contains(&vec!["down_bps".to_string(), "25000000".to_string()].as_slice()));
    assert!(tags.contains(&vec!["up_bps".to_string(), "5000000".to_string()].as_slice()));
    assert!(tags.contains(&vec!["uptime_secs".to_string(), "3600".to_string()].as_slice()));
    assert!(tags.contains(&vec!["last_seen_unix".to_string(), "123".to_string()].as_slice()));

    let content = &signed.event.content;
    assert!(!content.contains("public_ip"));
    assert!(!content.contains("publicIp"));
    assert!(!content.contains("realized_exit_ip"));
    assert!(!content.contains("203.0.113."));
    assert!(!content.contains("private_routes"));
}

#[test]
fn signed_offer_event_includes_spilman_receiver_pubkey_when_present() {
    let seller = Keys::generate();
    let receiver_pubkey_hex = format!("03{}", "11".repeat(32));
    let signed = signed_paid_exit_offer_from_config_with_receiver(
        "paid-exit-fi",
        &seller,
        &sample_paid_exit_config(),
        Some(&receiver_pubkey_hex),
        None,
        123,
    )
    .expect("sign paid route offer with receiver key");
    let offer = signed.offer().expect("decode offer");

    assert_eq!(offer.receiver_pubkey_hex, receiver_pubkey_hex);
    assert!(offer.location.region.is_empty());
    assert_eq!(offer.location.network_class, ExitNetworkClass::Unknown);
    assert!(signed.event.tags.iter().any(|tag| {
        tag.as_slice() == ["receiver_pubkey".to_string(), receiver_pubkey_hex.clone()].as_slice()
    }));
    SignedPaidRouteOffer::from_event(signed.event).expect("verify receiver-key offer");
}

#[test]
fn signed_offer_rejects_seller_that_does_not_match_signer() {
    let seller = Keys::generate();
    let signer = Keys::generate();
    let offer = sample_paid_exit_offer(&seller);
    let event = EventBuilder::new(
        Kind::Custom(PAID_ROUTE_OFFER_KIND),
        serde_json::to_string(&offer).expect("encode offer"),
    )
    .tags(paid_route_offer_tags(&offer).expect("offer tags"))
    .custom_created_at(Timestamp::from(123))
    .sign_with_keys(&signer)
    .expect("sign offer with mismatched key");

    let error = SignedPaidRouteOffer::from_event(event).expect_err("seller mismatch rejected");

    assert!(error.to_string().contains("seller"));
}

#[test]
fn signed_offer_rejects_private_vpn_access_tag_claims() {
    let seller = Keys::generate();
    let offer = sample_paid_exit_offer(&seller);
    let mut tags = paid_route_offer_tags(&offer).expect("offer tags");
    let private_access_index = tags
        .iter()
        .position(|tag| {
            tag.as_slice()
                .first()
                .is_some_and(|kind| kind == "private_vpn_access")
        })
        .expect("private access tag");
    tags[private_access_index] =
        paid_route_tag(&["private_vpn_access", "allowed"]).expect("bad access tag");
    let event = EventBuilder::new(
        Kind::Custom(PAID_ROUTE_OFFER_KIND),
        serde_json::to_string(&offer).expect("encode offer"),
    )
    .tags(tags)
    .custom_created_at(Timestamp::from(123))
    .sign_with_keys(&seller)
    .expect("sign tampered offer");

    let error = SignedPaidRouteOffer::from_event(event).expect_err("access claim rejected");

    assert!(error.to_string().contains("private VPN access"));
}

#[test]
fn signed_offer_builder_requires_enabled_paid_exit_with_mint_for_nonzero_price() {
    let seller = Keys::generate();
    let mut config = sample_paid_exit_config();
    config.enabled = false;

    let error = signed_paid_exit_offer_from_config("paid-exit-fi", &seller, &config, None, 123)
        .expect_err("disabled seller rejected");
    assert!(error.to_string().contains("disabled"));

    config.enabled = true;
    config.channel.accepted_mints.clear();
    let error = signed_paid_exit_offer_from_config("paid-exit-fi", &seller, &config, None, 123)
        .expect_err("priced offer without mint rejected");
    assert!(error.to_string().contains("mint"));

    config.pricing.price_msat = 0;
    config.pricing.connection_minimum_msat_per_day = 0;
    signed_paid_exit_offer_from_config("paid-exit-fi", &seller, &config, None, 123)
        .expect("free dev offer can omit mints");
}

#[test]
fn paid_route_offer_filter_targets_offer_kind() {
    let filter = paid_route_offer_filter(25, Some(100));
    let json = serde_json::to_value(&filter).expect("filter json");

    assert_eq!(json["kinds"], serde_json::json!([PAID_ROUTE_OFFER_KIND]));
    assert_eq!(json["limit"], 25);
    assert_eq!(json["since"], 100);
}

fn sample_paid_exit_offer(seller: &Keys) -> PaidRouteOffer {
    let config = sample_paid_exit_config();
    PaidRouteOffer::from_paid_exit_config(
        "paid-exit-fi",
        seller.public_key().to_bech32().expect("seller npub"),
        &config,
        Some(PaidRouteQualityMetrics {
            latency_ms: Some(42),
            jitter_ms: Some(7),
            packet_loss_ppm: Some(500),
            down_bps: Some(25_000_000),
            up_bps: Some(5_000_000),
            uptime_secs: Some(3600),
            last_seen_unix: Some(123),
        }),
    )
}

fn sample_paid_exit_config() -> PaidExitConfig {
    PaidExitConfig {
        enabled: true,
        access: PaidRouteAccessPolicy {
            upstream: PaidExitUpstream::WireGuardExit,
            private_vpn_access: PaidRoutePrivateVpnAccess::Denied,
        },
        pricing: PaidRoutePricing {
            price_msat: 2500,
            per_units: 1_000_000,
            connection_minimum_msat_per_day: 86_400,
        },
        channel: PaidRouteChannelTerms {
            accepted_mints: vec!["https://mint.minibits.cash/Bitcoin".to_string()],
            max_channel_capacity_sat: 100,
            channel_expiry_secs: 600,
            free_probe_units: 1_048_576,
            grace_units: 262_144,
        },
        location: PaidRouteLocationHint {
            country_code: "FI".to_string(),
            region: "Uusimaa".to_string(),
            asn: Some(14593),
            network_class: ExitNetworkClass::Satellite,
        },
        ip_support: PaidRouteIpSupport {
            ipv4: true,
            ipv6: false,
        },
        rating_discovery: PaidExitRatingDiscoveryConfig::default(),
    }
}

fn usage_bytes(bytes: u64) -> PaidRouteUsage {
    PaidRouteUsage {
        rx_bytes: bytes,
        billable_bytes: bytes,
        ..PaidRouteUsage::default()
    }
}
