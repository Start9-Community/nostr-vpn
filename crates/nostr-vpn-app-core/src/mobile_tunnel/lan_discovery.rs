impl MobileTunnel {
    pub(crate) fn lan_discovery_info_json(&self) -> Result<String> {
        let config = self
            .config
            .read()
            .map_err(|_| anyhow!("mobile config lock poisoned"))?;
        if !config.share_local_candidates || !mobile_nostr_enabled(&config) {
            return Ok(String::new());
        }
        let endpoint = self
            .endpoint
            .as_ref()
            .ok_or_else(|| anyhow!("mobile tunnel stopped"))?;
        let port = self
            .runtime
            .block_on(endpoint.bound_udp_listen_addrs())?
            .first()
            .map_or(0, SocketAddr::port);
        Ok(serde_json::json!({
            "npub": endpoint.npub(),
            "port": port,
            "scope": nostr_vpn_core::fips_discovery::FIPS_LAN_DISCOVERY_SCOPE_PREFIX,
        })
        .to_string())
    }

    pub(crate) fn observe_lan_peer(&self, npub: &str, addresses_json: &str) -> Result<()> {
        let identity = PeerIdentity::from_npub(npub)?;
        let addresses: Vec<String> = serde_json::from_str(addresses_json)?;
        let endpoint = Arc::clone(
            self.endpoint
                .as_ref()
                .ok_or_else(|| anyhow!("mobile tunnel stopped"))?,
        );
        let config = Arc::clone(&self.config);
        let peer_hints = Arc::clone(&self.peer_hints);
        self.runtime.spawn(async move {
            if !record_mobile_lan_peer(&config, identity, &addresses) {
                return;
            }
            // Preserve the observation when capability updates synchronize the
            // runtime's canonical hint cache back into its endpoint config.
            if let (Ok(config), Ok(mut cached)) = (config.read(), peer_hints.write()) {
                let participant = identity.pubkey().to_string();
                if let Some(hints) = config.peer_hints.get(&participant) {
                    cached.insert(participant, hints.clone());
                }
            }
            if let Err(error) = refresh_mobile_endpoint_peers(&endpoint, &config).await {
                tracing::warn!(?error, "mobile: failed to update LAN peer candidates");
                return;
            }
            if let Err(error) = endpoint.refresh_peer_paths(vec![identity]).await {
                tracing::warn!(?error, "mobile: failed to refresh LAN peer path");
            }
        });
        Ok(())
    }
}

fn record_mobile_lan_peer(
    config: &RwLock<MobileTunnelConfig>,
    identity: PeerIdentity,
    addresses: &[String],
) -> bool {
    let Ok(mut config) = config.write() else {
        return false;
    };
    if !config.share_local_candidates {
        return false;
    }
    let participant = identity.pubkey().to_string();
    // Bonjour is an unauthenticated address hint, never roster membership.
    // The approving device already knows the QR recipient's identity.
    if !config
        .peers
        .iter()
        .any(|peer| peer.participant_pubkey == participant)
        && !config.bootstrap_peers.contains_key(&participant)
    {
        return false;
    }
    let observed_at = unix_timestamp().saturating_mul(1_000);
    let hints = config.peer_hints.entry(participant).or_default();
    let mut changed = false;
    for addr in addresses
        .iter()
        .take(8)
        .filter_map(|addr| addr.parse::<SocketAddr>().ok())
    {
        if addr.port() == 0
            || addr.ip().is_unspecified()
            || addr.ip().is_loopback()
            || addr.ip().is_multicast()
            || matches!(addr, SocketAddr::V6(v6) if v6.ip().is_unicast_link_local() && v6.scope_id() == 0)
        {
            continue;
        }
        let addr = addr.to_string();
        if hints.iter().any(|hint| hint.addr == addr) {
            continue;
        }
        if hints.len() >= 16 {
            let oldest = hints
                .iter()
                .enumerate()
                .filter_map(|(index, hint)| hint.seen_at_ms.map(|seen| (index, seen)))
                .min_by_key(|(_, seen)| *seen)
                .map(|(index, _)| index);
            let Some(oldest) = oldest else {
                continue;
            };
            hints.remove(oldest);
        }
        hints.push(FipsPeerAddressHint {
            addr,
            seen_at_ms: Some(observed_at),
            priority: FIPS_DYNAMIC_PEER_ENDPOINT_PRIORITY,
        });
        changed = true;
    }
    changed
}
