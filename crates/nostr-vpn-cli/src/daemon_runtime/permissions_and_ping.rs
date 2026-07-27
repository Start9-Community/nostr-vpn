pub(crate) fn set_daemon_runtime_file_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        // Daemon runtime files must stay readable by the desktop app even when
        // the daemon was started with elevated privileges.
        let metadata = fs::symlink_metadata(path).with_context(|| {
            format!(
                "failed to inspect daemon runtime file permissions on {}",
                path.display()
            )
        })?;
        let file_type = metadata.file_type();
        if file_type.is_symlink() || !file_type.is_file() {
            return Err(anyhow!(
                "refusing to set daemon runtime permissions on non-regular file {}",
                path.display()
            ));
        }
        let permissions = fs::Permissions::from_mode(0o644);
        fs::set_permissions(path, permissions).with_context(|| {
            format!(
                "failed to set daemon runtime file permissions on {}",
                path.display()
            )
        })?;
    }

    #[cfg(not(unix))]
    let _ = path;

    Ok(())
}

pub(crate) fn set_daemon_cleanup_file_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        // Linux cleanup snapshots can contain an exact `wg showconf` restore
        // payload, including private and preshared keys. Unlike UI-facing
        // daemon status files, cleanup ownership is never desktop-readable.
        let metadata = fs::symlink_metadata(path).with_context(|| {
            format!(
                "failed to inspect daemon cleanup file permissions on {}",
                path.display()
            )
        })?;
        let file_type = metadata.file_type();
        if file_type.is_symlink() || !file_type.is_file() {
            return Err(anyhow!(
                "refusing to set daemon cleanup permissions on non-regular file {}",
                path.display()
            ));
        }
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).with_context(|| {
            format!(
                "failed to set daemon cleanup file permissions on {}",
                path.display()
            )
        })?;
    }

    #[cfg(not(unix))]
    let _ = path;

    Ok(())
}

pub(crate) fn set_daemon_cleanup_directory_permissions(path: &Path) -> Result<()> {
    #[cfg(target_os = "linux")]
    {
        let metadata = fs::symlink_metadata(path).with_context(|| {
            format!(
                "failed to inspect daemon cleanup directory permissions on {}",
                path.display()
            )
        })?;
        let file_type = metadata.file_type();
        if file_type.is_symlink() || !file_type.is_dir() {
            return Err(anyhow!(
                "refusing to use non-directory daemon cleanup path {}",
                path.display()
            ));
        }
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).with_context(|| {
            format!(
                "failed to set daemon cleanup directory permissions on {}",
                path.display()
            )
        })?;
    }

    #[cfg(not(target_os = "linux"))]
    let _ = path;

    Ok(())
}

pub(crate) fn set_daemon_runtime_file_permissions_on_file(
    file: &fs::File,
    path: &Path,
) -> Result<()> {
    #[cfg(unix)]
    {
        file.set_permissions(fs::Permissions::from_mode(0o644))
            .with_context(|| {
                format!(
                    "failed to set daemon runtime file permissions on {}",
                    path.display()
                )
            })?;
    }

    #[cfg(not(unix))]
    {
        let _ = file;
        let _ = path;
    }

    Ok(())
}

pub(crate) fn set_private_cache_file_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).with_context(|| {
            format!(
                "failed to set daemon peer cache file permissions on {}",
                path.display()
            )
        })?;
    }

    #[cfg(not(unix))]
    let _ = path;

    Ok(())
}

