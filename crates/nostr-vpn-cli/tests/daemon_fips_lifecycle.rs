#![cfg(target_os = "linux")]

use std::fs;
use std::net::UdpSocket;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use nostr_vpn_core::config::AppConfig;

// Run in an isolated Linux network namespace with /dev/net/tun and NET_ADMIN.
#[test]
#[ignore = "requires an isolated Linux container with NET_ADMIN and /dev/net/tun"]
fn pause_closes_fips_and_passive_join_links_cannot_restart_it() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("nvpn-fips-lifecycle-{nonce}"));
    fs::create_dir(&dir).unwrap();
    let config = dir.join("config.toml");
    let mut app = AppConfig::generated_without_networks();
    app.autoconnect = false;
    app.lan_discovery_enabled = false;
    app.fips_nostr_discovery_enabled = false;
    app.fips_webrtc_enabled = false;
    app.fips_bootstrap_enabled = false;
    app.fips_bootstrap_peers.clear();
    app.fips_websocket_seed_urls.clear();
    app.node.listen_port = 51829;
    fs::write(&config, app.plaintext_toml().unwrap()).unwrap();
    let bin = std::env::var("NVPN_TEST_BIN").unwrap_or_else(|_| env!("CARGO_BIN_EXE_nvpn").into());
    let log = fs::File::create(dir.join("daemon.log")).unwrap();
    let daemon = Command::new(&bin)
        .args(["daemon", "--paused", "--iface", "nvpnlife0", "--config"])
        .arg(&config)
        .stdout(log.try_clone().unwrap())
        .stderr(log)
        .spawn()
        .unwrap();
    let mut fixture = Fixture {
        dir,
        config,
        bin,
        daemon,
    };
    fixture.wait("paused startup", |f| f.is_off());
    // The initial state file precedes the control and join-request listeners.
    fixture.run(&["reload"]);

    for _ in 0..2 {
        fixture.run(&["status", "--json", "--include-join-request"]);
        fixture.run(&["join-request", "--no-wait", "--no-qr"]);
    }
    fixture.run(&["reload"]);
    sleep(Duration::from_secs(5)); // Includes multiple maintenance heartbeats.
    assert!(
        fixture.is_off(),
        "metadata reads and reload must remain offline"
    );

    for _ in 0..2 {
        fixture.run(&["resume"]);
        fixture.wait("resume starts FIPS", |f| f.is_on());
        fixture.run(&["pause"]);
        fixture.wait("pause closes FIPS and tunnel", |f| f.is_off());
    }

    let mut join = Command::new(&fixture.bin)
        .args(["join-request", "--no-qr", "--config"])
        .arg(&fixture.config)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    fixture.wait("explicit join starts FIPS", |f| f.is_on());
    assert!(
        Command::new("kill")
            .args(["-INT", &join.id().to_string()])
            .status()
            .unwrap()
            .success()
    );
    fixture.wait("cancelled join exits", |_| {
        join.try_wait().unwrap().is_some()
    });
    fixture.wait("cancelled join restores VPN off", |f| f.is_off());
    assert!(!AppConfig::load(&fixture.config).unwrap().autoconnect);

    // An explicit seed listener owns networking independently of the VPN switch.
    let mut app = AppConfig::load(&fixture.config).unwrap();
    app.fips_websocket_bind_addr = "127.0.0.1:18765".into();
    app.save(&fixture.config).unwrap();
    fixture.run(&["reload"]);
    fixture.wait("paused seed stays online", |f| {
        let state = f.state();
        state["vpn_enabled"] == false
            && f.has_fips_socket()
            && state["vpn_status"] == "VPN paused; FIPS server active"
    });
    fixture.run(&["pause"]);
    sleep(Duration::from_secs(3));
    assert!(fixture.has_fips_socket());
    let mut app = AppConfig::load(&fixture.config).unwrap();
    app.fips_websocket_bind_addr.clear();
    app.save(&fixture.config).unwrap();
    fixture.run(&["reload"]);
    fixture.wait("removing server role stops FIPS", |f| f.is_off());
}

struct Fixture {
    dir: PathBuf,
    config: PathBuf,
    bin: String,
    daemon: Child,
}

impl Fixture {
    fn run(&self, args: &[&str]) -> String {
        let output = Command::new(&self.bin)
            .args(args)
            .arg("--config")
            .arg(&self.config)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    }

    fn state(&self) -> serde_json::Value {
        fs::read(self.dir.join("daemon.state.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn has_fips_socket(&self) -> bool {
        UdpSocket::bind("0.0.0.0:51829").is_err()
    }

    fn is_off(&self) -> bool {
        let state = self.state();
        state["vpn_enabled"] == false
            && state["vpn_status"] == "Paused"
            && state["fips_other_peer_count"] == 0
            && state["fips_direct_roster_peer_count"] == 0
            && !self.has_fips_socket()
            && !std::path::Path::new("/sys/class/net/nvpnlife0").exists()
    }

    fn is_on(&self) -> bool {
        self.state()["vpn_enabled"] == true
            && self.has_fips_socket()
            && std::path::Path::new("/sys/class/net/nvpnlife0").exists()
    }

    fn wait(&mut self, step: &str, mut ready: impl FnMut(&Self) -> bool) {
        let deadline = Instant::now() + Duration::from_secs(30);
        while !ready(self) {
            assert!(
                self.daemon.try_wait().unwrap().is_none(),
                "daemon exited during {step}"
            );
            assert!(
                Instant::now() < deadline,
                "timed out: {step}; state: {}",
                self.state()
            );
            sleep(Duration::from_millis(100));
        }
        eprintln!("{step}: ready");
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.daemon.kill();
        let _ = self.daemon.wait();
        if std::thread::panicking() {
            eprintln!(
                "{}",
                fs::read_to_string(self.dir.join("daemon.log")).unwrap_or_default()
            );
        }
        let _ = AppConfig::delete_persisted_secrets_for_path(&self.config);
        let _ = fs::remove_dir_all(&self.dir);
    }
}
