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
IOS_RELEASE_NETWORK_XCTESTRUN=""
IOS_RELEASE_NETWORK_CASE_XCTESTRUN=""
IOS_RELEASE_NETWORK_DEVICE_RECEIPT=""
IOS_RELEASE_NETWORK_CLEANUP_SPEC_BASE64=""
IOS_RELEASE_NETWORK_FIPS_TREE=""
IOS_RELEASE_NETWORK_APP_HEAD=""
IOS_RELEASE_NETWORK_APP_TREE=""
IOS_RELEASE_NETWORK_XCODE_COMMAND=()

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
  [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]] || {
    echo "iOS Release network gate requires a clean app checkout" >&2
    return 1
  }
  if [[ -n "${NVPN_BUILD_GIT_SHA:-}" \
    && "$NVPN_BUILD_GIT_SHA" != "$IOS_RELEASE_NETWORK_APP_HEAD" ]]
  then
    echo "iOS Release build revision does not match the exact app checkout" >&2
    return 1
  fi
  local configured_team="${NVPN_IOS_TEAM_ID:-}"
  local signer_organization="${NVPN_IOS_EXPECTED_SIGNER_ORGANIZATION:-Sirius Business Oy}"
  local expected_device_name="${NVPN_IOS_EXPECTED_DEVICE_NAME:-}"
  local fips_path="${NVPN_FIPS_REPO_PATH:-}"
  local expected_fips="${NVPN_EXPECTED_FIPS_GIT_SHA:-}"
  [[ -n "$expected_device_name" ]] || {
    echo "iOS Release gate requires an explicit expected physical device name" >&2
    return 1
  }
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
  if [[ -n "$configured_team" && "$configured_team" != "$team" ]]; then
    echo "Configured iOS team is not the Sirius Business signing team" >&2
    return 1
  fi
  export NVPN_IOS_TEAM_ID="$team"
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
  if [[ -n "$expected_fips" && "$expected_fips" != "$fips_head" ]]; then
    echo "iOS Release network gate FIPS mismatch" >&2
    return 1
  fi
  export NVPN_EXPECTED_FIPS_GIT_SHA="$fips_head"
  export NVPN_EXPECTED_FIPS_VERSION="$fips_version"
  IOS_RELEASE_NETWORK_FIPS_TREE="$fips_tree"
  export NVPN_IOS_RUST_PROFILE=release

  IOS_RELEASE_NETWORK_SIGNING_DIR="$ROOT/ios/.build/ReleaseNetworkSigning"
  IOS_RELEASE_NETWORK_SIGNING_ENV="$IOS_RELEASE_NETWORK_SIGNING_DIR/provisioning.env"
  IOS_RELEASE_NETWORK_DERIVED_DATA="${NVPN_MOBILE_IOS_RELEASE_DERIVED_DATA:-$ROOT/ios/.build/ReleaseNetworkDerivedData}"
  mkdir -p "$IOS_RELEASE_NETWORK_SIGNING_DIR" \
    "${NVPN_MOBILE_WG_EXIT_IOS_UI_RESULT_DIR:-$ROOT/artifacts/mobile-ios}"
  local device_details device_udid
  device_details="$IOS_RELEASE_NETWORK_SIGNING_DIR/selected-device-details.json"
  IOS_RELEASE_NETWORK_DEVICE_RECEIPT="$IOS_RELEASE_NETWORK_SIGNING_DIR/selected-device-receipt.json"
  if ! xcrun devicectl device info details \
    --device "$device" \
    --json-output "$device_details" \
    --quiet >/dev/null
  then
    echo "iOS Release gate could not read back its explicitly selected phone" >&2
    return 1
  fi
  if ! python3 - \
    "$device_details" "$IOS_RELEASE_NETWORK_DEVICE_RECEIPT" \
    "$expected_device_name" "${NVPN_IOS_EXPECTED_DEVICE_MODEL:-}" <<'PY'
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
    "explicitPhysicalDeviceVerified": True,
    "model": model,
    "osVersion": str(device.get("osVersionNumber", "")),
    "platform": "iOS",
    "productType": str(hardware.get("productType", "")),
}
with open(receipt_path, "w", encoding="utf-8") as output:
    json.dump(receipt, output, indent=2, sort_keys=True)
    output.write("\n")
