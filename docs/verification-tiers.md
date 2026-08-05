# Verification tiers and managed native lab

Nostr VPN separates per-change core confidence from scarce native GUI, VM, and
physical-device confidence.

## Fast tier

Run `just verify-fast` for each coherent change. It checks native-lab contracts,
version parity, formatting, strict workspace/all-target
Clippy, focused dataplane/app-state safety tests, shared mobile Rust tests, and
platform-tool contracts. CI runs the remaining workspace tests independently
so they can overlap this tier without repeating app-core tests.

The fast tier does not reserve or mutate a VM, GUI session, simulator, or phone.

## Full tier

Run `just verify-full` nightly and at release boundaries. It runs the fast tier,
then atomically reserves the local Mac, configured Windows VM, selected iOS
simulator, selected iOS device, and selected Android device. Configure:

- `NVPN_WINDOWS_SSH_HOST`
- `NVPN_LAB_IOS_SIMULATOR` (name or ID; default `auto`)
- `NVPN_LAB_IOS_DEVICE` (name or ID; default `auto`)
- `NVPN_LAB_ANDROID_SERIAL` (default `auto`)

Prefer explicit IDs in scheduled jobs. The exact selected IDs are passed into
the mobile scripts. The full tier runs simulator and physical VPN/TUN smokes,
then the release gate with Linux, macOS, and Windows GUI/WireGuard lanes required.

`scripts/native-lab.py` writes
`artifacts/verification/full-native-result.json`. Missing or busy infrastructure
returns exit 75 and `status=infrastructure_unavailable`. A test failure on an
available reserved matrix retains its exit code and reports
`status=product_failure`.

Use `just verify-health` for preflight without tests.

## Deterministic reset

Reset is destructive and disabled by default. Use
`NVPN_NATIVE_LAB_RESET=1 just verify-full` only with dedicated lab targets. While
holding the reservation, the wrapper erases the selected simulator, uninstalls
the app from the selected iOS device, and clears the Android app package before
the matrix installs fresh builds.

The reset helper requires `NVPN_NATIVE_LAB_ALLOW_RESET=1`, which the full wrapper
sets only inside the reservation. Never select a personal device whose Nostr VPN
data should be preserved.
