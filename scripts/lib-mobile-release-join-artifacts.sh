#!/usr/bin/env bash

# Exact artifact preparation and installation for the physical Release join
# gate. Callers provide ROOT, RESULT_DIR, IOS_DEVICE, ANDROID_SERIAL and ADB.

RELEASE_JOIN_ARTIFACTS_VALIDATED=0
RELEASE_JOIN_DEVICE_MUTATION_ALLOWED=0
RELEASE_JOIN_DEVICE_MUTATED=0

release_join_reuse_artifacts() {
  case "${NVPN_RELEASE_JOIN_REUSE_ARTIFACTS:-0}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On) return 0 ;;
    *) return 1 ;;
  esac
}

release_join_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

release_join_record_selected_devices() {
  local expected_name="${NVPN_EXPECTED_IOS_DEVICE_NAME:-}"
  local expected_android_model="${NVPN_EXPECTED_ANDROID_DEVICE_MODEL:-}"
  local details="$PRIVATE_DIR/ios-selected-device.json"
  local android_manufacturer android_model android_product
  [[ -n "$expected_name" ]] || {
    echo "Release join gate requires NVPN_EXPECTED_IOS_DEVICE_NAME" >&2
    return 1
  }
  [[ -n "$expected_android_model" ]] || {
    echo "Release join gate requires NVPN_EXPECTED_ANDROID_DEVICE_MODEL" >&2
    return 1
  }
  xcrun devicectl device info details \
    --device "$IOS_DEVICE" \
    --json-output "$details" \
    --quiet >/dev/null
  android_manufacturer="$(
    "${ADB[@]}" shell getprop ro.product.manufacturer | tr -d '\r'
  )"
  android_model="$("${ADB[@]}" shell getprop ro.product.model | tr -d '\r')"
  android_product="$("${ADB[@]}" shell getprop ro.product.name | tr -d '\r')"
  [[ -n "$android_model" && -n "$android_product" ]] || {
    echo "Selected Android phone did not report its model" >&2
    return 1
  }
  python3 - \
    "$details" \
    "$RESULT_DIR/selected-physical-devices.json" \
    "$expected_name" \
    "$expected_android_model" \
    "$android_manufacturer" \
    "$android_model" \
    "$android_product" <<'PY'
import json
import sys

(
    source,
    output,
    expected,
    expected_android_model,
    android_manufacturer,
    android_model,
    android_product,
) = sys.argv[1:]
payload = json.load(open(source, encoding="utf-8"))
result = payload.get("result", {})
device = result.get("deviceProperties", {})
hardware = result.get("hardwareProperties", {})
name = device.get("name")
marketing_name = hardware.get("marketingName")
product_type = hardware.get("productType") or hardware.get("thinningProductType")
hardware_model = hardware.get("hardwareModel")
if name != expected:
    raise SystemExit(
        f"selected iPhone name mismatch: expected {expected!r}, got {name!r}"
    )
if not isinstance(marketing_name, str) or not marketing_name.strip():
    raise SystemExit("selected iPhone did not report a marketing model")
if not isinstance(product_type, str) or not product_type.strip():
    raise SystemExit("selected iPhone did not report a product type")
if android_model != expected_android_model:
    raise SystemExit(
        "selected Android model mismatch: "
        f"expected {expected_android_model!r}, got {android_model!r}"
    )
