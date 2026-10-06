#[cfg(target_os = "macos")]
use crate::macos_file_io as fs;
#[cfg(not(target_os = "macos"))]
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use anyhow::{Context, Result, anyhow};
use hashtree_updater::{
    ProductAssetPolicy, SecureNostrBlossomConfig, SecureNostrBlossomSelection, UpdateAsset,
    UpdateManifest, build_secure_nostr_blossom_updater_with_events, current_archive_target,
    dedupe_nonempty, download_product_selection, env_csv, platform_app_asset_suffixes,
    preferred_app_asset_for_suffixes, preferred_cli_asset_for_target, select_product_update,
    selected_download_path as shared_selected_download_path, update_ref_from_override,
};
pub use hashtree_updater::{
    ProductUpdateMode, SECURE_SOURCE_NAME, UpdateAutoCheckPolicy, UpdateEventCache, UpdateRef,
};
use nostr_sdk::prelude::Event;
use serde::{Deserialize, Serialize};

pub const GITHUB_LATEST_RELEASE_URL: &str =
    "https://api.github.com/repos/mmalmi/nostr-vpn/releases/latest";
pub const HTREE_MANIFEST_URL: &str = "https://upload.iris.to/npub1xdhnr9mrv47kkrn95k6cwecearydeh8e895990n3acntwvmgk2dsdeeycm/releases%2Fnostr-vpn/latest/release.json";
pub const HTREE_UPDATE_REF: &str = "htree://npub1xdhnr9mrv47kkrn95k6cwecearydeh8e895990n3acntwvmgk2dsdeeycm/releases%2Fnostr-vpn/latest";
pub const LEGACY_HTREE_SOURCE_NAME: &str = "legacy-htree-url";
pub const GITHUB_SOURCE_NAME: &str = "github";

