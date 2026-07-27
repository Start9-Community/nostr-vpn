use crate::*;
use std::net::Ipv4Addr;

#[test]
fn daemon_network_refresh_uses_platform_events_with_sparse_fallback() {
    #[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
    {
        assert_eq!(DAEMON_NETWORK_REFRESH_INTERVAL_SECS, 300);
        const {
            const FIPS_SOCKET_REBIND_RETRY_BUDGET_MILLIS: u64 = 2_000;
            assert!(DAEMON_NETWORK_EVENT_DEBOUNCE_MILLIS <= 1_000);
            assert!(
                DAEMON_NETWORK_EVENT_DEBOUNCE_MILLIS
                    + FIPS_SOCKET_REBIND_RETRY_BUDGET_MILLIS
                    + (FIPS_LINK_EVENT_CONFIG_BUILD_TIMEOUT_MILLIS * 2)
                    + DAEMON_NETWORK_REFRESH_RETRY_MILLIS
                    < 4_000
            );
            assert!(DAEMON_NETWORK_SETTLE_RECHECK_MILLIS <= 250);
            assert!(
                DAEMON_NETWORK_SETTLE_RECHECK_MILLIS
                    * (DAEMON_NETWORK_SETTLE_RECHECK_ATTEMPTS as u64)
                    >= 10_000
            );
            assert!(
                DAEMON_NETWORK_SETTLE_RECHECK_MILLIS
                    * (DAEMON_NETWORK_SETTLE_RECHECK_ATTEMPTS as u64)
                    <= 15_000
            );
        }
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    assert_eq!(DAEMON_NETWORK_REFRESH_INTERVAL_SECS, 1);
}

#[tokio::test(start_paused = true)]
async fn staged_refresh_retry_is_bounded_and_never_duplicates_a_successful_rebind() {
    let old_snapshot = crate::diagnostics::NetworkSnapshot {
        default_interface: Some("en0".to_string()),
        primary_ipv4: Some(Ipv4Addr::new(192, 0, 2, 10)),
        ..Default::default()
    };
    let new_snapshot = crate::diagnostics::NetworkSnapshot {
        default_interface: Some("en1".to_string()),
        primary_ipv4: Some(Ipv4Addr::new(198, 51, 100, 10)),
        ..Default::default()
    };

    let mut failed_rebind = PlatformNetworkRefreshAttempt::new(
        new_snapshot.clone(),
        FipsLinkEventRefresh::RebindUnderlayAndRefreshPaths,
        "network change",
    );
    assert!(failed_rebind.needs_carrier_rebind(true));
    let mut rebind_retry_deadline = PlatformNetworkSampleDeadline::default();
    assert_eq!(
        failed_rebind.schedule_completion_retry(&mut rebind_retry_deadline),
        PlatformNetworkRefreshRetry::Scheduled
    );
    assert!(
        !platform_network_background_maintenance_enabled(&rebind_retry_deadline),
        "a failed route refresh retry must remain exclusive"
    );
    assert!(
        failed_rebind.needs_carrier_rebind(true),
        "a failed carrier operation was incorrectly recorded as complete"
    );

    let mut sparse_timer =
        tokio::time::interval(Duration::from_secs(DAEMON_NETWORK_REFRESH_INTERVAL_SECS));
    sparse_timer.tick().await;
    tokio::time::advance(Duration::from_millis(
        DAEMON_NETWORK_REFRESH_RETRY_MILLIS - 1,
    ))
    .await;
    assert!(
        futures_util::FutureExt::now_or_never(next_daemon_network_trigger(
            &mut rebind_retry_deadline,
            &mut sparse_timer,
        ))
        .is_none(),
        "failed carrier rebind retried before the bounded delay"
    );
    tokio::time::advance(Duration::from_millis(1)).await;
    assert_eq!(
        next_daemon_network_trigger(&mut rebind_retry_deadline, &mut sparse_timer).await,
        DaemonNetworkTrigger::EventDeadline
    );
    assert_eq!(
        failed_rebind.schedule_completion_retry(&mut rebind_retry_deadline),
        PlatformNetworkRefreshRetry::Exhausted,
        "a second transient failure must fail closed instead of stalling until the 5-minute tick"
    );
    let mut terminal_error = None;
    assert!(
        !stage_platform_network_refresh_retry(
            &mut terminal_error,
            &mut failed_rebind,
            &mut rebind_retry_deadline,
            anyhow!("second transient carrier failure"),
            "FIPS carrier rebind retry budget exhausted",
        ),
        "exhausted retries must terminate the unhealthy daemon generation"
    );
    assert!(
        terminal_error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("retry budget exhausted"))
    );
    assert!(
        platform_network_event_receive_enabled(false, 0, &rebind_retry_deadline),
        "exhausted retry did not release intake for a fresh OS event"
    );

    let mut failed_completion = PlatformNetworkRefreshAttempt::new(
        new_snapshot.clone(),
        FipsLinkEventRefresh::RebindUnderlayAndRefreshPaths,
        "network change",
    );
    failed_completion.mark_carrier_rebound();
    assert!(
        !failed_completion.needs_carrier_rebind(true),
        "successful carrier state did not suppress a duplicate rebind"
    );
    let mut completion_retry_deadline = PlatformNetworkSampleDeadline::default();
    assert_eq!(
        failed_completion.schedule_completion_retry(&mut completion_retry_deadline),
        PlatformNetworkRefreshRetry::Scheduled
    );
    assert!(
        !failed_completion.needs_carrier_rebind(true),
        "config/apply retry tried to rebind an already-committed generation"
    );
    assert!(
        !failed_completion.is_superseded_by(&new_snapshot, false),
        "the exact committed snapshot lost its carrier completion marker"
    );
    assert!(
        failed_completion.is_superseded_by(&old_snapshot, false),
        "a newer physical snapshot did not reset staged carrier state"
    );
    assert!(
        failed_completion.is_superseded_by(&new_snapshot, true),
        "sleep/wake did not reset staged carrier state"
    );
}

