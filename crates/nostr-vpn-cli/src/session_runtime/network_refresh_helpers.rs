fn begin_platform_network_refresh_attempt(
    latest_snapshot: crate::diagnostics::NetworkSnapshot,
    platform_network_event: bool,
    network_changed: bool,
    network_state_drift: bool,
    endpoint_changed: bool,
    resumed_after_sleep: bool,
) -> Option<PlatformNetworkRefreshAttempt> {
    let refresh = fips_link_event_refresh(
        platform_network_event,
        network_changed,
        network_state_drift,
        endpoint_changed,
        resumed_after_sleep,
    );
    if matches!(refresh, FipsLinkEventRefresh::None) {
        return None;
    }
    let (reason, diagnostic) = if network_changed {
        (
            "network change",
            "daemon: network change detected; refreshing FIPS endpoint state",
        )
    } else if resumed_after_sleep {
        (
            "sleep/wake",
            "daemon: sleep/wake detected; refreshing FIPS endpoint state",
        )
    } else if network_state_drift {
        (
            "WireGuard route drift",
            "daemon: unmanaged Linux default route detected; reconciling WireGuard network state",
        )
    } else {
        (
            "endpoint change",
            "daemon: endpoint changed; refreshing FIPS endpoint state",
        )
    };
    eprintln!("{diagnostic}");
    Some(PlatformNetworkRefreshAttempt::new(
        latest_snapshot,
        refresh,
        reason,
    ))
}
