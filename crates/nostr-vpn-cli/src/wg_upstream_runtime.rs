//! Platform-routing helpers around the shared userspace WG runtime.
//!
//! The boringtun pump itself lives in `nostr_vpn_core::wg_upstream`
//! (so mobile + desktop both use the same tunnel state machine). This
//! module is the desktop-only glue: routing-table swaps, default-route
//! capture/restore, scoped host routes for the test command, and the
//! `DaemonWgUpstream` lifecycle holder that the daemon's reconcile
//! loop owns.

use std::net::{IpAddr, SocketAddr};
#[cfg(target_os = "windows")]
use std::path::{Path, PathBuf};
use std::process::Command as ProcessCommand;
use std::sync::Arc;
#[cfg(any(target_os = "macos", target_os = "windows"))]
use std::time::Duration;

use anyhow::{Context, Result, anyhow};

#[cfg(any(target_os = "linux", target_os = "macos"))]
use boringtun::device::tun::TunSocket;
#[cfg(target_os = "windows")]
use wintun::Session as WintunSession;

use nostr_vpn_core::config::WireGuardExitConfig;
#[cfg(any(target_os = "linux", target_os = "macos"))]
use nostr_vpn_core::wg_upstream::MAX_WG_PACKET;
pub use nostr_vpn_core::wg_upstream::WgUpstreamRuntime;
#[cfg(any(target_os = "macos", target_os = "windows"))]
pub use nostr_vpn_core::wg_upstream::{
    DAEMON_WG_UPSTREAM_HANDSHAKE_TIMEOUT, WireGuardExitFingerprint,
};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

const WG_TUN_PACKET_QUEUE_CAPACITY: usize = 1024;
const WG_TUN_BATCH_CAPACITY: usize = 64;
const WG_TUN_BATCH_CHANNEL_CAPACITY: usize = WG_TUN_PACKET_QUEUE_CAPACITY / WG_TUN_BATCH_CAPACITY;
#[cfg(any(target_os = "macos", test))]
const MACOS_WG_DEFAULT_ROUTE_TARGETS: &[&str] = &["0.0.0.0/1", "128.0.0.0/1"];

include!("wg_upstream_runtime/tun_io.rs");
include!("wg_upstream_runtime/posix_routes.rs");
include!("wg_upstream_runtime/daemon_handles.rs");
include!("wg_upstream_runtime/windows_routes.rs");
include!("wg_upstream_runtime/windows_daemon.rs");
include!("wg_upstream_runtime/windows_native_config.rs");
include!("wg_upstream_runtime/windows_native_ownership.rs");
include!("wg_upstream_runtime/tests.rs");
