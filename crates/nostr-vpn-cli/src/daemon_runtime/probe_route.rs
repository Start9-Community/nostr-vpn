// Serialize route invalidation with asynchronous daemon snapshots. A snapshot
// captured before a switch must never restore the old probe authorization.
fn daemon_probe_route_generation() -> &'static std::sync::Mutex<String> {
    static GENERATION: std::sync::OnceLock<std::sync::Mutex<String>> = std::sync::OnceLock::new();
    GENERATION.get_or_init(|| std::sync::Mutex::new(String::new()))
}

pub(crate) fn current_daemon_probe_route_generation() -> String {
    daemon_probe_route_generation()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone()
}

pub(crate) fn invalidate_daemon_probe_route(config_path: &Path) -> Result<()> {
    let mut generation = daemon_probe_route_generation()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    *generation = uuid::Uuid::new_v4().to_string();
    let path = daemon_state_file_path(config_path)?;
    if let Some(mut state) = read_daemon_state(&path)? {
        state.probe_route_generation = generation.clone();
        state.tunnel_exit_peer = None;
        write_daemon_state(&path, &state)?;
    }
    Ok(())
}

pub(crate) fn write_current_daemon_probe_state(
    path: &Path,
    state: &DaemonRuntimeState,
) -> Result<()> {
    let generation = daemon_probe_route_generation()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if state.probe_route_generation != *generation {
        return Ok(());
    }
    write_daemon_state(path, state)
}