#[tokio::test]
async fn back_to_back_network_roam_is_not_delayed_by_prior_refresh() {
    let previous = crate::diagnostics::NetworkSnapshot {
        default_interface: Some("en0".to_string()),
        default_interface_mtu: Some(1_500),
        primary_ipv4: Some(Ipv4Addr::new(192, 0, 2, 55)),
        primary_ipv6: None,
        gateway_ipv4: Some(Ipv4Addr::new(192, 0, 2, 1)),
        gateway_ipv6: None,
    };
    let after_roam = crate::diagnostics::NetworkSnapshot {
        primary_ipv4: Some(Ipv4Addr::new(198, 51, 100, 4)),
        gateway_ipv4: Some(Ipv4Addr::new(198, 51, 100, 1)),
        ..previous.clone()
    };
    let mut sparse_snapshot_timer = tokio::time::interval(std::time::Duration::from_secs(
        DAEMON_NETWORK_REFRESH_INTERVAL_SECS,
    ));
    sparse_snapshot_timer.tick().await;
    let mut event_deadline = PlatformNetworkSampleDeadline::default();
    let mut settle_rechecks_remaining = 0;

    begin_platform_network_settle_rechecks(&mut settle_rechecks_remaining);
    assert!(schedule_platform_network_settle_recheck(
        &mut event_deadline,
        &mut settle_rechecks_remaining,
    ));
    tokio::time::timeout(
        std::time::Duration::from_secs(1),
        next_daemon_network_trigger(&mut event_deadline, &mut sparse_snapshot_timer),
    )
    .await
    .expect("a second roam must wake the snapshot timer without waiting for a suppression window");

    let network_changed = after_roam.changed_since(&previous);
    assert!(network_changed, "the new IP and gateway must be observed");
    assert_eq!(
        fips_link_event_refresh(false, network_changed, false, false),
        FipsLinkEventRefresh::RebindUnderlayAndRefreshPaths,
        "same-interface address changes must rebind underlay sockets without discarding established sessions"
    );
    assert_eq!(
        fips_link_event_refresh(false, previous.changed_since(&previous), false, false),
        FipsLinkEventRefresh::None,
        "nvpn-only route notifications must remain a no-op"
    );
}

