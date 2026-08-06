use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

#[test]
fn paid_exit_run_and_status_cover_headless_seller_cli() {
    let dir = TestDir::new("nvpn-paid-exit-cli-seller");
    let config_path = dir.path().join("config.toml");

    let run = run_nvpn([
        "paid-exit",
        "run",
        "--config",
        config_path.to_str().expect("utf8 config path"),
        "--offer-id",
        "cli-fi",
        "--no-reload-daemon",
        "--price-msat-per-gb",
        "2500000",
        "--accepted-mint",
        "https://mint.example",
        "--country-code",
        "fi",
        "--free-probe-units",
        "1 MB",
        "--grace-units",
        "256 KB",
    ]);
    assert_success(&run);
    let stdout = output_stdout(&run);
    assert!(stdout.contains("paid_exit_seller: enabled"), "{stdout}");
    assert!(
        stdout.contains("price: 2500000 msat/GB · 2500 sat/GB"),
        "{stdout}"
    );
    assert!(stdout.contains("free_probe=1 MB"), "{stdout}");
    assert!(stdout.contains("grace=256 KB"), "{stdout}");

    let status = run_nvpn([
        "paid-exit",
        "status",
        "--config",
        config_path.to_str().expect("utf8 config path"),
        "--json",
    ]);
    assert_success(&status);
    let status_json = output_json(&status);
    assert_eq!(status_json["config"]["enabled"].as_bool(), Some(true));
    assert_eq!(
        status_json["config"]["price_msat_per_gb"].as_u64(),
        Some(2_500_000)
    );
    assert_eq!(
        status_json["config"]["price_text"].as_str(),
        Some("2500000 msat/GB · 2500 sat/GB")
    );
    assert_eq!(
        status_json["config"]["channel_expiry_text"].as_str(),
        Some("1 day")
    );
    assert_eq!(
        status_json["config"]["settlement_text"].as_str(),
        Some("Channels end after 1 day or when you manually collect")
    );
    assert_eq!(
        status_json["config"]["free_probe_units"].as_u64(),
        Some(1_048_576)
    );
    assert_eq!(
        status_json["config"]["free_probe_text"].as_str(),
        Some("1 MB")
    );
    assert_eq!(status_json["config"]["grace_units"].as_u64(), Some(262_144));
    assert_eq!(status_json["config"]["grace_text"].as_str(), Some("256 KB"));
    assert_eq!(status_json["config"]["country_code"].as_str(), Some("FI"));
    assert_eq!(status_json["config"]["region"].as_str(), Some(""));
    assert_eq!(
        status_json["config"]["network_class"].as_str(),
        Some("unknown")
    );
    assert_eq!(
        status_json["config"]["accepted_mints"][0].as_str(),
        Some("https://mint.example")
    );
    assert_eq!(status_json["counts"]["offers"].as_u64(), Some(1));
    assert_eq!(
        status_json["wallet"]["mints"].as_array().map(Vec::len),
        Some(1)
    );
    assert_eq!(
        status_json["seller_accounting"]["pending_buyer_credit_msat"].as_u64(),
        Some(0)
    );
    assert_eq!(
        status_json["seller_accounting"]["pending_buyer_credit_text"].as_str(),
        Some("0 sat")
    );

    let text_status = run_nvpn([
        "paid-exit",
        "status",
        "--config",
        config_path.to_str().expect("utf8 config path"),
    ]);
    assert_success(&text_status);
    let stdout = output_stdout(&text_status);
    assert!(
        stdout.contains(
            "paid_exit_settlement: Channels end after 1 day or when you manually collect"
        ),
        "{stdout}"
    );
    assert!(
        stdout.contains("paid_exit_pending_buyer_credit: 0 sat"),
        "{stdout}"
    );

    let collect_due = run_nvpn([
        "paid-exit",
        "collect-due",
        "--config",
        config_path.to_str().expect("utf8 config path"),
        "--json",
    ]);
    assert_success(&collect_due);
    let collect_due_json = output_json(&collect_due);
    assert_eq!(collect_due_json["due_count"].as_u64(), Some(0));
    assert_eq!(collect_due_json["collected_count"].as_u64(), Some(0));
    assert_eq!(collect_due_json["error_count"].as_u64(), Some(0));
    assert_eq!(collect_due_json["changed"].as_bool(), Some(false));
}

