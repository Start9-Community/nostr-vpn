#[cfg(target_os = "windows")]
pub(crate) struct FipsPrivateTunnelRuntime {
    iface: String,
    mesh: Arc<FipsPrivateMeshRuntime>,
    control_pubsub: Option<crate::control_pubsub_runtime::ControlPubsubFipsRuntime>,
    state_control: FipsControlTcpRuntime,
    secure_dns: Option<crate::secure_dns_runtime::SecureDnsRuntime>,
    config: FipsPrivateTunnelConfig,
    session: Arc<Session>,
    stop: Arc<AtomicBool>,
    tun_read_thread: ThreadJoinHandle<()>,
    mesh_recv_task: JoinHandle<()>,
    event_rx: mpsc::Receiver<FipsPrivateMeshEvent>,
    exit_route_ready: bool,
    interface_index: u32,
    route_guard: crate::wg_upstream_runtime::WindowsManagedInterfaceRoutes,
    endpoint_bypass_routes: Option<crate::wg_upstream_runtime::WindowsManagedEndpointRoutes>,
    /// Native WireGuardNT upstream reconciled whenever `wireguard_exit`
    /// changes. Its interface is distinct from the FIPS WinTun adapter.
    wg_upstream: Option<crate::wg_upstream_runtime::DaemonWgUpstream>,
}