#[tokio::test]
async fn platform_route_event_always_schedules_settle_snapshot_recheck() {
    let mut sparse_snapshot_timer = tokio::time::interval(std::time::Duration::from_secs(
        DAEMON_NETWORK_REFRESH_INTERVAL_SECS,
    ));
    sparse_snapshot_timer.tick().await;
    let mut event_deadline = PlatformNetworkSampleDeadline::default();
    let mut settle_rechecks_remaining = 0;

    begin_platform_network_settle_rechecks(&mut settle_rechecks_remaining);
    assert!(schedule_platform_network_settle_recheck(
        &mut event_deadline,
        &mut settle_rechecks_remaining,
    ));
    tokio::time::timeout(
        std::time::Duration::from_secs(1),
        next_daemon_network_trigger(&mut event_deadline, &mut sparse_snapshot_timer),
    )
    .await
    .expect("a handled route event must recheck quickly while the replacement route settles");

    for _ in 1..DAEMON_NETWORK_SETTLE_RECHECK_ATTEMPTS {
        assert!(schedule_platform_network_settle_recheck(
            &mut event_deadline,
            &mut settle_rechecks_remaining,
        ));
    }
    assert_eq!(settle_rechecks_remaining, 0);
    assert!(!schedule_platform_network_settle_recheck(
        &mut event_deadline,
        &mut settle_rechecks_remaining,
    ));
}

#[tokio::test(start_paused = true)]
async fn new_platform_event_after_settle_window_restarts_fast_sampling() {
    let mut sparse_snapshot_timer = tokio::time::interval(std::time::Duration::from_secs(
        DAEMON_NETWORK_REFRESH_INTERVAL_SECS,
    ));
    sparse_snapshot_timer.tick().await;
    let mut event_deadline = PlatformNetworkSampleDeadline::default();
    let mut settle_rechecks_remaining = 0;

    schedule_platform_network_event_sampling(&mut event_deadline, &mut settle_rechecks_remaining);
    tokio::time::advance(std::time::Duration::from_millis(
        DAEMON_NETWORK_EVENT_DEBOUNCE_MILLIS,
    ))
    .await;
    assert_eq!(
        next_daemon_network_trigger(&mut event_deadline, &mut sparse_snapshot_timer).await,
        DaemonNetworkTrigger::EventDeadline
    );

    for _ in 0..DAEMON_NETWORK_SETTLE_RECHECK_ATTEMPTS {
        assert!(schedule_platform_network_settle_recheck(
            &mut event_deadline,
            &mut settle_rechecks_remaining,
        ));
        tokio::time::advance(std::time::Duration::from_millis(
            DAEMON_NETWORK_SETTLE_RECHECK_MILLIS,
        ))
        .await;
        assert_eq!(
            next_daemon_network_trigger(&mut event_deadline, &mut sparse_snapshot_timer).await,
            DaemonNetworkTrigger::EventDeadline
        );
    }
    assert_eq!(settle_rechecks_remaining, 0);

    schedule_platform_network_event_sampling(&mut event_deadline, &mut settle_rechecks_remaining);
    tokio::time::advance(std::time::Duration::from_millis(
        DAEMON_NETWORK_EVENT_DEBOUNCE_MILLIS - 1,
    ))
    .await;
    assert!(
        futures_util::FutureExt::now_or_never(next_daemon_network_trigger(
            &mut event_deadline,
            &mut sparse_snapshot_timer,
        ))
        .is_none(),
        "the fresh event fired before its debounce elapsed"
    );
    tokio::time::advance(std::time::Duration::from_millis(1)).await;
    assert_eq!(
        futures_util::FutureExt::now_or_never(next_daemon_network_trigger(
            &mut event_deadline,
            &mut sparse_snapshot_timer,
        )),
        Some(DaemonNetworkTrigger::EventDeadline),
        "the exhausted settle window left the fresh event on the sparse fallback"
    );
}

