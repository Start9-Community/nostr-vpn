#!/usr/bin/env bash
# Build the installable Release APK from the exact Play AAB so physical-device
# gates and Play publication exercise one canonical Android artifact graph.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLETOOL_VERSION="1.18.3"
BUNDLETOOL_SHA256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
BUNDLETOOL_URL="https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar"
BUNDLE_DIR="$ROOT/android/app/build/outputs/bundle/release"
APK_DIR="$ROOT/android/app/build/outputs/apk/release"
AAB="$BUNDLE_DIR/app-release.aab"
APK="$APK_DIR/app-release.apk"
RECEIPT="$BUNDLE_DIR/physical-gate-artifact.json"
CACHE_DIR="${NVPN_BUNDLETOOL_CACHE_DIR:-$HOME/.cache/nvpn/bundletool}"
BUNDLETOOL_JAR="${NVPN_BUNDLETOOL_JAR:-$CACHE_DIR/bundletool-all-${BUNDLETOOL_VERSION}.jar}"
TEMP_DIR=""
APK_STAGE=""
RECEIPT_STAGE=""
ARTIFACTS_COMMITTED=0
LOCK_DIR="$BUNDLE_DIR/.physical-gate-artifact.lock"
LOCK_OWNED=0

fail() {
  echo "Android AAB-derived Release APK failed: $*" >&2
  exit 1
}

invalidate_gate_artifacts() {
  rm -f "$APK" "$RECEIPT"
}

acquire_gate_lock() {
  local owner attempt
  for attempt in 1 2; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_OWNED=1
      printf '%s\n' "$$" >"$LOCK_DIR/owner" \
        || fail "could not record the Android gate artifact lock owner"
      return 0
    fi
    [[ -d "$LOCK_DIR" && ! -L "$LOCK_DIR" ]] \
      || fail "Android gate artifact lock path is unsafe"
    owner="$(cat "$LOCK_DIR/owner" 2>/dev/null || true)"
    [[ "$owner" =~ ^[1-9][0-9]*$ ]] \
      || fail "Android gate artifact lock has no owner"
    kill -0 "$owner" >/dev/null 2>&1 \
      && fail "another Android gate artifact builder is active"
    rm -f "$LOCK_DIR/owner"
    rmdir "$LOCK_DIR" \
      || fail "stale Android gate artifact lock is not empty"
  done
  fail "could not acquire the Android gate artifact lock"
}

extract_single_universal_apk() {
  local archive="$1" output="$2"
  [[ -f "$archive" && ! -L "$archive" ]] \
    || fail "bundletool output archive is missing or is a symlink"
  [[ "$(unzip -Z1 "$archive" | grep -Fxc 'universal.apk')" == "1" ]] \
    || fail "bundletool output lacks one universal APK"
  unzip -p "$archive" universal.apk >"$output"
  [[ -s "$output" ]] || fail "bundletool produced an empty universal APK"
}

cleanup() {
  local status="$?"
  trap - EXIT
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
  [[ -z "$APK_STAGE" ]] || rm -f "$APK_STAGE"
  [[ -z "$RECEIPT_STAGE" ]] || rm -f "$RECEIPT_STAGE"
  if [[ "$LOCK_OWNED" -eq 1 && "$ARTIFACTS_COMMITTED" -ne 1 ]]; then
    invalidate_gate_artifacts
  fi
  if [[ "$LOCK_OWNED" -eq 1 ]]; then
    rm -f "$LOCK_DIR/owner" && rmdir "$LOCK_DIR" || status=1
    LOCK_OWNED=0
  fi
  exit "$status"
}

if [[ "${NVPN_ANDROID_BUNDLE_LIBRARY_ONLY:-0}" == "1" ]]; then
  return 0
fi
trap cleanup EXIT

mkdir -p "$APK_DIR"
acquire_gate_lock
invalidate_gate_artifacts
for name in \
  ANDROID_KEYSTORE_PATH \
  ANDROID_KEYSTORE_PASSWORD \
  ANDROID_KEY_ALIAS \
  ANDROID_KEY_PASSWORD
do
  [[ -n "${!name:-}" ]] || fail "missing $name"
done
[[ -f "$ANDROID_KEYSTORE_PATH" && ! -L "$ANDROID_KEYSTORE_PATH" ]] \
  || fail "release keystore is missing or is a symlink"
[[ -f "$AAB" && ! -L "$AAB" ]] || fail "signed Play AAB is missing"
command -v curl >/dev/null 2>&1 || fail "curl is unavailable"
command -v java >/dev/null 2>&1 || fail "Java is unavailable"
command -v unzip >/dev/null 2>&1 || fail "unzip is unavailable"
command -v jarsigner >/dev/null 2>&1 || fail "jarsigner is unavailable"

mkdir -p "$CACHE_DIR"
if [[ ! -f "$BUNDLETOOL_JAR" ]] \
  || [[ "$(shasum -a 256 "$BUNDLETOOL_JAR" | awk '{ print $1 }')" \
    != "$BUNDLETOOL_SHA256" ]]