receipt = {
    "explicitSelectionRequired": True,
    "ios": {
        "deviceName": name,
        "expectedDeviceNameMatched": True,
        "marketingName": marketing_name,
        "productType": product_type,
        "hardwareModel": hardware_model or "",
    },
    "android": {
        "manufacturer": android_manufacturer,
        "model": android_model,
        "expectedModelMatched": True,
        "productName": android_product,
    },
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

release_join_require_clean_fips() {
  : "${NVPN_FIPS_REPO_PATH:?Release join gate requires NVPN_FIPS_REPO_PATH}"
  [[ "${NVPN_EXPECTED_FIPS_GIT_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Release join gate requires an exact NVPN_EXPECTED_FIPS_GIT_SHA" >&2
    return 1
  }
  [[ -f "$NVPN_FIPS_REPO_PATH/crates/fips-core/Cargo.toml" ]] || {
    echo "Release join gate requires a FIPS source checkout" >&2
    return 1
  }
  RELEASE_JOIN_FIPS_SHA="$(git -C "$NVPN_FIPS_REPO_PATH" rev-parse HEAD)"
  RELEASE_JOIN_FIPS_TREE="$(git -C "$NVPN_FIPS_REPO_PATH" rev-parse HEAD^{tree})"
  [[ -z "$(git -C "$NVPN_FIPS_REPO_PATH" status --porcelain --untracked-files=all)" ]] || {
    echo "Release join gate refuses a dirty FIPS checkout" >&2
    return 1
  }
  if [[ "$RELEASE_JOIN_FIPS_SHA" != "$NVPN_EXPECTED_FIPS_GIT_SHA" ]]; then
    echo "Release join FIPS mismatch: expected $NVPN_EXPECTED_FIPS_GIT_SHA, got $RELEASE_JOIN_FIPS_SHA" >&2
    return 1
  fi
  RELEASE_JOIN_FIPS_VERSION="$(
    awk '
      $0 == "[package]" { package = 1; next }
      package && /^\[/ { exit }
      package && /^version = "/ {
        value = $0
        sub(/^version = "/, "", value)
        sub(/".*$/, "", value)
        print value
        exit
      }
    ' "$NVPN_FIPS_REPO_PATH/crates/fips-core/Cargo.toml"
  )"
  [[ "$RELEASE_JOIN_FIPS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || {
    echo "Release join gate could not derive the exact FIPS package version" >&2
    return 1
  }
  export RELEASE_JOIN_FIPS_SHA RELEASE_JOIN_FIPS_TREE
  export RELEASE_JOIN_FIPS_VERSION
}

release_join_assert_fips_unchanged() {
  [[ "$(git -C "$NVPN_FIPS_REPO_PATH" rev-parse HEAD)" == "$RELEASE_JOIN_FIPS_SHA" \
    && "$(git -C "$NVPN_FIPS_REPO_PATH" rev-parse HEAD^{tree})" == "$RELEASE_JOIN_FIPS_TREE" \
    && -z "$(git -C "$NVPN_FIPS_REPO_PATH" status --porcelain --untracked-files=all)" ]] || {
    echo "FIPS source changed while building Release join artifacts" >&2
    return 1
  }
}

release_join_require_device_mutation_allowed() {
  if release_join_reuse_artifacts \
    && [[ "$RELEASE_JOIN_ARTIFACTS_VALIDATED" -ne 1 ]]
  then
    echo "Strict Release join artifacts were not validated before device mutation" >&2
    return 1
  fi
  [[ "$RELEASE_JOIN_DEVICE_MUTATION_ALLOWED" -eq 1 ]] || {
    echo "Release join device mutation was not armed" >&2
    return 1
  }
}

release_join_assert_app_unchanged() {
  local expected_sha="$1" expected_tree="$2"
  assert_release_checkout_state \
    "$ROOT" "$expected_sha" "$expected_tree" \
    "Application Release artifact build" || {
    echo "Application candidate changed while building Release join artifacts" >&2
    return 1
  }
}

release_join_android_apksigner() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  find "$sdk/build-tools" -type f -name apksigner 2>/dev/null \
    | sort -V \
    | tail -n 1
}

release_join_assert_one_android_package() {
  local package="${NVPN_DEFAULT_APP_ID:-fi.siriusbusiness.nvpn}" unexpected
  unexpected="$(
    "${ADB[@]}" shell pm list packages \
      | tr -d '\r' \
      | sed -n 's/^package://p' \
      | awk -v canonical="$package" '
          $0 == "org.nostrvpn.app"
          || ($0 ~ /^fi\.siriusbusiness\.nvpn(\.|$)/ && $0 != canonical)
        '
  )"
  [[ -z "$unexpected" ]] || {
    echo "Parallel/stale Android nVPN package remains installed" >&2
    return 1
  }
  "${ADB[@]}" shell pm path "$package" >/dev/null 2>&1 || {
    echo "Canonical Android Release package is not installed" >&2
    return 1
  }
}

release_join_assert_one_android_process() {
  local package="${NVPN_DEFAULT_APP_ID:-fi.siriusbusiness.nvpn}" pids
  pids="$("${ADB[@]}" shell pidof "$package" 2>/dev/null | tr -d '\r' | xargs)"
  [[ -n "$pids" && "$(wc -w <<<"$pids" | tr -d ' ')" == 1 ]] || {
    echo "Android Release gate requires exactly one canonical app process; got: ${pids:-none}" >&2
    return 1
  }
}

release_join_reset_android_state() {
  local package="${NVPN_DEFAULT_APP_ID:-fi.siriusbusiness.nvpn}"
  release_join_require_device_mutation_allowed || return 1
  [[ "${NVPN_RELEASE_JOIN_ALLOW_DEVICE_RESET:-}" == "YES" ]] || {
    echo "Set NVPN_RELEASE_JOIN_ALLOW_DEVICE_RESET=YES for destructive physical join coverage" >&2
    return 1
  }
  "${ADB[@]}" shell am force-stop "$package" >/dev/null 2>&1 || true
  "${ADB[@]}" shell pm clear "$package" >/dev/null
  release_join_assert_one_android_package
}

release_join_prepare_android_release() {
  local package="${NVPN_DEFAULT_APP_ID:-fi.siriusbusiness.nvpn}"
  local apk="$ROOT/android/app/build/outputs/apk/release/app-release.apk"
  local apksigner remote_path pulled apk_sha installed_sha cert_sha cert_sha_lower app_sha app_tree
  local expected_android_cert="${NVPN_EXPECTED_ANDROID_SIGNER_CERT_SHA256:-}"
  local preexisting_package=false
  if release_join_reuse_artifacts; then
    [[ "$RELEASE_JOIN_ARTIFACTS_VALIDATED" -eq 1 \
      && -f "$RELEASE_JOIN_ANDROID_APK" ]] || {
      echo "Strict Android Release artifact was not prevalidated" >&2
      return 1
    }
    apk="$RELEASE_JOIN_ANDROID_APK"
    app_sha="$RELEASE_JOIN_APP_SHA"
    app_tree="$RELEASE_JOIN_APP_TREE"
    cert_sha_lower="$RELEASE_JOIN_ANDROID_SIGNER_SHA"
  else
    for name in ANDROID_KEYSTORE_PATH ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
      [[ -n "${!name:-}" ]] || {
        echo "Release join gate requires $name" >&2
        return 1
      }
    done
    [[ -f "$ANDROID_KEYSTORE_PATH" ]] || {
      echo "Android release keystore does not exist" >&2
      return 1
    }
    app_sha="$(git -C "$ROOT" rev-parse HEAD)"
    app_tree="$(git -C "$ROOT" rev-parse HEAD^{tree})"
    NVPN_IOS_RUST_PROFILE=release \
      NVPN_BUILD_GIT_SHA="$app_sha" \
      NVPN_FIPS_REPO_PATH="$NVPN_FIPS_REPO_PATH" \
      NVPN_ANDROID_PACKAGE="$package" \
      "$ROOT/tools/run-android" release
    [[ -f "$apk" ]] || {
      echo "Android Release APK was not built" >&2
      return 1
    }
    apksigner="$(release_join_android_apksigner)"
    [[ -x "$apksigner" ]] || {
      echo "Android apksigner is unavailable" >&2
      return 1
    }
    "$apksigner" verify "$apk" >/dev/null
    cert_sha="$(
      "$apksigner" verify --print-certs "$apk" \
        | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' \
        | head -n 1
    )"
    [[ "$cert_sha" =~ ^[0-9A-Fa-f]{64}$ ]] || {
      echo "Android Release APK has no signer certificate receipt" >&2
      return 1
    }
    cert_sha_lower="$(printf '%s' "$cert_sha" | tr '[:upper:]' '[:lower:]')"
    expected_android_cert="$(
      printf '%s' "$expected_android_cert" \
        | tr -d ':[:space:]' \
        | tr '[:upper:]' '[:lower:]'
    )"
    [[ "$expected_android_cert" =~ ^[0-9a-f]{64}$ ]] || {
      echo "Release join gate requires NVPN_EXPECTED_ANDROID_SIGNER_CERT_SHA256" >&2
      return 1
    }
    [[ "$cert_sha_lower" == "$expected_android_cert" ]] || {
      echo "Android Release APK was not signed by the expected company key" >&2
      return 1
    }
  fi

  release_join_require_device_mutation_allowed || return 1
  RELEASE_JOIN_DEVICE_MUTATED=1
  if "${ADB[@]}" shell pm path "$package" >/dev/null 2>&1; then
    preexisting_package=true
  fi
  # Install twice. The second operation is necessarily an in-place replacement
  # of the canonical package, even on a phone that began this gate clean.
  "${ADB[@]}" install -r "$apk" >/dev/null
  release_join_assert_one_android_package
  "${ADB[@]}" install -r "$apk" >/dev/null
  release_join_assert_one_android_package
  remote_path="$(
    "${ADB[@]}" shell pm path "$package" \
      | tr -d '\r' \
      | sed -n 's/^package://p' \
      | head -n 1
  )"
  pulled="$(mktemp "${TMPDIR:-/tmp}/nvpn-release-installed.XXXXXX.apk")"
  "${ADB[@]}" pull "$remote_path" "$pulled" >/dev/null
  apk_sha="$(release_join_sha256 "$apk")"
  installed_sha="$(release_join_sha256 "$pulled")"
  rm -f "$pulled"
  [[ "$apk_sha" == "$installed_sha" ]] || {
    echo "Installed Android package bytes differ from the Release APK" >&2
    return 1
  }
  if "${ADB[@]}" shell dumpsys package "$package" \
      | sed -n '/^[[:space:]]*flags=/{p;q;}' \
      | grep -qw DEBUGGABLE; then
    echo "Installed Android app is debuggable" >&2
    return 1
  fi
  "${ADB[@]}" shell am force-stop "$package"
  "${ADB[@]}" shell monkey -p "$package" -c android.intent.category.LAUNCHER 1 >/dev/null
  sleep 1
  release_join_assert_one_android_process
  release_join_assert_fips_unchanged
  release_join_assert_app_unchanged "$app_sha" "$app_tree"

  RELEASE_JOIN_ANDROID_APK="$apk"
  RELEASE_JOIN_ANDROID_APK_SHA="$apk_sha"
  export RELEASE_JOIN_ANDROID_APK RELEASE_JOIN_ANDROID_APK_SHA
  python3 - \
    "$RESULT_DIR/android-release-install.json" \
    "$apk_sha" "$cert_sha_lower" "$app_sha" "$app_tree" \
    "$RELEASE_JOIN_FIPS_SHA" "$RELEASE_JOIN_FIPS_TREE" "$package" \
    "$preexisting_package" <<'PY'