#[tokio::test(start_paused = true)]
async fn platform_event_storm_cannot_starve_debounced_sampling_or_settle_rechecks() {
    let mut sparse_snapshot_timer = tokio::time::interval(std::time::Duration::from_secs(
        DAEMON_NETWORK_REFRESH_INTERVAL_SECS,
    ));
    sparse_snapshot_timer.tick().await;
    let mut event_deadline = PlatformNetworkSampleDeadline::default();
    let (tx, mut rx) = tokio::sync::mpsc::channel(1);
    let mut event_pending = false;
    let mut settle_rechecks_remaining = 0;

    tx.try_send(()).expect("initial platform event");
    tokio::select! {
        event = rx.recv(),
            if platform_network_event_receive_enabled(
                event_pending,
                settle_rechecks_remaining,
                &event_deadline,
            ) => {
            assert_eq!(event, Some(()));
            event_pending = true;
            schedule_platform_network_event_sampling(
                &mut event_deadline,
                &mut settle_rechecks_remaining,
            );
        }
        _ = sparse_snapshot_timer.tick() => {
            panic!("sparse timer fired before the platform event");
        }
    }

    for _ in 0..100 {
        let _ = tx.try_send(());
    }
    assert!(
        !platform_network_event_receive_enabled(
            event_pending,
            settle_rechecks_remaining,
            &event_deadline,
        ),
        "an event storm must not compete with its already-scheduled sample"
    );
    tokio::time::advance(std::time::Duration::from_millis(
        DAEMON_NETWORK_EVENT_DEBOUNCE_MILLIS - 1,
    ))
    .await;
    assert!(
        futures_util::FutureExt::now_or_never(next_daemon_network_trigger(
            &mut event_deadline,
            &mut sparse_snapshot_timer,
        ))
        .is_none(),
        "the event-driven sample fired before the debounce elapsed"
    );
    tokio::time::advance(std::time::Duration::from_millis(1)).await;
    assert_eq!(
        futures_util::FutureExt::now_or_never(next_daemon_network_trigger(
            &mut event_deadline,
            &mut sparse_snapshot_timer,
        )),
        Some(DaemonNetworkTrigger::EventDeadline),
        "queued platform events starved the debounced sample"
    );

    while rx.try_recv().is_ok() {}
    event_pending = false;
    assert!(schedule_platform_network_settle_recheck(
        &mut event_deadline,
        &mut settle_rechecks_remaining,
    ));
    for _ in 0..100 {
        let _ = tx.try_send(());
    }
    assert!(
        !platform_network_event_receive_enabled(
            event_pending,
            settle_rechecks_remaining,
            &event_deadline,
        ),
        "queued events must remain coalesced throughout the settle window"
    );
    tokio::time::advance(std::time::Duration::from_millis(
        DAEMON_NETWORK_SETTLE_RECHECK_MILLIS,
    ))
    .await;
    assert_eq!(
        futures_util::FutureExt::now_or_never(next_daemon_network_trigger(
            &mut event_deadline,
            &mut sparse_snapshot_timer,
        )),
        Some(DaemonNetworkTrigger::EventDeadline),
        "queued platform events starved a settle recheck"
    );
}

#[tokio::test(start_paused = true)]
async fn final_settle_deadline_owns_and_drains_queued_event_storm() {
    let mut sparse_snapshot_timer = tokio::time::interval(std::time::Duration::from_secs(
        DAEMON_NETWORK_REFRESH_INTERVAL_SECS,
    ));
    sparse_snapshot_timer.tick().await;
    let mut event_deadline = PlatformNetworkSampleDeadline::default();
    let mut settle_rechecks_remaining = 1;
    let (tx, rx) = tokio::sync::mpsc::channel(1);

    assert!(schedule_platform_network_settle_recheck(
        &mut event_deadline,
        &mut settle_rechecks_remaining,
    ));
    assert_eq!(
        settle_rechecks_remaining, 0,
        "fixture did not arm the final settle deadline"
    );
    tx.try_send(()).expect("queue final-boundary event");
    assert!(
        !platform_network_event_receive_enabled(false, settle_rechecks_remaining, &event_deadline,),
        "the higher-priority event branch re-enabled before the final deadline was consumed"
    );

    tokio::time::advance(std::time::Duration::from_millis(
        DAEMON_NETWORK_SETTLE_RECHECK_MILLIS,
    ))
    .await;
    let trigger =
        next_daemon_network_trigger(&mut event_deadline, &mut sparse_snapshot_timer).await;
    assert_eq!(trigger, DaemonNetworkTrigger::EventDeadline);
    assert!(
        daemon_network_trigger_is_event_driven(trigger, false),
        "the final settle trigger lost event ownership when remaining reached zero"
    );
    let mut rx = Some(rx);
    drain_platform_network_changes_for_sample(
        &mut rx,
        daemon_network_trigger_is_event_driven(trigger, false),
    );
    assert!(
        rx.as_mut().is_some_and(|rx| rx.try_recv().is_err()),
        "the final event-owned sample did not coalesce its queued duplicate storm"
    );
    assert!(
        platform_network_event_receive_enabled(false, settle_rechecks_remaining, &event_deadline),
        "fresh platform events did not re-enable after the final deadline was consumed"
    );
}

