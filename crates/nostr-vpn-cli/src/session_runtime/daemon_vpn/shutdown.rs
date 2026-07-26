use super::*;

pub(super) fn daemon_termination_wait()
-> Result<std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>> {
    #[cfg(unix)]
    {
        let mut signal = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .context("failed to install SIGTERM handler")?;
        return Ok(Box::pin(async move {
            let _ = signal.recv().await;
        }));
    }
    #[cfg(not(unix))]
    Ok(Box::pin(std::future::pending()))
}

pub(super) struct DaemonVpnShutdown<'a> {
    pub(super) port_mapping_runtime: &'a mut PortMappingRuntime,
    pub(super) fips_tunnel_runtime: Option<crate::fips_private_mesh::FipsPrivateTunnelRuntime>,
    pub(super) tunnel_runtime: &'a mut CliTunnelRuntime,
    pub(super) config_path: &'a Path,
    pub(super) state_file: &'a Path,
    pub(super) pid_file: &'a Path,
    pub(super) expected_peers: usize,
    pub(super) network_snapshot: &'a crate::diagnostics::NetworkSnapshot,
    pub(super) network_changed_at: Option<u64>,
    pub(super) captive_portal: Option<bool>,
}

pub(super) async fn shutdown_daemon_vpn(shutdown: DaemonVpnShutdown<'_>) -> Result<()> {
    shutdown.port_mapping_runtime.stop().await;
    if let Some(runtime) = shutdown.fips_tunnel_runtime
        && let Err(error) = runtime.stop().await
    {
        eprintln!("daemon: failed to stop FIPS private mesh: {error}");
    }
    shutdown.tunnel_runtime.stop();
    if let Err(error) =
        persist_daemon_network_cleanup_state(shutdown.config_path, shutdown.tunnel_runtime)
    {
        eprintln!("daemon: failed to clear network cleanup state: {error}");
    }
    let final_state = disconnected_daemon_runtime_state(
        shutdown.expected_peers,
        &shutdown
            .network_snapshot
            .summary(shutdown.network_changed_at, shutdown.captive_portal),
    );
    let _ = write_daemon_state(shutdown.state_file, &final_state);
    clear_daemon_control_ready(shutdown.config_path);
    remove_current_daemon_pid_record(shutdown.pid_file);
    Ok(())
}
