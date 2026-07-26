use std::env;
use std::fs;
use std::net::{SocketAddr, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use anyhow::{Context, Result, anyhow, bail};
use nostr_sdk::prelude::{PublicKey, ToBech32};
use nostr_vpn_core::config::{AppConfig, DEFAULT_FIPS_WEBSOCKET_SEEDS, normalize_nostr_pubkey};
use nostr_vpn_core::join_delivery::load_join_rosters;
use nostr_vpn_core::signed_rosters::{load_signed_rosters, signed_rosters_file_path};
use serde_json::{Value, json};

const NETWORK_NAME: &str = "Manual join UI e2e";
const JOINER_ALIAS: &str = "desktop-ui-joiner";
const ISOLATED_LOOPBACK_WEBSOCKET_URL: &str = "ws://127.0.0.1:9";

struct Paths {
    command: String,
    admin_data_dir: PathBuf,
    joiner_data_dir: PathBuf,
    result: PathBuf,
    participant_npub: Option<String>,
    admin_npub: Option<String>,
    mesh_network_id: Option<String>,
    admin_endpoint: Option<SocketAddr>,
    joiner_endpoint: Option<SocketAddr>,
    direction: Option<String>,
}

fn required_value(args: &mut impl Iterator<Item = String>, flag: &str) -> Result<String> {
    args.next()
        .filter(|value| !value.trim().is_empty() && !value.starts_with("--"))
        .ok_or_else(|| anyhow!("{flag} requires a value"))
}

fn required_path(args: &mut impl Iterator<Item = String>, flag: &str) -> Result<PathBuf> {
    required_value(args, flag).map(PathBuf::from)
}

fn parse_paths() -> Result<Paths> {
    let mut args = env::args().skip(1);
    let command = args
        .next()
        .context("expected a manual-join fixture command")?;
    let mut admin_data_dir = None;
    let mut joiner_data_dir = None;
    let mut result = None;
    let mut participant_npub = None;
    let mut admin_npub = None;
    let mut mesh_network_id = None;
    let mut admin_endpoint = None;
    let mut joiner_endpoint = None;
    let mut direction = None;
    while let Some(flag) = args.next() {
        match flag.as_str() {
            "--admin-data-dir" => admin_data_dir = Some(required_path(&mut args, &flag)?),
            "--joiner-data-dir" => joiner_data_dir = Some(required_path(&mut args, &flag)?),
            "--result" => result = Some(required_path(&mut args, &flag)?),
            "--participant-npub" => {
                participant_npub = Some(required_value(&mut args, &flag)?);
            }
            "--admin-npub" => admin_npub = Some(required_value(&mut args, &flag)?),
            "--mesh-network-id" => {
                mesh_network_id = Some(required_value(&mut args, &flag)?);
            }
            "--admin-endpoint" => {
                admin_endpoint = Some(
                    required_value(&mut args, &flag)?
                        .parse()
                        .context("--admin-endpoint must be an IP socket address")?,
                );
            }
            "--joiner-endpoint" => {
                joiner_endpoint = Some(
                    required_value(&mut args, &flag)?
                        .parse()
                        .context("--joiner-endpoint must be an IP socket address")?,
                );
            }
            "--direction" => direction = Some(required_value(&mut args, &flag)?),
            _ => bail!("unknown argument: {flag}"),
        }
    }
    Ok(Paths {
        command,
        admin_data_dir: admin_data_dir.context("--admin-data-dir is required")?,
        joiner_data_dir: joiner_data_dir.context("--joiner-data-dir is required")?,
        result: result.context("--result is required")?,
        participant_npub,
        admin_npub,
        mesh_network_id,
        admin_endpoint,
        joiner_endpoint,
        direction,
    })
}

fn npub(config: &AppConfig) -> Result<String> {
    Ok(PublicKey::from_hex(&config.own_nostr_pubkey_hex()?)?.to_bech32()?)
}

fn load_persisted_public_config(path: &Path) -> Result<AppConfig> {
    // Physical-device snapshots intentionally exclude Keychain/Keystore
    // secrets. Decode them with the production AppConfig schema while
    // verifying only the durable public identity and roster fields.
    let raw =
        fs::read_to_string(path).with_context(|| format!("read config {}", path.display()))?;
    toml::from_str(&raw).context("parse persisted AppConfig")
}

fn contains_nostr_pubkey(values: &[String], expected: &str) -> bool {
    values
        .iter()
        .any(|value| normalize_nostr_pubkey(value).is_ok_and(|value| value == expected))
}

fn reset_dir(path: &Path) -> Result<()> {
    if path.exists() {
        fs::remove_dir_all(path)
            .with_context(|| format!("remove old fixture {}", path.display()))?;
    }
    fs::create_dir_all(path).with_context(|| format!("create fixture directory {}", path.display()))
}

fn reserve_udp_port() -> Result<u16> {
    Ok(UdpSocket::bind("127.0.0.1:0")
        .context("reserve isolated desktop manual-join UDP port")?
        .local_addr()
        .context("read isolated desktop manual-join UDP port")?
        .port())
}

fn configure_public_transit_only(config: &mut AppConfig, seed_index: usize, listen_port: u16) {
    let (selected_seed_npub, selected_seed_url) = DEFAULT_FIPS_WEBSOCKET_SEEDS[seed_index];
    config.autoconnect = false;
    config.lan_discovery_enabled = false;
    config.connect_to_non_roster_fips_peers = true;
    config.fips_nostr_discovery_enabled = false;
    config.fips_webrtc_enabled = false;
    config.fips_advertise_public_endpoint = false;
    config.fips_websocket_seed_urls = vec![selected_seed_url.to_string()];
    config.fips_websocket_bind_addr.clear();
    config.fips_websocket_public_url.clear();
    config.fips_bootstrap_enabled = true;
    // Keep both built-in identities present so ensure_defaults() does not add
    // the other live seed back. Only the selected seed has an address, which
    // pins each side to a different deployed public transit listener.
    config.fips_bootstrap_peers = DEFAULT_FIPS_WEBSOCKET_SEEDS
        .iter()
        .map(|(npub, url)| {
            (
                (*npub).to_string(),
                if *npub == selected_seed_npub {
                    vec![format!("websocket:{url}")]
                } else {
                    Vec::new()
                },
            )
        })
        .collect();
    config.fips_peer_endpoints.clear();
    config.node.listen_port = listen_port;
    config.node.endpoint = format!("127.0.0.1:{listen_port}");
}

fn configure_direct_runtime(
    config: &mut AppConfig,
    own_endpoint: SocketAddr,
    peer_npub: &str,
    peer_endpoint: SocketAddr,
) {
    config.autoconnect = false;
    config.lan_discovery_enabled = false;
    config.connect_to_non_roster_fips_peers = false;
    config.fips_nostr_discovery_enabled = false;
    config.fips_webrtc_enabled = false;
    config.fips_advertise_public_endpoint = false;
    // An empty list means "use public defaults" when constructing the FIPS
    // runtime, so pin the optional transports to a closed container-local port.
    config.fips_websocket_seed_urls = vec![ISOLATED_LOOPBACK_WEBSOCKET_URL.to_string()];
    config.fips_websocket_bind_addr.clear();
    config.fips_websocket_public_url.clear();
    config.fips_bootstrap_enabled = false;
    // Keep the built-in identities present with no addresses so
    // ensure_defaults() cannot re-add the public seeds to this isolated lane.
    config.fips_bootstrap_peers = DEFAULT_FIPS_WEBSOCKET_SEEDS
        .iter()
        .map(|(npub, _)| ((*npub).to_string(), Vec::new()))
        .collect();
    config.fips_peer_endpoints.clear();
    config
        .fips_peer_endpoints
        .insert(peer_npub.to_string(), vec![peer_endpoint.to_string()]);
    config.nostr.relays = vec![ISOLATED_LOOPBACK_WEBSOCKET_URL.to_string()];
    config.nostr.disabled_relays.clear();
    config.node.listen_port = own_endpoint.port();
    config.node.endpoint = own_endpoint.to_string();
}

fn prepare(paths: &Paths) -> Result<()> {
    reset_dir(&paths.admin_data_dir)?;
    reset_dir(&paths.joiner_data_dir)?;

    let mut admin = AppConfig::generated_without_networks();
    let network_entry_id = admin.add_owned_network(NETWORK_NAME);
    admin.set_network_enabled(&network_entry_id, true)?;
    let mesh_network_id = admin
        .network_by_id(&network_entry_id)
        .context("new admin network is missing")?
        .network_id
        .clone();
    let admin_npub = npub(&admin)?;
    let admin_hex = admin.own_nostr_pubkey_hex()?;

    let mut joiner = AppConfig::generated_without_networks();
    let joiner_npub = npub(&joiner)?;
    let joiner_hex = joiner.own_nostr_pubkey_hex()?;

    let (transport_mode, admin_listen_port, joiner_listen_port) =
        match (paths.admin_endpoint, paths.joiner_endpoint) {
            (Some(admin_endpoint), Some(joiner_endpoint)) => {
                configure_direct_runtime(&mut admin, admin_endpoint, &joiner_npub, joiner_endpoint);
                configure_direct_runtime(&mut joiner, joiner_endpoint, &admin_npub, admin_endpoint);
                ("direct", admin_endpoint.port(), joiner_endpoint.port())
            }
            (None, None) => {
                if DEFAULT_FIPS_WEBSOCKET_SEEDS.len() < 2 {
                    bail!("desktop manual join requires two deployed public FIPS seeds");
                }
                let admin_listen_port = reserve_udp_port()?;
                let mut joiner_listen_port = reserve_udp_port()?;
                while joiner_listen_port == admin_listen_port {
                    joiner_listen_port = reserve_udp_port()?;
                }
                configure_public_transit_only(&mut admin, 0, admin_listen_port);
                configure_public_transit_only(&mut joiner, 1, joiner_listen_port);
                ("public-websocket", admin_listen_port, joiner_listen_port)
            }
            _ => bail!("--admin-endpoint and --joiner-endpoint must be provided together"),
        };

    admin.save(&paths.admin_data_dir.join("config.toml"))?;
    joiner.save(&paths.joiner_data_dir.join("config.toml"))?;

    write_result(
        &paths.result,
        &json!({
            "ok": true,
            "phase": "prepared",
            "adminDataDir": paths.admin_data_dir,
            "joinerDataDir": paths.joiner_data_dir,
            "networkEntryId": network_entry_id,
            "meshNetworkId": mesh_network_id,
            "adminNpub": admin_npub,
            "adminHex": admin_hex,
            "joinerNpub": joiner_npub,
            "joinerHex": joiner_hex,
            "joinerAlias": JOINER_ALIAS,
            "adminSeedNpub": DEFAULT_FIPS_WEBSOCKET_SEEDS[0].0,
            "adminSeedUrl": DEFAULT_FIPS_WEBSOCKET_SEEDS[0].1,
            "joinerSeedNpub": DEFAULT_FIPS_WEBSOCKET_SEEDS[1].0,
            "joinerSeedUrl": DEFAULT_FIPS_WEBSOCKET_SEEDS[1].1,
            "adminListenPort": admin_listen_port,
            "joinerListenPort": joiner_listen_port,
            "adminEndpoint": paths.admin_endpoint.map(|value| value.to_string()),
            "joinerEndpoint": paths.joiner_endpoint.map(|value| value.to_string()),
            "direction": paths.direction.as_deref(),
            "transportMode": transport_mode,
            "ambientDiscoveryDisabled": true,
            "directPeerConfigAbsent": transport_mode != "direct",
        }),
    )
}

fn metadata(paths: &Paths) -> Result<Value> {
    serde_json::from_slice(
        &fs::read(&paths.result)
            .with_context(|| format!("read fixture metadata {}", paths.result.display()))?,
    )
    .context("parse fixture metadata")
}

fn metadata_string<'a>(metadata: &'a Value, key: &str) -> Result<&'a str> {
    metadata[key]
        .as_str()
        .with_context(|| format!("fixture metadata has no {key}"))
}