#[tokio::test(start_paused = true)]
async fn event_deadline_survives_select_cancellation_after_slow_maintenance() {
    let mut sparse_snapshot_timer = tokio::time::interval(std::time::Duration::from_secs(
        DAEMON_NETWORK_REFRESH_INTERVAL_SECS,
    ));
    sparse_snapshot_timer.tick().await;
    let mut event_deadline = PlatformNetworkSampleDeadline::default();
    let mut settle_rechecks_remaining = 0;
    let (tx, mut rx) = tokio::sync::mpsc::channel(1);
    let event_observed_at = tokio::time::Instant::now();

    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        tx.send(()).await.expect("queue platform event");
    });
    // Model an already-running maintenance future. The cap-1 platform channel
    // retains the event until the main loop returns.
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    assert_eq!(rx.try_recv(), Ok(()));
    schedule_platform_network_event_sampling(&mut event_deadline, &mut settle_rechecks_remaining);

    for _ in 0..32 {
        tokio::select! {
            biased;
            _ = tokio::task::yield_now() => {}
            trigger = next_daemon_network_trigger(
                &mut event_deadline,
                &mut sparse_snapshot_timer,
            ) => panic!("deadline fired early during cancellation test: {trigger:?}"),
        }
    }
    tokio::time::advance(std::time::Duration::from_millis(
        DAEMON_NETWORK_EVENT_DEBOUNCE_MILLIS - 1,
    ))
    .await;
    assert!(
        futures_util::FutureExt::now_or_never(next_daemon_network_trigger(
            &mut event_deadline,
            &mut sparse_snapshot_timer,
        ))
        .is_none(),
        "cancellation changed the absolute event deadline"
    );
    tokio::time::advance(std::time::Duration::from_millis(1)).await;
    assert_eq!(
        next_daemon_network_trigger(&mut event_deadline, &mut sparse_snapshot_timer).await,
        DaemonNetworkTrigger::EventDeadline
    );
    assert!(
        event_observed_at.elapsed() < std::time::Duration::from_secs(4),
        "queued event plus maintenance and debounce exceeded the recovery budget"
    );
}

#[tokio::test(start_paused = true)]
async fn ready_background_maintenance_cannot_preempt_active_network_deadline() {
    let mut sparse_snapshot_timer = tokio::time::interval(std::time::Duration::from_secs(
        DAEMON_NETWORK_REFRESH_INTERVAL_SECS,
    ));
    sparse_snapshot_timer.tick().await;
    let mut event_deadline = PlatformNetworkSampleDeadline::default();
    let mut settle_rechecks_remaining = 0;

    schedule_platform_network_event_sampling(&mut event_deadline, &mut settle_rechecks_remaining);
    assert!(
        !platform_network_background_maintenance_enabled(&event_deadline),
        "relay/FIPS maintenance must not start while outage recovery owns a sampling deadline"
    );
    tokio::time::advance(std::time::Duration::from_millis(
        DAEMON_NETWORK_EVENT_DEBOUNCE_MILLIS,
    ))
    .await;

    tokio::select! {
        biased;
        _ = std::future::ready(()),
            if platform_network_background_maintenance_enabled(&event_deadline) => {
            panic!("ready background maintenance preempted the outage-critical sample");
        }
        trigger = next_daemon_network_trigger(
            &mut event_deadline,
            &mut sparse_snapshot_timer,
        ) => assert_eq!(trigger, DaemonNetworkTrigger::EventDeadline),
    }
    assert!(
        platform_network_background_maintenance_enabled(&event_deadline),
        "background maintenance did not resume after the event deadline was consumed"
    );
}

