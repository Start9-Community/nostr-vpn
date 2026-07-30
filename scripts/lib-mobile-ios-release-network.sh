#!/usr/bin/env bash

# Company-signed iOS Release black-box network gate. The app under test receives
# no launch arguments or environment; only the separate XCTest runner receives
# a case specification.

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-mobile-ios-release-artifact.sh"

IOS_RELEASE_NETWORK_PREPARED=0
IOS_RELEASE_NETWORK_SIGNING_DIR=""
IOS_RELEASE_NETWORK_SIGNING_ENV=""
IOS_RELEASE_NETWORK_DERIVED_DATA=""
IOS_RELEASE_NETWORK_DESTINATION=""
IOS_RELEASE_NETWORK_DEVICE=""
IOS_RELEASE_NETWORK_BASE_CDHASH=""
IOS_RELEASE_NETWORK_BASE_TREE_SHA=""
IOS_RELEASE_NETWORK_BASE_TEST_PRODUCTS_TREE_SHA=""
IOS_RELEASE_NETWORK_XCTESTRUN=""
IOS_RELEASE_NETWORK_CASE_XCTESTRUN=""
IOS_RELEASE_NETWORK_DEVICE_RECEIPT=""
IOS_RELEASE_NETWORK_CLEANUP_SPEC_BASE64=""
IOS_RELEASE_NETWORK_FIPS_TREE=""
IOS_RELEASE_NETWORK_APP_HEAD=""
IOS_RELEASE_NETWORK_APP_TREE=""
IOS_RELEASE_NETWORK_FROZEN_APP=""
IOS_RELEASE_NETWORK_XCODE_COMMAND=()
IOS_RELEASE_NETWORK_ACTIVE_PGID=""
IOS_RELEASE_NETWORK_ACTIVE_PGID_FILE=""
IOS_RELEASE_NETWORK_PENDING_SPEC_BASE64=""
IOS_RELEASE_NETWORK_PENDING_LOG=""
IOS_RELEASE_NETWORK_PENDING_XCRESULT=""

ios_release_network_cleanup_private_artifacts() {
  local cleanup_failed=0 signing_removed=1
  ios_release_network_abort_active_run || cleanup_failed=1
  ios_release_network_delete_private_test_products || cleanup_failed=1
  if [[ -n "$IOS_RELEASE_NETWORK_SIGNING_DIR" ]]; then
    case "$(basename "$IOS_RELEASE_NETWORK_SIGNING_DIR")" in
      nvpn-ios-release-signing.*)
        if ! rm -rf "$IOS_RELEASE_NETWORK_SIGNING_DIR"; then
          cleanup_failed=1
          signing_removed=0
        fi
        ;;
      *)
        echo "Refusing to remove an unsafe iOS signing artifact path" >&2
        cleanup_failed=1
        signing_removed=0
        ;;
    esac
  fi
  if [[ "$signing_removed" -eq 1 ]]; then
    IOS_RELEASE_NETWORK_SIGNING_DIR=""
    IOS_RELEASE_NETWORK_SIGNING_ENV=""
    IOS_RELEASE_NETWORK_DEVICE_RECEIPT=""
    IOS_RELEASE_NETWORK_ACTIVE_PGID_FILE=""
    unset NVPN_IOS_CODE_SIGN_IDENTITY
    unset NVPN_IOS_PROVISIONING_PROFILE_UUID
    unset NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID
  fi
  return "$cleanup_failed"
}

ios_release_network_prepare_abort() {
  ios_release_network_cleanup_private_artifacts || true
  return 1
}

ios_release_network_company_signing() {
  local organization="$1"
  security find-identity -v -p codesigning \
    | python3 -c '
import re
import sys

organization = sys.argv[1]
matches = []
for line in sys.stdin:
    match = re.search(r"\b([0-9A-Fa-f]{40})\s+\"([^\"]+)\"", line)
    if not match:
        continue
    identity, label = match.groups()
    team_match = re.search(r"\(([A-Z0-9]+)\)$", label)
    if organization not in label or team_match is None:
        continue
    if not (
        label.startswith("Apple Distribution:")
        or label.startswith("iPhone Distribution:")
    ):
        continue
    matches.append((identity, team_match.group(1)))
if len(matches) != 1:
    raise SystemExit(
        f"expected one company distribution identity, observed {len(matches)}"
    )
print(f"{matches[0][0]}|{matches[0][1]}")
' "$organization"
}

