#![cfg(target_os = "linux")]

use std::fs;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream, UdpSocket};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};

use nostr_vpn_core::config::{AppConfig, InternetSource};
use socket2::{Domain, Protocol, Socket, Type};

// Invoke through scripts/test-linux-egress-lifecycle, which isolates networking,
// /run, /var/lib, /tmp and secrets. Never run against the host's network policy.
#[test]
#[ignore = "requires the isolated root namespace runner and Linux WireGuard"]
fn daemon_exit_intent_survives_restart_and_tunnel_loss() {
    assert_eq!(std::env::var("NVPN_EGRESS_ISOLATED").as_deref(), Ok("1"));
    let links = fs::read_dir("/sys/class/net")
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect::<Vec<_>>();
    assert_eq!(
        links,
        vec![std::ffi::OsString::from("lo")],
        "requires an empty network namespace"
    );
    assert!(std::path::Path::new("/var/lib/nvpn-egress-fixture").exists());
    let dir = std::env::temp_dir().join("nvpn-egress-lifecycle");
    fs::create_dir(&dir).unwrap();
    let bin = std::env::var("NVPN_TEST_BIN").unwrap_or_else(|_| env!("CARGO_BIN_EXE_nvpn").into());
    let mut f = Fixture {
        config: dir.join("config.toml"),
        dir,
        bin,
        daemon: None,
        server: None,
    };
    f.network();
    f.packets(None, Some("192.0.2.1"));
    let mut app = AppConfig::generated_without_networks();
    app.set_internet_source(InternetSource::PaidAutomatic);
    app.exit_node_leak_protection = true;
    app.lan_discovery_enabled = false;
    app.fips_nostr_discovery_enabled = false;
    app.fips_webrtc_enabled = false;
    app.fips_bootstrap_enabled = false;
    app.fips_bootstrap_peers.clear();
    app.fips_websocket_seed_urls.clear();
    app.nostr.relays.clear();
    app.nat.stun_servers.clear();
    app.node.listen_port = 51829;
    fs::write(&f.config, app.plaintext_toml().unwrap()).unwrap();
    f.start();
    f.wait("pending exit starts protected", |f| {
        f.guard_present() && f.state()["vpn_enabled"] == true
    });
    f.control("reload"); // Establish that startup reached the control listener.
    f.packets(None, None);
    f.packets(Some(20054), Some("192.0.2.1"));
    f.control("pause");
    f.wait("explicit pause releases protection", |f| {
        !f.guard_present() && f.state()["vpn_enabled"] == false
    });
    f.packets(None, Some("192.0.2.1"));
    f.control("resume");
    f.wait("resume restores pending protection", |f| {
        f.guard_present() && f.state()["vpn_enabled"] == true
    });
    f.packets(None, None);
    f.crash();
    f.packets(None, None);

    // Simulate the empty kernel state at boot while the user's config is absent.
    let unavailable = f.dir.join("unavailable.toml");
    fs::rename(&f.config, &unavailable).unwrap();
    run("nft", &["delete", "table", "inet", "nvpn_egress"]);
    for priority in ["101", "103"] {
        run("ip", &["-4", "rule", "del", "pref", priority]);
    }
    while Command::new("ip")
        .args(["-4", "rule", "del", "pref", "102"])
        .stderr(Stdio::null())
        .status()
        .unwrap()
        .success()
    {}
    for family in ["-4", "-6"] {
        for priority in ["98", "100", "105", "106", "110"] {
            run("ip", &[family, "rule", "del", "pref", priority]);
        }
        run("ip", &[family, "route", "flush", "table", "20054"]);
    }
    f.packets(None, Some("192.0.2.1"));
    f.control("egress-guard");
    f.packets(None, None);
    f.packets(Some(20054), Some("192.0.2.1"));
    let failed = Command::new(&f.bin)
        .args(["daemon", "--config"])
        .arg(&f.config)
        .output()
        .unwrap();
    assert!(
        !failed.status.success(),
        "missing config must not discard saved intent"
    );
    f.packets(None, None);
    fs::rename(&unavailable, &f.config).unwrap();
    f.start();
    f.wait("restart remains protected", |f| {
        f.guard_present() && f.state()["vpn_enabled"] == true
    });
    f.control("reload");

    let mut app = AppConfig::load(&f.config).unwrap();
    app.set_internet_source(InternetSource::WireGuard);
    app.wireguard_exit.interface = "nvwgproof".into();
    app.wireguard_exit.address = "10.77.0.2/32".into();
    app.wireguard_exit.private_key = run("wg", &["genkey"]).trim().into();
    let local_public = public_key(&app.wireguard_exit.private_key);
    let remote_private = run("wg", &["genkey"]);
    app.wireguard_exit.peer_public_key = public_key(&remote_private);
    app.wireguard_exit.endpoint = "192.0.2.2:51820".into();
    app.wireguard_exit.persistent_keepalive_secs = 1;
    app.wireguard_exit.dns.clear();
    run(
        "ip",
        &[
            "netns",
            "exec",
            "egress-peer",
            "ip",
            "link",
            "add",
            "wgpeer",
            "type",
            "wireguard",
        ],
    );
    let remote_config = format!(
        "[Interface]\nPrivateKey = {}\nListenPort = 51820\n[Peer]\nPublicKey = {local_public}\nAllowedIPs = 10.77.0.2/32\n",
        remote_private.trim()
    );
    let mut configure = Command::new("ip")
        .args([
            "netns",
            "exec",
            "egress-peer",
            "wg",
            "setconf",
            "wgpeer",
            "/dev/stdin",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    configure
        .stdin
        .take()
        .unwrap()
        .write_all(remote_config.as_bytes())
        .unwrap();
    let configured = configure.wait_with_output().unwrap();
    assert!(
        configured.status.success(),
        "local WireGuard peer setup: {}",
        String::from_utf8_lossy(&configured.stderr)
    );
    run(
        "ip",
        &[
            "netns",
            "exec",
            "egress-peer",
            "ip",
            "address",
            "add",
            "10.77.0.1/24",
            "dev",
            "wgpeer",
        ],
    );
    run(
        "ip",
        &[
            "netns",
            "exec",
            "egress-peer",
            "ip",
            "link",
            "set",
            "wgpeer",
            "up",
        ],
    );
    let defaults = run("ip", &["-4", "route", "show", "default"]);
    app.save(&f.config).unwrap();
    f.control("reload");
    f.wait("kernel WireGuard carries application packets", |_| {
        packet(false, None).as_deref().ok() == Some("10.77.0.2")
    });
    f.packets(None, Some("10.77.0.2"));
    f.packets(Some(20054), Some("192.0.2.1"));
    assert_eq!(run("ip", &["-4", "route", "show", "default"]), defaults);
    assert_eq!(run("wg", &["show", "nvwgproof", "fwmark"]).trim(), "0x4e56");
    let firewall = run("nft", &["-a", "-s", "list", "table", "inet", "nvpn_egress"]);
    sleep(Duration::from_secs(6));
    f.packets(None, Some("10.77.0.2"));
    assert_eq!(
        run("nft", &["-a", "-s", "list", "table", "inet", "nvpn_egress"]),
        firewall,
        "healthy traffic must not cause policy rewrites"
    );
    run(
        "ip",
        &[
            "-4",
            "route",
            "del",
            "default",
            "dev",
            "nvwgproof",
            "table",
            "20054",
            "metric",
            "100",
        ],
    );
    f.wait("withdrawn tunnel route is repaired", |_| {
        packet(false, None).as_deref().ok() == Some("10.77.0.2")
    });
    run("nft", &["delete", "table", "inet", "nvpn_egress"]);
    f.wait("firewall reload restores previously owned policy", |f| {
        f.guard_present()
    });
    f.packets(None, Some("10.77.0.2"));
    f.packets(Some(20054), Some("192.0.2.1"));
    // Freeze only the fixture daemon, then remove its tunnel. No repair race can
    // obscure whether the existing kernel policy leaks while the daemon is down.
    run(
        "kill",
        &["-STOP", &f.daemon.as_ref().unwrap().id().to_string()],
    );
    run("ip", &["link", "del", "nvwgproof"]);
    f.packets(None, None);
    f.packets(Some(20054), Some("192.0.2.1"));
    run(
        "kill",
        &["-CONT", &f.daemon.as_ref().unwrap().id().to_string()],
    );
    f.control("stop");
    f.wait_stopped();
    f.packets(None, None);
    let mut app = AppConfig::load(&f.config).unwrap();
    app.set_internet_source(InternetSource::Direct);
    app.save(&f.config).unwrap();
    f.start();
    f.wait("explicit Direct releases durable policy", |f| {
        !f.guard_present() && f.state()["vpn_enabled"] == true
    });
    f.control("reload");
    f.packets(None, Some("192.0.2.1"));
    f.control("stop");
    f.wait_stopped();
    eprintln!(
        "PASS daemon restart, boot without config, pause/resume, kernel WireGuard, tunnel loss, stop, explicit Direct"
    );
}

struct Fixture {
    dir: PathBuf,
    config: PathBuf,
    bin: String,
    daemon: Option<Child>,
    server: Option<Child>,
}
impl Fixture {
    fn network(&mut self) {
        run("ip", &["link", "set", "lo", "up"]);
        run("ip", &["netns", "add", "egress-peer"]);
        run(
            "ip",
            &[
                "link", "add", "physical", "type", "veth", "peer", "name", "remote",
            ],
        );
        run("ip", &["link", "set", "remote", "netns", "egress-peer"]);
        run("ip", &["address", "add", "192.0.2.1/24", "dev", "physical"]);
        run("ip", &["link", "set", "physical", "up"]);
        for args in [
            vec!["link", "set", "lo", "up"],
            vec!["link", "set", "remote", "up"],
            vec!["address", "add", "192.0.2.2/24", "dev", "remote"],
            vec!["address", "add", "198.51.100.10/32", "dev", "lo"],
        ] {
            let mut command = vec!["netns", "exec", "egress-peer", "ip"];
            command.extend(args);
            run("ip", &command);
        }
        run("ip", &["route", "add", "default", "via", "192.0.2.2"]);
        let ready = self.dir.join("receiver.ready");
        self.server = Some(
            Command::new("ip")
                .args([
                    "netns",
                    "exec",
                    "egress-peer",
                    "python3",
                    "-u",
                    "-c",
                    RECEIVER,
                ])
                .arg(&ready)
                .stdout(Stdio::null())
                .stderr(Stdio::inherit())
                .spawn()
                .unwrap(),
        );
        let until = Instant::now() + Duration::from_secs(5);
        while !ready.exists() {
            assert!(Instant::now() < until, "receiver startup");
            sleep(Duration::from_millis(20));
        }
    }
    fn start(&mut self) {
        assert!(self.daemon.is_none());
        let log = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.dir.join("daemon.log"))
            .unwrap();
        self.daemon = Some(
            Command::new(&self.bin)
                .args(["daemon", "--iface", "nvpnproof", "--config"])
                .arg(&self.config)
                .stdout(log.try_clone().unwrap())
                .stderr(log)
                .spawn()
                .unwrap(),
        );
    }
    fn crash(&mut self) {
        let mut child = self.daemon.take().unwrap();
        child.kill().unwrap();
        child.wait().unwrap();
    }
    fn control(&self, action: &str) {
        let output = Command::new(&self.bin)
            .args([action, "--config"])
            .arg(&self.config)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{action}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    fn state(&self) -> serde_json::Value {
        fs::read(self.dir.join("daemon.state.json"))
            .ok()
            .and_then(|v| serde_json::from_slice(&v).ok())
            .unwrap_or_default()
    }
    fn guard_present(&self) -> bool {
        Command::new("nft")
            .args(["list", "table", "inet", "nvpn_egress"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success()
    }
    fn wait(&mut self, step: &str, mut ready: impl FnMut(&Self) -> bool) {
        let until = Instant::now() + Duration::from_secs(35);
        while !ready(self) {
            assert!(
                self.daemon.as_mut().unwrap().try_wait().unwrap().is_none(),
                "daemon exited: {step}"
            );
            assert!(
                Instant::now() < until,
                "timed out: {step}; {}",
                self.state()
            );
            sleep(Duration::from_millis(100));
        }
        eprintln!("PASS {step}");
    }
    fn wait_stopped(&mut self) {
        let until = Instant::now() + Duration::from_secs(10);
        let child = self.daemon.as_mut().unwrap();
        while child.try_wait().unwrap().is_none() {
            assert!(Instant::now() < until, "daemon stop");
            sleep(Duration::from_millis(100));
        }
        self.daemon = None;
    }
    fn packets(&self, mark: Option<u32>, expected: Option<&str>) {
        for udp in [false, true] {
            let result = packet(udp, mark);
            match expected {
                Some(source) => assert_eq!(
                    result.as_deref().ok(),
                    Some(source),
                    "udp={udp} mark={mark:?}: {result:?}"
                ),
                None => assert!(
                    result.is_err(),
                    "leaked packet: udp={udp} mark={mark:?}: {result:?}"
                ),
            }
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(mut child) = self.daemon.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        if let Some(mut child) = self.server.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        if std::thread::panicking() {
            eprintln!("rules: {}", run("ip", &["-j", "-N", "-4", "rule", "show"]));
            eprintln!(
                "routes: {}",
                run("ip", &["-4", "route", "show", "table", "all"])
            );
            for name in ["all", "physical"] {
                eprintln!(
                    "rp_filter {name}: {}",
                    fs::read_to_string(format!("/proc/sys/net/ipv4/conf/{name}/rp_filter"))
                        .unwrap_or_default()
                );
            }
            eprintln!(
                "{}",
                fs::read_to_string(self.dir.join("daemon.log")).unwrap_or_default()
            );
        }
        // The runner discards the entire fixture filesystem and network namespace.
    }
}
fn run(program: &str, args: &[&str]) -> String {
    let output = Command::new(program).args(args).output().unwrap();
    assert!(
        output.status.success(),
        "{program}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap()
}
fn public_key(private: &str) -> String {
    let mut child = Command::new("wg")
        .arg("pubkey")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(private.as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    String::from_utf8(output.stdout).unwrap().trim().into()
}
fn packet(udp: bool, mark: Option<u32>) -> std::io::Result<String> {
    let socket = Socket::new(
        Domain::IPV4,
        if udp { Type::DGRAM } else { Type::STREAM },
        Some(if udp { Protocol::UDP } else { Protocol::TCP }),
    )?;
    if let Some(mark) = mark {
        socket.set_mark(mark)?;
    }
    let timeout = Duration::from_millis(350);
    socket.set_read_timeout(Some(timeout))?;
    socket.set_write_timeout(Some(timeout))?;
    let target: SocketAddr = "198.51.100.10:19090".parse().unwrap();
    let mut buffer = [0; 64];
    let length = if udp {
        let socket: UdpSocket = socket.into();
        socket.send_to(b"probe", target)?;
        socket.recv(&mut buffer)?
    } else {
        socket.connect_timeout(&target.into(), timeout)?;
        let mut stream: TcpStream = socket.into();
        stream.read(&mut buffer)?
    };
    Ok(String::from_utf8_lossy(&buffer[..length]).trim().into())
}
const RECEIVER: &str = r#"
import socket, select, sys
udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
tcp=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
for s in (udp,tcp): s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('198.51.100.10',19090))
tcp.listen()
open(sys.argv[1],'w').close()
while True:
 for s in select.select([udp,tcp],[],[])[0]:
  if s is udp:
   _,peer=udp.recvfrom(1024); udp.sendto(peer[0].encode(),peer)
  else:
   conn,peer=tcp.accept(); conn.sendall(peer[0].encode()); conn.close()
"#;
