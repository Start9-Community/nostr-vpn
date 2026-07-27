use std::sync::Arc;

use anyhow::{Context as _, Result};
use nostr_vpn_core::config::ExitDnsResolverConfig;
use nostr_vpn_core::secure_dns::{
    SecureDnsError, SecureDnsLookup, SecureDnsResolver, WireGuardDnsResolver,
};

use super::{FIPS_DNS_TTL_SECS, ResolverState, SharedResolver};

pub(super) fn dns_resolver(config: &ExitDnsResolverConfig) -> Result<SharedResolver> {
    match config {
        ExitDnsResolverConfig::Doh { .. } => Ok(Arc::new(
            SecureDnsResolver::from_resolver_config(config)
                .context("failed to initialize encrypted DNS")?,
        )),
        ExitDnsResolverConfig::ThroughExit { servers } => Ok(Arc::new(
            WireGuardDnsResolver::new(servers)
                .context("failed to initialize DNS through the selected exit")?,
        )),
        ExitDnsResolverConfig::FailClosed => Ok(Arc::new(FailClosedDnsResolver)),
    }
}

struct FailClosedDnsResolver;

#[async_trait::async_trait]
impl SecureDnsLookup for FailClosedDnsResolver {
    async fn resolve(&self, _query: &[u8]) -> Result<Vec<u8>, SecureDnsError> {
        Err(SecureDnsError::ExitNotReady)
    }
}

pub(super) fn current_resolver(resolver: &ResolverState) -> Option<SharedResolver> {
    resolver.read().ok().map(|resolver| Arc::clone(&*resolver))
}

pub(super) fn resolve_fips_dns_if_handled(
    query: &[u8],
) -> Option<(Vec<u8>, Option<fips_core::upper::dns::DnsResolvedIdentity>)> {
    let request = hickory_proto::op::Message::from_vec(query).ok()?;
    let name = request.queries.first()?.name.to_utf8();
    let name = name.trim_end_matches('.');
    if !name.to_ascii_lowercase().ends_with(".fips") {
        return None;
    }
    fips_core::upper::dns::handle_dns_packet(
        query,
        FIPS_DNS_TTL_SECS,
        &fips_core::upper::hosts::HostMap::new(),
    )
}
