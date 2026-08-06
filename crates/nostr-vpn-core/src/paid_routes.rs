use std::str::FromStr;

use anyhow::{Context, Result, anyhow};
#[cfg(feature = "paid-exit")]
use cashu_service::{
    CashuSpilmanPayment, StreamingRouteAccessState, StreamingRouteCashuTokenLease,
    StreamingRouteDecision, StreamingRouteMeter, StreamingRoutePolicy,
};
use nostr_sdk::prelude::{
    Event, EventBuilder, Filter, Keys, Kind, PublicKey, Tag, Timestamp, ToBech32,
};
use serde::{Deserialize, Serialize};

/// Parameterized replaceable Nostr event for generic paid route offers.
///
/// FIPS overlay endpoint discovery already uses kind 37195 for transport
/// locator adverts. Paid route offers deliberately use a separate adjacent
/// kind so market/payment terms do not overload endpoint discovery or require
/// publishing raw transport endpoints.
pub const PAID_ROUTE_OFFER_KIND: u16 = 37_196;
pub const PAID_ROUTE_OFFER_VERSION: &str = "3";
pub const PAID_ROUTE_OFFER_APP: &str = "fips/paid-route-offer";
/// Signed seller listings expire if the seller stops refreshing them.
pub const PAID_ROUTE_OFFER_TTL_SECS: u64 = 3_600;
const PAID_ROUTE_OFFER_FUTURE_SKEW_SECS: u64 = 5 * 60;
pub const DEFAULT_FIPS_PEER_RATING_SCOPE: &str = "fips.peer";

const DEFAULT_PRICE_DENOMINATOR_UNITS: u64 = 1_000_000;
const DEFAULT_MAX_CHANNEL_CAPACITY_SAT: u64 = 1_000;
const DEFAULT_CHANNEL_EXPIRY_SECS: u64 = 86_400;
const DEFAULT_FREE_PROBE_BYTES: u64 = 1_048_576;
const DEFAULT_GRACE_BYTES: u64 = 262_144;
const MILLIS_PER_DAY: u64 = 86_400_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum PaidRouteServiceKind {
    #[default]
    InternetExit,
}

impl PaidRouteServiceKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InternetExit => "internet_exit",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum PaidExitUpstream {
    #[default]
    HostDefault,
    #[serde(rename = "wireguard_exit")]
    WireGuardExit,
}

impl PaidExitUpstream {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::HostDefault => "host_default",
            Self::WireGuardExit => "wireguard_exit",
        }
    }
}