const UPDATE_CONNECT_TIMEOUT_SECS: &str = "4";
const UPDATE_MANIFEST_TIMEOUT_SECS: &str = "8";
const UPDATE_DOWNLOAD_TIMEOUT_SECS: &str = "180";
const UPDATE_USER_AGENT: &str = "nvpn-updater";
const DEFAULT_UPDATE_RELAYS: &[&str] = &[
    "wss://temp.iris.to",
    "wss://relay.damus.io",
    "wss://relay.snort.social",
    "wss://relay.primal.net",
    "wss://upload.iris.to/nostr",
];
const DEFAULT_BLOSSOM_READ_SERVERS: &[&str] = &[
    "https://cdn.iris.to",
    "https://upload.iris.to",
    "https://blossom.primal.net",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProductUpdateSource {
    Auto,
    Github,
    Hashtree,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProductUpdateResult {
    pub available: bool,
    pub current_version: String,
    pub latest_version: String,
    pub tag: String,
    pub asset: String,
    pub source: String,
    pub verified: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ReleaseManifest {
    #[serde(alias = "tag_name")]
    tag: String,
    assets: Vec<ReleaseAsset>,
}

#[derive(Clone, Debug, Deserialize)]
struct ReleaseAsset {
    name: String,
    #[serde(alias = "browser_download_url")]
    path: String,
}

struct LegacySelection {
    manifest: ReleaseManifest,
    asset: ReleaseAsset,
    asset_url: String,
    source_name: &'static str,
    update_available: bool,
}

enum UpdateSelection {
    Secure(Box<SecureNostrBlossomSelection>),
    Legacy(LegacySelection),
}

pub fn check_product_update_blocking(
    current_version: &str,
    mode: ProductUpdateMode,
    source: ProductUpdateSource,
) -> Result<ProductUpdateResult> {
    check_product_update_blocking_with_cache(current_version, mode, source, None)
}

pub fn check_product_update_blocking_with_cache(
    current_version: &str,
    mode: ProductUpdateMode,
    source: ProductUpdateSource,
    event_cache_path: Option<&Path>,
) -> Result<ProductUpdateResult> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("failed to start update runtime")?;
    runtime.block_on(check_product_update_with_cache(
        current_version,
        mode,
        source,
        event_cache_path,
    ))
}

pub async fn check_product_update(
    current_version: &str,
    mode: ProductUpdateMode,
    source: ProductUpdateSource,
) -> Result<ProductUpdateResult> {
    check_product_update_with_cache(current_version, mode, source, None).await
}

pub async fn check_product_update_with_cache(
    current_version: &str,
    mode: ProductUpdateMode,
    source: ProductUpdateSource,
    event_cache_path: Option<&Path>,
) -> Result<ProductUpdateResult> {
    let selection = select_update(current_version, mode, source, event_cache_path).await?;
    Ok(result_from_selection(current_version, &selection, None))
}

pub fn download_product_update_blocking(
    current_version: &str,
    mode: ProductUpdateMode,
    source: ProductUpdateSource,
    download_dir: Option<&Path>,
) -> Result<ProductUpdateResult> {
    download_product_update_blocking_with_cache(current_version, mode, source, download_dir, None)
}

pub fn download_product_update_blocking_with_cache(
    current_version: &str,
    mode: ProductUpdateMode,
    source: ProductUpdateSource,
    download_dir: Option<&Path>,
    event_cache_path: Option<&Path>,
) -> Result<ProductUpdateResult> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("failed to start update runtime")?;
    runtime.block_on(download_product_update_with_cache(
        current_version,
        mode,
        source,
        download_dir,
        event_cache_path,
    ))
}

pub async fn download_product_update(
    current_version: &str,
    mode: ProductUpdateMode,
    source: ProductUpdateSource,
    download_dir: Option<&Path>,
) -> Result<ProductUpdateResult> {
    download_product_update_with_cache(current_version, mode, source, download_dir, None).await
}

pub async fn download_product_update_with_cache(
    current_version: &str,
    mode: ProductUpdateMode,
    source: ProductUpdateSource,
    download_dir: Option<&Path>,
    event_cache_path: Option<&Path>,
) -> Result<ProductUpdateResult> {
    let selection = select_update(current_version, mode, source, event_cache_path).await?;
    let destination = download_selection(&selection, download_dir).await?;
    Ok(result_from_selection(
        current_version,
        &selection,
        Some(&destination),
    ))
}

async fn select_update(
    current_version: &str,
    mode: ProductUpdateMode,
    source: ProductUpdateSource,
    event_cache_path: Option<&Path>,
) -> Result<UpdateSelection> {
    if !should_use_secure_hashtree(source) {
        return legacy_selection(current_version, source, mode).map(UpdateSelection::Legacy);
    }

    let secure = secure_selection(current_version, mode, event_cache_path).await;
    let selection = match secure {
        Ok(selection) => selection,
        Err(error) if should_try_github_fallback(source, false) => {
            return legacy_selection(current_version, ProductUpdateSource::Github, mode)
                .map(UpdateSelection::Legacy)
                .with_context(|| format!("secure hashtree update check failed: {error}"));
        }
        Err(error) => return Err(error),
    };

    if should_try_github_fallback(source, selection.update_available)
        && let Ok(legacy) = legacy_selection(current_version, ProductUpdateSource::Github, mode)
        && legacy.update_available
    {
        return Ok(UpdateSelection::Legacy(legacy));
    }

    Ok(UpdateSelection::Secure(Box::new(selection)))
}

fn result_from_selection(
    current_version: &str,
    selection: &UpdateSelection,
    path: Option<&Path>,
) -> ProductUpdateResult {
    match selection {
        UpdateSelection::Secure(selection) => ProductUpdateResult {
            available: selection.update_available,
            current_version: current_version.to_string(),
            latest_version: selection.tag.trim_start_matches('v').to_string(),
            tag: selection.tag.clone(),
            asset: selection.asset.name.clone(),
            source: SECURE_SOURCE_NAME.to_string(),
            verified: true,
            url: None,
            path: path.map(|value| value.display().to_string()),
        },
        UpdateSelection::Legacy(selection) => ProductUpdateResult {
            available: selection.update_available,
            current_version: current_version.to_string(),
            latest_version: selection.manifest.tag.trim_start_matches('v').to_string(),
            tag: selection.manifest.tag.clone(),
            asset: selection.asset.name.clone(),
            source: selection.source_name.to_string(),
            verified: false,
            url: Some(selection.asset_url.clone()),
            path: path.map(|value| value.display().to_string()),
        },
    }
}

async fn secure_selection(
    current_version: &str,
    mode: ProductUpdateMode,
    event_cache_path: Option<&Path>,
) -> Result<SecureNostrBlossomSelection> {
    let reference = configured_update_ref()?;
    let updater = build_secure_updater(event_cache_path, &reference).await?;
    select_product_update(updater, reference, current_version, mode, &asset_policy())
        .await
        .with_context(|| {
            format!(
                "failed to resolve signed hashtree release for {}",
                asset_policy().noun(mode)
            )
        })
}

pub fn configured_update_ref() -> Result<UpdateRef> {
    update_ref_from_override(None, Some("NVPN_UPDATE_HTREE_REF"), HTREE_UPDATE_REF)
        .context("invalid update hashtree ref")
}

#[must_use]
pub fn update_event_cache_path(config_path: &Path) -> PathBuf {
    config_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("control-pubsub-events.json")
}

#[derive(Deserialize)]
struct CachedPubsubEvents {
    events: Vec<Event>,
}

fn load_cached_update_root_events(path: &Path, reference: &UpdateRef) -> Result<Vec<Event>> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    let cached: CachedPubsubEvents = serde_json::from_slice(&bytes)
        .with_context(|| format!("failed to decode {}", path.display()))?;
    let mut update_events = UpdateEventCache::new(reference)
        .context("failed to configure update announcement cache")?;
    for event in cached.events {
        let _ = update_events.ingest_event(event);
    }
    Ok(update_events.resolver_events())
}