#[test]
fn set_paid_exit_uses_fixed_gigabyte_price_and_accepts_human_traffic_units() {
    let dir = TestDir::new("nvpn-paid-exit-cli-set-human-bytes");
    let config_path = dir.path().join("config.toml");
    let config = config_path.to_str().expect("utf8 config path");

    let set = run_nvpn([
        "set",
        "--config",
        config,
        "--paid-exit-enabled",
        "true",
        "--paid-exit-price-msat-per-gb",
        "1000",
        "--paid-exit-free-probe-units",
        "1 MB",
        "--paid-exit-grace-units",
        "256 KB",
    ]);
    assert_success(&set);

    let status = run_nvpn(["paid-exit", "status", "--config", config, "--json"]);
    assert_success(&status);
    let status_json = output_json(&status);
    assert_eq!(
        status_json["config"]["price_text"].as_str(),
        Some("1000 msat/GB · 1 sat/GB")
    );
    assert_eq!(
        status_json["config"]["free_probe_units"].as_u64(),
        Some(1_048_576)
    );
    assert_eq!(
        status_json["config"]["free_probe_text"].as_str(),
        Some("1 MB")
    );
    assert_eq!(status_json["config"]["grace_units"].as_u64(), Some(262_144));
    assert_eq!(status_json["config"]["grace_text"].as_str(), Some("256 KB"));
}

#[test]
fn paid_exit_offer_includes_spilman_receiver_key_after_seller_config() {
    let dir = TestDir::new("nvpn-paid-exit-cli-offer-receiver");
    let config_path = dir.path().join("config.toml");
    let config = config_path.to_str().expect("utf8 config path");

    let run = run_nvpn([
        "paid-exit",
        "run",
        "--config",
        config,
        "--offer-id",
        "cli-fi",
        "--no-reload-daemon",
        "--price-msat-per-gb",
        "2500000",
        "--accepted-mint",
        "https://mint.example",
    ]);
    assert_success(&run);

    let offer = run_nvpn([
        "paid-exit",
        "offer",
        "--config",
        config,
        "--offer-id",
        "cli-fi",
        "--json",
    ]);
    assert_success(&offer);
    let offer_json = output_json(&offer);
    let receiver = offer_json["offer"]["receiver_pubkey_hex"]
        .as_str()
        .expect("offer receiver pubkey");
    assert_eq!(receiver.len(), 66);
    assert!(matches!(&receiver[..2], "02" | "03"));

    let content: Value = serde_json::from_str(
        offer_json["event"]["content"]
            .as_str()
            .expect("event content"),
    )
    .expect("event content is offer JSON");
    assert_eq!(content["receiver_pubkey_hex"].as_str(), Some(receiver));

    let tags = offer_json["event"]["tags"].as_array().expect("event tags");
    assert!(
        tags.iter().any(|tag| {
            let Some(parts) = tag.as_array() else {
                return false;
            };
            parts.first().and_then(Value::as_str) == Some("receiver_pubkey")
                && parts.get(1).and_then(Value::as_str) == Some(receiver)
        }),
        "receiver_pubkey tag missing from offer event: {offer_json}"
    );

    let store_path = dir.path().join("paid-routes.json");
    std::fs::remove_file(&store_path).expect("remove offer snapshot");

    let offer = run_nvpn(["paid-exit", "offer", "--config", config, "--publish"]);
    assert!(
        !offer.status.success(),
        "config-only publish unexpectedly succeeded"
    );
    assert!(
        String::from_utf8_lossy(&offer.stderr).contains("daemon is not running"),
        "unexpected stderr: {}",
        String::from_utf8_lossy(&offer.stderr)
    );
    assert!(
        !store_path.exists(),
        "failed publish persisted a live offer"
    );

    let untouched_config = dir.path().join("untouched.toml");
    let run = run_nvpn([
        "paid-exit",
        "run",
        "--config",
        untouched_config.to_str().expect("utf8 config path"),
        "--publish",
        "--no-reload-daemon",
    ]);
    assert!(
        !run.status.success(),
        "no-reload publish unexpectedly succeeded"
    );
    assert!(String::from_utf8_lossy(&run.stderr).contains("--publish requires daemon reload"));
    assert!(!untouched_config.exists(), "invalid command mutated config");
}