ios_release_network_prepare() {
  local device="$1"
  [[ "$IOS_RELEASE_NETWORK_PREPARED" -eq 0 ]] || return 0
  IOS_RELEASE_NETWORK_APP_HEAD="$(git -C "$ROOT" rev-parse HEAD)"
  IOS_RELEASE_NETWORK_APP_TREE="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
  assert_release_checkout_state \
    "$ROOT" "$IOS_RELEASE_NETWORK_APP_HEAD" \
    "$IOS_RELEASE_NETWORK_APP_TREE" "iOS Release network gate" \
    || return 1
  pin_exact_release_build_git_sha \
    "$ROOT" "$IOS_RELEASE_NETWORK_APP_HEAD" "iOS Release" \
    || return 1
  local configured_team="${NVPN_IOS_TEAM_ID:-}"
  local signer_organization="${NVPN_IOS_EXPECTED_SIGNER_ORGANIZATION:-Sirius Business Oy}"
  local expected_device_name="${NVPN_IOS_EXPECTED_DEVICE_NAME:-}"
  local fips_path="${NVPN_FIPS_REPO_PATH:-}"
  local expected_fips="${NVPN_EXPECTED_FIPS_GIT_SHA:-}"
  local expected_team="${NVPN_EXPECTED_IOS_DISTRIBUTION_TEAM_ID:-}"
  local expected_cert="${NVPN_EXPECTED_IOS_DISTRIBUTION_CERT_SHA256:-}"
  [[ -n "$expected_device_name" ]] || {
    echo "iOS Release gate requires an explicit expected physical device name" >&2
    return 1
  }
  [[ "$expected_team" =~ ^[A-Z0-9]{10}$ ]] || {
    echo "iOS Release gate requires an exact distribution team pin" >&2
    return 1
  }
  expected_cert="$(
    printf '%s' "$expected_cert" \
      | tr -d ':[:space:]' \
      | tr '[:upper:]' '[:lower:]'
  )"
  [[ "$expected_cert" =~ ^[0-9a-f]{64}$ ]] || {
    echo "iOS Release gate requires an exact distribution certificate SHA-256 pin" >&2
    return 1
  }
  [[ "$expected_fips" =~ ^[0-9a-f]{40}$ ]] || {
    echo "iOS Release gate requires an exact FIPS Git SHA pin" >&2
    return 1
  }
  NVPN_EXPECTED_IOS_DISTRIBUTION_CERT_SHA256="$expected_cert"
  export NVPN_EXPECTED_IOS_DISTRIBUTION_CERT_SHA256
  local company_signing company_identity team
  company_signing="$(
    ios_release_network_company_signing "$signer_organization"
  )" || {
    echo "iOS Release gate could not select the exact company distribution identity" >&2
    return 1
  }
  company_identity="${company_signing%%|*}"
  team="${company_signing#*|}"
  [[ "$company_identity" =~ ^[0-9A-Fa-f]{40}$ \
    && "$team" =~ ^[A-Z0-9]+$ ]] || {
    echo "iOS Release company signing receipt was malformed" >&2
    return 1
  }
  if [[ "$team" != "$expected_team" \
    || (-n "$configured_team" && "$configured_team" != "$expected_team") ]]
  then
    echo "Configured iOS team is not the Sirius Business signing team" >&2
    return 1
  fi
  export NVPN_IOS_TEAM_ID="$expected_team"
  [[ -n "$fips_path" && (-d "$fips_path/.git" || -f "$fips_path/.git") ]] || {
    echo "iOS Release network gate requires an exact local FIPS checkout" >&2
    return 1
  }
  local fips_head fips_tree fips_version
  fips_head="$(git -C "$fips_path" rev-parse HEAD)"
  fips_tree="$(git -C "$fips_path" rev-parse 'HEAD^{tree}')"
  [[ -z "$(git -C "$fips_path" status --porcelain)" ]] || {
    echo "iOS Release network gate refuses a dirty FIPS checkout" >&2
    return 1
  }
  fips_version="$(
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
    ' "$fips_path/crates/fips-core/Cargo.toml"
  )"
  [[ "$fips_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || {
    echo "iOS Release gate could not derive the exact FIPS package version" >&2
    return 1
  }
  if [[ "$expected_fips" != "$fips_head" ]]; then
    echo "iOS Release network gate FIPS mismatch" >&2
    return 1
  fi
  export NVPN_EXPECTED_FIPS_VERSION="$fips_version"
  IOS_RELEASE_NETWORK_FIPS_TREE="$fips_tree"
  export NVPN_IOS_RUST_PROFILE=release
  NVPN_IOS_CODE_SIGN_IDENTITY="$company_identity" \
    "$ROOT/scripts/ios-build" ios-archive || return 1
  IOS_RELEASE_NETWORK_FROZEN_APP="$ROOT/dist/ios/frozen/release-testing-unpacked/Payload/Nostr VPN.app"

  umask 077
  if ! IOS_RELEASE_NETWORK_SIGNING_DIR="$(
    mktemp -d "${TMPDIR:-/tmp}/nvpn-ios-release-signing.XXXXXX"
  )"; then
    echo "iOS Release gate could not create private signing storage" >&2
    return 1
  fi
  if ! chmod 700 "$IOS_RELEASE_NETWORK_SIGNING_DIR"; then
    ios_release_network_prepare_abort
    return
  fi
  IOS_RELEASE_NETWORK_ACTIVE_PGID_FILE="$IOS_RELEASE_NETWORK_SIGNING_DIR/active-xcode.pgid"
  IOS_RELEASE_NETWORK_SIGNING_ENV="$IOS_RELEASE_NETWORK_SIGNING_DIR/provisioning.env"
  IOS_RELEASE_NETWORK_DERIVED_DATA="$ROOT/ios/.build/ReleaseNetworkDerivedData"
  if ! mkdir -p "${NVPN_MOBILE_WG_EXIT_IOS_UI_RESULT_DIR:-$ROOT/artifacts/mobile-ios}"; then
    ios_release_network_prepare_abort
    return
  fi
  local device_details device_udid
  device_details="$IOS_RELEASE_NETWORK_SIGNING_DIR/selected-device-details.json"
  IOS_RELEASE_NETWORK_DEVICE_RECEIPT="$IOS_RELEASE_NETWORK_SIGNING_DIR/selected-device-receipt.json"
  if ! xcrun devicectl device info details \
    --device "$device" \
    --json-output "$device_details" \
    --quiet >/dev/null
  then
    echo "iOS Release gate could not read back its explicitly selected phone" >&2
    ios_release_network_prepare_abort
    return
  fi
  if ! device_udid="$(python3 - \
    "$device_details" "$IOS_RELEASE_NETWORK_DEVICE_RECEIPT" \
    "$expected_device_name" "${NVPN_IOS_EXPECTED_DEVICE_MODEL:-}" <<'PY'
import hashlib
import json
import sys

details_path, receipt_path, expected_name, expected_model = sys.argv[1:]
details = json.load(open(details_path, encoding="utf-8")).get("result", {})
device = details.get("deviceProperties", {})
hardware = details.get("hardwareProperties", {})
name = device.get("name")
model = hardware.get("marketingName")
udid = hardware.get("udid")
if hardware.get("platform") != "iOS":
    raise SystemExit("selected device is not physical iOS")
if name != expected_name:
    raise SystemExit("selected iOS device name does not match the required phone")
if expected_model and model != expected_model:
    raise SystemExit("selected iOS device model does not match")
if not isinstance(model, str) or not model:
    raise SystemExit("selected iOS device has no model receipt")
if not isinstance(udid, str) or not udid:
    raise SystemExit("selected iOS device has no resolved hardware identifier")
receipt = {
    "deviceIdentifierSha256": hashlib.sha256(udid.encode()).hexdigest(),
    "explicitPhysicalDeviceVerified": True,
    "model": model,
    "osVersion": str(device.get("osVersionNumber", "")),
    "platform": "iOS",
    "productType": str(hardware.get("productType", "")),
}
with open(receipt_path, "w", encoding="utf-8") as output:
    json.dump(receipt, output, indent=2, sort_keys=True)
    output.write("\n")
