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
    tunnel_name: &str,
    owner_token: &str,
) -> Result<bool> {
    let service_name = format!("WireGuardTunnel${tunnel_name}");
    let escaped_service_name = service_name.replace('\'', "''");
    let script = format!(
        "$ErrorActionPreference = 'Stop'; \
         $service = Get-CimInstance Win32_Service \
           -Filter \"Name='{escaped_service_name}'\"; \
         if ($null -eq $service) {{ 'absent' }} \
         elseif ($service.Description -ceq {}) {{ 'owned' }} \
         else {{ 'foreign' }}",
        windows_powershell_literal(owner_token),
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
pub(crate) fn cleanup_windows_native_wireguard_state(
    cleanup: &mut WindowsNativeWireGuardCleanupState,
) -> Result<()> {
    let mut failures = Vec::new();
    if cleanup.service_owned {
        match windows_native_wireguard_service_is_owned(&cleanup.name, &cleanup.owner_token) {
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
        match windows_native_wireguard_config_is_owned(
            &cleanup.config_path,
            &cleanup.owner_token,
        ) {
            Ok(false) => cleanup.config_owned = false,
            Ok(true) => match std::fs::remove_file(&cleanup.config_path) {
                Ok(()) => cleanup.config_owned = false,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    cleanup.config_owned = false;
                }
                Err(error) => failures.push(format!(
                    "remove owned config {}: {error}",
                    cleanup.config_path.display()
                )),
            },
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
        let result = cleanup_windows_native_wireguard_state(&mut cleanup);
        self.service_owned = cleanup.service_owned;
        self.config_owned = cleanup.config_owned;
        result
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
