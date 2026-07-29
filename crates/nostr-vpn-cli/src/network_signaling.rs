use std::path::Path;

use anyhow::{Context, Result, anyhow};
use nostr_vpn_core::config::{maybe_autoconfigure_node, normalize_nostr_pubkey};
use nostr_vpn_core::join_delivery::queue_join_roster;
use nostr_vpn_core::join_requests::prepare_manual_join_delivery;
use serde_json::json;

use super::{
    DaemonControlRequest, UpdateRosterArgs, clear_daemon_control_result, daemon_status,
    default_config_path, load_or_default_config, request_daemon_reload,
    wait_for_daemon_control_ack, wait_for_daemon_control_result,
};

pub(crate) fn reload_running_daemon_after_save(config_path: &Path) -> Result<()> {
    let status = daemon_status(config_path)
        .context("failed to inspect daemon status after saving configuration")?;
    if !status.running {
        return Ok(());
    }
    crate::wait_for_running_daemon_control_ready(config_path, &status)
        .context("daemon did not become ready after saving configuration")?;
    clear_daemon_control_result(config_path);
    request_daemon_reload(config_path)
        .context("failed to request daemon reload after saving configuration")?;
    wait_for_daemon_control_ack(
        config_path,
        crate::daemon_control_ack_timeout(DaemonControlRequest::Reload),
    )
    .context("daemon did not acknowledge reload after saving configuration")?;
    wait_for_daemon_control_result(
        config_path,
        DaemonControlRequest::Reload,
        crate::daemon_control_result_timeout(DaemonControlRequest::Reload),
    )
    .context("daemon failed to apply saved configuration")
}

pub(crate) fn maybe_reload_running_daemon(config_path: &Path) {
    if let Err(error) = reload_running_daemon_after_save(config_path) {
        eprintln!("config: daemon reload after save failed: {error}");
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum RosterEditAction {
    AddDevice,
    RemoveDevice,
    AddAdmin,
    RemoveAdmin,
}

pub(crate) async fn update_active_network_roster(
    args: UpdateRosterArgs,
    action: RosterEditAction,
) -> Result<()> {
    let config_path = args.config.unwrap_or_else(default_config_path);
    let mut app = load_or_default_config(&config_path)?;
    if let Some(network_id) = args.network_id {
        app.set_active_network_id(&network_id)?;
    }
    let active_network_id = app
        .active_network_opt()
        .ok_or_else(|| anyhow!("create or join a network first"))?
        .id
        .clone();

    let mut changed = Vec::new();
    for device in &args.devices {
        let normalized = match action {
            RosterEditAction::AddDevice => app.add_device_to_network(&active_network_id, device)?,
            RosterEditAction::RemoveDevice => {
                let normalized = normalize_nostr_pubkey(device)?;
                app.remove_device_from_network(&active_network_id, device)?;
                normalized
            }
            RosterEditAction::AddAdmin => app.add_admin_to_network(&active_network_id, device)?,
            RosterEditAction::RemoveAdmin => {
                let normalized = normalize_nostr_pubkey(device)?;
                app.remove_admin_from_network(&active_network_id, device)?;
                normalized
            }
        };
        changed.push(normalized);
    }

    app.ensure_defaults();
    maybe_autoconfigure_node(&mut app);
    if matches!(action, RosterEditAction::AddDevice) {
        for recipient in &changed {
            let delivery = prepare_manual_join_delivery(&app, &active_network_id, recipient)?;
            queue_join_roster(&config_path, recipient, &delivery)?;
        }
    }
    app.save(&config_path)?;
    reload_running_daemon_after_save(&config_path)?;

    let published = 0usize;

    if args.json {
        let active_network = app
            .active_network_opt()
            .ok_or_else(|| anyhow!("create or join a network first"))?;
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                        "network_id": app.effective_network_id(),
                        "devices": active_network.devices,
                        "participants": active_network.devices,
                        "admins": active_network.admins,
                "changed": changed,
                "published_recipients": published,
                "published": args.publish,
            }))?
        );
    } else {
        println!("saved {}", config_path.display());
        println!("network_id={}", app.effective_network_id());
        println!("changed={}", changed.join(","));
        if args.publish {
            println!("published_recipients={published}");
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    use nostr_sdk::Keys;
    use nostr_vpn_core::config::AppConfig;
    use nostr_vpn_core::join_delivery::{join_roster_outbox_directory, load_join_rosters};

    use super::*;

    #[tokio::test]
    async fn add_device_queues_receipt_backed_manual_join_roster() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let config_path = std::env::temp_dir().join(format!(
            "nvpn-cli-manual-join-{}-{nonce}.toml",
            std::process::id()
        ));
        let mut app = AppConfig::generated();
        let network_id = app.add_owned_network("Admin");
        let admin = app.own_nostr_pubkey_hex().expect("admin identity");
        app.add_admin_to_network(&network_id, &admin)
            .expect("make local device an admin");
        app.save(&config_path).expect("save admin config");
        let recipient = Keys::generate().public_key().to_hex();

        update_active_network_roster(
            UpdateRosterArgs {
                config: Some(config_path.clone()),
                network_id: Some(network_id),
                devices: vec![recipient.clone()],
                publish: true,
                json: true,
            },
            RosterEditAction::AddDevice,
        )
        .await
        .expect("add manual joiner");

        let queued = load_join_rosters(&config_path);
        assert_eq!(queued.len(), 1, "manual approval must remain retryable");
        assert_eq!(queued[0].1.recipient_npub, recipient);

        fs::remove_file(&queued[0].0).expect("remove queued roster");
        fs::remove_dir(join_roster_outbox_directory(&config_path)).expect("remove outbox");
        fs::remove_file(config_path).expect("remove config");
    }
}