import json
import sys

path, apk, cert, app, app_tree, fips, fips_tree, package, preexisting = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "artifact": "Android Release APK",
            "apkSha256": apk,
            "installedApkSha256": apk,
            "signerCertificateSha256": cert,
            "appGitSha": app,
            "appGitTree": app_tree,
            "fipsGitSha": fips,
            "fipsGitTree": fips_tree,
            "package": package,
            "preexistingCanonicalPackage": preexisting == "true",
            "replacementInstall": True,
            "replacementInstallVerified": True,
            "debuggable": False,
            "canonicalPackageCount": 1,
            "canonicalProcessCount": 1,
        },
        handle,
        indent=2,
        sort_keys=True,
    )
    handle.write("\n")
PY
}

release_join_ios_profile_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

release_join_codesign_team() {
  codesign -dvv "$1" 2>&1 \
    | sed -n 's/^TeamIdentifier=//p' \
    | head -n 1
}

release_join_codesign_certificate_sha256() {
  local bundle="$1" certificate_dir prefix certificate
  certificate_dir="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-signing-cert.XXXXXX")"
  prefix="$certificate_dir/certificate"
  codesign -d --extract-certificates "$prefix" "$bundle" >/dev/null 2>&1
  certificate="${prefix}0"
  [[ -f "$certificate" ]] || {
    rm -rf "$certificate_dir"
    return 1
  }
  release_join_sha256 "$certificate"
  rm -rf "$certificate_dir"
}