print(udid)
PY
  )"
  then
    rm -f "$device_details"
    echo "iOS Release gate rejected the selected physical phone" >&2
    ios_release_network_prepare_abort
    return
  fi
  rm -f "$device_details" || {
    echo "iOS Release gate could not scrub raw device details" >&2
    ios_release_network_prepare_abort
    return
  }
  IOS_RELEASE_NETWORK_DEVICE="$device_udid"
  # Xcode 26 advertises the same arm64e phone twice (arm64e and compatible
  # arm64). The test products are arm64, so select that exact destination
  # instead of allowing xcodebuild to choose the arm64e variant.
  IOS_RELEASE_NETWORK_DESTINATION="platform=iOS,id=$device_udid,arch=arm64"

  local profile_log="$IOS_RELEASE_NETWORK_SIGNING_DIR/ios-profiles.log"
  if ! NVPN_IOS_PROFILE_TYPE=IOS_APP_ADHOC \
    NVPN_IOS_PROFILE_NAME="Nostr VPN Ad Hoc main physical gate" \
    NVPN_IOS_PACKET_TUNNEL_PROFILE_NAME="Nostr VPN Ad Hoc packet tunnel physical gate" \
    NVPN_IOS_CODE_SIGN_IDENTITY="$company_identity" \
    NVPN_IOS_DEVICE_UDIDS="$device_udid" \
    NVPN_IOS_PROFILES_ENV_PATH="$IOS_RELEASE_NETWORK_SIGNING_ENV" \
    "$ROOT/scripts/ios-profiles" ensure >"$profile_log" 2>&1
  then
    if rm -f "$profile_log" "$IOS_RELEASE_NETWORK_SIGNING_ENV"; then
      echo "Unable to prepare company Ad Hoc signing; private details were deleted" >&2
    else
      echo "Unable to prepare company Ad Hoc signing; private cleanup failed" >&2
    fi
    ios_release_network_prepare_abort
    return
  fi
  unset NVPN_IOS_CODE_SIGN_IDENTITY
  unset NVPN_IOS_PROVISIONING_PROFILE_UUID
  unset NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID
  # shellcheck disable=SC1090
  if ! source "$IOS_RELEASE_NETWORK_SIGNING_ENV"; then
    rm -f "$profile_log" "$IOS_RELEASE_NETWORK_SIGNING_ENV"
    echo "iOS Release signing receipt could not be loaded" >&2
    ios_release_network_prepare_abort
    return
  fi
  rm -f "$profile_log" || {
    echo "iOS Release gate could not scrub its profile preparation log" >&2
    ios_release_network_prepare_abort
    return
  }
  local signing_name
  for signing_name in \
    NVPN_IOS_CODE_SIGN_IDENTITY \
    NVPN_IOS_PROVISIONING_PROFILE_UUID \
    NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID
  do
    [[ -n "${!signing_name:-}" ]] || {
      echo "iOS Release signing receipt is incomplete: $signing_name" >&2
      ios_release_network_prepare_abort
      return
    }
  done
  [[ "$NVPN_IOS_CODE_SIGN_IDENTITY" == "$company_identity" ]] || {
    echo "iOS Release profile preparation changed the explicit company signer" >&2
    ios_release_network_prepare_abort
    return
  }

  local reuse_build="${NVPN_MOBILE_WG_EXIT_REUSE_IOS_BUILD:-0}"
  local result_dir build_log
  result_dir="${NVPN_MOBILE_WG_EXIT_IOS_UI_RESULT_DIR:-$ROOT/artifacts/mobile-ios}"
  build_log="$IOS_RELEASE_NETWORK_SIGNING_DIR/build-for-testing.log"
  if bool_is_true "$reuse_build"; then
    ios_release_network_audit_rust_feature_surface || {
      ios_release_network_prepare_abort
      return
    }
  else
    ios_release_network_audit_rust_feature_surface || {
      ios_release_network_prepare_abort
      return
    }
    [[ -z "$(git -C "$fips_path" status --porcelain)" ]] || {
      echo "iOS Release FIPS build left the exact checkout dirty" >&2
      ios_release_network_prepare_abort
      return
    }
    ios_release_network_xcode_command
    local -a build_command=("${IOS_RELEASE_NETWORK_XCODE_COMMAND[@]}")
    build_command+=(build-for-testing)
    if ! "${build_command[@]}" >"$build_log" 2>&1; then
      tail -n 160 "$build_log" >&2
      rm -f "$build_log" || true
      echo "iOS company-signed Release build-for-testing failed" >&2
      ios_release_network_prepare_abort
      return
    fi
    rm -f "$build_log" || {
      echo "iOS Release gate could not scrub its signing build log" >&2
      ios_release_network_prepare_abort
      return
    }
  fi
  if ! NVPN_IOS_ADHOC_PROVISIONING_PROFILE_UUID="$NVPN_IOS_PROVISIONING_PROFILE_UUID" \
    NVPN_IOS_ADHOC_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID="$NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID" \
    NVPN_IOS_EXPORT_SIGNING_CERTIFICATE="$NVPN_IOS_CODE_SIGN_IDENTITY" \
    NVPN_IOS_FROZEN_DEVICE_UDID="$device_udid" \
    "$ROOT/scripts/ios-build" ios-release-testing
  then
    echo "iOS Release gate could not export the frozen archive for physical testing" >&2
    ios_release_network_prepare_abort
    return
  fi
  [[ -d "$IOS_RELEASE_NETWORK_FROZEN_APP" ]] || {
    echo "Frozen release-testing iOS app is missing" >&2
    ios_release_network_prepare_abort
    return
  }
  export NVPN_MOBILE_IOS_RELEASE_APP_PATH="$IOS_RELEASE_NETWORK_FROZEN_APP"
  rm -f "$IOS_RELEASE_NETWORK_SIGNING_ENV" || {
    echo "iOS Release gate could not scrub profile preparation artifacts" >&2
    ios_release_network_prepare_abort
    return
  }
  IOS_RELEASE_NETWORK_XCTESTRUN="$(
    select_generated_ios_release_xctestrun \
      "$IOS_RELEASE_NETWORK_DERIVED_DATA/Build/Products" \
      "iOS Release build"
  )" || {
    ios_release_network_prepare_abort
    return
  }
  [[ -s "$IOS_RELEASE_NETWORK_XCTESTRUN" ]] || {
    echo "iOS Release build-for-testing did not preserve its xctestrun" >&2
    ios_release_network_prepare_abort
    return
  }
  ios_release_network_write_runner_diagnostics \
    "$result_dir/mobile-ios-release-runner-diagnostics.json" \
    "$IOS_RELEASE_NETWORK_XCTESTRUN" || {
    ios_release_network_prepare_abort
    return
  }
  IOS_RELEASE_NETWORK_PREPARED=1
  if bool_is_true "$reuse_build"; then
    echo "iOS company-signed Release network gate reused its preserved build"
  else
    echo "iOS company-signed Release network gate prepared once"
  fi
}

ios_release_network_xcode_command() {
  IOS_RELEASE_NETWORK_XCODE_COMMAND=(
    xcodebuild
    -quiet
    -allowProvisioningUpdates
    -project "$ROOT/ios/NostrVpnIos.xcodeproj"
    -scheme NostrVpnIos
    -configuration Release
    -derivedDataPath "$IOS_RELEASE_NETWORK_DERIVED_DATA"
    -destination "$IOS_RELEASE_NETWORK_DESTINATION"
    -destination-timeout 60
    -collect-test-diagnostics never
    DEVELOPMENT_TEAM="$NVPN_IOS_TEAM_ID"
    NVPN_IOS_CODE_SIGN_IDENTITY="$NVPN_IOS_CODE_SIGN_IDENTITY"
    NVPN_IOS_PROVISIONING_PROFILE_UUID="$NVPN_IOS_PROVISIONING_PROFILE_UUID"
    NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID="$NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID"
    NVPN_BUILD_GIT_SHA="$NVPN_BUILD_GIT_SHA"
    NVPN_BUILD_TIMESTAMP_UTC="$NVPN_BUILD_TIMESTAMP_UTC"
  )
  if [[ -n "${NVPN_ASC_AUTH_KEY_PATH:-}" \
    && -n "${NVPN_ASC_AUTH_KEY_ID:-}" \
    && -n "${NVPN_ASC_AUTH_KEY_ISSUER_ID:-}" ]]
  then
    IOS_RELEASE_NETWORK_XCODE_COMMAND+=(
      -authenticationKeyPath "$NVPN_ASC_AUTH_KEY_PATH"
      -authenticationKeyID "$NVPN_ASC_AUTH_KEY_ID"
      -authenticationKeyIssuerID "$NVPN_ASC_AUTH_KEY_ISSUER_ID"
    )
  fi
}

ios_release_network_prepare_xctestrun() {
  local label="$1" spec_base64="$2"
  local -a rewrite_command=()
  local -a runner_environment=()
  [[ "$label" =~ ^[a-zA-Z0-9._-]+$ ]] || {
    echo "iOS Release xctestrun label is invalid" >&2
    return 1
  }
  [[ -s "$IOS_RELEASE_NETWORK_XCTESTRUN" ]] || {
    echo "iOS Release base xctestrun is missing" >&2
    return 1
  }
  IOS_RELEASE_NETWORK_CASE_XCTESTRUN="$(
    mktemp "$IOS_RELEASE_NETWORK_SIGNING_DIR/NostrVpnIos-$label.XXXXXX.xctestrun"
  )"
  rewrite_command=(
    python3 "$ROOT/scripts/ios_frozen_archive.py"
    rewrite-xctestrun
    --source "$IOS_RELEASE_NETWORK_XCTESTRUN"
    --output "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"
    --products-root "$IOS_RELEASE_NETWORK_DERIVED_DATA/Build/Products"
    --target-app "$(ios_release_network_app_path)"
    --environment-stdin0
  )
  runner_environment=(
    "NVPN_XCUITEST_RELEASE_NETWORK_GATE=1"
    "NVPN_XCUITEST_RELEASE_NETWORK_SPEC_BASE64="
  )
  if [[ -n "$spec_base64" ]]; then
    runner_environment+=(
      "NVPN_XCUITEST_RELEASE_NETWORK_SPEC_BASE64=$spec_base64"
    )
  fi
  if ! printf '%s\0' "${runner_environment[@]}" \
    | "${rewrite_command[@]}"
  then
    rm -f "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"
    IOS_RELEASE_NETWORK_CASE_XCTESTRUN=""
    return 1
  fi
}

