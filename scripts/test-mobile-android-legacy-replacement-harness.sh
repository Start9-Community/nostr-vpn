#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$ROOT/scripts/mobile-android-legacy-replacement-e2e.sh"
activity="$ROOT/android/app/src/main/java/org/nostrvpn/app/MainActivity.kt"
migration="$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidLegacyPackageMigration.kt"

for contract in \
  'LEGACY_PACKAGE="org.nostrvpn.app"' \
  'NVPN_ANDROID_PACKAGE="$LEGACY_PACKAGE"' \
  'gradle :app:assembleDebug -x buildRustArm64' \
  '"$ADB" -s "$serial" install -r "$work_dir/legacy.apk"' \
  'tap_ui description "Remove older Nostr VPN installation"' \
  'tap_system_uninstall' \
  'assert_only_canonical_package' \
  '"systemUninstallConfirmed": True'
do
  grep -Fq "$contract" "$gate" \
    || { echo "Android legacy replacement gate is missing: $contract" >&2; exit 1; }
done

grep -Fq 'id = "remove-legacy-app"' "$activity" \
  || { echo "Android shipped UI has no legacy-removal selector" >&2; exit 1; }
grep -Fq 'Intent(Intent.ACTION_DELETE' "$migration" \
  || { echo "Android legacy migration does not invoke the system uninstall UI" >&2; exit 1; }
grep -Fq 'REQUEST_DELETE_PACKAGES' "$ROOT/android/app/src/main/AndroidManifest.xml" \
  || {
    echo "Android migration cannot open the system uninstall confirmation" >&2
    exit 1
  }

echo "Android legacy replacement source contract passed"