PY
  then
    echo "iOS Release gate rejected the selected physical phone" >&2
    return 1
  fi
  device_udid="$(
    python3 - "$device_details" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
value = value["result"]["hardwareProperties"]["udid"]
print(value)
PY
  )"
  IOS_RELEASE_NETWORK_DEVICE="$device_udid"
  IOS_RELEASE_NETWORK_DESTINATION="platform=iOS,id=$device_udid"

  local profile_log="$IOS_RELEASE_NETWORK_SIGNING_DIR/ios-profiles.log"
  if ! NVPN_IOS_PROFILE_TYPE=IOS_APP_ADHOC \
    NVPN_IOS_PROFILE_NAME="Nostr VPN Ad Hoc main physical gate" \
    NVPN_IOS_PACKET_TUNNEL_PROFILE_NAME="Nostr VPN Ad Hoc packet tunnel physical gate" \
    NVPN_IOS_CODE_SIGN_IDENTITY="$company_identity" \
    NVPN_IOS_DEVICE_UDIDS="$device_udid" \
    NVPN_IOS_PROFILES_ENV_PATH="$IOS_RELEASE_NETWORK_SIGNING_ENV" \
    "$ROOT/scripts/ios-profiles" ensure >"$profile_log" 2>&1
  then
    echo "Unable to prepare company Ad Hoc signing; private details are in $profile_log" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$IOS_RELEASE_NETWORK_SIGNING_ENV"
  : "${NVPN_IOS_CODE_SIGN_IDENTITY:?iOS Release signing identity is missing}"
  : "${NVPN_IOS_PROVISIONING_PROFILE_UUID:?iOS Release app profile is missing}"
  : "${NVPN_IOS_PACKET_TUNNEL_PROVISIONING_PROFILE_UUID:?iOS Release tunnel profile is missing}"
  [[ "$NVPN_IOS_CODE_SIGN_IDENTITY" == "$company_identity" ]] || {
    echo "iOS Release profile preparation changed the explicit company signer" >&2
    return 1
  }

  local reuse_build="${NVPN_MOBILE_WG_EXIT_REUSE_IOS_BUILD:-0}"
  local result_dir build_log xctestrun_count
  result_dir="${NVPN_MOBILE_WG_EXIT_IOS_UI_RESULT_DIR:-$ROOT/artifacts/mobile-ios}"
  build_log="$result_dir/mobile-ios-release-build-for-testing-$$.log"
  if bool_is_true "$reuse_build"; then
    ios_release_network_audit_rust_feature_surface || return 1
  else
    NVPN_IOS_RUST_PROFILE=release "$ROOT/tools/run-ios" xcframework
    "$ROOT/tools/run-ios" project
    ios_release_network_audit_rust_feature_surface || return 1
    [[ -z "$(git -C "$fips_path" status --porcelain)" ]] || {
      echo "iOS Release FIPS build left the exact checkout dirty" >&2
      return 1
    }
    ios_release_network_xcode_command
    local -a build_command=("${IOS_RELEASE_NETWORK_XCODE_COMMAND[@]}")
    build_command+=(build-for-testing)
    if ! "${build_command[@]}" >"$build_log" 2>&1; then
      tail -n 160 "$build_log" >&2
      echo "iOS company-signed Release build-for-testing failed" >&2
      return 1
    fi
  fi
  if [[ -n "${NVPN_MOBILE_IOS_RELEASE_XCTESTRUN:-}" ]]; then
    IOS_RELEASE_NETWORK_XCTESTRUN="$NVPN_MOBILE_IOS_RELEASE_XCTESTRUN"
  else
    xctestrun_count="$(
      find "$IOS_RELEASE_NETWORK_DERIVED_DATA/Build/Products" \
        -maxdepth 1 -type f -name 'NostrVpnIos_*.xctestrun' \
        | wc -l \
        | tr -d ' '
    )"
    if [[ "$xctestrun_count" != "1" ]]; then
      echo "iOS Release build produced $xctestrun_count xctestrun files, expected one" >&2
      return 1
    fi
    IOS_RELEASE_NETWORK_XCTESTRUN="$(
      find "$IOS_RELEASE_NETWORK_DERIVED_DATA/Build/Products" \
        -maxdepth 1 -type f -name 'NostrVpnIos_*.xctestrun' \
        | head -n 1
    )"
  fi
  [[ -s "$IOS_RELEASE_NETWORK_XCTESTRUN" ]] || {
    echo "iOS Release build-for-testing did not preserve its xctestrun" >&2
    return 1
  }
  IOS_RELEASE_NETWORK_PREPARED=1
  if bool_is_true "$reuse_build"; then
    echo "iOS company-signed Release network gate reused its preserved build"
  else
    echo "iOS company-signed Release network gate prepared once: $build_log"
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
  [[ "$label" =~ ^[a-zA-Z0-9._-]+$ ]] || {
    echo "iOS Release xctestrun label is invalid" >&2
    return 1
  }
  [[ -s "$IOS_RELEASE_NETWORK_XCTESTRUN" ]] || {
    echo "iOS Release base xctestrun is missing" >&2
    return 1
  }
  IOS_RELEASE_NETWORK_CASE_XCTESTRUN="$(
    mktemp "${TMPDIR:-/tmp}/NostrVpnIos-$label.XXXXXX.xctestrun"
  )"
  cp "$IOS_RELEASE_NETWORK_XCTESTRUN" "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"
  chmod 600 "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"
  if ! /usr/libexec/PlistBuddy \
    -c "Set :NostrVpnIosUITests:EnvironmentVariables:NVPN_XCUITEST_RELEASE_NETWORK_GATE 1" \
    "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"
  then
    rm -f "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"
    IOS_RELEASE_NETWORK_CASE_XCTESTRUN=""
    return 1
  fi
  if [[ -n "$spec_base64" ]]; then
    if ! /usr/libexec/PlistBuddy \
      -c "Set :NostrVpnIosUITests:EnvironmentVariables:NVPN_XCUITEST_RELEASE_NETWORK_SPEC_BASE64 $spec_base64" \
      "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"
    then
      rm -f "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"
      IOS_RELEASE_NETWORK_CASE_XCTESTRUN=""
      return 1
    fi
  fi
}