pub(crate) fn executable_fingerprint(path: &Path) -> Result<ExecutableFingerprint> {
    let metadata = fs::metadata(path)
        .with_context(|| format!("failed to stat executable {}", path.display()))?;
    let modified_unix_nanos = metadata
        .modified()
        .ok()
        .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
        .map(|value| value.as_nanos());
    Ok(ExecutableFingerprint {
        len: metadata.len(),
        modified_unix_nanos,
    })
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
pub(crate) fn current_executable_fingerprint() -> Result<(PathBuf, ExecutableFingerprint)> {
    let executable = std::env::current_exe().context("failed to resolve current executable")?;
    let executable = fs::canonicalize(&executable)
        .with_context(|| format!("failed to canonicalize {}", executable.display()))?;
    let fingerprint = executable_fingerprint(&executable)?;
    Ok((executable, fingerprint))
}

pub(crate) fn service_supervisor_restart_due(
    executable: &Path,
    launched_fingerprint: &ExecutableFingerprint,
) -> Result<bool> {
    Ok(executable_fingerprint(executable)? != *launched_fingerprint)
}

#[cfg(unix)]
pub(crate) fn send_signal(pid: u32, signal: &str) -> Result<()> {
    if cfg!(not(unix)) {
        return Err(anyhow!("daemon signal control is only supported on unix"));
    }

    let output = ProcessCommand::new("kill")
        .arg(signal)
        .arg(pid.to_string())
        .output()
        .with_context(|| format!("failed to execute kill {signal} {pid}"))?;

    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    let stdout = String::from_utf8_lossy(&output.stdout);
    Err(anyhow!(
        "kill {signal} {pid} failed\nstdout: {}\nstderr: {}",
        stdout.trim(),
        stderr.trim()
    ))
}

#[cfg(target_os = "windows")]
pub(crate) fn windows_taskkill_pid(pid: u32) -> Result<()> {
    let output = ProcessCommand::new("taskkill")
        .args(["/PID", &pid.to_string(), "/F"])
        .output()
        .with_context(|| format!("failed to execute taskkill /PID {pid} /F"))?;

    if output.status.success() {
        return Ok(());
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let details = format!("{}\n{}", stdout.trim(), stderr.trim())
        .trim()
        .to_string();
    let lower = details.to_ascii_lowercase();
    if lower.contains("not found") || lower.contains("no running instance") {
        return Ok(());
    }

    Err(anyhow!(
        "taskkill /PID {pid} /F failed\nstdout: {}\nstderr: {}",
        stdout.trim(),
        stderr.trim()
    ))
}

#[cfg(any(unix, test))]
pub(crate) fn kill_error_requires_control_fallback(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("operation not permitted") || lower.contains("permission denied")
}

fn ping_wait_arg_from_secs(timeout_secs: u64) -> String {
    if cfg!(any(target_os = "macos", target_os = "windows")) {
        timeout_secs.saturating_mul(1000).to_string()
    } else {
        timeout_secs.to_string()
    }
}

pub(crate) fn run_ping(target: &str, count: u32, timeout_secs: u64) -> Result<()> {
    let mut command = ProcessCommand::new("ping");
    if cfg!(target_os = "windows") {
        command
            .arg("-n")
            .arg(count.to_string())
            .arg("-w")
            .arg(ping_wait_arg_from_secs(timeout_secs))
            .arg(target);
    } else {
        command
            .arg("-c")
            .arg(count.to_string())
            .arg("-W")
            .arg(ping_wait_arg_from_secs(timeout_secs))
            .arg(target);
    }

    let output = command
        .output()
        .with_context(|| format!("failed to execute ping for {target}"))?;

    print!("{}", String::from_utf8_lossy(&output.stdout));
    eprint!("{}", String::from_utf8_lossy(&output.stderr));

    if !output.status.success() {
        return Err(anyhow!("ping failed for {target}"));
    }

    Ok(())
}

#[cfg(all(test, target_os = "macos"))]
mod ping_command_tests {
    use super::ping_wait_arg_from_secs;

    #[test]
    fn timeout_seconds_are_converted_to_macos_ping_milliseconds() {
        assert_eq!(ping_wait_arg_from_secs(2), "2000");
    }
}

pub(crate) fn resolve_ping_target(target: &str, peers: &[PeerAnnouncement]) -> Option<String> {
    if target.parse::<IpAddr>().is_ok() {
        return Some(target.to_string());
    }

    peers.iter().find_map(|peer| {
        let tunnel_ip = strip_cidr(&peer.tunnel_ip);
        if peer.node_id == target || peer.tunnel_ip == target || tunnel_ip == target {
            Some(tunnel_ip.to_string())
        } else {
            None
        }
    })
}