async fn build_secure_updater(
    event_cache_path: Option<&Path>,
    reference: &UpdateRef,
) -> Result<hashtree_updater::SecureNostrBlossomUpdater> {
    let cached_events = match event_cache_path {
        Some(path) => load_cached_update_root_events(path, reference).unwrap_or_else(|error| {
            tracing::warn!(%error, path = %path.display(), "ignored invalid update-root pubsub cache");
            Vec::new()
        }),
        None => Vec::new(),
    };
    build_secure_nostr_blossom_updater_with_events(secure_updater_config(), cached_events)
        .await
        .context("failed to connect to Nostr release relays")
}

fn secure_updater_config() -> SecureNostrBlossomConfig {
    SecureNostrBlossomConfig {
        // Cached pubsub events are a fast starting point, not an authority for
        // freshness. Keep querying relays so an old cache cannot pin updates.
        relays: update_relays(),
        manifest_timeout: Duration::from_secs(
            UPDATE_MANIFEST_TIMEOUT_SECS.parse::<u64>().unwrap_or(8),
        ),
        download_timeout: Duration::from_secs(
            UPDATE_DOWNLOAD_TIMEOUT_SECS.parse::<u64>().unwrap_or(180),
        ),
        blossom_read_servers: blossom_read_servers(),
    }
}

fn legacy_selection(
    current_version: &str,
    source: ProductUpdateSource,
    mode: ProductUpdateMode,
) -> Result<LegacySelection> {
    let (manifest_url, manifest) = fetch_first_manifest(source)?;
    let newer = version_is_newer(&manifest.tag, current_version);
    let asset = preferred_asset(&manifest, mode).ok_or_else(|| {
        anyhow!(
            "release {} has no {} asset for {}",
            manifest.tag,
            asset_policy().noun(mode),
            current_target()
        )
    })?;
    let asset_url = manifest_asset_url(&manifest_url, &asset.path);
    let source_name = if manifest_url.contains("api.github.com") {
        GITHUB_SOURCE_NAME
    } else {
        LEGACY_HTREE_SOURCE_NAME
    };

    Ok(LegacySelection {
        manifest,
        asset,
        asset_url,
        source_name,
        update_available: newer,
    })
}

