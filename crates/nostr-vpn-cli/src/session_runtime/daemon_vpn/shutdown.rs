use super::*;

pub(super) fn daemon_termination_wait()
-> Result<std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>> {
    #[cfg(unix)]
    {
        let mut signal = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .context("failed to install SIGTERM handler")?;
        Ok(Box::pin(async move {
            let _ = signal.recv().await;
        }))
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

trait DaemonShutdownOwnershipActions {
    fn write_terminal_state(&mut self) -> Result<()>;
    fn clear_control_ready(&mut self);
    fn remove_pid_record(&mut self);
}

struct SystemDaemonShutdownOwnership<'a> {
    config_path: &'a Path,
    state_file: &'a Path,
    pid_file: &'a Path,
    final_state: &'a DaemonRuntimeState,
}

impl DaemonShutdownOwnershipActions for SystemDaemonShutdownOwnership<'_> {
    fn write_terminal_state(&mut self) -> Result<()> {
        write_daemon_state(self.state_file, self.final_state)
            .context("failed to write terminal daemon state")
    }

    fn clear_control_ready(&mut self) {
        clear_daemon_control_ready(self.config_path);
    }

    fn remove_pid_record(&mut self) {
        remove_current_daemon_pid_record(self.pid_file);
    }
}

fn finalize_daemon_shutdown_ownership(
    actions: &mut impl DaemonShutdownOwnershipActions,
    mut failures: Vec<String>,
) -> Result<()> {
    if let Err(error) = actions.write_terminal_state() {
        failures.push(format!(
            "failed to persist terminal daemon state: {error:#}"
        ));
    }
    actions.clear_control_ready();
    actions.remove_pid_record();
    if failures.is_empty() {
        Ok(())
    } else {
        Err(anyhow!("{}", failures.join("; ")))
    }
}

pub(super) async fn shutdown_daemon_vpn(shutdown: DaemonVpnShutdown<'_>) -> Result<()> {
    let mut failures = Vec::new();
    shutdown.port_mapping_runtime.stop().await;
    let fips_ownership_persist_error = persist_fips_daemon_network_cleanup_state(
        shutdown.config_path,
        shutdown.fips_tunnel_runtime.as_ref(),
    )
    .err();
    if let Some(runtime) = shutdown.fips_tunnel_runtime {
        match runtime.stop().await {
            Ok(()) => {
                if let Err(error) = clear_fips_daemon_network_cleanup_state(shutdown.config_path) {
                    failures.push(format!(
                        "failed to clear FIPS network cleanup ownership: {error:#}"
                    ));
                }
            }
            Err(error) => {
                eprintln!("daemon: failed to stop FIPS private mesh: {error}");
                failures.push(format!("failed to stop FIPS private mesh: {error:#}"));
                if let Some(persist_error) = fips_ownership_persist_error {
                    failures.push(format!(
                        "failed to persist exact FIPS cleanup ownership before teardown: \
                         {persist_error:#}"
                    ));
                }
            }
        }
    } else if let Some(persist_error) = fips_ownership_persist_error {
        failures.push(format!(
            "failed to persist pending FIPS cleanup ownership: {persist_error:#}"
        ));
    }
    shutdown.tunnel_runtime.stop();
    if let Err(error) =
        persist_daemon_network_cleanup_state(shutdown.config_path, shutdown.tunnel_runtime)
    {
        eprintln!("daemon: failed to clear network cleanup state: {error}");
        failures.push(format!("failed to clear network cleanup state: {error:#}"));
    }
    let network = shutdown
        .network_snapshot
        .summary(shutdown.network_changed_at, shutdown.captive_portal);
    let final_state = if failures.is_empty() {
        disconnected_daemon_runtime_state(shutdown.expected_peers, &network)
    } else {
        cleanup_failed_daemon_runtime_state(shutdown.expected_peers, &network, &failures)
    };
    finalize_daemon_shutdown_ownership(
        &mut SystemDaemonShutdownOwnership {
            config_path: shutdown.config_path,
            state_file: shutdown.state_file,
            pid_file: shutdown.pid_file,
            final_state: &final_state,
        },
        failures,
    )
}

pub(super) fn finish_daemon_vpn_shutdown(
    terminal_error: Option<anyhow::Error>,
    shutdown_result: Result<()>,
) -> Result<()> {
    match (terminal_error, shutdown_result) {
        (None, result) => result,
        (Some(error), Ok(())) => Err(error),
        (Some(error), Err(shutdown_error)) => Err(anyhow!(
            "{error:#}; daemon shutdown also failed: {shutdown_error:#}"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct FakeShutdownOwnership {
        events: Vec<&'static str>,
        fail_state_write: bool,
    }

    impl DaemonShutdownOwnershipActions for FakeShutdownOwnership {
        fn write_terminal_state(&mut self) -> Result<()> {
            self.events.push("write-terminal");
            if self.fail_state_write {
                Err(anyhow!("synthetic state write failure"))
            } else {
                Ok(())
            }
        }

        fn clear_control_ready(&mut self) {
            self.events.push("clear-control");
        }

        fn remove_pid_record(&mut self) {
            self.events.push("remove-pid");
        }
    }

    #[test]
    fn failed_network_cleanup_writes_terminal_state_then_clears_liveness_markers() {
        let mut actions = FakeShutdownOwnership::default();
        let error = finalize_daemon_shutdown_ownership(
            &mut actions,
            vec!["synthetic network cleanup failure".to_string()],
        )
        .expect_err("cleanup failure must remain visible");

        assert!(format!("{error:#}").contains("synthetic network cleanup failure"));
        assert_eq!(
            actions.events,
            vec!["write-terminal", "clear-control", "remove-pid"],
            "the cleanup obligation remains durable, but an exited process must not retain \
             stale liveness markers"
        );
    }

    #[test]
    fn disconnected_state_must_persist_before_ownership_markers_are_removed() {
        let mut actions = FakeShutdownOwnership {
            fail_state_write: true,
            ..FakeShutdownOwnership::default()
        };
        finalize_daemon_shutdown_ownership(&mut actions, Vec::new())
            .expect_err("state persistence failure");
        assert_eq!(
            actions.events,
            vec!["write-terminal", "clear-control", "remove-pid"]
        );

        let mut actions = FakeShutdownOwnership::default();
        finalize_daemon_shutdown_ownership(&mut actions, Vec::new()).expect("clean shutdown");
        assert_eq!(
            actions.events,
            vec!["write-terminal", "clear-control", "remove-pid"]
        );
    }
}