fn verify_joiner(paths: &Paths, metadata: &Value) -> Result<()> {
    let expected_admin = normalize_nostr_pubkey(metadata_string(metadata, "adminNpub")?)?;
    let expected_joiner = normalize_nostr_pubkey(metadata_string(metadata, "joinerNpub")?)?;
    let expected_mesh = metadata_string(metadata, "meshNetworkId")?;
    let config = AppConfig::load(&paths.joiner_data_dir.join("config.toml"))?;

    if config.own_nostr_pubkey_hex()? != expected_joiner {
        bail!("joiner identity changed while using the manual-join UI");
    }
    if config.networks.len() != 1 {
        bail!(
            "joiner manual-join UI persisted {} networks instead of exactly one",
            config.networks.len()
        );
    }
    let network = config
        .active_network_opt()
        .context("joiner manual-join UI did not activate the network")?;
    if network.network_id != expected_mesh {
        bail!("joiner manual-join UI persisted the wrong mesh network ID");
    }
    if !network.devices.iter().any(|value| value == &expected_admin)
        || !network.admins.iter().any(|value| value == &expected_admin)
        || !normalize_nostr_pubkey(&network.join_request_admin)
            .is_ok_and(|value| value == expected_admin)
    {
        bail!("joiner manual-join UI did not persist the admin trust boundary");
    }
    Ok(())
}