ios_release_network_write_runner_diagnostics() {
  local output="$1" xctestrun="$2"
  local app runner test_bundle app_details runner_details test_details
  local app_entitlements runner_entitlements test_entitlements
  local runner_archs test_archs xctestrun_sha
  app="$(ios_release_network_app_path)"
  runner="$IOS_RELEASE_NETWORK_DERIVED_DATA/Build/Products/Release-iphoneos/NostrVpnIosUITests-Runner.app"
  test_bundle="$runner/PlugIns/NostrVpnIosUITests.xctest"
  [[ -d "$app" && -d "$runner" \
    && -x "$test_bundle/NostrVpnIosUITests" \
    && -s "$xctestrun" ]] || {
    echo "iOS Release runner diagnostics found incomplete test products" >&2
    return 1
  }
  if ! codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
    || ! codesign --verify --deep --strict "$runner" >/dev/null 2>&1 \
    || ! codesign --verify --strict "$test_bundle" >/dev/null 2>&1
  then
    echo "iOS Release runner diagnostics rejected a test product signature" >&2
    return 1
  fi
  app_details="$(codesign -dvvv "$app" 2>&1)" \
    && runner_details="$(codesign -dvvv "$runner" 2>&1)" \
    && test_details="$(codesign -dvvv "$test_bundle" 2>&1)" \
    && app_entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null)" \
    && runner_entitlements="$(
      codesign -d --entitlements :- "$runner" 2>/dev/null
    )" \
    && test_entitlements="$(
      codesign -d --entitlements :- "$test_bundle" 2>/dev/null
    )" || {
    rm -f "$output"
    echo "iOS Release runner diagnostics could not read code signatures" >&2
    return 1
  }
  runner_archs="$(lipo -archs "$runner/NostrVpnIosUITests-Runner")"
  test_archs="$(lipo -archs "$test_bundle/NostrVpnIosUITests")"
  [[ "$app_details" == *"Authority=Apple Distribution: ${NVPN_IOS_EXPECTED_SIGNER_ORGANIZATION:-Sirius Business Oy}"* \
      || "$app_details" == *"Authority=iPhone Distribution: ${NVPN_IOS_EXPECTED_SIGNER_ORGANIZATION:-Sirius Business Oy}"* ]] \
    && [[ "$app_details" == *"TeamIdentifier=$NVPN_IOS_TEAM_ID"* \
    && "$runner_details" == *"Authority=Apple Development:"* \
    && "$runner_details" == *"TeamIdentifier=$NVPN_IOS_TEAM_ID"* \
    && "$test_details" == *"Authority=Apple Development:"* \
    && "$test_details" == *"TeamIdentifier=$NVPN_IOS_TEAM_ID"* \
    && "$app_entitlements" != *"<key>get-task-allow</key><true/>"* \
    && "$runner_entitlements" == *"<key>get-task-allow</key><true/>"* \
    && "$test_entitlements" == *"<key>get-task-allow</key><true/>"* \
    && " $runner_archs " == *" arm64 "* \
    && " $test_archs " == *" arm64 "* ]] || {
      echo "iOS Release app/runner signing or architecture contract failed" >&2
      return 1
    }
  xctestrun_sha="$(shasum -a 256 "$xctestrun" | awk '{print $1}')" \
    && [[ "$xctestrun_sha" =~ ^[0-9a-f]{64}$ ]] || {
      echo "iOS Release xctestrun hash receipt failed" >&2
      return 1
    }
  printf '{\n  "appDebuggable": false,\n  "appSigningClass": "distribution",\n  "destinationArchitecture": "arm64",\n  "runnerArchitectures": "%s",\n  "runnerDebuggable": true,\n  "runnerSigningClass": "development",\n  "sameSigningTeam": true,\n  "schemaVersion": 1,\n  "testBundleArchitectures": "%s",\n  "testBundleDebuggable": true,\n  "testBundleSigningClass": "development",\n  "xctestrunSha256": "%s"\n}\n' \
    "$runner_archs" "$test_archs" "$xctestrun_sha" >"$output"
}

ios_release_network_delete_private_test_products() {
  local cleanup_failed=0
  if [[ -n "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN" ]]; then
    if rm -f "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"; then
      IOS_RELEASE_NETWORK_CASE_XCTESTRUN=""
    else
      cleanup_failed=1
    fi
  fi
  return "$cleanup_failed"
}

ios_release_network_private_data() {
  local mode="$1" spec_base64="$2"
  shift 2
  [[ "$mode" == "assert" || "$mode" == "redact" ]] || return 2
  if [[ -z "$spec_base64" ]]; then
    [[ "$mode" != "redact" ]] || echo false
    return 0
  fi
  NVPN_PRIVATE_RELEASE_SPEC_BASE64="$spec_base64" \
    python3 - "$mode" "$@" <<'PY'
import base64
import hashlib
import json
import os
import pathlib
import sys

mode = sys.argv[1]
encoded = os.environ["NVPN_PRIVATE_RELEASE_SPEC_BASE64"]
raw = base64.b64decode(encoded, validate=True)
spec = json.loads(raw)
needles = {
    encoded.encode(),
    raw,
    hashlib.sha256(raw).hexdigest().encode(),
    hashlib.sha256(encoded.encode()).hexdigest().encode(),
}
wireguard = spec.get("wireGuardConfig")
if isinstance(wireguard, str) and wireguard:
    needles.add(wireguard.encode())
else:
    wireguard = ""
for line in wireguard.splitlines():
    if line.strip().lower().startswith("privatekey"):
        _, _, value = line.partition("=")
        if value.strip():
            needles.add(value.strip().encode())
needles = sorted(
    (needle for needle in needles if len(needle) >= 8),
    key=len,
    reverse=True,
)
changed = False
for raw_path in sys.argv[2:]:
    path = pathlib.Path(raw_path)
    candidates = [path] if path.is_file() else (
        sorted(candidate for candidate in path.rglob("*") if candidate.is_file())
        if path.is_dir()
        else []
    )
    for candidate in candidates:
        data = candidate.read_bytes()
        if mode == "assert":
            if any(needle in data for needle in needles):
                raise SystemExit(
                    "retained iOS artifact contains private gate input"
                )
            continue
        redacted = data
        for needle in needles:
            redacted = redacted.replace(
                needle, b"<redacted-private-gate-input>"
            )
        if redacted != data:
            candidate.write_bytes(redacted)
            changed = True
if mode == "redact":
    print("true" if changed else "false")
PY
}

ios_release_network_assert_retained_no_secrets() {
  local spec_base64="$1"
  shift
  ios_release_network_private_data assert "$spec_base64" "$@"
}

