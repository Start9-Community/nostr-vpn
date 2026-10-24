#![cfg(feature = "updater")]

use nostr_vpn_core::config::AppConfig;
use nostr_vpn_core::updater::{
    ProductUpdateMode, ProductUpdateSource, check_product_update_blocking_with_config,
};

#[test]
fn update_check_can_start_fips_from_a_swift_sized_stack() {
    // Isolate a stack overflow so it reports a failed regression test instead
    // of aborting the remaining integration tests.
    const CHILD: &str = "NVPN_TEST_UPDATER_SMALL_STACK";
    if std::env::var_os(CHILD).is_none() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "update_check_can_start_fips_from_a_swift_sized_stack",
                "--nocapture",
            ])
            .env(CHILD, "1")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "update check crashed on a small calling stack: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    let dir = std::env::temp_dir().join(format!("nvpn-update-stack-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("config.toml");
    let mut app = AppConfig::generated_without_networks();
    app.fips_bootstrap_enabled = false;
    app.save(&path).unwrap();
    std::thread::Builder::new()
        .stack_size(512 * 1024)
        .spawn(move || {
            // The network result may be unavailable. The regression is FIPS
            // initialization overflowing the caller before a result returns.
            let result = check_product_update_blocking_with_config(
                "9999.0.0",
                ProductUpdateMode::App,
                ProductUpdateSource::Hashtree,
                Some(&path),
            );
            if let Err(error) = result {
                assert!(
                    error
                        .to_string()
                        .contains("failed to resolve a fresh signed hashtree release"),
                    "update check failed before reaching release lookup: {error:#}"
                );
            }
        })
        .unwrap()
        .join()
        .unwrap();
    std::fs::remove_dir_all(dir).unwrap();
}
