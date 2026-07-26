#!/usr/bin/env bash

# Production-path probes shared by the debug diagnostic lane and the Release
# black-box lane. The probe runs as Android's shell UID, outside the app
# process, so it exercises the device VPN routing policy without app test hooks.

android_build_captured_network_probe() {
  [[ -n "$ANDROID_CAPTURED_PROBE_REMOTE_JAR" ]] && return 0
  local sdk d8 local_jar compiled_class
  local -a class_files=()
  command -v javac >/dev/null 2>&1 || {
    echo "Android captured network probe requires javac" >&2
    return 1
  }
  sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -z "$sdk" ]]; then
    sdk="$(sdk_from_local_properties)"
  fi
  [[ -n "$sdk" ]] || sdk="$HOME/Library/Android/sdk"
  d8="$(
    find "$sdk/build-tools" -maxdepth 2 -type f -name d8 2>/dev/null \
      | sort -V \
      | tail -n 1
  )"
  [[ -x "$d8" ]] || {
    echo "Android captured network probe requires Android SDK d8" >&2
    return 1
  }
  ANDROID_CAPTURED_PROBE_BUILD_DIR="$(
    mktemp -d "${TMPDIR:-/tmp}/nvpn-android-captured-probe.XXXXXX"
  )"
  local_jar="$ANDROID_CAPTURED_PROBE_BUILD_DIR/mobile-android-captured-probe.jar"
  javac \
    --release 8 \
    -d "$ANDROID_CAPTURED_PROBE_BUILD_DIR" \
    "$ROOT/scripts/MobileAndroidCapturedNetworkProbe.java"
  while IFS= read -r -d '' compiled_class; do
    class_files+=("$compiled_class")
  done < <(
    find "$ANDROID_CAPTURED_PROBE_BUILD_DIR" \
      -maxdepth 1 \
      -type f \
      -name 'MobileAndroidCapturedNetworkProbe*.class' \
      -print0
  )
  if ((${#class_files[@]} < 2)); then
    echo "Android captured network probe did not compile" >&2
    return 1
  fi
  "$d8" --min-api 26 --output "$local_jar" "${class_files[@]}" >/dev/null
  [[ -s "$local_jar" ]] || {
    echo "Android captured network probe dex archive is missing" >&2
    return 1
  }
  ANDROID_CAPTURED_PROBE_REMOTE_JAR="/data/local/tmp/nvpn-captured-probe-$$.jar"
  "$ADB" -s "$serial" push "$local_jar" "$ANDROID_CAPTURED_PROBE_REMOTE_JAR" \
    >/dev/null
}

run_android_captured_network_probe() {
  local label="$1"
  [[ -n "$CAPTURED_PROBE_URL" && -n "$CAPTURED_PROBE_TOKEN" ]] || {
    echo "Android WireGuard exit gate requires its controlled captured-UID HTTP probe" >&2
    return 1
  }
  [[ -n "$EXIT_SOURCE_PROBE_URL" && -n "$EXPECTED_EXIT_SOURCE_IP" ]] || {
    echo "Android WireGuard exit gate requires its external exit-source receipt" >&2
    return 1
  }
  [[ "$CAPTURED_PROBE_TOKEN" =~ ^[a-zA-Z0-9_-]+$ ]] || {
    echo "Android captured HTTP token is invalid" >&2
    return 1
  }
  android_build_captured_network_probe || return 1
  copy_android_runtime_state || return 1
  local baseline_read baseline_written baseline_dropped
  local current_read current_written current_dropped
  local result_path deadline
  baseline_read="$(android_runtime_state_number tunPacketsRead)"
  baseline_written="$(android_runtime_state_number tunPacketsWritten)"
  baseline_dropped="$(android_runtime_state_number tunPacketsDropped)"
  result_path="$(android_network_probe_path "$label-captured-http-https")"
  if ! "$ADB" -s "$serial" shell \
      env "CLASSPATH=$ANDROID_CAPTURED_PROBE_REMOTE_JAR" \
      app_process /system/bin MobileAndroidCapturedNetworkProbe \
      "$CAPTURED_PROBE_URL" "$CAPTURED_PROBE_TOKEN" "$EXIT_PROBE_URL" \
      "$EXIT_SOURCE_PROBE_URL" "$EXPECTED_EXIT_SOURCE_IP" \
      >"$result_path" 2>&1
  then
    echo "Android captured shell-UID HTTP/HTTPS probe failed: $result_path" >&2
    return 1
  fi
  if ! grep -Fq "token=$CAPTURED_PROBE_TOKEN" "$result_path" \
    || ! grep -Fq "exitSourceIp=$EXPECTED_EXIT_SOURCE_IP" "$result_path" \
    || ! grep -Eq 'capturedHttpStatus=200 capturedHttpsStatus=[23][0-9][0-9]' \
      "$result_path"
  then
    echo "Android captured shell-UID network receipt is incomplete: $result_path" >&2
    return 1
  fi
  deadline=$((SECONDS + TUN_PACKET_PROBE_WAIT_SECS))
  while ((SECONDS < deadline)); do
    if copy_android_runtime_state; then
      current_read="$(android_runtime_state_number tunPacketsRead 2>/dev/null || true)"
      current_written="$(
        android_runtime_state_number tunPacketsWritten 2>/dev/null || true
      )"
      current_dropped="$(
        android_runtime_state_number tunPacketsDropped 2>/dev/null || true
      )"
      if [[ "$current_read" =~ ^[0-9]+$ \
        && "$current_written" =~ ^[0-9]+$ \
        && "$current_dropped" =~ ^[0-9]+$ ]] \
        && (( current_read > baseline_read )) \
        && (( current_written > baseline_written )) \
        && (( current_dropped == baseline_dropped ))
      then
        {
          printf 'tunPacketsRead=%s->%s\n' "$baseline_read" "$current_read"
          printf 'tunPacketsWritten=%s->%s\n' \
            "$baseline_written" "$current_written"
          printf 'tunPacketsDropped=%s->%s\n' \
            "$baseline_dropped" "$current_dropped"
        } >>"$result_path"
        echo "Android captured shell-UID HTTP + authenticated HTTPS passed through the active TUN after $label: $result_path"
        return 0
      fi
    fi
    sleep 0.1
  done
  echo "Android captured HTTP/HTTPS succeeded but TUN counters did not prove capture: $result_path" >&2
  return 1
}