async fn download_selection(
    selection: &UpdateSelection,
    download_dir: Option<&Path>,
) -> Result<PathBuf> {
    match selection {
        UpdateSelection::Secure(selection) => {
            download_product_selection(selection, download_dir, &asset_policy())
                .await
                .with_context(|| {
                    format!(
                        "failed to download verified hashtree asset {}",
                        selection.asset.name
                    )
                })
        }
        UpdateSelection::Legacy(selection) => {
            let destination = selected_download_path(download_dir, &selection.asset.name)?;
            download_asset(&selection.asset_url, &destination)?;
            Ok(destination)
        }
    }
}

fn should_use_secure_hashtree(source: ProductUpdateSource) -> bool {
    std::env::var("NVPN_UPDATE_MANIFEST_URL")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .is_none()
        && !matches!(source, ProductUpdateSource::Github)
}

#[must_use]
pub fn should_try_github_fallback(source: ProductUpdateSource, secure_available: bool) -> bool {
    matches!(source, ProductUpdateSource::Auto) && !secure_available
}

fn update_relays() -> Vec<String> {
    env_csv("NVPN_UPDATE_RELAYS").unwrap_or_else(|| {
        dedupe_nonempty(
            DEFAULT_UPDATE_RELAYS
                .iter()
                .map(|value| (*value).to_string())
                .collect(),
        )
    })
}

fn blossom_read_servers() -> Vec<String> {
    env_csv("NVPN_UPDATE_BLOSSOM_SERVERS").unwrap_or_else(|| {
        dedupe_nonempty(
            DEFAULT_BLOSSOM_READ_SERVERS
                .iter()
                .map(|value| (*value).to_string())
                .collect(),
        )
    })
}

fn asset_policy() -> ProductAssetPolicy {
    ProductAssetPolicy::new("nvpn", "nvpn CLI", "Nostr VPN app")
        .with_app_asset_suffixes(platform_app_asset_suffixes().iter().copied())
        .with_download_file_name_fallback("nvpn-update-archive")
}

fn current_target() -> &'static str {
    current_archive_target()
}

fn legacy_update_manifest(manifest: &ReleaseManifest) -> UpdateManifest {
    UpdateManifest {
        tag: Some(manifest.tag.clone()),
        assets: manifest
            .assets
            .iter()
            .map(|asset| UpdateAsset {
                name: asset.name.clone(),
                path: asset.path.clone(),
                ..UpdateAsset::default()
            })
            .collect(),
        ..UpdateManifest::default()
    }
}

fn release_asset_from_update_asset(asset: UpdateAsset) -> ReleaseAsset {
    ReleaseAsset {
        name: asset.name,
        path: asset.path,
    }
}

fn preferred_asset(manifest: &ReleaseManifest, mode: ProductUpdateMode) -> Option<ReleaseAsset> {
    match mode {
        ProductUpdateMode::Cli => preferred_cli_asset(manifest),
        ProductUpdateMode::App => preferred_legacy_app_asset(manifest),
    }
}

fn preferred_cli_asset(manifest: &ReleaseManifest) -> Option<ReleaseAsset> {
    let update_manifest = legacy_update_manifest(manifest);
    preferred_cli_asset_for_target(&update_manifest, "nvpn", current_target())
        .map(release_asset_from_update_asset)
}

fn preferred_legacy_app_asset(manifest: &ReleaseManifest) -> Option<ReleaseAsset> {
    let update_manifest = legacy_update_manifest(manifest);
    preferred_app_asset_for_suffixes(&update_manifest, platform_app_asset_suffixes())
        .map(release_asset_from_update_asset)
}