fn verify_admin(paths: &Paths, metadata: &Value) -> Result<()> {
    let expected_admin = normalize_nostr_pubkey(metadata_string(metadata, "adminNpub")?)?;
    let expected_joiner = normalize_nostr_pubkey(metadata_string(metadata, "joinerNpub")?)?;
    let expected_network_entry_id = metadata_string(metadata, "networkEntryId")?;
    let expected_mesh = metadata_string(metadata, "meshNetworkId")?;
    let config = AppConfig::load(&paths.admin_data_dir.join("config.toml"))?;

    if config.own_nostr_pubkey_hex()? != expected_admin {
        bail!("admin identity changed while using the add-device UI");
    }
    let network = config
        .network_by_id(expected_network_entry_id)
        .context("admin network entry disappeared")?;
    if !network.enabled || network.network_id != expected_mesh {
        bail!("admin add-device UI changed the active network");
    }
    if !network
        .devices
        .iter()
        .any(|value| value == &expected_joiner)
    {
        bail!("admin add-device UI did not persist the joining device");
    }
    if config.peer_alias(&expected_joiner).as_deref() != Some(JOINER_ALIAS) {
        bail!("admin add-device UI did not persist the joining device name");
    }
    Ok(())
}

fn capture_delivery(paths: &Paths) -> Result<()> {
    let mut metadata = metadata(paths)?;
    verify_joiner(paths, &metadata)?;
    verify_admin(paths, &metadata)?;
    let expected_admin = normalize_nostr_pubkey(metadata_string(&metadata, "adminNpub")?)?;
    let expected_joiner = normalize_nostr_pubkey(metadata_string(&metadata, "joinerNpub")?)?;
    let expected_mesh = metadata_string(&metadata, "meshNetworkId")?;
    let transport_mode = metadata_string(&metadata, "transportMode")?;
    let direct_runtime = transport_mode == "direct";
    let config_path = paths.admin_data_dir.join("config.toml");
    let queued = load_join_rosters(&config_path);
    let (outbox_path, outbox_attempts, outbox_last_attempt_at, signed_roster, delivered_during_ui) =
        match queued.as_slice() {
            [(outbox_path, queued)] => {
                if queued.recipient_npub != expected_joiner {
                    bail!("admin UI queued the signed roster for the wrong recipient");
                }
                if !direct_runtime && (queued.attempts != 0 || queued.last_attempt_at != 0) {
                    bail!("admin roster delivery ran before the real runtime gate started");
                }
                (
                    Some(outbox_path.to_string_lossy().into_owned()),
                    queued.attempts,
                    queued.last_attempt_at,
                    queued.join_roster.signed_roster.clone(),
                    false,
                )
            }
            [] if direct_runtime => {
                let joiner_config_path = paths.joiner_data_dir.join("config.toml");
                let signed_rosters =
                    load_signed_rosters(&signed_rosters_file_path(&joiner_config_path))?;
                let signed_roster = signed_rosters
                    .latest_for(expected_mesh)
                    .context(
                        "direct runtime consumed the admin outbox without durably persisting its signed roster",
                    )?
                    .clone();
                (None, 0, 0, signed_roster, true)
            }
            _ => {
                bail!(
                    "admin UI left {} roster deliveries; expected exactly one pending or one already durably delivered",
                    queued.len()
                );
            }
        };
    signed_roster.verify()?;
    if signed_roster.signer_pubkey_hex()? != expected_admin
        || signed_roster.network_id()? != expected_mesh
    {
        bail!("admin UI queued the wrong signed roster artifact");
    }
    let roster = signed_roster.roster()?;
    if !contains_nostr_pubkey(&roster.admins, &expected_admin)
        || !contains_nostr_pubkey(&roster.devices, &expected_admin)
        || !contains_nostr_pubkey(&roster.devices, &expected_joiner)
    {
        bail!("admin UI queued a signed roster without the exact manual-join members");
    }
    let expected_event_id = signed_roster.artifact_hash();
    let object = metadata
        .as_object_mut()
        .context("fixture result is not a JSON object")?;
    object.insert("phase".into(), json!("ui-verified"));
    object.insert("expectedRosterEventId".into(), json!(expected_event_id));
    object.insert("queuedOutboxPath".into(), json!(outbox_path));
    object.insert(
        "adminOutboxQueuedBeforeRuntime".into(),
        json!(!delivered_during_ui),
    );
    object.insert(
        "adminOutboxAttemptsBeforeRuntime".into(),
        json!(outbox_attempts),
    );
    object.insert(
        "adminOutboxLastAttemptAtBeforeRuntime".into(),
        json!(outbox_last_attempt_at),
    );
    object.insert(
        "deliveryCompletedDuringUi".into(),
        json!(delivered_during_ui),
    );
    write_result(&paths.result, &metadata)
}

