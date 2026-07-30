#[cfg(any(target_os = "linux", target_os = "macos"))]
impl FipsPrivateTunnelRuntime {
    fn start_packet_workers(
        &mut self,
        tun_fd: BorrowedTunFd,
        event_tx: mpsc::Sender<FipsPrivateMeshEvent>,
        fips_host_enabled: bool,
    ) -> Result<()> {
        self.tun_send_worker = Some(spawn_tun_send_worker(
            Arc::clone(&self._tun),
            Arc::clone(&self.mesh),
            fips_host_enabled,
        )?);
        self.mesh_recv_worker = Some(spawn_mesh_recv_worker(
            Arc::clone(&self.mesh),
            tun_fd,
            event_tx,
        )?);
        self.fips_host_recv_worker = fips_host_enabled
            .then(|| spawn_fips_host_recv_worker(Arc::clone(self.mesh.endpoint()), tun_fd));
        Ok(())
    }
}
