#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nvpn-ios-appstore-policy.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'iOS App Store policy test failed: %s\n' "$*" >&2
  exit 1
}

cat >"$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

var direct = AppState()
direct.walletFiatEnabled = false
require(
    AppStorePolicy.compatibilityPatch(for: direct).isEmpty,
    "ordinary direct configuration must remain unchanged"
)

var paidBuyer = direct
paidBuyer.internetSource = "paid_automatic"
paidBuyer.exitNode = "paid-seller"
let buyerPatch = AppStorePolicy.compatibilityPatch(for: paidBuyer)
require(buyerPatch["internetSource"] as? String == "direct", "paid source must reset")
require(buyerPatch["exitNode"] as? String == "", "paid seller must clear")

var paidSeller = direct
paidSeller.paidExitSeller.enabled = true
paidSeller.walletFiatEnabled = true
let sellerPatch = AppStorePolicy.compatibilityPatch(for: paidSeller)
require(sellerPatch["paidExitEnabled"] as? Bool == false, "paid selling must disable")
require(sellerPatch["walletFiatEnabled"] as? Bool == false, "wallet fiat must disable")

require(
    AppStorePolicy.blocks(["type": "buy_best_paid_route_offer"]),
    "paid route purchase action must be blocked"
)
require(
    AppStorePolicy.blocks([
        "type": "update_settings",
        "patch": ["internetSource": "paid_manual"],
    ]),
    "paid internet source must be blocked"
)
require(
    AppStorePolicy.blocks([
        "type": "update_settings",
        "patch": ["paidExitAcceptedMints": "https://mint.example"],
    ]),
    "dormant paid seller settings must be blocked"
)
require(
    AppStorePolicy.blocks([
        "type": "update_settings",
        "patch": ["walletFiatEnabled": false],
    ]),
    "all wallet settings must be blocked, including hidden controls"
)
require(
    !AppStorePolicy.blocks([
        "type": "update_settings",
        "patch": ["internetSource": "wireguard", "exitDnsMode": "encrypted"],
    ]),
    "user-supplied WireGuard settings must remain available"
)
require(
    !AppStorePolicy.blocks(["type": "add_network"]),
    "private mesh actions must remain available"
)
require(
    !AppStorePolicy.allowsVpnStart(disclosureAccepted: false),
    "VPN start must remain blocked before the disclosure is accepted"
)
require(
    AppStorePolicy.allowsVpnStart(disclosureAccepted: true),
    "VPN start must remain available after the disclosure is accepted"
)

print("iOS App Store policy behavior passed")
SWIFT

swiftc \
  "$ROOT/ios/Sources/Models.swift" \
  "$ROOT/ios/Sources/AppStorePolicy.swift" \
  "$TMP_DIR/main.swift" \
  -o "$TMP_DIR/test-ios-appstore-policy"
"$TMP_DIR/test-ios-appstore-policy"

if rg -n 'state = self\.core\?\.refresh\(\) \?\? self\.state' \
  "$ROOT/ios/Sources/AppModelSupport.swift" >/dev/null
then
  fail "Packet Tunnel snapshots can still bypass App Store state sanitization"
fi

support_adoptions="$(
  rg -c 'adoptAppStoreCompatibleState\(' "$ROOT/ios/Sources/AppModelSupport.swift"
)"
[[ "$support_adoptions" -ge 2 ]] \
  || fail "both Packet Tunnel config and runtime refreshes must use the policy"

rg -q 'reconcileAppStoreTunnelAfterSanitization' "$ROOT/ios/Sources/AppModel.swift" \
  || fail "sanitized state does not replace a running stale Packet Tunnel"
rg -q 'schedulePacketTunnelConfigSync' "$ROOT/ios/Sources/AppModel.swift" \
  || fail "sanitized state is not propagated to the Packet Tunnel"
rg -q 'AppStorePolicy\.allowsVpnStart' "$ROOT/ios/Sources/AppModel.swift" \
  || fail "the central VPN start path can bypass the pre-use disclosure"
if sed -n '/#else/,/#endif/p' "$ROOT/ios/Sources/AppModel.swift" \
  | rg -q 'action == "(tick|connect|disconnect)"'
then
  fail "production iOS still exposes debug VPN deep-link actions"
fi
for debug_entrypoint in runLaunchAutomationIfRequested runDebugAutomation; do
  entrypoint_body="$(
    sed -n \
      "/func ${debug_entrypoint}/,/^    }/p" \
      "$ROOT/ios/Sources/AppModelDebugAutomation.swift"
  )"
  printf '%s\n' "$entrypoint_body" | rg -q '#if DEBUG' \
    || fail "$debug_entrypoint is not compiled out of the App Store build"
done
rg -q -- '--no-default-features' "$ROOT/tools/run-ios" \
  || fail "the iOS framework still compiles the Cashu/paid-exit feature"

no_default_feature_tree="$(
  cargo tree \
  --manifest-path "$ROOT/Cargo.toml" \
  -p nostr-vpn-app-core \
  --no-default-features \
  -e features
)"
if printf '%s\n' "$no_default_feature_tree" \
  | rg -i 'cashu|paid-exit|hashtree-updater|nostr-vpn-core feature "updater"' \
  >/dev/null; then
  fail "the iOS no-default-features graph still resolves Cashu, paid-exit, or updater code"