fn verify(paths: &Paths) -> Result<()> {
    let metadata = metadata(paths)?;
    verify_joiner(paths, &metadata)?;
    verify_admin(paths, &metadata)?;
    write_result(
        &paths.result,
        &json!({
            "ok": true,
            "phase": "verified",
            "adminDataDir": paths.admin_data_dir,
            "joinerDataDir": paths.joiner_data_dir,
            "networkEntryId": metadata_string(&metadata, "networkEntryId")?,
            "meshNetworkId": metadata_string(&metadata, "meshNetworkId")?,
            "adminNpub": metadata_string(&metadata, "adminNpub")?,
            "joinerNpub": metadata_string(&metadata, "joinerNpub")?,
            "joinerAlias": JOINER_ALIAS,
            "joinerNetworkPersisted": true,
            "joinerAdminPersisted": true,
            "adminParticipantPersisted": true,
            "adminAliasPersisted": true,
            "identitiesStable": true,
        }),
    )
}

fn verify_public_transit_state(
    data_dir: &Path,
    expected_seed: &str,
    expected_seed_url: &str,
    forbidden_direct_peer: &str,
) -> Result<()> {
    let state_path = data_dir.join("daemon.state.json");
    let state: Value = serde_json::from_slice(
        &fs::read(&state_path).with_context(|| format!("read {}", state_path.display()))?,
    )
    .with_context(|| format!("parse {}", state_path.display()))?;
    if state["vpn_enabled"].as_bool() != Some(true) || state["vpn_active"].as_bool() != Some(true) {
        bail!(
            "desktop manual-join runtime is not active in {}",
            state_path.display()
        );
    }
    if state["fips_other_peer_count"].as_u64().unwrap_or_default() < 1 {
        bail!("desktop manual-join runtime has no authenticated public FIPS transit peer");
    }
    if state["fips_direct_roster_peer_count"]
        .as_u64()
        .unwrap_or_default()
        != 0
    {
        bail!("desktop manual-join runtime established a forbidden direct roster peer");
    }

    let expected_seed = normalize_nostr_pubkey(expected_seed)?;
    let expected_seed_address = format!("websocket:{expected_seed_url}");
    let forbidden_direct_peer = normalize_nostr_pubkey(forbidden_direct_peer)?;
    let peers = state["fips_endpoint_peers"]
        .as_array()
        .context("daemon state has no fips_endpoint_peers array")?;
    let mut address_bearing_peers = 0usize;
    let mut saw_expected_seed = false;
    for peer in peers {
        let peer_npub = peer["npub"].as_str().unwrap_or_default();
        let peer_hex = normalize_nostr_pubkey(peer_npub).ok();
        let addresses = peer["addresses"]
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or_default();
        if !addresses.is_empty() {
            address_bearing_peers += 1;
        }
        if peer_hex.as_deref() == Some(expected_seed.as_str()) {
            saw_expected_seed = addresses
                .iter()
                .any(|address| address["addr"].as_str() == Some(expected_seed_address.as_str()));
        }
        if peer_hex.as_deref() == Some(forbidden_direct_peer.as_str()) && !addresses.is_empty() {
            bail!("manual-join peers gained forbidden direct transport configuration");
        }
    }
    if !saw_expected_seed {
        bail!("daemon state does not contain the identity-pinned expected public FIPS seed");
    }
    if address_bearing_peers != 1 {
        bail!(
            "manual-join runtime has {address_bearing_peers} address-bearing peers; expected only its public transit seed"
        );
    }
    Ok(())
}

