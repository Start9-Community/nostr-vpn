use super::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DaemonNetworkTrigger {
    EventDeadline,
    Periodic,
}

#[derive(Default)]
pub(crate) struct PlatformNetworkSampleDeadline {
    sleep: Option<std::pin::Pin<Box<tokio::time::Sleep>>>,
}

impl PlatformNetworkSampleDeadline {
    pub(crate) fn is_active(&self) -> bool {
        self.sleep.is_some()
    }

    pub(crate) fn reset_after(&mut self, delay: Duration) {
        let deadline = tokio::time::Instant::now() + delay;
        match self.sleep.as_mut() {
            Some(sleep) => sleep.as_mut().reset(deadline),
            None => self.sleep = Some(Box::pin(tokio::time::sleep_until(deadline))),
        }
    }

    async fn wait(&mut self) {
        self.sleep
            .as_mut()
            .expect("active platform network deadline")
            .as_mut()
            .await;
        self.sleep = None;
    }
}

pub(crate) async fn next_daemon_network_trigger(
    event_deadline: &mut PlatformNetworkSampleDeadline,
    periodic: &mut tokio::time::Interval,
) -> DaemonNetworkTrigger {
    if event_deadline.is_active() {
        // The event-owned absolute Sleep survives cancellation when another
        // daemon branch wins. A ready sparse-periodic tick must not bypass an
        // active debounce or settle deadline.
        event_deadline.wait().await;
        DaemonNetworkTrigger::EventDeadline
    } else {
        periodic.tick().await;
        DaemonNetworkTrigger::Periodic
    }
}

pub(super) struct DaemonVpnIntervals {
    pub(super) state: tokio::time::Interval,
    pub(super) tunnel_heartbeat: tokio::time::Interval,
    pub(super) network: tokio::time::Interval,
    pub(super) network_deadline: PlatformNetworkSampleDeadline,
    pub(super) runtime_resume_pending: bool,
}

pub(super) fn daemon_vpn_intervals() -> DaemonVpnIntervals {
    let interval = |seconds| {
        let mut timer = tokio::time::interval(Duration::from_secs(seconds));
        timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        timer
    };
    DaemonVpnIntervals {
        state: interval(1),
        tunnel_heartbeat: interval(2),
        network: interval(DAEMON_NETWORK_REFRESH_INTERVAL_SECS),
        network_deadline: PlatformNetworkSampleDeadline::default(),
        runtime_resume_pending: false,
    }
}