ios_release_network_delete_private_test_products() {
  local xcresult="${1:-}" log="${2:-}"
  if [[ -n "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN" ]]; then
    rm -f "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"
    IOS_RELEASE_NETWORK_CASE_XCTESTRUN=""
  fi
  [[ -z "$xcresult" ]] || rm -rf "$xcresult"
  [[ -z "$log" ]] || rm -f "$log"
}

ios_release_network_assert_retained_no_secrets() {
  local spec_base64="$1"
  shift
  [[ -n "$spec_base64" ]] || return 0
  NVPN_PRIVATE_RELEASE_SPEC_BASE64="$spec_base64" python3 - "$@" <<'PY'
import base64
import hashlib
import json
import os
import pathlib
import sys

encoded = os.environ["NVPN_PRIVATE_RELEASE_SPEC_BASE64"]
raw = base64.b64decode(encoded, validate=True)
spec = json.loads(raw)
needles = {
    encoded.encode(),
    raw,
    hashlib.sha256(raw).hexdigest().encode(),
    hashlib.sha256(encoded.encode()).hexdigest().encode(),
}
for key in (
    "wireGuardConfig",
    "underlayHomePassphrase",
    "underlayAlternatePassphrase",
):
    value = spec.get(key)
    if isinstance(value, str) and value:
        needles.add(value.encode())
wireguard = spec.get("wireGuardConfig", "")
for line in wireguard.splitlines():
    if line.strip().lower().startswith("privatekey"):
        _, _, value = line.partition("=")
        if value.strip():
            needles.add(value.strip().encode())
for raw_path in sys.argv[1:]:
    path = pathlib.Path(raw_path)
    if not path.is_file():
        continue
    data = path.read_bytes()
    if any(len(needle) >= 8 and needle in data for needle in needles):
        raise SystemExit("retained iOS artifact contains private gate input")
PY
}

