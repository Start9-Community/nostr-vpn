#!/usr/bin/env bash

ios_lifecycle_copy_result() {
  local device="$1"
  local bundle_id="$2"
  local result_name="$3"
  local destination="$4"
  rm -f "$destination"
  xcrun devicectl device copy from \
    --device "$device" \
    --domain-type appDataContainer \
    --domain-identifier "$bundle_id" \
    --source "Library/Application Support/Nostr VPN Debug Results/$result_name" \
    --destination "$destination" \
    --quiet
}

ios_lifecycle_wait_for_phase() {
  local device="$1"
  local bundle_id="$2"
  local result_name="$3"
  local expected_phase="$4"
  local expected_core="$5"
  local previous_transition="$6"
  local artifact="$7"
  local attempt transition

  for attempt in $(seq 1 24); do
    if ios_lifecycle_copy_result \
      "$device" "$bundle_id" "$result_name" "$artifact" 2>/dev/null
    then
      if transition="$(python3 - \
        "$artifact" "$expected_phase" "$expected_core" "$previous_transition" <<'PY'
import json
import sys

path, expected_phase, expected_core_raw, previous_raw = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    result = json.load(handle)
expected_core = expected_core_raw == "true"
transition = result.get("transition")
if (
    result.get("ok") is True
    and result.get("phase") == expected_phase
    and result.get("nativeCoreAvailable") is expected_core
    and isinstance(transition, int)
    and transition > int(previous_raw)
):
    print(transition)
else:
    raise SystemExit(1)
PY
      )"; then
        printf '%s\n' "$transition"
        return 0
      fi
    fi
    sleep 0.25
  done
  printf 'iOS lifecycle gate did not observe %s with native core=%s\n' \
    "$expected_phase" "$expected_core" >&2
  return 1
}

run_ios_app_lifecycle_gate() {
  local device="$1"
  local bundle_id="$2"
  local result_dir="$3"
  local cycles="$4"
  local result_name="mobile-ios-lifecycle-$$-$RANDOM.json"
  local background_dwell="${NVPN_IOS_LIFECYCLE_BACKGROUND_DWELL_SECS:-10}"
  local transition=0
  local cycle phase_artifact

  mkdir -p "$result_dir"
  ios_device_launch \
    "$device" "$bundle_id" \
    --nvpn-debug-lifecycle-result "$result_name" >/dev/null

  for cycle in $(seq 1 "$cycles"); do
    xcrun devicectl device process launch \
      --device "$device" \
      com.apple.Preferences \
      --quiet >/dev/null
    phase_artifact="$result_dir/${result_name%.json}-cycle-$cycle-background.json"
    transition="$(ios_lifecycle_wait_for_phase \
      "$device" "$bundle_id" "$result_name" background false \
      "$transition" "$phase_artifact")" || return
    if [[ "$cycle" -eq 1 ]] && [[ "$background_dwell" != "0" ]]; then
      sleep "$background_dwell"
    fi

    ios_device_launch "$device" "$bundle_id" >/dev/null
    phase_artifact="$result_dir/${result_name%.json}-cycle-$cycle-active.json"
    transition="$(ios_lifecycle_wait_for_phase \
      "$device" "$bundle_id" "$result_name" active true \
      "$transition" "$phase_artifact")" || return
  done

  printf 'iOS background/foreground lifecycle gate passed: %s cycles\n' "$cycles"
}