impl FromStr for PaidExitUpstream {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match normalize_enum_value(value).as_str() {
            "" | "host_default" | "host" | "default" | "internet" | "local" => {
                Ok(Self::HostDefault)
            }
            "wireguard_exit" | "wireguard" | "wg" | "upstream_vpn" | "vpn" => {
                Ok(Self::WireGuardExit)
            }
            _ => Err(format!("unsupported paid exit upstream '{value}'")),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum PaidRoutePrivateVpnAccess {
    #[default]
    Denied,
}

impl PaidRoutePrivateVpnAccess {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Denied => "denied",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct PaidRouteAccessPolicy {
    #[serde(default)]
    pub upstream: PaidExitUpstream,
    #[serde(default)]
    pub private_vpn_access: PaidRoutePrivateVpnAccess,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ExitNetworkClass {
    #[default]
    Unknown,
    Datacenter,
    Residential,
    Mobile,
    Satellite,
    CommunityMesh,
}

impl ExitNetworkClass {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Datacenter => "datacenter",
            Self::Residential => "residential",
            Self::Mobile => "mobile",
            Self::Satellite => "satellite",
            Self::CommunityMesh => "community_mesh",
        }
    }
}

impl FromStr for ExitNetworkClass {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match normalize_enum_value(value).as_str() {
            "" | "unknown" => Ok(Self::Unknown),
            "datacenter" | "data_center" | "dc" | "hosting" => Ok(Self::Datacenter),
            "residential" | "home" => Ok(Self::Residential),
            "mobile" | "cellular" | "lte" | "5g" => Ok(Self::Mobile),
            "satellite" | "starlink" => Ok(Self::Satellite),
            "community_mesh" | "mesh" | "community" => Ok(Self::CommunityMesh),
            _ => Err(format!("unsupported exit network class '{value}'")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaidRouteIpSupport {
    #[serde(default = "default_true")]
    pub ipv4: bool,
    #[serde(default)]
    pub ipv6: bool,
}

impl Default for PaidRouteIpSupport {
    fn default() -> Self {
        Self {
            ipv4: true,
            ipv6: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct PaidRouteLocationHint {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub country_code: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub region: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub asn: Option<u32>,
    #[serde(default, skip_serializing_if = "ExitNetworkClass::is_unknown")]
    pub network_class: ExitNetworkClass,
}

impl ExitNetworkClass {
    fn is_unknown(value: &Self) -> bool {
        *value == Self::Unknown
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaidRoutePricing {
    #[serde(default, skip_serializing_if = "is_zero")]
    pub price_msat: u64,
    #[serde(default = "default_price_denominator_units")]
    pub per_units: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub connection_minimum_msat_per_day: u64,
}

impl Default for PaidRoutePricing {
    fn default() -> Self {
        Self {
            price_msat: 0,
            per_units: DEFAULT_PRICE_DENOMINATOR_UNITS,
            connection_minimum_msat_per_day: 0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaidRouteChannelTerms {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub accepted_mints: Vec<String>,
    #[serde(default = "default_max_channel_capacity_sat")]
    pub max_channel_capacity_sat: u64,
    #[serde(default = "default_channel_expiry_secs")]
    pub channel_expiry_secs: u64,
    #[serde(default = "default_free_probe_bytes")]
    pub free_probe_units: u64,
    #[serde(default = "default_grace_bytes")]
    pub grace_units: u64,
}

impl Default for PaidRouteChannelTerms {
    fn default() -> Self {
        Self {
            accepted_mints: Vec::new(),
            max_channel_capacity_sat: DEFAULT_MAX_CHANNEL_CAPACITY_SAT,
            channel_expiry_secs: DEFAULT_CHANNEL_EXPIRY_SECS,
            free_probe_units: DEFAULT_FREE_PROBE_BYTES,
            grace_units: DEFAULT_GRACE_BYTES,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaidExitRatingDiscoveryConfig {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub file: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub relays: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub trusted_authors: Vec<String>,
    #[serde(
        default = "default_fips_peer_rating_scope",
        skip_serializing_if = "fips_peer_rating_scope_is_default"
    )]
    pub scope: String,
}

impl Default for PaidExitRatingDiscoveryConfig {
    fn default() -> Self {
        Self {
            file: String::new(),
            relays: Vec::new(),
            trusted_authors: Vec::new(),
            scope: default_fips_peer_rating_scope(),
        }
    }
}

impl PaidExitRatingDiscoveryConfig {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }

    pub fn normalize(&mut self) {
        self.file = self.file.trim().to_string();
        self.relays = normalize_string_list(&self.relays);
        self.trusted_authors = normalize_string_list(&self.trusted_authors);
        self.scope = self.scope.trim().to_string();
        if self.scope.is_empty() {
            self.scope = default_fips_peer_rating_scope();
        }
    }

    pub fn configured(&self) -> bool {
        !self.file.trim().is_empty() || !self.relays.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct PaidExitConfig {
    #[serde(default, skip_serializing_if = "is_false")]
    pub enabled: bool,
    #[serde(default)]
    pub access: PaidRouteAccessPolicy,
    #[serde(default)]
    pub pricing: PaidRoutePricing,
    #[serde(default)]
    pub channel: PaidRouteChannelTerms,
    #[serde(default)]
    pub location: PaidRouteLocationHint,
    #[serde(default)]
    pub ip_support: PaidRouteIpSupport,
    #[serde(
        default,
        skip_serializing_if = "PaidExitRatingDiscoveryConfig::is_default"
    )]
    pub rating_discovery: PaidExitRatingDiscoveryConfig,
}

impl PaidExitConfig {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }

    pub fn normalize(&mut self) {
        self.access.private_vpn_access = PaidRoutePrivateVpnAccess::Denied;
        self.pricing.per_units = self.pricing.per_units.max(1);
        self.channel.max_channel_capacity_sat = self.channel.max_channel_capacity_sat.max(1);
        self.channel.channel_expiry_secs = self.channel.channel_expiry_secs.max(1);
        self.channel.accepted_mints = normalize_string_list(&self.channel.accepted_mints);
        self.location.country_code = normalize_paid_route_country_code(&self.location.country_code);
        self.location.region.clear();
        self.location.network_class = ExitNetworkClass::Unknown;
        self.rating_discovery.normalize();
    }

    #[cfg(feature = "paid-exit")]
    pub fn streaming_policy(&self) -> StreamingRoutePolicy {
        StreamingRoutePolicy {
            meter: StreamingRouteMeter::Bytes,
            price_msat: self.pricing.price_msat,
            per_units: self.pricing.per_units.max(1),
            max_channel_capacity_sat: self.channel.max_channel_capacity_sat.max(1),
            channel_expiry_secs: self.channel.channel_expiry_secs.max(1),
            free_probe_units: self.channel.free_probe_units,
            grace_units: self.channel.grace_units,
        }
    }

    pub fn amount_due_msat(&self, usage: &PaidRouteUsage) -> u64 {
        paid_route_amount_due_msat_for_usage(
            usage,
            self.channel.free_probe_units,
            self.pricing.price_msat,
            self.pricing.per_units,
            self.pricing.connection_minimum_msat_per_day,
        )
    }

    pub fn amount_due_msat_with_connection_minimum_skew(
        &self,
        usage: &PaidRouteUsage,
        active_millis_skew: u64,
    ) -> u64 {
        paid_route_amount_due_msat_for_usage_with_connection_minimum_skew(
            usage,
            self.channel.free_probe_units,
            self.pricing.price_msat,
            self.pricing.per_units,
            self.pricing.connection_minimum_msat_per_day,
            active_millis_skew,
        )
    }

    pub fn routing_decision(
        &self,
        usage: &PaidRouteUsage,
        paid_msat: u64,
    ) -> PaidRouteRoutingDecision {
        let delivered_units = usage.billable_bytes;
        let amount_due_msat = self.amount_due_msat(usage);
        let mut enforced_usage = usage.clone();
        enforced_usage.billable_bytes = delivered_units.saturating_sub(self.channel.grace_units);
        let enforced_amount_due_msat = self.amount_due_msat(&enforced_usage);
        let unpaid_msat = amount_due_msat.saturating_sub(paid_msat);
        let enforced_unpaid_msat = enforced_amount_due_msat.saturating_sub(paid_msat);
        let state = if amount_due_msat == 0 {
            PaidRouteAccessState::FreeProbe
        } else if unpaid_msat == 0 {
            PaidRouteAccessState::Paid
        } else if enforced_unpaid_msat == 0 {
            PaidRouteAccessState::Grace
        } else {
            PaidRouteAccessState::Suspended
        };

        PaidRouteRoutingDecision {
            state,
            allow_routing: state != PaidRouteAccessState::Suspended,
            delivered_units,
            paid_msat,
            amount_due_msat,
            enforced_amount_due_msat,
            unpaid_msat,
            free_probe_remaining_units: self
                .channel
                .free_probe_units
                .saturating_sub(delivered_units),
            grace_remaining_units: paid_route_grace_remaining_units(
                delivered_units,
                self.channel.free_probe_units,
                self.channel.grace_units,
                paid_msat,
                self.pricing.price_msat,
                self.pricing.per_units,
            ),
        }
    }

    pub fn can_continue_routing(&self, usage: &PaidRouteUsage, paid_msat: u64) -> bool {
        self.routing_decision(usage, paid_msat).allow_routing
    }

    pub fn from_paid_route_offer(offer: &PaidRouteOffer) -> Self {
        Self {
            enabled: true,
            access: offer.access.clone(),
            pricing: offer.pricing.clone(),
            channel: offer.channel.clone(),
            location: offer.location.clone(),
            ip_support: offer.ip_support.clone(),
            rating_discovery: PaidExitRatingDiscoveryConfig::default(),
        }
    }
}

fn default_fips_peer_rating_scope() -> String {
    DEFAULT_FIPS_PEER_RATING_SCOPE.to_string()
}

fn fips_peer_rating_scope_is_default(value: &str) -> bool {
    value == DEFAULT_FIPS_PEER_RATING_SCOPE
}

fn paid_route_amount_due_msat(
    delivered_units: u64,
    free_probe_units: u64,
    price_msat: u64,
    per_units: u64,
) -> u64 {
    let billable_units = delivered_units.saturating_sub(free_probe_units);
    paid_route_price_for_units(billable_units, price_msat, per_units)
}

fn paid_route_amount_due_msat_for_usage(
    usage: &PaidRouteUsage,
    free_probe_units: u64,
    price_msat: u64,
    per_units: u64,
    connection_minimum_msat_per_day: u64,
) -> u64 {
    let traffic_due = paid_route_amount_due_msat(
        usage.billable_bytes,
        free_probe_units,
        price_msat,
        per_units,
    );
    let connection_due = paid_route_connection_minimum_due_msat(
        usage.active_millis,
        connection_minimum_msat_per_day,
    );
    traffic_due.max(connection_due)
}

fn paid_route_amount_due_msat_for_usage_with_connection_minimum_skew(
    usage: &PaidRouteUsage,
    free_probe_units: u64,
    price_msat: u64,
    per_units: u64,
    connection_minimum_msat_per_day: u64,
    active_millis_skew: u64,
) -> u64 {
    let traffic_due = paid_route_amount_due_msat(
        usage.billable_bytes,
        free_probe_units,
        price_msat,
        per_units,
    );
    let connection_due = paid_route_connection_minimum_due_msat(
        usage.active_millis.saturating_sub(active_millis_skew),
        connection_minimum_msat_per_day,
    );
    traffic_due.max(connection_due)
}

fn paid_route_connection_minimum_due_msat(
    active_millis: u64,
    connection_minimum_msat_per_day: u64,
) -> u64 {
    if active_millis == 0 || connection_minimum_msat_per_day == 0 {
        return 0;
    }
    active_millis
        .saturating_mul(connection_minimum_msat_per_day)
        .saturating_div(MILLIS_PER_DAY)
}

fn paid_route_price_for_units(units: u64, price_msat: u64, per_units: u64) -> u64 {
    if units == 0 || price_msat == 0 {
        return 0;
    }
    let numerator = u128::from(units).saturating_mul(u128::from(price_msat));
    let denominator = u128::from(per_units.max(1));
    let due = numerator
        .saturating_add(denominator.saturating_sub(1))
        .saturating_div(denominator);
    due.min(u128::from(u64::MAX)) as u64
}

fn paid_route_grace_remaining_units(
    delivered_units: u64,
    free_probe_units: u64,
    grace_units: u64,
    paid_msat: u64,
    price_msat: u64,
    per_units: u64,
) -> u64 {
    let billable_units = delivered_units.saturating_sub(free_probe_units);
    if billable_units == 0 || grace_units == 0 {
        return 0;
    }
    let paid_units = if price_msat == 0 {
        billable_units
    } else {
        let units = u128::from(paid_msat)
            .saturating_mul(u128::from(per_units.max(1)))
            .saturating_div(u128::from(price_msat));
        units.min(u128::from(u64::MAX)) as u64
    };
    paid_units
        .saturating_add(grace_units)
        .saturating_sub(billable_units)
        .min(grace_units)
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct PaidRouteUsage {
    #[serde(default, skip_serializing_if = "is_zero")]
    pub active_millis: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub tx_bytes: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub rx_bytes: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub tx_packets: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub rx_packets: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub billable_bytes: u64,
}

impl PaidRouteUsage {
    pub fn total_bytes(&self) -> u64 {
        self.tx_bytes.saturating_add(self.rx_bytes)
    }

    pub fn total_packets(&self) -> u64 {
        self.tx_packets.saturating_add(self.rx_packets)
    }

    pub fn add_assign(&mut self, delta: &Self) {
        self.active_millis = self.active_millis.saturating_add(delta.active_millis);
        self.tx_bytes = self.tx_bytes.saturating_add(delta.tx_bytes);
        self.rx_bytes = self.rx_bytes.saturating_add(delta.rx_bytes);
        self.tx_packets = self.tx_packets.saturating_add(delta.tx_packets);
        self.rx_packets = self.rx_packets.saturating_add(delta.rx_packets);
        self.billable_bytes = self.billable_bytes.saturating_add(delta.billable_bytes);
    }

    pub fn is_empty(&self) -> bool {
        self.active_millis == 0
            && self.tx_bytes == 0
            && self.rx_bytes == 0
            && self.tx_packets == 0
            && self.rx_packets == 0
            && self.billable_bytes == 0
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct PaidRouteQualityMetrics {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latency_ms: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub jitter_ms: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub packet_loss_ppm: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub down_bps: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub up_bps: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uptime_secs: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_seen_unix: Option<u64>,
}

impl PaidRouteQualityMetrics {
    pub fn is_empty(&self) -> bool {
        self.latency_ms.is_none()
            && self.jitter_ms.is_none()
            && self.packet_loss_ppm.is_none()
            && self.down_bps.is_none()
            && self.up_bps.is_none()
            && self.uptime_secs.is_none()
            && self.last_seen_unix.is_none()
    }

    pub fn merge_patch(&mut self, patch: PaidRouteQualityMetrics) {
        if patch.latency_ms.is_some() {
            self.latency_ms = patch.latency_ms;
        }
        if patch.jitter_ms.is_some() {
            self.jitter_ms = patch.jitter_ms;
        }
        if patch.packet_loss_ppm.is_some() {
            self.packet_loss_ppm = patch.packet_loss_ppm;
        }
        if patch.down_bps.is_some() {
            self.down_bps = patch.down_bps;
        }
        if patch.up_bps.is_some() {
            self.up_bps = patch.up_bps;
        }
        if patch.uptime_secs.is_some() {
            self.uptime_secs = patch.uptime_secs;
        }
        if patch.last_seen_unix.is_some() {
            self.last_seen_unix = patch.last_seen_unix;
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum PaidRoutePaymentMode {
    #[default]
    CashuSpilman,
    CashuTokenLease,
}

impl PaidRoutePaymentMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::CashuSpilman => "cashu_spilman",
            Self::CashuTokenLease => "cashu_token_lease",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PaidRouteAccessState {
    FreeProbe,
    Paid,
    Grace,
    Suspended,
}

impl PaidRouteAccessState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::FreeProbe => "free_probe",
            Self::Paid => "paid",
            Self::Grace => "grace",
            Self::Suspended => "suspended",
        }
    }
}

#[cfg(feature = "paid-exit")]
impl From<StreamingRouteAccessState> for PaidRouteAccessState {
    fn from(value: StreamingRouteAccessState) -> Self {
        match value {
            StreamingRouteAccessState::FreeProbe => Self::FreeProbe,
            StreamingRouteAccessState::Paid => Self::Paid,
            StreamingRouteAccessState::Grace => Self::Grace,
            StreamingRouteAccessState::Suspended => Self::Suspended,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaidRouteRoutingDecision {
    pub state: PaidRouteAccessState,
    pub allow_routing: bool,
    pub delivered_units: u64,
    pub paid_msat: u64,
    pub amount_due_msat: u64,
    pub enforced_amount_due_msat: u64,
    pub unpaid_msat: u64,
    pub free_probe_remaining_units: u64,
    pub grace_remaining_units: u64,
}

#[cfg(feature = "paid-exit")]
impl From<StreamingRouteDecision> for PaidRouteRoutingDecision {
    fn from(value: StreamingRouteDecision) -> Self {
        Self {
            state: value.state.into(),
            allow_routing: value.allow_routing,
            delivered_units: value.delivered_units,
            paid_msat: value.paid_msat,
            amount_due_msat: value.amount_due_msat,
            enforced_amount_due_msat: value.enforced_amount_due_msat,
            unpaid_msat: value.unpaid_msat,
            free_probe_remaining_units: value.free_probe_remaining_units,
            grace_remaining_units: value.grace_remaining_units,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PaidRouteCountryClaimStatus {
    NoClaim,
    Unknown,
    Match,
    Mismatch,
}

impl PaidRouteCountryClaimStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NoClaim => "no_claim",
            Self::Unknown => "unknown",
            Self::Match => "match",
            Self::Mismatch => "mismatch",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaidRouteCountryClaim {
    pub claimed_country_code: String,
    pub observed_country_code: String,
    pub status: PaidRouteCountryClaimStatus,
}

impl PaidRouteCountryClaim {
    pub fn matches_claim(&self) -> Option<bool> {
        match self.status {
            PaidRouteCountryClaimStatus::Match => Some(true),
            PaidRouteCountryClaimStatus::Mismatch => Some(false),
            PaidRouteCountryClaimStatus::NoClaim | PaidRouteCountryClaimStatus::Unknown => None,
        }
    }
}

pub fn paid_route_country_claim(
    claimed_country_code: impl AsRef<str>,
    observed_country_code: Option<&str>,
) -> PaidRouteCountryClaim {
    let claimed_country_code = normalize_paid_route_country_code(claimed_country_code.as_ref());
    let observed_country_code = observed_country_code
        .map(normalize_paid_route_country_code)
        .unwrap_or_default();
    let status = if claimed_country_code.is_empty() {
        PaidRouteCountryClaimStatus::NoClaim
    } else if observed_country_code.is_empty() {
        PaidRouteCountryClaimStatus::Unknown
    } else if claimed_country_code == observed_country_code {
        PaidRouteCountryClaimStatus::Match
    } else {
        PaidRouteCountryClaimStatus::Mismatch
    };
    PaidRouteCountryClaim {
        claimed_country_code,
        observed_country_code,
        status,
    }
}

fn default_true() -> bool {
    true
}

fn default_price_denominator_units() -> u64 {
    DEFAULT_PRICE_DENOMINATOR_UNITS
}

fn default_max_channel_capacity_sat() -> u64 {
    DEFAULT_MAX_CHANNEL_CAPACITY_SAT
}

fn default_channel_expiry_secs() -> u64 {
    DEFAULT_CHANNEL_EXPIRY_SECS
}

fn default_free_probe_bytes() -> u64 {
    DEFAULT_FREE_PROBE_BYTES
}

fn default_grace_bytes() -> u64 {
    DEFAULT_GRACE_BYTES
}

fn is_false(value: &bool) -> bool {
    !*value
}

fn is_zero(value: &u64) -> bool {
    *value == 0
}

pub fn normalize_paid_route_country_code(value: &str) -> String {
    let value = value.trim();
    if value.len() == 2 && value.chars().all(|ch| ch.is_ascii_alphabetic()) {
        value.to_ascii_uppercase()
    } else {
        String::new()
    }
}

fn normalize_enum_value(value: &str) -> String {
    value
        .trim()
        .chars()
        .map(|ch| match ch {
            '-' | ' ' => '_',
            other => other.to_ascii_lowercase(),
        })
        .collect()
}

fn normalize_string_list(values: &[String]) -> Vec<String> {
    let mut normalized = values
        .iter()
        .flat_map(|value| value.split([',', '\n', '\r', '\t']))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    normalized.sort();
    normalized.dedup();
    normalized
}

mod events;

pub use events::*;

#[cfg(test)]
mod tests;