fi

cargo build \
  --manifest-path "$ROOT/Cargo.toml" \
  -p nostr-vpn-app-core \
  --no-default-features \
  --lib

cargo_target_dir="$(
  cargo metadata \
    --manifest-path "$ROOT/Cargo.toml" \
    --format-version 1 \
    --no-deps \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])'
)"
no_default_core="$cargo_target_dir/debug/deps/libnostr_vpn_app_core.a"
[[ -f "$no_default_core" ]] \
  || fail "the no-default app-core static library was not produced"
if strings -a "$no_default_core" \
  | rg -i \
    'api\.coinbase\.com|api\.kraken\.com|nvpn-exchange-rate|paid_exit_wallet_runtime|wallet_worker|PaidRouteWalletRuntime|nvpn-updater|secure hashtree update check' \
    >/dev/null
then
  fail "the iOS no-default app core still contains wallet, paid-exit, updater, or fiat-rate runtime code"
fi
if strings -a "$no_default_core" \
  | rg 'nostr_vpn_update_(check|download)' >/dev/null
then
  fail "the iOS no-default app core still exports self-update entry points"
fi

packaged_core_count=0
for packaged_core in \
  "$ROOT"/ios/Frameworks/NostrVpnAppCore.xcframework/*/libnostr_vpn_app_core.a
do
  [[ -f "$packaged_core" ]] || continue
  packaged_core_count=$((packaged_core_count + 1))
  if strings -a "$packaged_core" \
    | rg -i \
      'api\.coinbase\.com|api\.kraken\.com|nvpn-exchange-rate|paid_exit_wallet_runtime|wallet_worker|PaidRouteWalletRuntime|nvpn-updater|secure hashtree update check' \
      >/dev/null
  then
    fail "the packaged iOS XCFramework still contains wallet, paid-exit, updater, or fiat-rate runtime code"
  fi
  if strings -a "$packaged_core" \
    | rg 'nostr_vpn_update_(check|download)' >/dev/null
  then
    fail "the packaged iOS XCFramework still exports self-update entry points"
  fi
done
[[ "$packaged_core_count" -ge 2 ]] \
  || fail "the packaged iOS XCFramework is missing device or simulator archives"

if rg -ni 'paid|cashu|wallet|mint' \
  "$ROOT/ios/Sources/InternetViews.swift" \
  "$ROOT/ios/Sources/SettingsViews.swift" \
  "$ROOT/ios/Sources/NativeCoreClient.swift" \
  "$ROOT/ios/Sources/ScreenshotFixtures.swift" \
  "$ROOT/ios/Sources/RootView.swift" \
  "$ROOT/ios/Sources/ViewComponents.swift" >/dev/null
then
  fail "the iOS app still contains paid/wallet views, actions, navigation, or fixtures"
fi

rg -q 'does not collect or retain your browsing traffic' \
  "$ROOT/ios/Sources/DevicesViews.swift" \
  || fail "the pre-use VPN disclosure omits the developer collection statement"
rg -q 'ScrollView' "$ROOT/ios/Sources/DevicesViews.swift" \
  || fail "the pre-use VPN disclosure can clip required text on a small device"
for dns_disclosure in \
  'WireGuard profile' \
  'Cloudflare encrypted DNS' \
  'Quad9' \
  'custom encrypted DNS' \
  'through the exit' \
  'DNS queries' \
  'connection metadata'
do
  rg -q "$dns_disclosure" \
    "$ROOT/ios/Sources/DevicesViews.swift" \
    "$ROOT/docs/privacy/index.html" \
    || fail "the iOS DNS disclosure omits: $dns_disclosure"
done
rg -q 'otherwise uses Cloudflare encrypted DNS' \
  "$ROOT/ios/Sources/ExitDnsSettingsCard.swift" \
  || fail "Automatic exit DNS does not name its Cloudflare fallback"
rg -q 'does not sell, use, or disclose VPN data to third parties' \
  "$ROOT/docs/privacy/index.html" \
  || fail "the privacy policy omits the VPN data-use commitment"
for plist in "$ROOT/ios/Info.plist" "$ROOT/ios/PacketTunnel/Info.plist"; do
  [[ "$(plutil -extract ITSAppUsesNonExemptEncryption raw -o - "$plist")" == "false" ]] \
    || fail "the no-France build must declare export-exempt encryption"
done
rg -q '"unrestrictedWebAccess": False' "$ROOT/scripts/appstore-draft" \
  || fail "App Store metadata incorrectly declares an in-app unrestricted browser"
rg -Fq ': "${NVPN_IOS_TEAM_ID:?NVPN_IOS_TEAM_ID is required in the private release environment}"' \
  "$ROOT/scripts/ios-build" \
  || fail "the iOS release build does not require a private signing-team setting"
if rg -q 'NVPN_IOS_TEAM_ID:-[A-Z0-9]+' "$ROOT/scripts/ios-build"; then
  fail "the iOS release build exposes a signing-team identifier as a public default"
fi

printf 'iOS App Store policy test passed\n'