fn verify_direct_runtime_state(
    data_dir: &Path,
    expected_peer: &str,
    expected_endpoint: &str,
) -> Result<()> {
    let config = AppConfig::load(&data_dir.join("config.toml"))?;
    if config.fips_nostr_discovery_enabled
        || config.fips_bootstrap_enabled
        || config
            .fips_bootstrap_peers
            .values()
            .any(|addresses| !addresses.is_empty())
        || config.fips_websocket_seed_urls != [ISOLATED_LOOPBACK_WEBSOCKET_URL]
        || config.nostr.relays != [ISOLATED_LOOPBACK_WEBSOCKET_URL]
    {
        bail!("web/StartOS manual-join runtime escaped its isolated direct transport config");
    }

    let state_path = data_dir.join("daemon.state.json");
    let state: Value = serde_json::from_slice(
        &fs::read(&state_path).with_context(|| format!("read {}", state_path.display()))?,
    )
    .with_context(|| format!("parse {}", state_path.display()))?;
    if state["vpn_enabled"].as_bool() != Some(true) || state["vpn_active"].as_bool() != Some(true) {
        bail!(
            "web/StartOS manual-join runtime is not active in {}",
            state_path.display()
        );
    }
    if state["fips_direct_roster_peer_count"]
        .as_u64()
        .unwrap_or_default()
        < 1
    {
        bail!("web/StartOS runtime has no authenticated direct roster peer");
    }
    if state["fips_other_peer_count"].as_u64().unwrap_or_default() != 0 {
        bail!("web/StartOS runtime authenticated an unexpected non-roster FIPS peer");
    }

    let expected_peer = normalize_nostr_pubkey(expected_peer)?;
    let endpoint_peers = state["fips_endpoint_peers"]
        .as_array()
        .context("daemon state has no fips_endpoint_peers array")?;
    let configured = endpoint_peers.iter().any(|peer| {
        normalize_nostr_pubkey(peer["npub"].as_str().unwrap_or_default())
            .is_ok_and(|npub| npub == expected_peer)
            && peer["addresses"].as_array().is_some_and(|addresses| {
                addresses.iter().any(|address| {
                    address["addr"].as_str().is_some_and(|value| {
                        value == expected_endpoint || value == format!("udp:{expected_endpoint}")
                    })
                })
            })
    });
    if !configured {
        bail!("web/StartOS runtime lacks the identity-pinned configured endpoint for its peer");
    }

    let connected = state["peers"].as_array().is_some_and(|peers| {
        peers.iter().any(|peer| {
            let participant = peer["participant_pubkey"]
                .as_str()
                .or_else(|| peer["public_key"].as_str())
                .or_else(|| peer["fips_endpoint_npub"].as_str())
                .unwrap_or_default();
            normalize_nostr_pubkey(participant).is_ok_and(|npub| npub == expected_peer)
                && peer["reachable"].as_bool() == Some(true)
        })
    });
    if !connected {
        bail!("web/StartOS runtime did not authenticate its expected roster peer");
    }
    Ok(())
}

