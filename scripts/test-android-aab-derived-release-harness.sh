#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDER="$ROOT/scripts/prepare-android-release-from-bundle.sh"
ANDROID_RUNNER="$ROOT/tools/run-android"
PHYSICAL="$ROOT/scripts/lib-mobile-android-release-gate.sh"
PUBLISH="$ROOT/scripts/local-release.mjs"

fail() {
  echo "Android AAB-derived release contract failed: $*" >&2
  exit 1
}

require_token() {
  local path="$1" token="$2"
  grep -Fq -- "$token" "$path" || fail "$(basename "$path") lacks: $token"
}

bash -n "$BUILDER" "$ANDROID_RUNNER" "$PHYSICAL"
[[ -x "$BUILDER" ]] || fail "bundle-derived APK builder is not executable"

require_token "$ANDROID_RUNNER" ':app:bundleRelease'
require_token "$ANDROID_RUNNER" 'prepare-android-release-from-bundle.sh'
if sed -n '/release|assembleRelease)/,/;;/p' "$ANDROID_RUNNER" \
  | grep -Fq ':app:assembleRelease'
then
  fail "canonical Release path still assembles an independent APK"
fi

for token in \
  'a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29' \
  'build-apks' \
  '--mode=universal' \
  'universal-apk-derived-from-exact-aab' \
  'physical-gate-artifact.json' \
  'jarsigner -verify' \
  'apksigner'
do
  require_token "$BUILDER" "$token"
done

for token in \
  '"aabSha256": actual_aab_sha' \
  '"apkDerivedFromAab": True' \
  '"bundleReceiptSha256":' \
  'Android APK is not derived from the exact Play AAB'
do
  require_token "$PHYSICAL" "$token"
done

for token in \
  "bundleReceipt.relationship" \
  "sha256FileSync(aabDest) !== gate.aabSha256" \
  "physical-gate-sealed bundletool-derived APK"
do
  require_token "$PUBLISH" "$token"
done

echo "ANDROID_AAB_DERIVED_RELEASE_CONTRACT_OK"