then
  [[ "$BUNDLETOOL_JAR" == "$CACHE_DIR/"* ]] \
    || fail "custom bundletool JAR does not match the pinned release"
  download="${BUNDLETOOL_JAR}.download.$$"
  rm -f "$download"
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    --output "$download" "$BUNDLETOOL_URL"
  [[ "$(shasum -a 256 "$download" | awk '{ print $1 }')" \
    == "$BUNDLETOOL_SHA256" ]] \
    || { rm -f "$download"; fail "downloaded bundletool hash differs"; }
  chmod 0555 "$download"
  mv -f "$download" "$BUNDLETOOL_JAR"
fi
[[ -f "$BUNDLETOOL_JAR" && ! -L "$BUNDLETOOL_JAR" \
  && "$(shasum -a 256 "$BUNDLETOOL_JAR" | awk '{ print $1 }')" \
    == "$BUNDLETOOL_SHA256" ]] \
  || fail "bundletool cache is not the pinned executable"
[[ "$(java -jar "$BUNDLETOOL_JAR" version)" == "$BUNDLETOOL_VERSION" ]] \
  || fail "bundletool reported the wrong version"
jarsigner -verify "$AAB" >/dev/null \
  || fail "Play AAB signature verification failed"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-android-bundle.XXXXXX")"
umask 077
printf '%s\n' "$ANDROID_KEYSTORE_PASSWORD" >"$TEMP_DIR/store-password"
printf '%s\n' "$ANDROID_KEY_PASSWORD" >"$TEMP_DIR/key-password"
java -jar "$BUNDLETOOL_JAR" build-apks \
  --bundle="$AAB" \
  --output="$TEMP_DIR/release.apks" \
  --mode=universal \
  --ks="$ANDROID_KEYSTORE_PATH" \
  --ks-pass="file:$TEMP_DIR/store-password" \
  --ks-key-alias="$ANDROID_KEY_ALIAS" \
  --key-pass="file:$TEMP_DIR/key-password" \
  --overwrite
extract_single_universal_apk \
  "$TEMP_DIR/release.apks" "$TEMP_DIR/app-release.apk"

sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
[[ -n "$sdk" ]] || fail "Android SDK root is unavailable"
apksigner="$(
  find "$sdk/build-tools" -type f -name apksigner 2>/dev/null \
    | sort -V \
    | tail -n 1
)"
[[ -x "$apksigner" ]] || fail "apksigner is unavailable"
"$apksigner" verify --verbose "$TEMP_DIR/app-release.apk" >/dev/null \
  || fail "AAB-derived universal APK signature verification failed"

APK_STAGE="$(mktemp "$APK_DIR/.app-release.apk.XXXXXX")"
RECEIPT_STAGE="$(
  mktemp "$BUNDLE_DIR/.physical-gate-artifact.json.XXXXXX"
)"
cp "$TEMP_DIR/app-release.apk" "$APK_STAGE"
chmod 0644 "$APK_STAGE"
app_sha="$(git -C "$ROOT" rev-parse HEAD)"
app_tree="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
aab_sha="$(shasum -a 256 "$AAB" | awk '{ print $1 }')"
apk_sha="$(shasum -a 256 "$APK_STAGE" | awk '{ print $1 }')"
python3 - \
  "$RECEIPT_STAGE" \
  "$app_sha" \
  "$app_tree" \
  "$AAB" \
  "$aab_sha" \
  "$APK" \
  "$apk_sha" \
  "$BUNDLETOOL_VERSION" \
  "$BUNDLETOOL_SHA256" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

(
    output,
    app_sha,
    app_tree,
    aab_path,
    aab_sha,
    apk_path,
    apk_sha,
    bundletool_version,
    bundletool_sha,
) = sys.argv[1:]
payload = {
    "schema": 1,
    "relationship": "universal-apk-derived-from-exact-aab",
    "appGitSha": app_sha,
    "appGitTree": app_tree,
    "aabPathSha256": hashlib.sha256(
        os.path.realpath(aab_path).encode()
    ).hexdigest(),
    "aabSha256": aab_sha,
    "apkPathSha256": hashlib.sha256(
        os.path.realpath(apk_path).encode()
    ).hexdigest(),
    "apkSha256": apk_sha,
    "bundletoolVersion": bundletool_version,
    "bundletoolSha256": bundletool_sha,
}
path = pathlib.Path(output)
temporary = path.with_name(f".{path.name}.tmp")
temporary.write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
temporary.replace(path)
PY
chmod 0444 "$RECEIPT_STAGE"
[[ "$(shasum -a 256 "$APK_STAGE" | awk '{ print $1 }')" == "$apk_sha" ]] \
  || fail "staged universal APK changed before publication"
mv -f "$APK_STAGE" "$APK"
APK_STAGE=""
mv -f "$RECEIPT_STAGE" "$RECEIPT"
RECEIPT_STAGE=""
[[ -s "$APK" && -s "$RECEIPT" && ! -L "$APK" && ! -L "$RECEIPT" ]] \
  || fail "atomic Android gate artifact promotion was incomplete"
ARTIFACTS_COMMITTED=1
printf '%s\n' "$APK"