release_join_ios_tree_receipt() {
  python3 - "$1" "$2" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
entries = []
for path in sorted(item for item in root.rglob("*") if item.is_file()):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    entries.append({"path": str(path.relative_to(root)), "sha256": digest, "size": path.stat().st_size})
canonical = json.dumps(entries, separators=(",", ":"), sort_keys=True).encode()
receipt = {
    "bundleManifestSha256": hashlib.sha256(canonical).hexdigest(),
    "files": entries,
}
output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(receipt["bundleManifestSha256"])
PY
}

release_join_prepare_ios_profiles() {
  local udid="$1" profile_dir="$RESULT_DIR/ios-signing"
  local profile_env="$profile_dir/provisioning.env"
  mkdir -p "$profile_dir"
  NVPN_IOS_PROFILE_TYPE=IOS_APP_ADHOC \
    NVPN_IOS_PROFILE_NAME="Nostr VPN Ad Hoc Release join gate" \
    NVPN_IOS_PACKET_TUNNEL_PROFILE_NAME="Nostr VPN Ad Hoc Release join tunnel" \
    NVPN_IOS_CODE_SIGN_IDENTITY="Apple Distribution" \
    NVPN_IOS_DEVICE_UDIDS="$udid" \
    NVPN_IOS_PROFILES_ENV_PATH="$profile_env" \
    "$ROOT/scripts/ios-profiles" ensure >"$profile_dir/profile-setup.log" 2>&1
  # shellcheck disable=SC1090
  source "$profile_env"
  : "${NVPN_IOS_CODE_SIGN_IDENTITY:?Ad Hoc signing identity missing}"
  : "${NVPN_IOS_PROVISIONING_PROFILE_UUID:?Ad Hoc app profile missing}"
  : "${NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID:?Ad Hoc tunnel profile missing}"
}