fn selected_download_path(download_dir: Option<&Path>, asset_name: &str) -> Result<PathBuf> {
    shared_selected_download_path(download_dir, asset_name, "nvpn-update-archive")
        .with_context(|| format!("failed to choose update download path for {asset_name}"))
}

fn fetch_first_manifest(source: ProductUpdateSource) -> Result<(String, ReleaseManifest)> {
    let mut last_error = None;
    for url in manifest_urls(source) {
        match fetch_manifest(&url) {
            Ok(manifest) => return Ok((url, manifest)),
            Err(error) => last_error = Some(error),
        }
    }
    Err(last_error.unwrap_or_else(|| anyhow!("no update manifest URL configured")))
}

fn manifest_urls(source: ProductUpdateSource) -> Vec<String> {
    manifest_urls_for(
        source,
        std::env::var("NVPN_UPDATE_MANIFEST_URL")
            .ok()
            .filter(|value| !value.trim().is_empty()),
    )
}

fn manifest_urls_for(source: ProductUpdateSource, override_url: Option<String>) -> Vec<String> {
    if let Some(override_url) = override_url.filter(|value| !value.trim().is_empty()) {
        return vec![override_url];
    }

    match source {
        ProductUpdateSource::Auto => vec![
            HTREE_MANIFEST_URL.to_string(),
            GITHUB_LATEST_RELEASE_URL.to_string(),
        ],
        ProductUpdateSource::Github => vec![GITHUB_LATEST_RELEASE_URL.to_string()],
        ProductUpdateSource::Hashtree => vec![HTREE_MANIFEST_URL.to_string()],
    }
}

fn fetch_manifest(url: &str) -> Result<ReleaseManifest> {
    let mut command = Command::new("curl");
    command.args([
        "-fsSL",
        "--connect-timeout",
        UPDATE_CONNECT_TIMEOUT_SECS,
        "--max-time",
        UPDATE_MANIFEST_TIMEOUT_SECS,
    ]);
    if url.contains("api.github.com") {
        command
            .arg("-H")
            .arg("Accept: application/vnd.github+json")
            .arg("-H")
            .arg(format!("User-Agent: {UPDATE_USER_AGENT}"));
    }
    let output = command
        .arg(url)
        .output()
        .with_context(|| format!("failed to run curl for {url}"))?;
    if !output.status.success() {
        return Err(anyhow!("{}", command_error("update check failed", &output)));
    }
    serde_json::from_slice(&output.stdout).context("failed to parse release manifest")
}

fn manifest_asset_url(manifest_url: &str, path: &str) -> String {
    if path.starts_with("http://") || path.starts_with("https://") || path.starts_with("file://") {
        return path.to_string();
    }
    let base = manifest_url
        .rsplit_once('/')
        .map(|(base, _)| base)
        .unwrap_or(manifest_url);
    format!("{}/{}", base, path.trim_start_matches('/'))
}

fn download_asset(url: &str, destination: &Path) -> Result<()> {
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    let output = Command::new("curl")
        .arg("-fL")
        .arg("--connect-timeout")
        .arg(UPDATE_CONNECT_TIMEOUT_SECS)
        .arg("--max-time")
        .arg(UPDATE_DOWNLOAD_TIMEOUT_SECS)
        .arg("-o")
        .arg(destination)
        .arg(url)
        .output()
        .with_context(|| format!("failed to run curl for {url}"))?;
    if !output.status.success() {
        return Err(anyhow!(
            "{}",
            command_error("update download failed", &output)
        ));
    }
    Ok(())
}

fn command_error(prefix: &str, output: &std::process::Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !stderr.is_empty() {
        format!("{prefix}: {stderr}")
    } else if !stdout.is_empty() {
        format!("{prefix}: {stdout}")
    } else {
        format!("{prefix}: exit {}", output.status)
    }
}

#[must_use]
pub fn version_is_newer(candidate: &str, current: &str) -> bool {
    let left = version_parts(candidate);
    let right = version_parts(current);
    for index in 0..left.len().max(right.len()) {
        let left_value = left.get(index).copied().unwrap_or_default();
        let right_value = right.get(index).copied().unwrap_or_default();
        if left_value != right_value {
            return left_value > right_value;
        }
    }
    false
}

