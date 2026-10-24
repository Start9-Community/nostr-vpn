use super::*;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

struct Fixture(PathBuf);

impl Drop for Fixture {
    fn drop(&mut self) {
        // Release only this fixture's CLI calls, including after an assertion fails.
        let _ = fs::remove_file(self.0.join("block-status"));
        let _ = fs::remove_file(self.0.join("block-install-cli"));
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn pump_until(context: &glib::MainContext, ready: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(3);
    while !ready() {
        assert!(Instant::now() < deadline, "background CLI did not progress");
        context.iteration(false);
        std::thread::sleep(Duration::from_millis(1));
    }
}

#[test]
fn blocked_cli_keeps_main_context_responsive_and_results_in_order() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let fixture = Fixture(
        std::env::temp_dir().join(format!("nvpn-gtk-worker-{}-{nonce}", std::process::id())),
    );
    fs::create_dir(&fixture.0).unwrap();
    let cli = fixture.0.join("nvpn");
    fs::write(
        &cli,
        r#"#!/bin/sh
dir=$(dirname "$0")
case "$1" in
  status|install-cli)
    if [ -f "$dir/block-$1" ]; then
      : > "$dir/started-$1"
      attempt=0
      while [ -f "$dir/block-$1" ]; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 600 ] || exit 7
        sleep 0.01
      done
    fi
    ;;
esac
case "$1" in
  status) echo '{"daemon":{"running":false,"state":null}}' ;;
  service) echo '{"supported":false,"installed":false,"loaded":false,"running":false,"pid":null}' ;;
  version) echo '{"version":"test"}' ;;
esac
exit 0
"#,
    )
    .unwrap();
    fs::set_permissions(&cli, fs::Permissions::from_mode(0o755)).unwrap();
    let config_path = fixture.0.join("config.toml");
    let mut config = nostr_vpn_core::config::AppConfig::generated_without_networks();
    config.node.endpoint = "198.51.100.10:51820".to_string();
    config.wallet_fiat_enabled = false;
    config.save(&config_path).unwrap();
    let context = glib::MainContext::new();
    let _guard = context.acquire().unwrap();
    let ticks = Arc::new(AtomicUsize::new(0));
    let timer_ticks = ticks.clone();
    let timer = glib::timeout_source_new(
        Duration::from_millis(10),
        None,
        glib::Priority::DEFAULT,
        move || {
            timer_ticks.fetch_add(1, Ordering::SeqCst);
            glib::ControlFlow::Continue
        },
    );
    timer.attach(Some(&context));

    // Block the real FFI constructor's first status call, before any explicit
    // refresh/action. The window's main context must already be free to run.
    let startup_block = fixture.0.join("block-status");
    let startup_started = fixture.0.join("started-status");
    fs::write(&startup_block, "").unwrap();
    let before_start = Instant::now();
    let (requests, results) = start_core_worker(move || {
        FfiApp::new_with_config_path(config_path, "test".to_string(), Some(cli))
    });
    assert!(
        before_start.elapsed() < Duration::from_secs(1),
        "backend construction blocked the main thread"
    );
    pump_until(&context, || startup_started.exists());
    let initial_ticks = ticks.load(Ordering::SeqCst);
    pump_until(&context, || {
        ticks.load(Ordering::SeqCst) >= initial_ticks + 3
    });
    assert!(matches!(results.try_recv(), Err(mpsc::TryRecvError::Empty)));
    fs::remove_file(startup_block).unwrap();
    let initial = results.recv_timeout(Duration::from_secs(3)).unwrap();
    assert!(!initial.is_action);
    assert!(initial.state.error.is_empty(), "{}", initial.state.error);

    for is_action in [false, true] {
        let command = if is_action { "install-cli" } else { "status" };
        let block = fixture.0.join(format!("block-{command}"));
        let started = fixture.0.join(format!("started-{command}"));
        if started.exists() {
            fs::remove_file(&started).unwrap();
        }
        fs::write(&block, "").unwrap();
        requests
            .send(is_action.then_some(NativeAppAction::InstallCli))
            .unwrap();
        pump_until(&context, || started.exists());
        // Queue another real FFI call while the first is inside its CLI process.
        requests
            .send((!is_action).then_some(NativeAppAction::GetState))
            .unwrap();
        let initial_ticks = ticks.load(Ordering::SeqCst);
        pump_until(&context, || {
            ticks.load(Ordering::SeqCst) >= initial_ticks + 3
        });
        assert!(matches!(results.try_recv(), Err(mpsc::TryRecvError::Empty)));
        fs::remove_file(block).unwrap();

        for expected_action in [is_action, !is_action] {
            let result = RefCell::new(None);
            pump_until(&context, || {
                if let Ok(value) = results.try_recv() {
                    *result.borrow_mut() = Some(value);
                    true
                } else {
                    false
                }
            });
            let result = result.into_inner().unwrap();
            assert_eq!(result.is_action, expected_action);
            assert!(result.state.error.is_empty(), "{}", result.state.error);
        }
    }
    timer.destroy();
    drop(requests);
    assert!(matches!(
        results.recv_timeout(Duration::from_secs(1)),
        Err(mpsc::RecvTimeoutError::Disconnected)
    ));
}