#[test]
fn paid_exit_wallet_and_status_cover_mint_management_cli() {
    let dir = TestDir::new("nvpn-paid-exit-cli-wallet");
    let config_path = dir.path().join("config.toml");

    let add_primary = run_nvpn([
        "paid-exit",
        "wallet",
        "--config",
        config_path.to_str().expect("utf8 config path"),
        "--json",
        "add-mint",
        "https://mint.example",
        "--label",
        "Example",
        "--balance-msat",
        "2500",
        "--make-default",
    ]);
    assert_success(&add_primary);
    let add_primary_json = output_json(&add_primary);
    assert_eq!(add_primary_json["changed"].as_bool(), Some(true));
    assert_eq!(
        add_primary_json["wallet"]["default_mint"].as_str(),
        Some("https://mint.example")
    );
    assert_eq!(
        add_primary_json["wallet"]["mints"][0]["balance_msat"].as_u64(),
        Some(2_500)
    );

    let add_backup = run_nvpn([
        "paid-exit",
        "wallet",
        "--config",
        config_path.to_str().expect("utf8 config path"),
        "--json",
        "add-mint",
        "https://backup-mint.example",
        "--label",
        "Backup",
    ]);
    assert_success(&add_backup);

    let set_default = run_nvpn([
        "paid-exit",
        "wallet",
        "--config",
        config_path.to_str().expect("utf8 config path"),
        "--json",
        "set-default",
        "https://backup-mint.example",
    ]);
    assert_success(&set_default);
    let set_default_json = output_json(&set_default);
    assert_eq!(
        set_default_json["wallet"]["default_mint"].as_str(),
        Some("https://backup-mint.example")
    );

    let remove_primary = run_nvpn([
        "paid-exit",
        "wallet",
        "--config",
        config_path.to_str().expect("utf8 config path"),
        "--json",
        "remove-mint",
        "https://mint.example",
    ]);
    assert_success(&remove_primary);

    let status = run_nvpn([
        "paid-exit",
        "status",
        "--config",
        config_path.to_str().expect("utf8 config path"),
        "--json",
    ]);
    assert_success(&status);
    let status_json = output_json(&status);
    assert_eq!(
        status_json["wallet"]["default_mint"].as_str(),
        Some("https://backup-mint.example")
    );
    let mints = status_json["wallet"]["mints"]
        .as_array()
        .expect("wallet mints array");
    assert_eq!(mints.len(), 1);
    assert_eq!(
        mints[0]["url"].as_str(),
        Some("https://backup-mint.example")
    );
    assert_eq!(mints[0]["label"].as_str(), Some("Backup"));
}

#[test]
fn paid_exit_collect_requires_seller_mode() {
    let dir = TestDir::new("nvpn-paid-exit-cli-collect-disabled");
    let config_path = dir.path().join("config.toml");

    let collect = run_nvpn([
        "paid-exit",
        "collect",
        "--config",
        config_path.to_str().expect("utf8 config path"),
        "--json",
        "channel-1",
    ]);

    assert!(!collect.status.success(), "collect unexpectedly succeeded");
    let stderr = String::from_utf8_lossy(&collect.stderr);
    assert!(
        stderr.contains("paid exit selling is disabled"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn paid_exit_discover_accepts_the_shared_gui_command_contract() {
    let dir = TestDir::new("nvpn-paid-exit-cli-discover");
    let config_path = dir.path().join("config.toml");
    let ratings_path = dir.path().join("ratings.json");
    std::fs::write(&ratings_path, r#"{"ratings":[]}"#).expect("write ratings fixture");

    let discover = run_nvpn([
        "paid-exit",
        "discover",
        "--config",
        config_path.to_str().expect("utf8 config path"),
        "--json",
        "--fips-peer-ratings",
        ratings_path.to_str().expect("utf8 ratings path"),
        "--trusted-rating-author",
        "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
        "--rating-scope",
        "fips.peer.test",
    ]);

    assert_success(&discover);
    let json = output_json(&discover);
    assert_eq!(json["count"].as_u64(), Some(0));
    assert_eq!(json["ratings"]["scope"].as_str(), Some("fips.peer.test"));
}

fn run_nvpn<I, S>(args: I) -> Output
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    Command::new(env!("CARGO_BIN_EXE_nvpn"))
        .args(args)
        .output()
        .expect("run nvpn")
}

fn assert_success(output: &Output) {
    if output.status.success() {
        return;
    }

    panic!(
        "nvpn failed with status {}\nstdout:\n{}\nstderr:\n{}",
        output.status,
        output_stdout(output),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn output_stdout(output: &Output) -> String {
    String::from_utf8(output.stdout.clone()).expect("stdout is utf8")
}

fn output_json(output: &Output) -> Value {
    serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
        panic!(
            "stdout is not JSON: {error}\nstdout:\n{}\nstderr:\n{}",
            output_stdout(output),
            String::from_utf8_lossy(&output.stderr)
        )
    })
}

struct TestDir {
    path: PathBuf,
}

impl TestDir {
    fn new(prefix: &str) -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock is after epoch")
            .as_nanos();
        let path = std::env::temp_dir().join(format!("{prefix}-{}-{nonce}", std::process::id()));
        std::fs::create_dir_all(&path).expect("create test dir");
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}