fn version_parts(value: &str) -> Vec<u32> {
    value
        .trim_matches(|ch: char| ch == 'v' || ch == 'V' || ch.is_whitespace())
        .split(|ch: char| !ch.is_ascii_digit())
        .filter(|part| !part.is_empty())
        .map(|part| part.parse::<u32>().unwrap_or_default())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr_sdk::prelude::{EventBuilder, Keys, Kind, Tag, TagKind, ToBech32};

    #[test]
    fn auto_source_checks_htree_before_github() {
        assert_eq!(
            manifest_urls_for(ProductUpdateSource::Auto, None),
            vec![
                HTREE_MANIFEST_URL.to_string(),
                GITHUB_LATEST_RELEASE_URL.to_string(),
            ]
        );
    }

    #[test]
    fn auto_source_can_cross_check_github_when_secure_hashtree_is_not_newer() {
        assert!(should_try_github_fallback(ProductUpdateSource::Auto, false));
        assert!(!should_try_github_fallback(ProductUpdateSource::Auto, true));
        assert!(!should_try_github_fallback(
            ProductUpdateSource::Hashtree,
            false
        ));
        assert!(!should_try_github_fallback(
            ProductUpdateSource::Github,
            false
        ));
    }

    #[test]
    fn compares_semver_like_tags() {
        assert!(version_is_newer("v4.0.55", "4.0.52"));
        assert!(version_is_newer("v4.0.13", "4.0.12"));
        assert!(!version_is_newer("v4.0.12", "4.0.12"));
        assert!(!version_is_newer("v4.0.11", "4.0.12"));
    }

    #[test]
    fn resolves_relative_manifest_asset_urls() {
        assert_eq!(
            manifest_asset_url(
                "https://example.invalid/latest/release.json",
                "assets/nvpn.tgz"
            ),
            "https://example.invalid/latest/assets/nvpn.tgz"
        );
    }

    #[test]
    fn cached_pubsub_roots_are_verified_filtered_and_replaceable() {
        let publisher = Keys::generate();
        let other = Keys::generate();
        let reference = UpdateRef {
            npub: publisher.public_key().to_bech32().expect("npub"),
            tree_name: "releases/test-app".to_string(),
            path: Some("latest".to_string()),
        };
        let root = |keys: &Keys, created_at: u64, hash: &str| {
            EventBuilder::new(Kind::Custom(30_064), "")
                .tags([
                    Tag::identifier("releases/test-app"),
                    Tag::custom(TagKind::Custom("l".into()), ["hashtree"]),
                    Tag::custom(TagKind::Custom("hash".into()), [hash]),
                ])
                .custom_created_at(nostr_sdk::Timestamp::from_secs(created_at))
                .sign_with_keys(keys)
                .expect("signed root")
        };
        let older = root(
            &publisher,
            1_700_000_000,
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        );
        let newer = root(
            &publisher,
            1_700_000_001,
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        );
        let unrelated = root(
            &other,
            1_700_000_002,
            "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        );
        let directory =
            std::env::temp_dir().join(format!("nvpn-update-roots-{}", std::process::id()));
        std::fs::create_dir_all(&directory).expect("cache directory");
        let path = directory.join("control-pubsub-events.json");
        std::fs::write(
            &path,
            serde_json::to_vec(&serde_json::json!({
                "version": 1,
                "events": [older, unrelated, newer],
            }))
            .expect("cache JSON"),
        )
        .expect("write cache");

        let events = load_cached_update_root_events(&path, &reference).expect("load roots");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].created_at.as_secs(), 1_700_000_001);
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn secure_updater_refreshes_relays_even_with_cached_roots() {
        let config = secure_updater_config();

        assert_eq!(config.relays, update_relays());
        assert!(!config.relays.is_empty());
    }
}