ios_release_network_preserve_diagnostics() {
  local spec_base64="$1" log="$2" xcresult="$3"
  local base="${xcresult%.xcresult}"
  local summary="$base-xcresult-summary.json"
  local redaction="$base-diagnostic-redaction.json"
  local log_redacted summary_redacted=false retained_xcresult=false
  local xcresult_redacted=false
  mkdir -p "$(dirname "$log")"
  [[ -e "$log" ]] || : >"$log"
  if [[ -d "$xcresult" ]]; then
    if ! xcrun xcresulttool get test-results summary \
      --path "$xcresult" >"$summary.tmp" 2>/dev/null
    then
      printf '{\n  "result": "xcresult-summary-unavailable"\n}\n' \
        >"$summary.tmp"
    fi
    mv -f "$summary.tmp" "$summary"
    if ios_release_network_assert_retained_no_secrets \
      "$spec_base64" "$xcresult" 2>/dev/null
    then
      retained_xcresult=true
    else
      rm -rf "$xcresult"
      xcresult_redacted=true
    fi
  else
    printf '{\n  "result": "xcresult-not-created"\n}\n' >"$summary"
  fi
  log_redacted="$(
    ios_release_network_private_data redact "$spec_base64" "$log"
  )"
  summary_redacted="$(
    ios_release_network_private_data redact "$spec_base64" "$summary"
  )"
  ios_release_network_assert_retained_no_secrets \
    "$spec_base64" "$log" "$xcresult" "$summary"
  printf '{\n  "logRedacted": %s,\n  "retainedFullXcresult": %s,\n  "summaryRedacted": %s,\n  "xcresultRedactedToSummary": %s\n}\n' \
    "$log_redacted" "$retained_xcresult" "$summary_redacted" \
    "$xcresult_redacted" >"$redaction.tmp"
  mv -f "$redaction.tmp" "$redaction"
}

ios_release_network_register_diagnostics() {
  IOS_RELEASE_NETWORK_PENDING_SPEC_BASE64="$1"
  IOS_RELEASE_NETWORK_PENDING_LOG="$2"
  IOS_RELEASE_NETWORK_PENDING_XCRESULT="$3"
}

ios_release_network_clear_pending_diagnostics() {
  IOS_RELEASE_NETWORK_PENDING_SPEC_BASE64=""
  IOS_RELEASE_NETWORK_PENDING_LOG=""
  IOS_RELEASE_NETWORK_PENDING_XCRESULT=""
}

ios_release_network_delete_pending_diagnostics() {
  local xcresult="$IOS_RELEASE_NETWORK_PENDING_XCRESULT"
  local cleanup_failed=0
  [[ -z "$IOS_RELEASE_NETWORK_PENDING_LOG" ]] \
    || rm -f "$IOS_RELEASE_NETWORK_PENDING_LOG" || cleanup_failed=1
  if [[ -n "$xcresult" ]]; then
    rm -rf "$xcresult" || cleanup_failed=1
    rm -f "${xcresult%.xcresult}-xcresult-summary.json" \
      "${xcresult%.xcresult}-diagnostic-redaction.json" || cleanup_failed=1
  fi
  ((cleanup_failed)) || ios_release_network_clear_pending_diagnostics
  return "$cleanup_failed"
}

ios_release_network_preserve_pending_diagnostics() {
  [[ -n "$IOS_RELEASE_NETWORK_PENDING_LOG" \
    && -n "$IOS_RELEASE_NETWORK_PENDING_XCRESULT" ]] || return 2
  ios_release_network_preserve_diagnostics \
    "$IOS_RELEASE_NETWORK_PENDING_SPEC_BASE64" \
    "$IOS_RELEASE_NETWORK_PENDING_LOG" \
    "$IOS_RELEASE_NETWORK_PENDING_XCRESULT" || return 1
  ios_release_network_clear_pending_diagnostics
}

ios_release_network_test_command() {
  local xctestrun="$1"
  IOS_RELEASE_NETWORK_XCODE_COMMAND=(
    xcodebuild
    -xctestrun "$xctestrun"
    -destination "$IOS_RELEASE_NETWORK_DESTINATION"
    -destination-timeout 60
    -collect-test-diagnostics never
    -parallel-testing-enabled NO
  )
}

ios_release_network_process_group_alive() {
  local pgid="$1"
  [[ -n "$pgid" ]] || return 1
  ps -axo pgid=,stat= 2>/dev/null \
    | awk -v expected="$pgid" '
        $1 == expected && $2 !~ /^Z/ { found = 1 }
        END { exit !found }
      '
}

ios_release_network_terminate_process_group() {
  local pgid="$1"
  local grace="${NVPN_IOS_XCTEST_TERM_GRACE_SECS:-5}"
  local signal deadline
  [[ "$grace" =~ ^[1-9][0-9]*$ ]] || {
    echo "iOS XCTest termination grace must be positive seconds" >&2
    return 2
  }
  for signal in TERM KILL; do
    ios_release_network_process_group_alive "$pgid" || return 0
    kill -s "$signal" -- "-$pgid" >/dev/null 2>&1 || true
    deadline=$((SECONDS + grace))
    while ((SECONDS < deadline)); do
      ios_release_network_process_group_alive "$pgid" || return 0
      sleep 0.05
    done
  done
  ! ios_release_network_process_group_alive "$pgid"
}

ios_release_network_stop_active_processes() {
  local cleanup_failed=0
  local pgid="$IOS_RELEASE_NETWORK_ACTIVE_PGID"
  if [[ -z "$pgid" && -s "$IOS_RELEASE_NETWORK_ACTIVE_PGID_FILE" ]]; then
    pgid="$(<"$IOS_RELEASE_NETWORK_ACTIVE_PGID_FILE")"
  fi
  if [[ "$pgid" =~ ^[1-9][0-9]*$ ]]; then
    ios_release_network_terminate_process_group "$pgid" || cleanup_failed=1
  fi
  IOS_RELEASE_NETWORK_ACTIVE_PGID=""
  [[ -z "$IOS_RELEASE_NETWORK_ACTIVE_PGID_FILE" ]] \
    || rm -f "$IOS_RELEASE_NETWORK_ACTIVE_PGID_FILE" || cleanup_failed=1
  return "$cleanup_failed"
}

ios_release_network_abort_active_run() {
  local cleanup_failed=0
  ios_release_network_stop_active_processes || cleanup_failed=1
  ios_release_network_delete_pending_diagnostics || cleanup_failed=1
  return "$cleanup_failed"
}