release_join_install_ios_release() {
  local app_path="$1" app_sha="$2" app_tree="$3" manifest_sha="$4"
  local team_hash="$5" app_cert="$6" derived="$7" udid="$8"
  local bundle="${NVPN_DEFAULT_IOS_BUNDLE_ID:-fi.siriusbusiness.nvpn}"
  local installed_json="$RESULT_DIR/ios-installed-apps.json"
  local installed_receipt="$RESULT_DIR/ios-release-install.json"
  release_join_require_device_mutation_allowed || return 1
  RELEASE_JOIN_DEVICE_MUTATED=1
  xcrun devicectl device uninstall app \
    --device "$IOS_DEVICE" "$bundle" --quiet >/dev/null 2>&1 || true
  xcrun devicectl device install app \
    --device "$IOS_DEVICE" "$app_path" --quiet
  xcrun devicectl device info apps \
    --device "$IOS_DEVICE" \
    --json-output "$installed_json" \
    --quiet
  python3 - \
    "$installed_json" "$installed_receipt" "$bundle" "$manifest_sha" \
    "$app_sha" "$app_tree" "$RELEASE_JOIN_FIPS_SHA" \
    "$RELEASE_JOIN_FIPS_TREE" "$RELEASE_JOIN_FIPS_VERSION" \
    "$team_hash" "$app_cert" <<'PY'
import json
import sys

(
    source,
    output,
    bundle,
    manifest,
    app,
    app_tree,
    fips,
    fips_tree,
    fips_version,
    team_hash,
    cert,
) = sys.argv[1:]
payload = json.load(open(source, encoding="utf-8"))
matches = []


def visit(value):
    if isinstance(value, dict):
        if value.get("bundleIdentifier") == bundle:
            matches.append(value)
        for child in value.values():
            visit(child)
    elif isinstance(value, list):
        for child in value:
            visit(child)


visit(payload)
if len(matches) != 1:
    raise SystemExit(f"expected one installed iOS app for {bundle}, found {len(matches)}")
item = matches[0]
receipt = {
    "artifact": "iOS Ad Hoc Release app",
    "bundleIdentifier": bundle,
    "bundleManifestSha256": manifest,
    "installedVersion": item.get("version") or item.get("bundleVersion") or "",
    "installedShortVersion": item.get("shortVersion") or item.get("bundleShortVersion") or "",
    "appGitSha": app,
    "appGitTree": app_tree,
    "fipsGitSha": fips,
    "fipsGitTree": fips_tree,
    "fipsCoreVersion": fips_version,
    "signingTeamSha256": team_hash,
    "signerCertificateSha256": cert,
    "appAndPacketTunnelSignerMatch": True,
    "distribution": "Ad Hoc",
    "configuration": "Release",
    "debugAutomation": False,
    "installedBundleCount": 1,
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  RELEASE_JOIN_IOS_DERIVED_DATA="$derived"
  RELEASE_JOIN_IOS_APP_PATH="$app_path"
  RELEASE_JOIN_IOS_UDID="$udid"
  export RELEASE_JOIN_IOS_DERIVED_DATA RELEASE_JOIN_IOS_APP_PATH
  export RELEASE_JOIN_IOS_UDID
}

release_join_prepare_ios_release() {
  local bundle="${NVPN_DEFAULT_IOS_BUNDLE_ID:-fi.siriusbusiness.nvpn}"
  local tunnel="$bundle.PacketTunnel"
  local group="group.$bundle.shared"
  local team="${NVPN_IOS_TEAM_ID:?Release join gate requires NVPN_IOS_TEAM_ID}"
  local expected_team="${NVPN_EXPECTED_IOS_DISTRIBUTION_TEAM_ID:-}"
  local expected_cert="${NVPN_EXPECTED_IOS_DISTRIBUTION_CERT_SHA256:-}"
  local udid app_path app_binary tunnel_app tunnel_binary profile_plist tunnel_profile_plist
  local app_signed_team tunnel_signed_team app_cert tunnel_cert team_hash
  local derived="$RESULT_DIR/ios-derived-data"
  local app_sha app_tree manifest_sha
  if release_join_reuse_artifacts; then
    [[ "$RELEASE_JOIN_ARTIFACTS_VALIDATED" -eq 1 \
      && -d "$RELEASE_JOIN_IOS_APP_PATH" \
      && -d "$RELEASE_JOIN_IOS_DERIVED_DATA" \
      && -s "$RELEASE_JOIN_IOS_XCTESTRUN" ]] || {
      echo "Strict iOS Release artifact was not prevalidated" >&2
      return 1
    }
    team_hash="$(
      printf '%s' "$expected_team" | shasum -a 256 | awk '{print $1}'
    )"
    release_join_install_ios_release \
      "$RELEASE_JOIN_IOS_APP_PATH" \
      "$RELEASE_JOIN_APP_SHA" \
      "$RELEASE_JOIN_APP_TREE" \
      "$RELEASE_JOIN_IOS_APP_TREE_SHA" \
      "$team_hash" \
      "$RELEASE_JOIN_IOS_APP_CERT" \
      "$RELEASE_JOIN_IOS_DERIVED_DATA" \
      "$RELEASE_JOIN_IOS_UDID"
    return
  fi
  [[ -n "$expected_team" && "$team" == "$expected_team" ]] || {
    echo "NVPN_IOS_TEAM_ID is not the explicitly expected company distribution team" >&2
    return 1
  }
  expected_cert="$(
    printf '%s' "$expected_cert" \
      | tr -d ':[:space:]' \
      | tr '[:upper:]' '[:lower:]'
  )"
  [[ "$expected_cert" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Release join gate requires NVPN_EXPECTED_IOS_DISTRIBUTION_CERT_SHA256" >&2
    return 1
  }
  udid="$(resolve_physical_ios_udid "$IOS_DEVICE")"
  release_join_prepare_ios_profiles "$udid"
  app_sha="$(git -C "$ROOT" rev-parse HEAD)"
  app_tree="$(git -C "$ROOT" rev-parse HEAD^{tree})"

  export NVPN_IOS_BUNDLE_ID="$bundle"
  export NVPN_IOS_PACKET_TUNNEL_BUNDLE_ID="$tunnel"
  export NVPN_IOS_APP_GROUP_IDENTIFIER="$group"
  NVPN_IOS_RUST_PROFILE=release \
    NVPN_BUILD_GIT_SHA="$app_sha" \
    NVPN_FIPS_REPO_PATH="$NVPN_FIPS_REPO_PATH" \
    "$ROOT/tools/run-ios" xcframework
  "$ROOT/tools/run-ios" project
  xcodebuild \
    -quiet \
    -allowProvisioningUpdates \
    -project "$ROOT/ios/NostrVpnIos.xcodeproj" \
    -scheme NostrVpnIos \
    -configuration Release \
    -derivedDataPath "$derived" \
    -destination "platform=iOS,id=$udid" \
    DEVELOPMENT_TEAM="$team" \
    NVPN_IOS_CODE_SIGN_IDENTITY="$NVPN_IOS_CODE_SIGN_IDENTITY" \
    NVPN_IOS_PROVISIONING_PROFILE_UUID="$NVPN_IOS_PROVISIONING_PROFILE_UUID" \
    NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID="$NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID" \
    NVPN_BUILD_GIT_SHA="$app_sha" \
    build-for-testing

  app_path="$derived/Build/Products/Release-iphoneos/Nostr VPN.app"
  [[ -d "$app_path" ]] || {
    echo "iOS Release app was not built for testing" >&2
    return 1
  }
  app_binary="$app_path/Nostr VPN"
  tunnel_app="$app_path/PlugIns/Nostr VPN Tunnel.appex"
  tunnel_binary="$tunnel_app/Nostr VPN Tunnel"
  codesign --verify --deep --strict "$app_path"
  codesign --verify --strict "$tunnel_app"
  profile_plist="$RESULT_DIR/ios-signing/embedded-profile.plist"
  tunnel_profile_plist="$RESULT_DIR/ios-signing/embedded-tunnel-profile.plist"
  security cms -D -i "$app_path/embedded.mobileprovision" >"$profile_plist"
  security cms -D -i "$tunnel_app/embedded.mobileprovision" >"$tunnel_profile_plist"
  [[ "$(release_join_ios_profile_value "$profile_plist" ProvisionsAllDevices)" != true ]]
  /usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$profile_plist" \
    | grep -Fq "$udid"
  [[ "$(release_join_ios_profile_value "$tunnel_profile_plist" ProvisionsAllDevices)" != true ]]
  /usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$tunnel_profile_plist" \
    | grep -Fq "$udid"
  [[ "$(release_join_ios_profile_value "$profile_plist" Entitlements:get-task-allow)" != true ]]
  [[ "$(release_join_ios_profile_value "$tunnel_profile_plist" Entitlements:get-task-allow)" != true ]]
  [[ "$(release_join_ios_profile_value "$profile_plist" TeamIdentifier:0)" == "$team" ]]
  [[ "$(release_join_ios_profile_value "$profile_plist" Entitlements:application-identifier)" == "$team.$bundle" ]]
  [[ "$(release_join_ios_profile_value "$tunnel_profile_plist" TeamIdentifier:0)" == "$team" ]]
  [[ "$(release_join_ios_profile_value "$tunnel_profile_plist" Entitlements:application-identifier)" == "$team.$tunnel" ]]
  app_signed_team="$(release_join_codesign_team "$app_path")"
  tunnel_signed_team="$(release_join_codesign_team "$tunnel_app")"
  [[ "$app_signed_team" == "$expected_team" \
    && "$tunnel_signed_team" == "$expected_team" ]] || {
    echo "iOS app or PacketTunnel was signed by the wrong team" >&2
    return 1
  }
  app_cert="$(release_join_codesign_certificate_sha256 "$app_path")"
  tunnel_cert="$(release_join_codesign_certificate_sha256 "$tunnel_app")"
  [[ "$app_cert" == "$expected_cert" && "$tunnel_cert" == "$expected_cert" ]] || {
    echo "iOS app or PacketTunnel was signed by the wrong distribution certificate" >&2
    return 1
  }
  team_hash="$(printf '%s' "$expected_team" | shasum -a 256 | awk '{print $1}')"
  if strings "$app_binary" "$tunnel_binary" \
      | grep -Eq 'nvpn-debug|DEBUG_ACTION|SCREENSHOT_FIXTURE'; then
    echo "iOS Release binary contains debug automation entry points" >&2
    return 1
  fi
  manifest_sha="$(
    release_join_ios_tree_receipt \
      "$app_path" "$RESULT_DIR/ios-release-bundle-manifest.json"
  )"
  release_join_assert_fips_unchanged
  release_join_assert_app_unchanged "$app_sha" "$app_tree"
  release_join_install_ios_release \
    "$app_path" "$app_sha" "$app_tree" "$manifest_sha" \
    "$team_hash" "$app_cert" "$derived" "$udid"
}