fn verify_runtime(paths: &Paths) -> Result<()> {
    let mut metadata = metadata(paths)?;
    verify_joiner(paths, &metadata)?;
    verify_admin(paths, &metadata)?;
    let expected_admin = normalize_nostr_pubkey(metadata_string(&metadata, "adminNpub")?)?;
    let expected_joiner = normalize_nostr_pubkey(metadata_string(&metadata, "joinerNpub")?)?;
    let expected_mesh = metadata_string(&metadata, "meshNetworkId")?;
    let expected_event_id = metadata_string(&metadata, "expectedRosterEventId")?;
    let joiner_config_path = paths.joiner_data_dir.join("config.toml");
    let joiner_config = AppConfig::load(&joiner_config_path)?;
    let network = joiner_config
        .active_network_opt()
        .context("runtime joiner has no active network")?;
    let signed_rosters = load_signed_rosters(&signed_rosters_file_path(&joiner_config_path))?;
    let signed_roster = signed_rosters
        .latest_for(expected_mesh)
        .context("runtime joiner did not durably persist the signed roster")?;
    if signed_roster.artifact_hash() != expected_event_id
        || signed_roster.signer_pubkey_hex()? != expected_admin
        || signed_roster.network_id()? != expected_mesh
        || network.shared_roster_updated_at != signed_roster.signed_at()
        || !normalize_nostr_pubkey(&network.shared_roster_signed_by)
            .is_ok_and(|value| value == expected_admin)
    {
        bail!("runtime joiner did not durably apply the exact UI-queued signed roster");
    }
    let roster = signed_roster.roster()?;
    if !contains_nostr_pubkey(&roster.admins, &expected_admin)
        || !contains_nostr_pubkey(&roster.devices, &expected_admin)
        || !contains_nostr_pubkey(&roster.devices, &expected_joiner)
    {
        bail!("runtime joiner persisted a signed roster with the wrong members");
    }
    if !load_join_rosters(&paths.admin_data_dir.join("config.toml")).is_empty() {
        bail!("admin retained the roster outbox after the joiner's durable acknowledgement");
    }

    match metadata_string(&metadata, "transportMode")? {
        "direct" => {
            verify_direct_runtime_state(
                &paths.admin_data_dir,
                metadata_string(&metadata, "joinerNpub")?,
                metadata_string(&metadata, "joinerEndpoint")?,
            )?;
            verify_direct_runtime_state(
                &paths.joiner_data_dir,
                metadata_string(&metadata, "adminNpub")?,
                metadata_string(&metadata, "adminEndpoint")?,
            )?;
        }
        "public-websocket" => {
            verify_public_transit_state(
                &paths.admin_data_dir,
                metadata_string(&metadata, "adminSeedNpub")?,
                metadata_string(&metadata, "adminSeedUrl")?,
                metadata_string(&metadata, "joinerNpub")?,
            )?;
            verify_public_transit_state(
                &paths.joiner_data_dir,
                metadata_string(&metadata, "joinerSeedNpub")?,
                metadata_string(&metadata, "joinerSeedUrl")?,
                metadata_string(&metadata, "adminNpub")?,
            )?;
        }
        mode => bail!("unsupported manual-join fixture transport mode: {mode}"),
    }

    let transport_mode = metadata_string(&metadata, "transportMode")?.to_string();
    let object = metadata
        .as_object_mut()
        .context("fixture result is not a JSON object")?;
    object.insert("ok".into(), json!(true));
    object.insert("phase".into(), json!("runtime-verified"));
    object.insert("exactSignedRosterDurablyApplied".into(), json!(true));
    object.insert(
        "adminOutboxConsumedByExactJoinRosterAck".into(),
        json!(true),
    );
    object.insert(
        "publicFipsCrossSeedRouteOnly".into(),
        json!(transport_mode == "public-websocket"),
    );
    object.insert(
        "directProductionRuntime".into(),
        json!(transport_mode == "direct"),
    );
    write_result(&paths.result, &metadata)
}