ios_release_network_run_bounded_xcode() {
  local label="$1" timeout_secs="$2" launch_timeout_secs="$3"
  local first_marker="$4" log="$5" host_markers="$6"
  local device="$7" process_summary="$8"
  shift 8
  local pid pgid actual_pgid caller_pgid started
  local reason="" status=0 monitor_was_enabled=0
  [[ "$timeout_secs" =~ ^[1-9][0-9]*$ ]] || {
    echo "iOS $label timeout must be positive seconds" >&2
    return 2
  }
  [[ "$launch_timeout_secs" =~ ^[1-9][0-9]*$ ]] || {
    echo "iOS $label launch timeout must be positive seconds" >&2
    return 2
  }
  (($# > 0)) || {
    echo "iOS $label has no xcodebuild command" >&2
    return 2
  }
  local -a capture_command=(
    python3 "$ROOT/scripts/capture-mobile-ios-underlay-output.py"
    "$log" "$host_markers"
  )
  if [[ -n "$device" && -n "$process_summary" ]]; then
    capture_command+=("$device" "$process_summary")
  fi

  [[ "$-" == *m* ]] && monitor_was_enabled=1
  set -m
  (
    set +m
    set +e
    NSUnbufferedIO=YES "$@" 2>&1 | "${capture_command[@]}"
    local -a pipe_status=("${PIPESTATUS[@]}")
    ((pipe_status[0] == 0)) || exit "${pipe_status[0]}"
    exit "${pipe_status[1]}"
  ) &
  pid=$!
  ((monitor_was_enabled)) || set +m
  pgid="$pid"
  actual_pgid="$(
    ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true
  )"
  caller_pgid="$(
    ps -o pgid= -p "$$" 2>/dev/null \
      | tr -d '[:space:]' \
      || true
  )"
  if [[ -n "$actual_pgid" && "$actual_pgid" != "$pgid" ]] \
    || [[ -n "$caller_pgid" && "$pgid" == "$caller_pgid" ]]
  then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
    echo "iOS $label did not receive an isolated process group" >&2
    return 2
  fi
  IOS_RELEASE_NETWORK_ACTIVE_PGID="$pgid"
  if [[ -n "$IOS_RELEASE_NETWORK_ACTIVE_PGID_FILE" ]]; then
    printf '%s\n' "$pgid" >"$IOS_RELEASE_NETWORK_ACTIVE_PGID_FILE"
  fi
  started=$SECONDS
  while ios_release_network_process_group_alive "$pgid"; do
    if [[ -n "$first_marker" \
      && $SECONDS -ge $((started + launch_timeout_secs)) ]] \
      && ! grep -Fq -- "$first_marker" "$log" 2>/dev/null
    then
      reason="launch"
      break
    fi
    if ((SECONDS >= started + timeout_secs)); then
      reason="total"
      break
    fi
    sleep 0.1
  done
  if [[ -n "$reason" ]]; then
    ios_release_network_terminate_process_group "$pgid" || status=1
  fi
  if wait "$pid" 2>/dev/null; then
    :
  else
    status=$?
  fi
  if ios_release_network_process_group_alive "$pgid"; then
    echo "iOS $label left a process-group descendant" >&2
    ios_release_network_terminate_process_group "$pgid" || status=1
  fi
  IOS_RELEASE_NETWORK_ACTIVE_PGID=""
  [[ -z "$IOS_RELEASE_NETWORK_ACTIVE_PGID_FILE" ]] \
    || rm -f "$IOS_RELEASE_NETWORK_ACTIVE_PGID_FILE" || status=1
  if [[ "$reason" == "total" ]]; then
    echo "iOS $label exceeded its ${timeout_secs}s total deadline" >&2
    return 124
  fi
  if [[ "$reason" == "launch" ]]; then
    echo "iOS $label emitted no first test-method marker within ${launch_timeout_secs}s" >&2
    return 125
  fi
  if [[ -n "$first_marker" ]] \
    && ! grep -Fq -- "$first_marker" "$log" 2>/dev/null
  then
    echo "iOS $label exited before emitting its first test-method marker" >&2
    return 125
  fi
  return "$status"
}

ios_release_network_require_unlocked() {
  local device="$1"
  local lock_state
  lock_state="$(mktemp "${TMPDIR:-/tmp}/nvpn-ios-lock-state.XXXXXX.json")"
  if ! xcrun devicectl device info lockState \
    --device "$device" \
    --json-output "$lock_state" \
    --quiet >/dev/null
  then
    rm -f "$lock_state"
    echo "iOS Release gate could not verify that the selected phone is unlocked" >&2
    return 1
  fi
  if ! python3 - "$lock_state" <<'PY'
import json
import sys

result = json.load(open(sys.argv[1], encoding="utf-8")).get("result", {})
if result.get("unlockedSinceBoot") is not True:
    raise SystemExit(1)
if result.get("passcodeRequired") is not False:
    raise SystemExit(1)
PY
  then
    rm -f "$lock_state"
    echo "iOS Release gate requires the selected phone to be unlocked" >&2
    return 1
  fi
  rm -f "$lock_state"
}

ios_release_network_copy_markers() {
  local destination="$1"
  rm -f "$destination"
  xcrun devicectl device copy from \
    --device "$IOS_RELEASE_NETWORK_DEVICE" \
    --domain-type appDataContainer \
    --domain-identifier "$IOS_BUNDLE_ID.UITests.xctrunner" \
    --source "Documents/nvpn-ui-gate-markers.log" \
    --destination "$destination" \
    --quiet >/dev/null
}

ios_release_network_validate_markers() {
  local markers="$1" run_id="$2" label="$3" lifecycle="$4" underlay="$5"
  local direct="$6" start_stop="$7"
  local required
  for required in \
    "NVPN_IOS_RELEASE_RUN_ID=$run_id" \
    "NVPN_IOS_RELEASE_DNS_UI_PERSISTED=$label" \
    "NVPN_IOS_RELEASE_WIREGUARD_UI_PERSISTED=1" \
    "NVPN_IOS_RELEASE_DIRECT_BEFORE_PASSED=1" \
    "NVPN_IOS_RELEASE_EXIT_CONNECTED=$label" \
    "NVPN_IOS_RELEASE_ACTIVE_SESSION_BEGIN_MS=" \
    "NVPN_IOS_RELEASE_ACTIVE_SESSION_END_MS=" \
    "NVPN_IOS_RELEASE_DIRECT_AFTER_PASSED=1" \
    "NVPN_IOS_RELEASE_NETWORK_PASSED=$label"
  do
    if [[ "$required" == *= ]]; then
      [[ "$(grep -Fc "$required" "$markers")" -eq 1 ]] || {
        echo "iOS Release marker occurred zero or multiple times: $required" >&2
        return 1
      }
    else
      [[ "$(grep -Fxc "$required" "$markers")" -eq 1 ]] || {
        echo "iOS Release marker occurred zero or multiple times: $required" >&2
        return 1
      }
    fi
  done
  if bool_is_true "$underlay"; then
    local fresh_dns_host phase recovery
    for phase in \
      REQUESTED OUTAGE RECOVERY_REQUESTED PAYLOAD_RECOVERY VERIFIED
    do
      [[ "$(grep -Fc \
        "NVPN_IOS_UNDERLAY_SWITCH_1_${phase}_MS=" \
        "$markers")" -eq 1 ]] || {
        echo "iOS Wi-Fi radio cycle has no unique $phase receipt" >&2
        return 1
      }
    done
    [[ "$(grep -Fxc \
      "NVPN_IOS_UNDERLAY_SWITCH_1_NO_VALIDATED_PHYSICAL_FALLBACK=1" \
      "$markers")" -eq 1 ]] || {
      echo "iOS Wi-Fi radio-off phase lacks no-fallback proof" >&2
      return 1
    }
    [[ "$(grep -Fxc \
      "NVPN_IOS_UNDERLAY_SWITCH_1_ORIGINAL_WIFI_RESTORED=1" \
      "$markers")" -eq 1 ]] || {
      echo "iOS radio-on phase did not restore the original Wi-Fi" >&2
      return 1
    }
    fresh_dns_host="$(
      sed -n \
        's/^NVPN_IOS_UNDERLAY_SWITCH_1_FRESH_DNS_QUERY=//p' \
        "$markers"
    )"
    [[ "$(grep -Fc \
      "NVPN_IOS_UNDERLAY_SWITCH_1_FRESH_DNS_QUERY=" \
      "$markers")" -eq 1 \
      && "$fresh_dns_host" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\..+ ]] || {
      echo "iOS radio-on phase lacks a unique non-cacheable DNS query" >&2
      return 1
    }
    recovery="$(
      sed -n \
        's/^NVPN_IOS_UNDERLAY_SWITCH_1_PAYLOAD_RECOVERY_MS=//p' \
        "$markers"
    )"
    [[ "$recovery" =~ ^[0-9]+$ ]] \
      && (( recovery <= ${NVPN_MOBILE_UNDERLAY_RECOVERY_MAX_MS:-4000} )) || {
      echo "iOS radio-on phase has no valid <=4s DNS/WireGuard recovery receipt" >&2
      return 1
    }
  fi
  if bool_is_true "$lifecycle"; then
    local cycle
    for cycle in $(seq 1 "${NVPN_IOS_ACTIVE_TUNNEL_LIFECYCLE_CYCLES:-3}"); do
      grep -Fq "NVPN_IOS_RELEASE_BACKGROUND_${cycle}_REQUESTED_MS=" "$markers" \
        && grep -Fq "NVPN_IOS_RELEASE_FOREGROUND_${cycle}_VERIFIED_MS=" "$markers" \
        || {
          echo "iOS Release lifecycle cycle $cycle has no exact marker pair" >&2
          return 1
        }
    done
  fi
  if bool_is_true "$direct"; then
    grep -Fxq "NVPN_IOS_RELEASE_CONNECTED_DIRECT_PASSED=1" "$markers" || {
      echo "iOS Release connected Direct receipt is missing" >&2
      return 1
    }
  fi
  if bool_is_true "$start_stop"; then
    [[ "$(grep -Fxc "NVPN_IOS_RELEASE_START_STOP_RECOVERED=1" "$markers")" -eq 1 ]] || {
      echo "iOS Release rapid start/stop recovery receipt is missing" >&2
      return 1
    }
    local cycle marker
    for cycle in $(seq 1 8); do
      for marker in \
        "NVPN_IOS_RELEASE_RAPID_STOP_REQUESTED_${cycle}_MS=" \
        "NVPN_IOS_RELEASE_RAPID_STOPPED_${cycle}_MS="
      do
        [[ "$(grep -Fc "$marker" "$markers")" -eq 1 ]] || {
          echo "iOS Release rapid start/stop marker occurred zero or multiple times: $marker" >&2
          return 1
        }
      done
    done
  fi
}

