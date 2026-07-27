#[cfg(target_os = "windows")]
fn run_windows_wireguard_command(exe: &Path, args: &[&str]) -> Result<()> {
    let output = ProcessCommand::new(exe)
        .args(args)
        .output()
        .with_context(|| format!("spawn {} {}", exe.display(), args.join(" ")))?;
    if !output.status.success() {
        return Err(anyhow!(
            "{} {} failed with {}\nstdout: {}\nstderr: {}",
            exe.display(),
            args.join(" "),
            output.status,
            String::from_utf8_lossy(&output.stdout).trim(),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(())
}

#[cfg(target_os = "windows")]
fn windows_native_wireguard_service_is_owned(
    cleanup: &WindowsNativeWireGuardCleanupState,
) -> Result<bool> {
    let service_name = format!("WireGuardTunnel${}", cleanup.name);
    let escaped_service_name = service_name.replace('\'', "''");
    let expected_binary_path = windows_native_wireguard_service_binary_path(
        &cleanup.wireguard_exe,
        &cleanup.config_path,
    );
    let script = format!(
        "$ErrorActionPreference = 'Stop'; \
         $expectedPath = {}; \
         $service = Get-CimInstance Win32_Service \
           -Filter \"Name='{escaped_service_name}'\"; \
         if ($null -eq $service) {{ 'absent' }} \
         elseif ($service.PathName -cne $expectedPath) {{ 'foreign' }} \
         elseif ($service.Description -ceq {}) {{ 'owned' }} \
         elseif ([string]::IsNullOrEmpty($service.Description)) {{ 'path-owned' }} \
         else {{ 'foreign' }}",
        windows_powershell_literal(&expected_binary_path),
        windows_powershell_literal(&cleanup.owner_token),
    );
    let output = ProcessCommand::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .output()
        .with_context(|| format!("audit native WireGuard service ownership {service_name}"))?;
    if !output.status.success() {
        return Err(anyhow!(
            "native WireGuard service ownership audit failed for {service_name}: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    match String::from_utf8_lossy(&output.stdout)
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "owned" => Ok(true),
        "path-owned" => {
            if windows_native_wireguard_config_is_owned(
                &cleanup.config_path,
                &cleanup.owner_token,
            )? {
                Ok(true)
            } else {
                Err(anyhow!(
                    "native WireGuard service {service_name} has the intended binary path \
                     but its owner-marked config is absent"
                ))
            }
        }
        "absent" => Ok(false),
        "foreign" => Err(anyhow!(
            "refusing to remove foreign same-name native WireGuard service {service_name}"
        )),
        state => Err(anyhow!(
            "unexpected ownership state {state:?} for native WireGuard service {service_name}"
        )),
    }
}

#[cfg(target_os = "windows")]
fn cleanup_windows_native_wireguard_config(
    path: &Path,
    owner_token: &str,
) -> Result<()> {
    let legacy_layout = matches!(
        windows_native_wireguard_config_layout(path, owner_token)?,
        WindowsNativeWireGuardConfigLayout::Legacy
    );
    let config_owned = windows_native_wireguard_config_is_owned(path, owner_token)?;
    let marker_owned = windows_native_wireguard_owner_marker_is_owned(path, owner_token)?;
    if config_owned {
        match std::fs::remove_file(path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("remove owned config {}", path.display()));
            }
        }
    }

    let marker_path = if legacy_layout {
        windows_native_wireguard_legacy_owner_marker_path(path)
    } else {
        windows_native_wireguard_owner_marker_path(path)
    };
    if marker_owned {
        match std::fs::remove_file(&marker_path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error).with_context(|| {
                    format!(
                        "remove owned native WireGuard marker {}",
                        marker_path.display()
                    )
                });
            }
        }
    }

    // The per-owner directory is not itself a network or secret-bearing
    // artifact once the exact config and marker are gone. Remove it when it
    // is still empty, but never recurse into or touch unexpected contents.
    if (config_owned || marker_owned)
        && let Some(owner_root) = windows_native_wireguard_owner_root(path, owner_token)?
    {
        let _ = std::fs::remove_dir(owner_root);
    }
    Ok(())
}

#[cfg(target_os = "windows")]
pub(crate) fn cleanup_windows_native_wireguard_state(
    cleanup: &mut WindowsNativeWireGuardCleanupState,
) -> Result<()> {
    let mut failures = Vec::new();
    if cleanup.service_owned {
        match windows_native_wireguard_service_is_owned(cleanup) {
            Ok(false) => cleanup.service_owned = false,
            Ok(true) => match run_windows_wireguard_command(
                &cleanup.wireguard_exe,
                &["/uninstalltunnelservice", &cleanup.name],
            ) {
                Ok(()) => cleanup.service_owned = false,
                Err(error) => {
                    failures.push(format!("uninstall owned tunnel service: {error:#}"))
                }
            },
            Err(error) => failures.push(format!("{error:#}")),
        }
    }
    if cleanup.config_owned && !cleanup.service_owned {
        match cleanup_windows_native_wireguard_config(
            &cleanup.config_path,
            &cleanup.owner_token,
        ) {
            Ok(()) => cleanup.config_owned = false,
            Err(error) => failures.push(format!("{error:#}")),
        }
    } else if cleanup.config_owned {
        failures.push("owned config cleanup deferred until service removal succeeds".to_string());
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(anyhow!(failures.join("; ")))
    }
}

#[cfg(target_os = "windows")]
impl WindowsNativeWireGuardTunnel {
    fn cleanup(&mut self) -> Result<()> {
        let Some(mut cleanup) = self.cleanup_state() else {
            return Ok(());
        };
        let cleanup_result = cleanup_windows_native_wireguard_state(&mut cleanup);
        self.service_owned = cleanup.service_owned;
        self.config_owned = cleanup.config_owned;
        let persist_result =
            crate::daemon_runtime::persist_windows_native_wireguard_cleanup_intent(
                &self.cleanup_journal_config_path,
                &cleanup,
            );
        match (cleanup_result, persist_result) {
            (Ok(()), Ok(())) => Ok(()),
            (Err(error), Ok(())) => Err(error),
            (Ok(()), Err(error)) => {
                Err(error.context("persist completed native WireGuard cleanup"))
            }
            (Err(cleanup_error), Err(persist_error)) => Err(anyhow!(
                "{cleanup_error:#}; failed to persist remaining native WireGuard ownership: \
                 {persist_error:#}"
            )),
        }
    }
}

#[cfg(target_os = "windows")]
impl Drop for WindowsNativeWireGuardTunnel {
    fn drop(&mut self) {
        if let Err(error) = self.cleanup() {
            if let Some(cleanup) = self.cleanup_state() {
                retain_pending_windows_native_cleanup(cleanup);
            }
            eprintln!(
                "wg-upstream: WARNING — owned native WireGuard cleanup retained: {error:#}"
            );
        }
    }
}

#[cfg(target_os = "windows")]
fn with_windows_native_cleanup_error(
    error: anyhow::Error,
    operation: &str,
    cleanup: Result<()>,
) -> anyhow::Error {
    match cleanup {
        Ok(()) => error,
        Err(cleanup_error) => anyhow!("{error:#}; {operation}: {cleanup_error:#}"),
    }
}
