#[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
pub(crate) fn read_daemon_network_cleanup_state(
    path: &Path,
) -> Result<Option<DaemonNetworkCleanupState>> {
    if !path.exists() {
        return Ok(None);
    }

    if let Some(parent) = path.parent() {
        set_daemon_cleanup_directory_permissions(parent)?;
    }
    set_daemon_cleanup_file_permissions(path)?;
    let raw = fs::read(path)
        .with_context(|| format!("failed to read daemon cleanup file {}", path.display()))?;
    match serde_json::from_slice::<DaemonNetworkCleanupState>(&raw) {
        Ok(parsed) => Ok(Some(parsed)),
        Err(parse_error) => {
            let trimmed = trim_runtime_json_padding(&raw);
            if trimmed.len() != raw.len()
                && !trimmed.is_empty()
                && let Ok(parsed) = serde_json::from_slice::<DaemonNetworkCleanupState>(trimmed)
            {
                if let Err(error) = write_private_runtime_file_atomically(path, trimmed) {
                    eprintln!(
                        "daemon: parsed padded cleanup file {} but failed to rewrite clean copy: {}",
                        path.display(),
                        error
                    );
                } else {
                    set_daemon_cleanup_file_permissions(path)?;
                }
                return Ok(Some(parsed));
            }

            Err(parse_error).with_context(|| {
                format!(
                    "refusing to discard unreadable network cleanup ownership in {}",
                    path.display()
                )
            })
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
pub(crate) fn write_daemon_network_cleanup_state(
    path: &Path,
    state: &DaemonNetworkCleanupState,
) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
        set_daemon_cleanup_directory_permissions(parent)?;
    }
    let raw = serde_json::to_string_pretty(state)?;
    write_private_runtime_file_atomically(path, raw.as_bytes())
        .with_context(|| format!("failed to write daemon cleanup file {}", path.display()))?;
    set_daemon_cleanup_file_permissions(path)?;
    fs::OpenOptions::new()
        .write(true)
        .open(path)
        .and_then(|file| file.sync_all())
        .with_context(|| format!("failed to sync daemon cleanup file {}", path.display()))?;
    #[cfg(unix)]
    if let Some(parent) = path.parent() {
        fs::File::open(parent)
            .and_then(|directory| directory.sync_all())
            .with_context(|| {
                format!(
                    "failed to sync daemon cleanup directory {}",
                    parent.display()
                )
            })?;
    }
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
pub(crate) fn remove_runtime_file_if_exists(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).with_context(|| format!("failed to remove {}", path.display())),
    }
}