run_ios_release_network_case() {
  local label="$1" run_id="$2" spec_base64="$3" lifecycle="$4" underlay="$5"
  local direct="$6" start_stop="$7"
  local result_dir="${NVPN_MOBILE_WG_EXIT_IOS_UI_RESULT_DIR:-$ROOT/artifacts/mobile-ios}"
  local stem="mobile-ios-release-network-$label-$$"
  local log="$result_dir/$stem-xcodebuild.log"
  local host_markers="$result_dir/$stem-host-markers.tsv"
  local markers="$result_dir/$stem-runner-markers.log"
  local process_summary="$result_dir/$stem-processes.json"
  local ping_log="$result_dir/$stem-reverse-payload.log"
  local continuity_summary="$result_dir/$stem-continuity.json"
  local xcresult="$result_dir/$stem.xcresult"
  local xctest_timeout="${NVPN_IOS_XCTEST_CASE_TIMEOUT_SECS:-600}"
  local launch_timeout="${NVPN_IOS_XCTEST_LAUNCH_TIMEOUT_SECS:-45}"
  mkdir -p "$result_dir"
  if bool_is_true "$underlay"; then
    IOS_RELEASE_NETWORK_CLEANUP_SPEC_BASE64="$spec_base64"
  fi
  rm -rf "$xcresult"
  rm -f "$log" "$host_markers" "$markers" "$process_summary" \
    "$ping_log" "$continuity_summary" \
    "${xcresult%.xcresult}-xcresult-summary.json" \
    "${xcresult%.xcresult}-diagnostic-redaction.json"
  if bool_is_true "$underlay"; then
    mobile_continuity_start \
      "$NVPN_MOBILE_UNDERLAY_CONTINUITY_CONTAINER" \
      "$NVPN_MOBILE_UNDERLAY_CONTINUITY_CLIENT_IP" \
      "$ping_log" \
      || return 1
  fi

  local -a command=()
  ios_release_network_require_unlocked "$IOS_RELEASE_NETWORK_DEVICE" || return 1
  ios_release_network_prepare_xctestrun "$label" "$spec_base64" || return 1
  ios_release_network_test_command "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"
  command=("${IOS_RELEASE_NETWORK_XCODE_COMMAND[@]}")
  command+=(
    -resultBundlePath "$xcresult"
    "-only-testing:NostrVpnIosUITests/NostrVpnReleaseNetworkUITests/testReleaseNetworkLifecycle"
    test-without-building
  )
  ios_release_network_register_diagnostics "$spec_base64" "$log" "$xcresult"
  local command_status=0
  if ios_release_network_run_bounded_xcode \
    "Release network case $label" \
    "$xctest_timeout" "$launch_timeout" \
    "NVPN_IOS_RELEASE_RUN_ID=$run_id" \
    "$log" "$host_markers" \
    "$IOS_RELEASE_NETWORK_DEVICE" "$process_summary" \
    "${command[@]}"
  then
    command_status=0
  else
    command_status=$?
  fi
  mobile_continuity_stop
  ios_release_network_delete_private_test_products || {
    echo "iOS Release gate could not delete its private xctestrun" >&2
    return 1
  }
  ios_release_network_preserve_pending_diagnostics || {
    echo "iOS Release gate could not retain safe test diagnostics" >&2
    return 1
  }
  if [[ "$command_status" -ne 0 ]]; then
    ios_release_network_assert_retained_no_secrets \
      "$spec_base64" "$host_markers" \
      "$process_summary" "$ping_log" "$continuity_summary" || return 1
    echo "iOS company-signed Release network case failed; safe diagnostics retained at $result_dir" >&2
    return 1
  fi

  ios_release_network_copy_markers "$markers" || return 1
  ios_release_network_validate_markers \
    "$markers" "$run_id" "$label" "$lifecycle" "$underlay" "$direct" \
    "$start_stop" || return 1
  python3 - \
    "$process_summary" "$underlay" "$lifecycle" "$direct" \
    "${NVPN_IOS_ACTIVE_TUNNEL_LIFECYCLE_CYCLES:-3}" <<'PY'
import json
import sys

def truthy(value):
    return value.lower() in {"1", "true", "yes", "on"}

with open(sys.argv[1], encoding="utf-8") as handle:
    receipt = json.load(handle)
if receipt.get("passed") is not True:
    raise SystemExit("iOS Release process continuity receipt did not pass")
expected = {"active-session-begin", "active-session-end"}
if truthy(sys.argv[2]):
    for phase in (
        "requested",
        "outage",
        "recovery_requested",
        "payload_recovery",
        "verified",
    ):
        expected.add(f"underlay_switch_1_{phase}")
if truthy(sys.argv[3]):
    for cycle in range(1, int(sys.argv[5]) + 1):
        expected.add(f"release_background_{cycle}_requested")
        expected.add(f"release_foreground_{cycle}_verified")
if truthy(sys.argv[4]):
    expected.add("release_connected_direct_passed")
required = set(receipt.get("requiredCheckpoints", []))
observed = set(receipt.get("observedCheckpoints", []))
if required != expected:
    raise SystemExit(
        "iOS Release process sampler did not receive every expected checkpoint"
    )
if not expected.issubset(observed):
    raise SystemExit(
        "iOS Release process sampler did not observe every expected checkpoint"
    )
PY
  if bool_is_true "$underlay"; then
    mobile_continuity_validate \
      "$ROOT" "$ping_log" "$host_markers" "$continuity_summary" \
      iOS "${NVPN_MOBILE_UNDERLAY_RECOVERY_MAX_MS:-4000}" \
      || return 1
  fi
  ios_release_network_audit_artifact "$label" "$result_dir" || return 1
  ios_release_network_assert_retained_no_secrets \
    "$spec_base64" "$host_markers" "$markers" "$process_summary" "$ping_log" \
    "$continuity_summary" \
    "${NVPN_MOBILE_IOS_RELEASE_RECEIPT:-$result_dir/mobile-ios-release-artifact.json}" \
    || return 1
  echo "iOS Release real-network case passed: $label"
}