release_join_reset_ios_state() {
  local bundle="${NVPN_DEFAULT_IOS_BUNDLE_ID:-fi.siriusbusiness.nvpn}"
  release_join_require_device_mutation_allowed || return 1
  [[ "${NVPN_RELEASE_JOIN_ALLOW_DEVICE_RESET:-}" == "YES" ]] || {
    echo "Set NVPN_RELEASE_JOIN_ALLOW_DEVICE_RESET=YES for destructive physical join coverage" >&2
    return 1
  }
  [[ -d "$RELEASE_JOIN_IOS_APP_PATH" ]] || {
    echo "Exact iOS Release artifact is unavailable for a clean reinstall" >&2
    return 1
  }
  RELEASE_JOIN_DEVICE_MUTATED=1
  xcrun devicectl device uninstall app \
    --device "$IOS_DEVICE" "$bundle" --quiet >/dev/null 2>&1 || true
  xcrun devicectl device install app \
    --device "$IOS_DEVICE" "$RELEASE_JOIN_IOS_APP_PATH" --quiet
}

release_join_assert_one_ios_process() {
  local processes="$RESULT_DIR/ios-processes-final.json"
  xcrun devicectl device info processes \
    --device "$IOS_DEVICE" \
    --json-output "$processes" \
    --quiet
  python3 - "$processes" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
matches = []

def visit(value):
    if isinstance(value, dict):
        executable = str(value.get("executable", ""))
        if executable.endswith("/Nostr%20VPN.app/Nostr%20VPN") or executable.endswith("/Nostr VPN.app/Nostr VPN"):
            matches.append(value)
        for child in value.values():
            visit(child)
    elif isinstance(value, list):
        for child in value:
            visit(child)

visit(payload)
if len(matches) != 1:
    raise SystemExit(f"expected one iOS Nostr VPN app process, found {len(matches)}")
PY
}

release_join_launch_ios_release() {
  local bundle="${NVPN_DEFAULT_IOS_BUNDLE_ID:-fi.siriusbusiness.nvpn}"
  xcrun devicectl device process launch \
    --device "$IOS_DEVICE" \
    --activate \
    "$bundle" >/dev/null
  sleep 1
}