pub(crate) fn persist_daemon_network_cleanup_state(
    config_path: &Path,
    tunnel_runtime: &CliTunnelRuntime,
) -> Result<()> {
    #[cfg(target_os = "macos")]
    {
        let path = daemon_network_cleanup_file_path(config_path);
        if let Some(state) = tunnel_runtime.macos_network_cleanup_state() {
            write_daemon_network_cleanup_state(&path, &state)?;
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = (config_path, tunnel_runtime);
    }

    Ok(())
}

#[cfg(target_os = "windows")]
fn windows_network_cleanup_journal_lock() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    LOCK.lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[cfg(target_os = "windows")]
pub(crate) fn persist_windows_route_cleanup_intent(
    config_path: &Path,
    routes: &crate::wg_upstream_runtime::WindowsRouteCleanupSnapshot,
    retain: bool,
) -> Result<()> {
    let _journal_lock = windows_network_cleanup_journal_lock();
    let path = daemon_network_cleanup_file_path(config_path);
    let mut state = read_daemon_network_cleanup_state(&path)?.unwrap_or_default();
    if retain {
        state.routes.merge(routes.clone());
    } else {
        state.routes.remove(routes);
    }
    if state.is_empty() {
        remove_runtime_file_if_exists(&path)
    } else {
        write_daemon_network_cleanup_state(&path, &state)
    }
}

#[cfg(target_os = "windows")]
pub(crate) fn persist_windows_native_wireguard_cleanup_intent(
    config_path: &Path,
    cleanup: &crate::wg_upstream_runtime::WindowsNativeWireGuardCleanupState,
) -> Result<()> {
    let _journal_lock = windows_network_cleanup_journal_lock();
    let path = daemon_network_cleanup_file_path(config_path);
    let mut state = read_daemon_network_cleanup_state(&path)?.unwrap_or_default();
    state
        .native_wireguard
        .retain(|existing| !existing.same_owner(cleanup));
    if !cleanup.is_empty() {
        state.native_wireguard.push(cleanup.clone());
    }
    if state.is_empty() {
        remove_runtime_file_if_exists(&path)
    } else {
        write_daemon_network_cleanup_state(&path, &state)
    }
}

pub(crate) fn persist_fips_daemon_network_cleanup_state(
    config_path: &Path,
    runtime: Option<&crate::fips_private_mesh::FipsPrivateTunnelRuntime>,
) -> Result<()> {
    #[cfg(target_os = "macos")]
    {
        let path = daemon_network_cleanup_file_path(config_path);
        let state = runtime
            .and_then(
                crate::fips_private_mesh::FipsPrivateTunnelRuntime::macos_network_cleanup_state,
            )
            .or_else(crate::fips_private_mesh::pending_macos_network_cleanup_state);
        if let Some(state) = state {
            write_daemon_network_cleanup_state(&path, &state)?;
        } else {
            remove_runtime_file_if_exists(&path)?;
        }
    }

    #[cfg(target_os = "linux")]
    {
        let path = daemon_network_cleanup_file_path(config_path);
        let state = runtime
            .and_then(LinuxNetworkCleanupState::from_runtime)
            .or_else(crate::fips_private_mesh::pending_linux_network_cleanup_state);
        if let Some(state) = state {
            write_daemon_network_cleanup_state(&path, &state)?;
        } else {
            remove_runtime_file_if_exists(&path)?;
        }
    }

    #[cfg(target_os = "windows")]
    {
        let _journal_lock = windows_network_cleanup_journal_lock();
        let path = daemon_network_cleanup_file_path(config_path);
        let state = WindowsNetworkCleanupState::from_runtime_and_pending(runtime);
        if state.is_empty() {
            remove_runtime_file_if_exists(&path)?;
        } else {
            write_daemon_network_cleanup_state(&path, &state)?;
        }
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        let _ = (config_path, runtime);
    }

    Ok(())
}

fn persist_fips_failed_mutation_network_cleanup_state(
    config_path: &Path,
    runtime: Option<&crate::fips_private_mesh::FipsPrivateTunnelRuntime>,
) -> Result<()> {
    #[cfg(target_os = "windows")]
    {
        let _journal_lock = windows_network_cleanup_journal_lock();
        let path = daemon_network_cleanup_file_path(config_path);
        let mut durable = read_daemon_network_cleanup_state(&path)?.unwrap_or_default();
        let current = WindowsNetworkCleanupState::from_runtime_and_pending(runtime);
        durable.routes.merge(current.routes);
        for cleanup in current.native_wireguard {
            if let Some(existing) = durable
                .native_wireguard
                .iter_mut()
                .find(|existing| existing.same_owner(&cleanup))
            {
                existing.merge_ownership(&cleanup);
            } else {
                durable.native_wireguard.push(cleanup);
            }
        }
        durable
            .secure_dns_interface_indexes
            .extend(current.secure_dns_interface_indexes);
        durable.secure_dns_interface_indexes.sort_unstable();
        durable.secure_dns_interface_indexes.dedup();
        if durable.is_empty() {
            remove_runtime_file_if_exists(&path)
        } else {
            write_daemon_network_cleanup_state(&path, &durable)
        }
    }

    #[cfg(not(target_os = "windows"))]
    {
        persist_fips_daemon_network_cleanup_state(config_path, runtime)
    }
}

#[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
pub(crate) fn persist_fips_secure_dns_cleanup_intent(
    config_path: &Path,
    intent: &crate::secure_dns_runtime::SystemDnsCleanupIntent,
) -> Result<()> {
    #[cfg(target_os = "windows")]
    let _journal_lock = windows_network_cleanup_journal_lock();
    let path = daemon_network_cleanup_file_path(config_path);
    let mut state = read_daemon_network_cleanup_state(&path)?.unwrap_or_default();

    #[cfg(target_os = "linux")]
    {
        let crate::secure_dns_runtime::SystemDnsCleanupIntent::Linux(cleanup) = intent;
        state.secure_dns = Some(cleanup.clone());
    }

    #[cfg(target_os = "macos")]
    {
        let crate::secure_dns_runtime::SystemDnsCleanupIntent::MacosResolverFiles = intent;
        state.secure_dns_resolver_files = true;
    }

    #[cfg(target_os = "windows")]
    {
        let crate::secure_dns_runtime::SystemDnsCleanupIntent::WindowsInterface(interface_index) =
            intent;
        state.secure_dns_interface_indexes.push(*interface_index);
        state.secure_dns_interface_indexes.sort_unstable();
        state.secure_dns_interface_indexes.dedup();
    }

    write_daemon_network_cleanup_state(&path, &state)
}

pub(crate) fn persist_fips_private_tunnel_start_result<T>(
    config_path: &Path,
    result: Result<T>,
) -> Result<T> {
    match result {
        Ok(value) => Ok(value),
        Err(start_error) => {
            match persist_fips_failed_mutation_network_cleanup_state(config_path, None) {
                Ok(()) => Err(start_error),
                Err(persist_error) => Err(anyhow!(
                    "{start_error:#}; failed to persist partial FIPS startup cleanup ownership: \
                 {persist_error:#}"
                )),
            }
        }
    }
}

pub(crate) async fn start_fips_private_tunnel_runtime(
    config_path: &Path,
    config: crate::fips_private_mesh::FipsPrivateTunnelConfig,
) -> Result<crate::fips_private_mesh::FipsPrivateTunnelRuntime> {
    let result =
        crate::fips_private_mesh::FipsPrivateTunnelRuntime::start(config, config_path).await;
    let runtime = persist_fips_private_tunnel_start_result(config_path, result)?;
    persist_started_runtime_or_rollback(
        runtime,
        |runtime| persist_fips_daemon_network_cleanup_state(config_path, Some(runtime)),
        |runtime| rollback_started_fips_runtime(config_path, runtime),
    )
    .await
}

pub(crate) async fn apply_fips_private_tunnel_runtime_config(
    config_path: &Path,
    runtime: &mut crate::fips_private_mesh::FipsPrivateTunnelRuntime,
    config: crate::fips_private_mesh::FipsPrivateTunnelConfig,
) -> Result<()> {
    let apply_error = runtime.apply_config(config, config_path).await.err();
    let persist_error = if apply_error.is_some() {
        persist_fips_failed_mutation_network_cleanup_state(config_path, Some(runtime)).err()
    } else {
        persist_fips_daemon_network_cleanup_state(config_path, Some(runtime)).err()
    };
    match (apply_error, persist_error) {
        (None, None) => Ok(()),
        (Some(apply), None) => Err(apply),
        (None, Some(persist)) => {
            Err(persist.context("persist FIPS network cleanup ownership after config apply"))
        }
        (Some(apply), Some(persist)) => Err(anyhow!(
            "FIPS config apply failed ({apply:#}); failed to persist resulting network cleanup \
             ownership ({persist:#})"
        )),
    }
}

async fn rollback_started_fips_runtime(
    config_path: &Path,
    runtime: crate::fips_private_mesh::FipsPrivateTunnelRuntime,
) -> Result<()> {
    let stop_error = runtime.stop().await.err();
    let persist_error = if stop_error.is_some() {
        persist_fips_failed_mutation_network_cleanup_state(config_path, None).err()
    } else {
        persist_fips_daemon_network_cleanup_state(config_path, None).err()
    };
    match (stop_error, persist_error) {
        (None, None) => Ok(()),
        (Some(stop), None) => Err(stop),
        (None, Some(persist)) => Err(persist),
        (Some(stop), Some(persist)) => Err(anyhow!(
            "failed to stop FIPS private mesh: {stop:#}; failed to persist remaining cleanup \
             ownership: {persist:#}"
        )),
    }
}

async fn persist_started_runtime_or_rollback<T, Persist, Rollback, RollbackFuture>(
    runtime: T,
    persist: Persist,
    rollback: Rollback,
) -> Result<T>
where
    Persist: FnOnce(&T) -> Result<()>,
    Rollback: FnOnce(T) -> RollbackFuture,
    RollbackFuture: std::future::Future<Output = Result<()>>,
{
    let Err(persist_error) = persist(&runtime) else {
        return Ok(runtime);
    };
    match rollback(runtime).await {
        Ok(()) => Err(anyhow!(
            "failed to persist FIPS network cleanup ownership after startup: \
             {persist_error:#}; started runtime was rolled back"
        )),
        Err(rollback_error) => Err(anyhow!(
            "failed to persist FIPS network cleanup ownership after startup: \
             {persist_error:#}; failed to roll back the started FIPS runtime: \
             {rollback_error:#}"
        )),
    }
}

pub(crate) async fn stop_fips_private_tunnel_runtime(
    config_path: &Path,
    runtime: crate::fips_private_mesh::FipsPrivateTunnelRuntime,
) -> Result<()> {
    let before_error = persist_fips_daemon_network_cleanup_state(config_path, Some(&runtime)).err();
    let stop_error = runtime.stop().await.err();
    let stop_failed = stop_error.is_some();
    let remaining_error = if stop_error.is_none() {
        persist_fips_daemon_network_cleanup_state(config_path, None).err()
    } else {
        None
    };
    if stop_error.is_none() && remaining_error.is_none() {
        return Ok(());
    }

    let mut failures = Vec::new();
    if let Some(error) = stop_error {
        failures.push(format!("failed to stop FIPS private mesh: {error:#}"));
    }
    if (stop_failed || remaining_error.is_some())
        && let Some(error) = before_error
    {
        failures.push(format!(
            "failed to persist cleanup ownership before teardown: {error:#}"
        ));
    }
    if let Some(error) = remaining_error {
        failures.push(format!(
            "failed to persist remaining cleanup ownership after teardown: {error:#}"
        ));
    }
    Err(anyhow!(failures.join("; ")))
}

#[cfg(test)]
mod started_runtime_journal_tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    #[tokio::test]
    async fn successful_start_journal_returns_the_owned_runtime() {
        let rollback_called = Arc::new(AtomicBool::new(false));
        let rollback_observer = Arc::clone(&rollback_called);
        let runtime = persist_started_runtime_or_rollback(
            42_u8,
            |_| Ok(()),
            move |_| async move {
                rollback_observer.store(true, Ordering::SeqCst);
                Ok(())
            },
        )
        .await
        .expect("successful journal keeps runtime owned");
        assert_eq!(runtime, 42);
        assert!(!rollback_called.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn failed_start_journal_rolls_back_before_returning_the_error() {
        let rollback_called = Arc::new(AtomicBool::new(false));
        let rollback_observer = Arc::clone(&rollback_called);
        let error = persist_started_runtime_or_rollback(
            42_u8,
            |_| Err(anyhow!("journal unavailable")),
            move |_| async move {
                rollback_observer.store(true, Ordering::SeqCst);
                Ok(())
            },
        )
        .await
        .expect_err("failed journal must fail startup");
        assert!(rollback_called.load(Ordering::SeqCst));
        assert!(
            error
                .to_string()
                .contains("started runtime was rolled back")
        );
    }

    #[tokio::test]
    async fn failed_start_journal_reports_a_failed_rollback() {
        let error = persist_started_runtime_or_rollback(
            42_u8,
            |_| Err(anyhow!("journal unavailable")),
            |_| async { Err(anyhow!("route cleanup failed")) },
        )
        .await
        .expect_err("failed journal and rollback must fail startup");
        let message = error.to_string();
        assert!(message.contains("journal unavailable"));
        assert!(message.contains("route cleanup failed"));
    }
}