fn verify_physical_admin(paths: &Paths) -> Result<()> {
    let participant = normalize_nostr_pubkey(
        paths
            .participant_npub
            .as_deref()
            .context("--participant-npub is required")?,
    )?;
    let config = load_persisted_public_config(&paths.admin_data_dir.join("config.toml"))?;
    if !config
        .networks
        .iter()
        .any(|network| network.enabled && contains_nostr_pubkey(&network.devices, &participant))
    {
        bail!("desktop admin did not persist the physical participant");
    }
    Ok(())
}

fn verify_physical_joiner(paths: &Paths) -> Result<()> {
    let expected_admin = normalize_nostr_pubkey(
        paths
            .admin_npub
            .as_deref()
            .context("--admin-npub is required")?,
    )?;
    let expected_mesh = paths
        .mesh_network_id
        .as_deref()
        .context("--mesh-network-id is required")?;
    let config = load_persisted_public_config(&paths.joiner_data_dir.join("config.toml"))?;
    let own = config.own_nostr_pubkey_hex()?;
    let network = config
        .networks
        .iter()
        .find(|network| network.enabled && network.network_id == expected_mesh)
        .context("desktop joiner did not persist the physical Android network")?;
    let signed_rosters = load_signed_rosters(&signed_rosters_file_path(
        &paths.joiner_data_dir.join("config.toml"),
    ))?;
    let signed_roster = signed_rosters
        .latest_for(expected_mesh)
        .context("desktop joiner did not persist the signed-roster artifact")?;
    let roster = signed_roster.roster()?;
    if network.shared_roster_updated_at != signed_roster.signed_at()
        || !normalize_nostr_pubkey(&network.shared_roster_signed_by)
            .is_ok_and(|value| value == expected_admin)
        || signed_roster.signer_pubkey_hex()? != expected_admin
        || signed_roster.network_id()? != expected_mesh
        || !normalize_nostr_pubkey(&network.join_request_admin)
            .is_ok_and(|value| value == expected_admin)
        || !contains_nostr_pubkey(&network.admins, &expected_admin)
        || !contains_nostr_pubkey(&network.devices, &expected_admin)
        || !contains_nostr_pubkey(&roster.admins, &expected_admin)
        || !contains_nostr_pubkey(&roster.devices, &expected_admin)
        || !contains_nostr_pubkey(&roster.devices, &own)
    {
        bail!("desktop joiner lacks the exact durable admin-signed roster");
    }
    Ok(())
}