ios_release_network_disconnect_cleanup_inner() {
  local result_dir="${NVPN_MOBILE_WG_EXIT_IOS_UI_RESULT_DIR:-$ROOT/artifacts/mobile-ios}"
  local stem="${1:-mobile-ios-release-cleanup-$$-$RANDOM}"
  local log="$result_dir/$stem-xcodebuild.log"
  local host_markers="$result_dir/$stem-host-markers.tsv"
  local markers="$result_dir/$stem-runner-markers.log"
  local xcresult="$result_dir/$stem.xcresult"
  local cleanup_timeout="${NVPN_IOS_XCTEST_CLEANUP_TIMEOUT_SECS:-75}"
  local launch_timeout="${NVPN_IOS_XCTEST_LAUNCH_TIMEOUT_SECS:-45}"
  local -a command=()
  local command_status=0
  mkdir -p "$result_dir"
  rm -rf "$xcresult"
  rm -f "$log" "$host_markers" "$markers" \
    "${xcresult%.xcresult}-xcresult-summary.json" \
    "${xcresult%.xcresult}-diagnostic-redaction.json"
  ios_release_network_require_unlocked "$IOS_RELEASE_NETWORK_DEVICE" || return 1
  ios_release_network_delete_private_test_products || return 1
  ios_release_network_prepare_xctestrun \
    cleanup "$IOS_RELEASE_NETWORK_CLEANUP_SPEC_BASE64" || return 1
  ios_release_network_test_command "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"
  command=("${IOS_RELEASE_NETWORK_XCODE_COMMAND[@]}")
  command+=(
    -resultBundlePath "$xcresult"
    "-only-testing:NostrVpnIosUITests/NostrVpnReleaseNetworkUITests/testReleaseDisconnectCleanup"
    test-without-building
  )
  ios_release_network_register_diagnostics \
    "$IOS_RELEASE_NETWORK_CLEANUP_SPEC_BASE64" "$log" "$xcresult"
  if ios_release_network_run_bounded_xcode \
    "Release disconnect cleanup" \
    "$cleanup_timeout" "$launch_timeout" "NVPN_XCUITEST_STARTED=1" \
    "$log" "$host_markers" "" "" \
    "${command[@]}"
  then
    command_status=0
  else
    command_status=$?
  fi
  ios_release_network_delete_private_test_products || {
    echo "iOS Release cleanup could not delete its private xctestrun" >&2
    return 1
  }
  ios_release_network_preserve_pending_diagnostics || {
    echo "iOS Release cleanup could not retain safe diagnostics" >&2
    return 1
  }
  if [[ "$command_status" -ne 0 ]]; then
    echo "iOS Release cleanup failed; safe diagnostics retained at $result_dir" >&2
    return 1
  fi
  ios_release_network_copy_markers "$markers" || return 1
  grep -Fxq "NVPN_IOS_RELEASE_DISCONNECT_PASSED=1" "$markers" \
    && {
      [[ -z "$IOS_RELEASE_NETWORK_CLEANUP_SPEC_BASE64" ]] \
        || grep -Fxq "NVPN_IOS_RELEASE_HOME_WIFI_RESTORED=1" "$markers"
    } \
    && ios_release_network_assert_retained_no_secrets \
      "$IOS_RELEASE_NETWORK_CLEANUP_SPEC_BASE64" \
      "$host_markers" "$markers"
}

ios_release_network_disconnect_cleanup() {
  local cleanup_failed=0
  ios_release_network_abort_active_run || cleanup_failed=1
  if [[ "$IOS_RELEASE_NETWORK_PREPARED" -eq 1 ]]; then
    local timeout="${NVPN_IOS_DISCONNECT_CLEANUP_TOTAL_TIMEOUT_SECS:-90}"
    local grace="${NVPN_IOS_XCTEST_TERM_GRACE_SECS:-5}"
    local result_dir="${NVPN_MOBILE_WG_EXIT_IOS_UI_RESULT_DIR:-$ROOT/artifacts/mobile-ios}"
    local stem="mobile-ios-release-cleanup-$$-$RANDOM"
    local xcresult="$result_dir/$stem.xcresult"
    local marker pid watchdog status=0 monitor_was_enabled=0 actual_pgid
    [[ "$timeout" =~ ^[1-9][0-9]*$ \
      && "$grace" =~ ^[1-9][0-9]*$ ]] || {
      echo "iOS disconnect cleanup deadlines must be positive seconds" >&2
      return 2
    }
    marker="$(mktemp "${TMPDIR:-/tmp}/nvpn-ios-cleanup-active.XXXXXX")"
    ios_release_network_register_diagnostics \
      "$IOS_RELEASE_NETWORK_CLEANUP_SPEC_BASE64" \
      "$result_dir/$stem-xcodebuild.log" "$xcresult"
    [[ "$-" == *m* ]] && monitor_was_enabled=1
    set -m
    (
      set +m
      trap 'ios_release_network_abort_active_run; ios_release_network_delete_private_test_products; rm -f "$marker"; exit 124' TERM INT
      trap 'rm -f "$marker"' EXIT
      ios_release_network_disconnect_cleanup_inner "$stem"
    ) &
    pid=$!
    ((monitor_was_enabled)) || set +m
    actual_pgid="$(
      ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true
    )"
    if [[ -n "$actual_pgid" && "$actual_pgid" != "$pid" ]]; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      rm -f "$marker"
      ios_release_network_delete_pending_diagnostics || true
      echo "iOS disconnect cleanup received no isolated process group" >&2
      return 2
    fi
    (
      sleep "$timeout"
      [[ -e "$marker" ]] || exit 0
      kill -s TERM -- "-$pid" >/dev/null 2>&1 || true
      sleep "$grace"
      [[ -e "$marker" ]] || exit 0
      kill -s KILL -- "-$pid" >/dev/null 2>&1 || true
    ) &
    watchdog=$!
    if wait "$pid" 2>/dev/null; then
      :
    else
      status=$?
    fi
    kill "$watchdog" >/dev/null 2>&1 || true
    wait "$watchdog" >/dev/null 2>&1 || true
    rm -f "$marker"
    ios_release_network_stop_active_processes || cleanup_failed=1
    if [[ -s "${xcresult%.xcresult}-diagnostic-redaction.json" ]]; then
      ios_release_network_clear_pending_diagnostics
    else
      ios_release_network_delete_pending_diagnostics || cleanup_failed=1
    fi
    if [[ "$status" -eq 124 || "$status" -eq 137 ]]; then
      echo "iOS disconnect cleanup exceeded its ${timeout}s total deadline" >&2
    fi
    [[ "$status" -eq 0 ]] || cleanup_failed=1
  fi
  ios_release_network_cleanup_private_artifacts || cleanup_failed=1
  return "$cleanup_failed"
}
