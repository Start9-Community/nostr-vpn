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

fail() {
  echo "Android AAB-derived Release APK failed: $*" >&2
  exit 1
}

cleanup() {
  local status="$?"
  trap - EXIT
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT

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
[[ "$(unzip -Z1 "$TEMP_DIR/release.apks" | grep -c '^universal\\.apk$')" \
  == "1" ]] || fail "bundletool output lacks one universal APK"
unzip -p "$TEMP_DIR/release.apks" universal.apk >"$TEMP_DIR/app-release.apk"
[[ -s "$TEMP_DIR/app-release.apk" ]] \
  || fail "bundletool produced an empty universal APK"

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

mkdir -p "$APK_DIR"
chmod 0644 "$TEMP_DIR/app-release.apk"
mv -f "$TEMP_DIR/app-release.apk" "$APK"
app_sha="$(git -C "$ROOT" rev-parse HEAD)"
app_tree="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
aab_sha="$(shasum -a 256 "$AAB" | awk '{ print $1 }')"
apk_sha="$(shasum -a 256 "$APK" | awk '{ print $1 }')"
python3 - \
  "$RECEIPT" \
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
chmod 0444 "$RECEIPT"
printf '%s\n' "$APK"
