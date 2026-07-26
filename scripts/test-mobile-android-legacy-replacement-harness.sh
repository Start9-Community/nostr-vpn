#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$ROOT/scripts/mobile-android-legacy-replacement-e2e.sh"
activity="$ROOT/android/app/src/main/java/org/nostrvpn/app/MainActivity.kt"
migration="$ROOT/android/app/src/main/java/org/nostrvpn/app/AndroidLegacyPackageMigration.kt"
boot_receiver="$ROOT/android/app/src/main/java/org/nostrvpn/app/vpn/NostrVpnBootReceiver.kt"
vpn_service="$ROOT/android/app/src/main/java/org/nostrvpn/app/vpn/NostrVpnService.kt"
manifest="$ROOT/android/app/src/main/AndroidManifest.xml"
gradle_build="$ROOT/android/app/build.gradle.kts"

for contract in \
  'RETIRED_PACKAGES=(' \
  'org.nostrvpn.app' \
  'fi.siriusbusiness.nvpn.releasegate' \
  'fi.siriusbusiness.nvpn.mobileexit' \
  'fi.siriusbusiness.nvpn.joine2e' \
  'fi.siriusbusiness.nvpn.debug' \
  'fi.siriusbusiness.nvpn.test' \
  'build_retired_fixture_apks' \
  'install-multi-package -r' \
  'NVPN_ANDROID_LEGACY_FIXTURE_WITHOUT_NATIVE_LIBS=1' \
  'gradle :app:assembleDebug -x buildRustArm64' \
  'assert_fixture_has_no_native_libraries' \
  'unzip -Z1 "$apk"' \
  '"$ADB" -s "$serial" install -r "$work_dir/canonical.apk"' \
  'assert_canonical_update_preserved_data' \
  'touch files/nvpn-replacement-marker' \
  'test -f files/nvpn-replacement-marker' \
  'assert_vpn_start_blocked' \
  'am get-current-user' \
  'shell run-as "$CANONICAL_PACKAGE"' \
  '--user "$android_user"' \
  'wait_for_ui description "Remove older Nostr VPN installation"' \
  'Canonical Android migration prompt did not recover after guarded VPN start' \
  'assert_no_retired_processes' \
  'tap_ui description "Remove older Nostr VPN installation"' \
  'tap_system_uninstall' \
  'assert_only_canonical_package' \
  '"vpnStartBlockedBeforeCleanup": True' \
  '"systemUninstallConfirmed": True'
do
  grep -Fq -- "$contract" "$gate" \
    || { echo "Android legacy replacement gate is missing: $contract" >&2; exit 1; }
done

if grep -Eq 'sh -c .*nvpn-replacement-marker' "$gate"; then
  echo "Android upgrade marker still relies on ADB shell redirection quoting" >&2
  exit 1
fi

for gradle_contract in \
  'NVPN_ANDROID_LEGACY_FIXTURE_WITHOUT_NATIVE_LIBS' \
  'androidLegacyFixtureWithoutNativeLibs' \
  'excludes += "**/*.so"' \
  'Native-free Android fixtures cannot use the canonical package'
do
  grep -Fq "$gradle_contract" "$gradle_build" \
    || { echo "Android Gradle fixture packaging is missing: $gradle_contract" >&2; exit 1; }
done

grep -Fq 'id = "remove-legacy-app"' "$activity" \
  || { echo "Android shipped UI has no legacy-removal selector" >&2; exit 1; }
grep -Fq 'Intent(Intent.ACTION_DELETE' "$migration" \
  || { echo "Android legacy migration does not invoke the system uninstall UI" >&2; exit 1; }
for runtime_guard in "$activity" "$boot_receiver" "$vpn_service"; do
  grep -Fq 'AndroidLegacyPackageMigration' "$runtime_guard" \
    || { echo "Android VPN startup is not guarded in $runtime_guard" >&2; exit 1; }
done
for package_name in \
  org.nostrvpn.app \
  fi.siriusbusiness.nvpn.releasegate \
  fi.siriusbusiness.nvpn.mobileexit \
  fi.siriusbusiness.nvpn.joine2e \
  fi.siriusbusiness.nvpn.debug \
  fi.siriusbusiness.nvpn.test
do
  grep -Fq "<package android:name=\"$package_name\" />" "$manifest" \
    || { echo "Android cannot query retired package $package_name" >&2; exit 1; }
done
grep -Fq 'REQUEST_DELETE_PACKAGES' "$manifest" \
  || {
    echo "Android migration cannot open the system uninstall confirmation" >&2
    exit 1
  }

echo "Android legacy replacement source contract passed"