fn print_active_admin(paths: &Paths) -> Result<()> {
    let config = load_persisted_public_config(&paths.admin_data_dir.join("config.toml"))?;
    let network = config
        .active_network_opt()
        .context("no active physical admin network")?;
    println!("{}", npub(&config)?);
    println!("{}", network.network_id);
    Ok(())
}

fn write_result(path: &Path, value: &Value) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, serde_json::to_vec_pretty(value)?)
        .with_context(|| format!("write {}", path.display()))
}

fn run() -> Result<()> {
    let paths = parse_paths()?;
    match paths.command.as_str() {
        "prepare" => prepare(&paths),
        "verify-joiner" => {
            let metadata = metadata(&paths)?;
            verify_joiner(&paths, &metadata)
        }
        "verify-admin" => {
            let metadata = metadata(&paths)?;
            verify_admin(&paths, &metadata)
        }
        "capture-delivery" => capture_delivery(&paths),
        "verify" => verify(&paths),
        "verify-runtime" => verify_runtime(&paths),
        "verify-physical-admin" => verify_physical_admin(&paths),
        "verify-physical-joiner" => verify_physical_joiner(&paths),
        "print-active-admin" => print_active_admin(&paths),
        _ => bail!(
            "expected prepare, verify-joiner, verify-admin, capture-delivery, verify, \
             verify-runtime, \
             verify-physical-admin, verify-physical-joiner, or print-active-admin"
        ),
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("desktop manual-join e2e fixture failed: {error:#}");
            ExitCode::FAILURE
        }
    }
}
