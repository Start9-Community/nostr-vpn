# Mobile Test Kit

Mobile coverage is split by what each layer can prove.

## Shared Rust

Run this when touching mobile state, FFI, config, reconnect, roster, or FIPS
handoff behavior:

```sh
just mobile-test-kit-rust
```

These checks belong in `nostr-vpn` because the mobile apps call
`nostr-vpn-app-core`. Plain `fips` should keep protocol, routing, session,
candidate, and cross-target Rust tests platform-neutral; real Android/iOS VPN
behavior depends on the `nostr-vpn` shells, permissions, FFI, and packet tunnel
integration.

## Build Smoke

Run the normal fast kit before handing off a mobile-sensitive change:

```sh
just mobile-test-kit
```

This runs shared Rust tests, builds the Android debug APK, and builds the iOS
simulator/device xcframework path. It catches JNI/C ABI drift, missing mobile
targets, and Xcode/Gradle project breakage.

## Simulator And Emulator Smoke

Run this when UI, launch, deep-link, or mobile packaging behavior changed:

```sh
just mobile-test-kit-sim
```

The iOS simulator can verify build, install, launch, state/action UI, and
screenshot capture. It cannot prove the NetworkExtension packet tunnel or VPN
permission path. Android emulator or attached-device smoke verifies APK install
and launch; use `NVPN_ANDROID_SERIAL` or `ANDROID_SERIAL` when more than one adb
target is online.

## Physical Device VPN Smoke

Run this after VPN dataplane, reconnect, local-path discovery, roster transfer, or
mobile tunnel config changes:

```sh
just mobile-test-kit-device
```

This runs the local OS VPN/TUN packet path without private peer fixtures.
Android builds/installs the debug APK, creates a debug-only local network,
cycles the VPN, captures runtime-state/link/ping/TUN summaries, and may tap the
system VPN consent prompt on a trusted local test device. iOS builds/installs
the current development-signed app, creates a debug-only local network, cycles
the Packet Tunnel, and validates the current build metadata plus TUN packet
probe counters. Keep `NVPN_ANDROID_SERIAL`, `NVPN_IOS_DEVICE`,
`NVPN_IOS_TEAM_ID`, and any other device/signing values in shell env or
`.env.mobile.local`.

For peer latency, jitter, loss, and throughput evidence, run the underlying
smoke scripts with real ignored-local join-request or WireGuard fixture values. Use a
reachable peer/exit probe target and set
`NVPN_ANDROID_TUN_PACKET_PROBE_REQUIRE_REPLY=1` or
`NVPN_IOS_TUN_PACKET_PROBE_REQUIRE_REPLY=1` when the run should fail unless
reply traffic returns through native TUN writes.