ios_release_network_test_command() {
  local xctestrun="$1"
  IOS_RELEASE_NETWORK_XCODE_COMMAND=(
    xcodebuild
    -quiet
    -xctestrun "$xctestrun"
    -destination "$IOS_RELEASE_NETWORK_DESTINATION"
    -destination-timeout 60
    -collect-test-diagnostics never
  )
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
  local markers="$1" run_id="$2" label="$3" lifecycle="$4" underlay="$5" direct="$6"
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
    local cycle recovery
    for cycle in 1 2; do
      recovery="$(
        sed -n \
          "s/^NVPN_IOS_UNDERLAY_SWITCH_${cycle}_PAYLOAD_RECOVERY_MS=//p" \
          "$markers"
      )"
      [[ "$recovery" =~ ^[0-9]+$ ]] \
        && (( recovery <= ${NVPN_MOBILE_UNDERLAY_RECOVERY_MAX_MS:-4000} )) || {
        echo "iOS switch $cycle has no valid <=4s same-clock recovery receipt" >&2
        return 1
      }
    done
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
}

run_ios_release_network_case() {
  local label="$1" run_id="$2" spec_base64="$3" lifecycle="$4" underlay="$5" direct="$6"
  local result_dir="${NVPN_MOBILE_WG_EXIT_IOS_UI_RESULT_DIR:-$ROOT/artifacts/mobile-ios}"
  local stem="mobile-ios-release-network-$label-$$"
  local log="$result_dir/$stem-xcodebuild.log"
  local host_markers="$result_dir/$stem-host-markers.tsv"
  local markers="$result_dir/$stem-runner-markers.log"
  local process_summary="$result_dir/$stem-processes.json"
  local ping_log="$result_dir/$stem-reverse-payload.log"
  local continuity_summary="$result_dir/$stem-continuity.json"
  local xcresult="$result_dir/$stem.xcresult"
  mkdir -p "$result_dir"
  if bool_is_true "$underlay"; then
    IOS_RELEASE_NETWORK_CLEANUP_SPEC_BASE64="$spec_base64"
  fi
  rm -rf "$xcresult"
  rm -f "$log" "$host_markers" "$markers" "$process_summary" \
    "$ping_log" "$continuity_summary"
  if bool_is_true "$underlay"; then
    mobile_continuity_start \
      "$NVPN_MOBILE_UNDERLAY_CONTINUITY_CONTAINER" \
      "$NVPN_MOBILE_UNDERLAY_CONTINUITY_CLIENT_IP" \
      "$ping_log" \
      || return 1
  fi

  local -a command=()
  ios_release_network_prepare_xctestrun "$label" "$spec_base64" || return 1
  ios_release_network_test_command "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"
  command=("${IOS_RELEASE_NETWORK_XCODE_COMMAND[@]}")
  command+=(
    -resultBundlePath "$xcresult"
    "-only-testing:NostrVpnIosUITests/NostrVpnReleaseNetworkUITests/testReleaseNetworkLifecycle"
    test-without-building
  )
  local command_status=0
  set +e
  NSUnbufferedIO=YES "${command[@]}" 2>&1 \
    | python3 "$ROOT/scripts/capture-mobile-ios-underlay-output.py" \
      "$log" "$host_markers" \
      "$IOS_RELEASE_NETWORK_DEVICE" "$process_summary"
  local -a pipeline_status=("${PIPESTATUS[@]}")
  set -e
  command_status="${pipeline_status[0]}"
  if [[ "$command_status" -eq 0 && "${pipeline_status[1]}" -ne 0 ]]; then
    command_status="${pipeline_status[1]}"
  fi
  mobile_continuity_stop
  ios_release_network_delete_private_test_products "$xcresult" "$log"
  if [[ "$command_status" -ne 0 ]]; then
    ios_release_network_assert_retained_no_secrets \
      "$spec_base64" "$host_markers" "$process_summary" "$ping_log" \
      "$continuity_summary" || return 1
    echo "iOS company-signed Release network case failed; private diagnostics were deleted" >&2
    return 1
  fi

  ios_release_network_copy_markers "$markers" || return 1
  ios_release_network_validate_markers \
    "$markers" "$run_id" "$label" "$lifecycle" "$underlay" "$direct" || return 1
  python3 - "$process_summary" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    receipt = json.load(handle)
if receipt.get("passed") is not True:
    raise SystemExit("iOS Release process continuity receipt did not pass")
PY
  if bool_is_true "$underlay"; then
    mobile_continuity_validate \
      "$ROOT" "$ping_log" "$host_markers" "$continuity_summary" \
      iOS "${NVPN_MOBILE_UNDERLAY_RECOVERY_MAX_MS:-4000}" \
      || return 1
  fi
  ios_release_network_audit_artifact "$label" "$result_dir" || return 1
  ios_release_network_assert_retained_no_secrets \
    "$spec_base64" "$host_markers" "$markers" "$process_summary" \
    "$ping_log" "$continuity_summary" \
    "${NVPN_MOBILE_IOS_RELEASE_RECEIPT:-$result_dir/mobile-ios-release-artifact.json}" \
    || return 1
  echo "iOS Release real-network case passed: $label"
}