#[tokio::test(start_paused = true)]
async fn ready_state_work_preserves_join_control_and_absolute_network_deadline() {
    let mut sparse_snapshot_timer = tokio::time::interval(std::time::Duration::from_secs(
        DAEMON_NETWORK_REFRESH_INTERVAL_SECS,
    ));
    sparse_snapshot_timer.tick().await;
    let mut event_deadline = PlatformNetworkSampleDeadline::default();
    let mut settle_rechecks_remaining = 0;
    let (join_tx, mut join_rx) = tokio::sync::mpsc::unbounded_channel();
    let (control_tx, mut control_rx) = tokio::sync::mpsc::unbounded_channel();
    let mut join_handled = false;
    let mut control_handled = false;
    let mut background_runs = 0;

    schedule_platform_network_event_sampling(&mut event_deadline, &mut settle_rechecks_remaining);
    join_tx.send(()).expect("queue join work");
    control_tx.send(()).expect("queue control work");

    // Mirror the daemon's biased order: local join IPC, the absolute network
    // deadline, then the one-second state tick. A ready state tick polls and
    // handles control, but skips every background operation while recovery
    // owns the deadline.
    for _ in 0..32 {
        tokio::select! {
            biased;
            Some(()) = join_rx.recv(), if !join_handled => join_handled = true,
            trigger = next_daemon_network_trigger(
                &mut event_deadline,
                &mut sparse_snapshot_timer,
            ) => panic!("network deadline fired before debounce elapsed: {trigger:?}"),
            _ = std::future::ready(()) => {
                let pending_control = control_rx.try_recv().ok();
                if daemon_state_background_maintenance_enabled(
                    &event_deadline,
                    pending_control.is_some(),
                ) {
                    background_runs += 1;
                }
                control_handled |= pending_control.is_some();
            }
        }
    }
    assert!(join_handled, "ready state work starved local join IPC");
    assert!(
        control_handled,
        "ready state work did not handle queued control"
    );
    assert_eq!(
        background_runs, 0,
        "state background work ran while the network deadline was active"
    );

    tokio::time::advance(std::time::Duration::from_millis(
        DAEMON_NETWORK_EVENT_DEBOUNCE_MILLIS,
    ))
    .await;
    tokio::select! {
        biased;
        trigger = next_daemon_network_trigger(
            &mut event_deadline,
            &mut sparse_snapshot_timer,
        ) => assert_eq!(trigger, DaemonNetworkTrigger::EventDeadline),
        _ = std::future::ready(()) => {
            panic!("ready state work preempted the absolute network deadline");
        }
    }
}

#[tokio::test(start_paused = true)]
async fn join_and_control_work_remain_selectable_throughout_unchanged_settle() {
    let mut sparse_snapshot_timer = tokio::time::interval(std::time::Duration::from_secs(
        DAEMON_NETWORK_REFRESH_INTERVAL_SECS,
    ));
    sparse_snapshot_timer.tick().await;
    let mut event_deadline = PlatformNetworkSampleDeadline::default();
    let mut settle_rechecks_remaining = 0;
    let (join_tx, mut join_rx) = tokio::sync::mpsc::unbounded_channel();
    let (control_tx, mut control_rx) = tokio::sync::mpsc::unbounded_channel();

    schedule_platform_network_event_sampling(&mut event_deadline, &mut settle_rechecks_remaining);
    tokio::time::advance(std::time::Duration::from_millis(
        DAEMON_NETWORK_EVENT_DEBOUNCE_MILLIS,
    ))
    .await;
    assert_eq!(
        next_daemon_network_trigger(&mut event_deadline, &mut sparse_snapshot_timer).await,
        DaemonNetworkTrigger::EventDeadline
    );

    for sequence in 0..DAEMON_NETWORK_SETTLE_RECHECK_ATTEMPTS {
        assert!(schedule_platform_network_settle_recheck(
            &mut event_deadline,
            &mut settle_rechecks_remaining,
        ));
        join_tx.send(sequence).expect("queue join work");
        tokio::select! {
            biased;
            Some(received) = join_rx.recv() => assert_eq!(received, sequence),
            trigger = next_daemon_network_trigger(
                &mut event_deadline,
                &mut sparse_snapshot_timer,
            ) => panic!("join work stalled behind settle sample: {trigger:?}"),
        }
        control_tx.send(sequence).expect("queue control work");
        tokio::select! {
            biased;
            Some(received) = control_rx.recv() => assert_eq!(received, sequence),
            trigger = next_daemon_network_trigger(
                &mut event_deadline,
                &mut sparse_snapshot_timer,
            ) => panic!("control work stalled behind settle sample: {trigger:?}"),
        }
        tokio::time::advance(std::time::Duration::from_millis(
            DAEMON_NETWORK_SETTLE_RECHECK_MILLIS,
        ))
        .await;
        assert_eq!(
            next_daemon_network_trigger(&mut event_deadline, &mut sparse_snapshot_timer).await,
            DaemonNetworkTrigger::EventDeadline
        );
    }
    assert_eq!(settle_rechecks_remaining, 0);
}

