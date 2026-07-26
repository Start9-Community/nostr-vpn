#!/usr/bin/env bash

# Rust provenance and company-signing audits for the exact iOS Release artifact.

ios_release_network_audit_rust_feature_surface() {
  local target_root="${CARGO_TARGET_DIR:-$ROOT/target}"
  [[ "$target_root" = /* ]] || target_root="$ROOT/$target_root"
  local archive="$target_root/aarch64-apple-ios/release/libnostr_vpn_app_core.a"
  local archive_strings archive_symbols dep_file metadata_receipt rebuild_marker
  [[ -s "$archive" ]] || {
    echo "iOS Release Rust archive is missing" >&2
    return 1
  }
  grep -Fq -- '--no-default-features' "$ROOT/tools/run-ios" || {
    echo "iOS Release Rust build does not disable paid-exit/Cashu features" >&2
    return 1
  }
  archive_strings="$(mktemp "${TMPDIR:-/tmp}/nvpn-ios-release-strings.XXXXXX")"
  archive_symbols="$(mktemp "${TMPDIR:-/tmp}/nvpn-ios-release-symbols.XXXXXX")"
  strings "$archive" >"$archive_strings"
  local forbidden
  for forbidden in \
    'nvpn-cashu-wallet' \
    'Cashu wallet worker' \
    'wallet_worker' \
    'cashu_service'
  do
    if grep -Fiq "$forbidden" "$archive_strings"; then
      rm -f "$archive_strings" "$archive_symbols"
      echo "iOS Release Rust archive contains forbidden paid-exit/Cashu worker code" >&2
      return 1
    fi
  done
  local fips_path="${NVPN_FIPS_REPO_PATH%/}"
  nm -arch arm64 -gU "$archive" >"$archive_symbols" 2>/dev/null || {
    rm -f "$archive_strings" "$archive_symbols"
    echo "iOS Release archive symbol audit failed" >&2
    return 1
  }
  if ! grep -Fq "$fips_path/crates/fips-core/src/" "$archive_strings" \
    || ! grep -Fq 'fips_core::node' "$archive_strings" \
    || ! grep -Fq 'fips_core::transport' "$archive_strings" \
    || ! grep -Fq 'fips_core' "$archive_symbols"
  then
    rm -f "$archive_strings" "$archive_symbols"
    echo "iOS Release archive lacks exact-checkout FIPS production code/symbols" >&2
    return 1
  fi
  rm -f "$archive_strings" "$archive_symbols"
  dep_file="$(
    python3 - \
      "$target_root/aarch64-apple-ios/release" \
      "$fips_path/crates/fips-core" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = sys.argv[2]
matches = []
for path in root.rglob("fips_core-*.d"):
    try:
        if expected in path.read_text(encoding="utf-8", errors="ignore"):
            matches.append(path)
    except OSError:
        pass
if matches:
    print(max(matches, key=lambda path: path.stat().st_mtime))
PY
  )"
  if [[ -z "$dep_file" ]]; then
    echo "iOS Release dependency files do not prove the exact local FIPS checkout" >&2
    return 1
  fi
  metadata_receipt="${NVPN_IOS_FIPS_METADATA_RECEIPT:-$ROOT/artifacts/mobile-ios/fips-linkage.json}"
  rebuild_marker="${NVPN_IOS_FIPS_REBUILD_MARKER_DIR:-$ROOT/artifacts/mobile-ios}/fips-rebuild-aarch64-apple-ios.marker"
  if ! python3 - \
    "$metadata_receipt" "$rebuild_marker" "$dep_file" "$archive" \
    "$fips_path" "$NVPN_EXPECTED_FIPS_GIT_SHA" \
    "$IOS_RELEASE_NETWORK_FIPS_TREE" "$NVPN_EXPECTED_FIPS_VERSION" <<'PY'
import json
import hashlib
import os
import sys

(
    receipt_path,
    marker_path,
    dep_path,
    artifact_path,
    checkout,
    head,
    tree,
    version,
) = sys.argv[1:]
receipt = json.load(open(receipt_path, encoding="utf-8"))
checkout_hash = hashlib.sha256(os.path.realpath(checkout).encode()).hexdigest()
if receipt.get("checkoutPathSha256") != checkout_hash:
    raise SystemExit("iOS Cargo metadata receipt has the wrong FIPS path")
if receipt.get("checkoutHead") != head or receipt.get("checkoutTree") != tree:
    raise SystemExit("iOS Cargo metadata receipt has the wrong FIPS tree")
if receipt.get("fipsCoreVersion") != version:
    raise SystemExit("iOS Cargo metadata receipt has the wrong FIPS version")
marker_mtime = os.path.getmtime(marker_path)
if os.path.getmtime(dep_path) < marker_mtime:
    raise SystemExit("iOS fips-core dep-info predates its forced rebuild")
if os.path.getmtime(artifact_path) < marker_mtime:
    raise SystemExit("iOS Release archive predates its forced FIPS rebuild")
PY
  then
    echo "iOS Release FIPS metadata/rebuild receipt failed" >&2
    return 1
  fi
  if [[ "$(git -C "$fips_path" rev-parse HEAD)" \
      != "$NVPN_EXPECTED_FIPS_GIT_SHA" \
    || "$(git -C "$fips_path" rev-parse 'HEAD^{tree}')" \
      != "$IOS_RELEASE_NETWORK_FIPS_TREE" \
    || -n "$(git -C "$fips_path" status --porcelain --untracked-files=all)" ]]
  then
    echo "iOS Release app/FIPS source changed during the artifact build" >&2
    return 1
  fi
  assert_release_checkout_state \
    "$ROOT" "$IOS_RELEASE_NETWORK_APP_HEAD" \
    "$IOS_RELEASE_NETWORK_APP_TREE" "iOS Release artifact build"
}

ios_release_network_app_path() {
  if [[ -n "${NVPN_MOBILE_IOS_RELEASE_APP_PATH:-}" ]]; then
    printf '%s\n' "$NVPN_MOBILE_IOS_RELEASE_APP_PATH"
    return
  fi
  find "$IOS_RELEASE_NETWORK_DERIVED_DATA/Build/Products/Release-iphoneos" \
    -maxdepth 1 -name '*.app' -type d \
    ! -name '*Runner.app' \
    | sort \
    | head -n 1
}

ios_release_network_write_artifact_receipt() {
  python3 - "$@" <<'PY'
import hashlib
import json
import os
import plistlib
import sys

(
    path,
    app_cdhash,
    tunnel_cdhash,
    app_sha,
    tunnel_sha,
    tree_sha,
    app_git_sha,
    fips_git_sha,
    app_info_path,
    installed_apps_path,
    expected_bundle_id,
    selected_device_receipt_path,
    app_path,
    derived_data_path,
    xctestrun_path,
    fips_tree,
    fips_version,
    fips_metadata_sha,
    signer_sha,
) = sys.argv[1:]
app_info = plistlib.load(open(app_info_path, "rb"))
installed_payload = json.load(open(installed_apps_path, encoding="utf-8"))
installed = []


def visit(value):
    if isinstance(value, dict):
        if value.get("bundleIdentifier") == expected_bundle_id:
            installed.append(value)
        for child in value.values():
            visit(child)
    elif isinstance(value, list):
        for child in value:
            visit(child)


visit(installed_payload)
if len(installed) != 1:
    raise SystemExit(f"expected one installed Release app, observed {len(installed)}")
installed_app = installed[0]
if installed_app.get("builtByDeveloper") is not True:
    raise SystemExit("installed iOS Release app is not a developer-supplied artifact")
if installed_app.get("removable") is not True:
    raise SystemExit("installed iOS Release app is not the removable tested artifact")
if str(installed_app.get("version")) != str(
    app_info["CFBundleShortVersionString"]
):
    raise SystemExit("installed iOS marketing version differs from the built app")
if str(installed_app.get("bundleVersion")) != str(
    app_info["CFBundleVersion"]
):
    raise SystemExit("installed iOS build number differs from the built app")
selected_device = json.load(
    open(selected_device_receipt_path, encoding="utf-8")
)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "appCodeDirectoryHash": app_cdhash,
            "appExecutableSha256": app_sha,
            "appGitSha": app_git_sha,
            "appPathSha256": hashlib.sha256(
                os.path.realpath(app_path).encode()
            ).hexdigest(),
            "artifactType": "iOS company Ad Hoc Release app",
            "cashuAndPaidExitCompiled": False,
            "debuggable": False,
            "derivedDataPathSha256": hashlib.sha256(
                os.path.realpath(derived_data_path).encode()
            ).hexdigest(),
            "fipsGitSha": fips_git_sha,
            "fipsGitTree": fips_tree,
            "fipsCoreVersion": fips_version,
            "fipsCargoMetadataReceiptSha256": fips_metadata_sha,
            "fipsDependenciesForcedRebuilt": True,
            "packetTunnelCodeDirectoryHash": tunnel_cdhash,
            "packetTunnelExecutableSha256": tunnel_sha,
            "companySigningVerified": True,
            "signerCertificateSha256": signer_sha,
            "selectedPhysicalDevice": selected_device,
            "treeSha256": tree_sha,
            "xctestrunPathSha256": hashlib.sha256(
                os.path.realpath(xctestrun_path).encode()
            ).hexdigest(),
            "installedBundleIdentifier": expected_bundle_id,
            "installedBuildNumber": str(installed_app["bundleVersion"]),
            "installedMarketingVersion": str(installed_app["version"]),
        },
        handle,
        indent=2,
        sort_keys=True,
    )
    handle.write("\n")
PY
}

ios_release_network_audit_artifact() {
  local label="$1" result_dir="$2"
  local app appex executable tunnel_executable receipt
  app="$(ios_release_network_app_path)"
  appex="$app/PlugIns/Nostr VPN Tunnel.appex"
  executable="$app/Nostr VPN"
  tunnel_executable="$appex/Nostr VPN Tunnel"
  [[ -d "$app" && -d "$appex" && -x "$executable" && -x "$tunnel_executable" ]] || {
    echo "iOS Release app/Packet Tunnel artifact is incomplete" >&2
    return 1
  }
  codesign --verify --deep --strict "$app" >/dev/null 2>&1 || {
    echo "iOS Release app signature verification failed" >&2
    return 1
  }

  local audit_dir app_details tunnel_details app_profile tunnel_profile
  local installed_apps app_entitlements tunnel_entitlements certificate_prefix
  local tunnel_certificate_prefix signer_sha_path signer_sha
  audit_dir="$(
    mktemp -d "$IOS_RELEASE_NETWORK_SIGNING_DIR/artifact-audit.XXXXXX"
  )" \
    || return 1
  chmod 700 "$audit_dir" || {
    rm -rf "$audit_dir"
    return 1
  }
  app_details="$audit_dir/app-codesign.txt"
  tunnel_details="$audit_dir/tunnel-codesign.txt"
  app_profile="$audit_dir/app-profile.plist"
  tunnel_profile="$audit_dir/tunnel-profile.plist"
  app_entitlements="$audit_dir/app-entitlements.plist"
  tunnel_entitlements="$audit_dir/tunnel-entitlements.plist"
  certificate_prefix="$audit_dir/app-cert"
  tunnel_certificate_prefix="$audit_dir/tunnel-cert"
  installed_apps="$audit_dir/installed-apps.json"
  signer_sha_path="$audit_dir/signer.sha256"
  if ! codesign -dvvv "$app" >"$app_details" 2>&1 \
    || ! codesign -dvvv "$appex" >"$tunnel_details" 2>&1 \
    || ! security cms -D -i "$app/embedded.mobileprovision" >"$app_profile" \
    || ! security cms -D -i "$appex/embedded.mobileprovision" >"$tunnel_profile" \
    || ! codesign -d --entitlements :- "$app" >"$app_entitlements" 2>/dev/null \
    || ! codesign -d --entitlements :- "$appex" >"$tunnel_entitlements" 2>/dev/null \
    || ! codesign -d --extract-certificates "$certificate_prefix" "$app" \
      >/dev/null 2>&1 \
    || ! codesign -d --extract-certificates "$tunnel_certificate_prefix" "$appex" \
      >/dev/null 2>&1
  then
    rm -rf "$audit_dir"
    echo "iOS Release signing artifact extraction failed" >&2
    return 1
  fi
  if ! xcrun devicectl device info apps \
    --device "$IOS_RELEASE_NETWORK_DEVICE" \
    --bundle-id "$IOS_BUNDLE_ID" \
    --columns '*' \
    --json-output "$installed_apps" \
    --quiet >/dev/null
  then
    rm -rf "$audit_dir"
    echo "iOS Release installed-app readback failed" >&2
    return 1
  fi

  if ! python3 - \
    "$app_profile" "$tunnel_profile" "$app_entitlements" \
    "$tunnel_entitlements" "${certificate_prefix}0" \
    "${tunnel_certificate_prefix}0" "$NVPN_IOS_TEAM_ID" \
    "${NVPN_IOS_EXPECTED_SIGNER_ORGANIZATION:-Sirius Business Oy}" \
    "$IOS_BUNDLE_ID" \
    "${NVPN_IOS_PACKET_TUNNEL_BUNDLE_ID:-${IOS_BUNDLE_ID}.PacketTunnel}" \
    "$NVPN_EXPECTED_IOS_DISTRIBUTION_CERT_SHA256" "$signer_sha_path" <<'PY'
import hashlib
import plistlib
import sys

(
    app_profile_path,
    tunnel_profile_path,
    app_entitlements_path,
    tunnel_entitlements_path,
    app_certificate_path,
    tunnel_certificate_path,
    team_id,
    expected_organization,
    app_bundle_id,
    tunnel_bundle_id,
    expected_signer_sha,
    signer_sha_path,
) = sys.argv[1:]
app_profile, tunnel_profile, app_entitlements, tunnel_entitlements = [
    plistlib.load(open(path, "rb"))
    for path in (
        app_profile_path,
        tunnel_profile_path,
        app_entitlements_path,
        tunnel_entitlements_path,
    )
]
app_certificate = open(app_certificate_path, "rb").read()
tunnel_certificate = open(tunnel_certificate_path, "rb").read()
if app_certificate != tunnel_certificate:
    raise SystemExit("app and Packet Tunnel use different signing certificates")
actual_signer_sha = hashlib.sha256(app_certificate).hexdigest()
if actual_signer_sha != expected_signer_sha:
    raise SystemExit("Release signer does not match the required certificate pin")

try:
    from cryptography import x509
    from cryptography.x509.oid import NameOID
except ImportError as error:
    raise SystemExit("cryptography is required for signer verification") from error

certificate = x509.load_der_x509_certificate(app_certificate)
organizations = certificate.subject.get_attributes_for_oid(
    NameOID.ORGANIZATION_NAME
)
organizational_units = certificate.subject.get_attributes_for_oid(
    NameOID.ORGANIZATIONAL_UNIT_NAME
)
if [entry.value for entry in organizations] != [expected_organization]:
    raise SystemExit("Release signer is not the expected company organization")
if team_id not in [entry.value for entry in organizational_units]:
    raise SystemExit("Release signer does not belong to the expected company team")

for profile, bundle_id in (
    (app_profile, app_bundle_id),
    (tunnel_profile, tunnel_bundle_id),
):
    if not profile.get("ProvisionedDevices"):
        raise SystemExit("Ad Hoc profile has no provisioned device")
    if profile.get("ProvisionsAllDevices") is True:
        raise SystemExit("physical Release gate received an enterprise profile")
    if profile.get("Entitlements", {}).get("get-task-allow") is True:
        raise SystemExit("physical Release profile is debuggable")
    if profile.get("TeamIdentifier") != [team_id]:
        raise SystemExit("Ad Hoc profile belongs to the wrong Apple team")
    profile_entitlements = profile.get("Entitlements", {})
    if profile_entitlements.get("com.apple.developer.team-identifier") != team_id:
        raise SystemExit("Ad Hoc profile entitlement belongs to the wrong Apple team")
    if profile_entitlements.get("application-identifier") != f"{team_id}.{bundle_id}":
        raise SystemExit("Ad Hoc profile application identifier is wrong")
    signer_sha = hashlib.sha256(app_certificate).digest()
    profile_signers = {
        hashlib.sha256(value).digest()
        for value in profile.get("DeveloperCertificates", [])
    }
    if signer_sha not in profile_signers:
        raise SystemExit("Ad Hoc profile does not authorize the exact signer")
for entitlements, bundle_id in (
    (app_entitlements, app_bundle_id),
    (tunnel_entitlements, tunnel_bundle_id),
):
    if entitlements.get("get-task-allow") is True:
        raise SystemExit("signed physical Release artifact is debuggable")
    if entitlements.get("com.apple.developer.team-identifier") != team_id:
        raise SystemExit("signed Release artifact belongs to the wrong Apple team")
    if entitlements.get("application-identifier") != f"{team_id}.{bundle_id}":
        raise SystemExit("signed Release application identifier is wrong")
if not tunnel_entitlements.get("com.apple.developer.networking.networkextension"):
    raise SystemExit("Packet Tunnel entitlement is missing")
with open(signer_sha_path, "w", encoding="ascii") as handle:
    handle.write(actual_signer_sha + "\n")
PY
  then
    rm -rf "$audit_dir"
    return 1
  fi
  signer_sha="$(<"$signer_sha_path")"
  [[ "$signer_sha" =~ ^[0-9a-f]{64}$ ]] || {
    rm -rf "$audit_dir"
    echo "iOS Release signer audit produced no certificate receipt" >&2
    return 1
  }

  local app_cdhash tunnel_cdhash app_sha tunnel_sha tree_sha
  app_cdhash="$(sed -n 's/^CDHash=//p' "$app_details" | head -n 1)"
  tunnel_cdhash="$(sed -n 's/^CDHash=//p' "$tunnel_details" | head -n 1)"
  [[ "$app_cdhash" =~ ^[0-9a-fA-F]+$ \
    && "$tunnel_cdhash" =~ ^[0-9a-fA-F]+$ ]] || {
    rm -rf "$audit_dir"
    echo "iOS Release artifact has no CodeDirectory hash receipt" >&2
    return 1
  }
  if [[ -n "$IOS_RELEASE_NETWORK_BASE_CDHASH" \
    && "$IOS_RELEASE_NETWORK_BASE_CDHASH" != "$app_cdhash" ]]
  then
    rm -rf "$audit_dir"
    echo "iOS DNS cases did not test one exact Release app artifact" >&2
    return 1
  fi
  if ! app_sha="$(shasum -a 256 "$executable" | awk '{print $1}')" \
    || ! tunnel_sha="$(shasum -a 256 "$tunnel_executable" | awk '{print $1}')" \
    || ! tree_sha="$(
    find "$app" -type f -print \
      | sort \
      | while IFS= read -r file; do shasum -a 256 "$file"; done \
      | shasum -a 256 \
      | awk '{print $1}'
    )"
  then
    rm -rf "$audit_dir"
    echo "iOS Release artifact hashing failed" >&2
    return 1
  fi
  [[ "$app_sha" =~ ^[0-9a-f]{64}$ \
    && "$tunnel_sha" =~ ^[0-9a-f]{64}$ \
    && "$tree_sha" =~ ^[0-9a-f]{64}$ ]] || {
    rm -rf "$audit_dir"
    echo "iOS Release artifact hashing produced an invalid receipt" >&2
    return 1
  }
  if [[ -n "$IOS_RELEASE_NETWORK_BASE_TREE_SHA" \
    && "$IOS_RELEASE_NETWORK_BASE_TREE_SHA" != "$tree_sha" ]]
  then
    rm -rf "$audit_dir"
    echo "iOS DNS cases did not test one byte-identical Release app tree" >&2
    return 1
  fi
  IOS_RELEASE_NETWORK_BASE_CDHASH="$app_cdhash"
  IOS_RELEASE_NETWORK_BASE_TREE_SHA="$tree_sha"
  receipt="${NVPN_MOBILE_IOS_RELEASE_RECEIPT:-$result_dir/mobile-ios-release-artifact.json}"
  local fips_metadata_receipt fips_metadata_sha
  fips_metadata_receipt="${NVPN_IOS_FIPS_METADATA_RECEIPT:-$ROOT/artifacts/mobile-ios/fips-linkage.json}"
  if ! fips_metadata_sha="$(
    shasum -a 256 "$fips_metadata_receipt" | awk '{print $1}'
  )" || [[ ! "$fips_metadata_sha" =~ ^[0-9a-f]{64}$ ]]
  then
    rm -rf "$audit_dir"
    echo "iOS Release FIPS metadata receipt hashing failed" >&2
    return 1
  fi
  mkdir -p "$(dirname "$receipt")"
  if ! ios_release_network_write_artifact_receipt \
    "$receipt" "$app_cdhash" "$tunnel_cdhash" "$app_sha" \
    "$tunnel_sha" "$tree_sha" "$NVPN_BUILD_GIT_SHA" \
    "$NVPN_EXPECTED_FIPS_GIT_SHA" "$app/Info.plist" \
    "$installed_apps" "$IOS_BUNDLE_ID" "$IOS_RELEASE_NETWORK_DEVICE_RECEIPT" "$app" \
    "$IOS_RELEASE_NETWORK_DERIVED_DATA" "$IOS_RELEASE_NETWORK_XCTESTRUN" \
    "$IOS_RELEASE_NETWORK_FIPS_TREE" "$NVPN_EXPECTED_FIPS_VERSION" \
    "$fips_metadata_sha" "$signer_sha"
  then
    rm -f "$receipt"
    rm -rf "$audit_dir"
    echo "iOS Release artifact receipt generation failed" >&2
    return 1
  fi
  if ! rm -rf "$audit_dir"; then
    rm -f "$receipt"
    echo "iOS Release artifact audit could not scrub private signing data" >&2
    return 1
  fi
  echo "iOS exact company-signed Release artifact passed: $receipt"
}