ios_release_network_disconnect_cleanup() {
  [[ "$IOS_RELEASE_NETWORK_PREPARED" -eq 1 ]] || return 0
  local result_dir="${NVPN_MOBILE_WG_EXIT_IOS_UI_RESULT_DIR:-$ROOT/artifacts/mobile-ios}"
  local log="$result_dir/mobile-ios-release-cleanup-$$.log"
  local markers="$result_dir/mobile-ios-release-cleanup-markers-$$.log"
  local -a command=()
  ios_release_network_delete_private_test_products
  ios_release_network_prepare_xctestrun \
    cleanup "$IOS_RELEASE_NETWORK_CLEANUP_SPEC_BASE64" || return 1
  ios_release_network_test_command "$IOS_RELEASE_NETWORK_CASE_XCTESTRUN"
  command=("${IOS_RELEASE_NETWORK_XCODE_COMMAND[@]}")
  command+=(
    "-only-testing:NostrVpnIosUITests/NostrVpnReleaseNetworkUITests/testReleaseDisconnectCleanup"
    test-without-building
  )
  if ! NSUnbufferedIO=YES "${command[@]}" >"$log" 2>&1; then
    ios_release_network_delete_private_test_products "" "$log"
    echo "iOS Release cleanup failed; private diagnostics were deleted" >&2
    return 1
  fi
  ios_release_network_delete_private_test_products "" "$log"
  ios_release_network_copy_markers "$markers" \
    && grep -Fxq "NVPN_IOS_RELEASE_DISCONNECT_PASSED=1" "$markers" \
    && {
      [[ -z "$IOS_RELEASE_NETWORK_CLEANUP_SPEC_BASE64" ]] \
        || grep -Fxq "NVPN_IOS_RELEASE_HOME_WIFI_RESTORED=1" "$markers"
    } \
    && ios_release_network_assert_retained_no_secrets \
      "$IOS_RELEASE_NETWORK_CLEANUP_SPEC_BASE64" "$markers"
}