#[tokio::test(start_paused = true)]
async fn fips_control_maintenance_continues_between_unchanged_settle_samples() {
    let mut sparse_snapshot_timer = tokio::time::interval(std::time::Duration::from_secs(
        DAEMON_NETWORK_REFRESH_INTERVAL_SECS,
    ));
    sparse_snapshot_timer.tick().await;
    let mut event_deadline = PlatformNetworkSampleDeadline::default();
    let mut settle_rechecks_remaining = 0;

    schedule_platform_network_event_sampling(&mut event_deadline, &mut settle_rechecks_remaining);
    assert!(
        !platform_network_background_maintenance_enabled(&event_deadline),
        "the initial event debounce must remain exclusive"
    );
    tokio::time::advance(std::time::Duration::from_millis(
        DAEMON_NETWORK_EVENT_DEBOUNCE_MILLIS,
    ))
    .await;
    assert_eq!(
        next_daemon_network_trigger(&mut event_deadline, &mut sparse_snapshot_timer).await,
        DaemonNetworkTrigger::EventDeadline
    );

    let mut status_refreshes = 0;
    let mut heartbeat_runs = 0;
    let mut roster_retries = 0;
    for _ in 0..3 {
        assert!(schedule_platform_network_settle_recheck(
            &mut event_deadline,
            &mut settle_rechecks_remaining,
        ));
        assert!(
            platform_network_background_maintenance_enabled(&event_deadline),
            "an unchanged-route settle timer must not black out FIPS control maintenance"
        );

        tokio::select! {
            biased;
            _ = std::future::ready(()),
                if platform_network_background_maintenance_enabled(&event_deadline) => {
                status_refreshes += 1;
                heartbeat_runs += 1;
                roster_retries += 1;
            }
            trigger = next_daemon_network_trigger(
                &mut event_deadline,
                &mut sparse_snapshot_timer,
            ) => panic!("settle sample fired before its absolute deadline: {trigger:?}"),
        }

        tokio::time::advance(std::time::Duration::from_millis(
            DAEMON_NETWORK_SETTLE_RECHECK_MILLIS,
        ))
        .await;
        assert_eq!(
            next_daemon_network_trigger(&mut event_deadline, &mut sparse_snapshot_timer).await,
            DaemonNetworkTrigger::EventDeadline
        );
    }

    assert_eq!(status_refreshes, 3);
    assert_eq!(heartbeat_runs, 3);
    assert_eq!(roster_retries, 3);
}

#[test]
fn sparse_periodic_sample_does_not_discard_a_coincident_platform_event() {
    let (tx, rx) = tokio::sync::mpsc::channel(1);
    let mut rx = Some(rx);
    tx.try_send(()).expect("coincident platform event");

    drain_platform_network_changes_for_sample(&mut rx, false);
    assert_eq!(
        rx.as_mut().and_then(|rx| rx.try_recv().ok()),
        Some(()),
        "a sparse periodic tick must leave the coincident event queued for debounce and settle sampling"
    );

    tx.try_send(()).expect("event represented by active sample");
    drain_platform_network_changes_for_sample(&mut rx, true);
    assert!(
        rx.as_mut().is_some_and(|rx| rx.try_recv().is_err()),
        "an active event-driven sample should coalesce queued duplicate notifications"
    );
}
