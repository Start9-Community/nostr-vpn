async fn resolve_endpoint(endpoint: &str) -> Result<SocketAddr> {
    let endpoint = endpoint.trim();
    if let Ok(addr) = endpoint.parse::<SocketAddr>() {
        return Ok(addr);
    }
    let resolved = tokio::net::lookup_host(endpoint)
        .await
        .with_context(|| format!("resolve WG upstream endpoint '{endpoint}'"))?;
    let resolved = select_roaming_stable_endpoint(resolved)
        .ok_or_else(|| anyhow!("no DNS results for '{endpoint}'"))?;
    Ok(resolved)
}

fn select_roaming_stable_endpoint(
    resolved: impl IntoIterator<Item = SocketAddr>,
) -> Option<SocketAddr> {
    // A UDP socket cannot change address family in place. Prefer an available
    // IPv4 endpoint deterministically because IPv4 remains routable on both
    // dual-stack Wi-Fi and IPv4-only phone hotspots. IPv6-only endpoints are
    // still accepted when they are the only published address.
    resolved
        .into_iter()
        .enumerate()
        .min_by_key(|(order, address)| (u8::from(address.is_ipv6()), *order))
        .map(|(_, address)| address)
}

#[cfg(unix)]
fn raw_udp_socket_fd(socket: &UdpSocket) -> c_int {
    use std::os::unix::io::AsRawFd;
    socket.as_raw_fd() as c_int
}

#[cfg(not(unix))]
fn raw_udp_socket_fd(_socket: &UdpSocket) -> c_int {
    -1
}

#[cfg(target_os = "macos")]
fn bind_apple_udp_socket_to_interface(
    socket_fd: c_int,
    upstream: SocketAddr,
    interface_index: u32,
) -> Result<()> {
    let value = c_int::try_from(interface_index)
        .context("macOS WG underlay interface index exceeds c_int")?;
    if value == 0 {
        return Err(anyhow!(
            "macOS WG underlay interface index must be non-zero"
        ));
    }
    let (level, option) = match upstream {
        SocketAddr::V4(_) => (libc::IPPROTO_IP, libc::IP_BOUND_IF),
        SocketAddr::V6(_) => (libc::IPPROTO_IPV6, libc::IPV6_BOUND_IF),
    };
    let result = unsafe {
        libc::setsockopt(
            socket_fd,
            level,
            option,
            (&value as *const c_int).cast(),
            std::mem::size_of_val(&value) as libc::socklen_t,
        )
    };
    if result != 0 {
        return Err(std::io::Error::last_os_error()).with_context(|| {
            format!("bind WG UDP socket for {upstream} to macOS interface index {interface_index}")
        });
    }
    Ok(())
}

fn udp_bind_addr_for_upstream(upstream: SocketAddr) -> SocketAddr {
    match upstream {
        SocketAddr::V4(addr) if addr.ip().is_loopback() => {
            SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0).into()
        }
        SocketAddr::V4(_) => SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0).into(),
        SocketAddr::V6(addr) if addr.ip().is_loopback() => {
            SocketAddrV6::new(Ipv6Addr::LOCALHOST, 0, 0, 0).into()
        }
        SocketAddr::V6(_) => SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, 0, 0, 0).into(),
    }
}

// Direct OS-log bridges so the WG pump's diagnostic messages surface
// during device testing — Rust stderr/stdout is redirected to
// /dev/null on Android and inside an iOS app extension, and the
// existing `tracing` macros silently no-op without a registered
// subscriber. The Android side bridges to logcat; iOS appends to a
// file inside the extension's sandboxed temp dir, which we can pull
// back with `xcrun devicectl device copy from`.

#[cfg(target_os = "android")]
fn log_android(prio: i32, message: &str) {
    use std::ffi::CString;
    let tag = CString::new("nvpn-wg").unwrap_or_default();
    if let Ok(msg) = CString::new(message) {
        unsafe {
            __android_log_write(prio, tag.as_ptr(), msg.as_ptr());
        }
    }
}

#[cfg(target_os = "android")]
fn log_android_info(message: &str) {
    log_android(4 /* ANDROID_LOG_INFO */, message);
}

#[cfg(target_os = "android")]
fn log_android_warn(message: &str) {
    log_android(5 /* ANDROID_LOG_WARN */, message);
}

#[cfg(target_os = "ios")]
fn log_android_info(message: &str) {
    log_ios_file(message);
}

#[cfg(target_os = "ios")]
fn log_android_warn(message: &str) {
    log_ios_file(message);
}

#[cfg(target_os = "ios")]
fn log_ios_file(message: &str) {
    use std::fs::OpenOptions;
    use std::io::Write;
    use std::time::{SystemTime, UNIX_EPOCH};
    let path = std::env::temp_dir().join("nvpn-wg.log");
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(file, "{secs:.3} {message}");
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn log_android_info(_message: &str) {}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn log_android_warn(_message: &str) {}

#[cfg(target_os = "android")]
unsafe extern "C" {
    fn __android_log_write(
        prio: i32,
        tag: *const std::os::raw::c_char,
        text: *const std::os::raw::c_char,
    ) -> i32;
}
