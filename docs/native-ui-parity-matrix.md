# Native UI Parity Matrix

This is the working checklist for the Rust-core, native-front architecture
similar to `~/src/iris-chat-rs`. The legacy Svelte/Tauri app has been removed;
its feature inventory remains here only as the migration contract.

The goal is not visual sameness. The goal is feature and behavior parity across
native shells while keeping product truth in Rust.

## Target Shape

| Layer | macOS | Windows | Linux | Android | iPhone |
| --- | --- | --- | --- | --- | --- |
| Shared core | Rust app core exposed through UniFFI | Rust app core exposed through explicit C ABI JSON bridge | Rust app core used directly or through UniFFI | Rust app core exposed through explicit C ABI JSON bridge over JNI | Rust app core exposed through explicit C ABI JSON bridge |
| Native shell | SwiftUI/AppKit | WPF/.NET | GTK4/libadwaita Rust | Kotlin/Jetpack Compose | SwiftUI/UIKit |
| App state owner | Rust | Rust | Rust | Rust | Rust |
| Rendering owner | Native | Native | Native | Native | Native |
| Secure/platform effects | Keychain, launch agent, status item | Credential Manager, service/UAC, tray | Secret Service fallback, desktop entry, tray/status notifier | Keystore, VpnService, camera/share intents | Keychain, NetworkExtension, camera/share sheet |
| VPN control model | Background service + FIPS private mesh | Windows service + FIPS private mesh | Background service + tun/FIPS private mesh | Android VpnService runtime | NetworkExtension Packet Tunnel |
| Package target | `.app`/DMG or signed archive | Installer/MSIX or NSIS | AppImage/deb/rpm later | APK/AAB/Zapstore | TestFlight/App Store |

## Rust Core Boundary

| Area | Core responsibility | Native responsibility |
| --- | --- | --- |
| State projection | `UiState`, networks, participants, diagnostics, service status, mobile capability flags | Render state with platform controls and local presentation state |
| Actions | Existing product commands as typed Rust actions | Dispatch actions, disable conflicting controls while actions run |
| Long-running runtime | Daemon/VPN lifecycle, config persistence, FIPS peer status, join requests | Keep app alive enough for platform lifecycle and show system-level affordances |
| Formatting | Shared user-facing derived labels that encode policy, like mesh readiness, join request status, exit-node availability, service repair recommendation | Platform typography, layout, control affordances |
| Platform effects | Declare requested effect and update state after completion | Clipboard, startup registration, tray/status item, camera QR scan, update installer, mobile VPN permission prompts |
| Errors | Stable action errors and recoverable service repair hints | Dialog/toast/sheet presentation |

## Feature Parity Matrix

Legend:

- `Required`: must ship on that platform.
- `Desktop`: desktop-only parity.
- `Mobile`: mobile-only equivalent.
- `Hidden`: code exists today but is not mounted in the current app.
- `N/A`: intentionally not applicable.

| Current feature | Current source | Core/API need | macOS | Windows | Linux | Android | iPhone | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| One snapshot app model | `UiState`, `get_state`, `tick` | `FfiApp.state()`, periodic or push updates, typed actions | Required | Required | Required | Required | Required | Keep a single state/action contract for all shells. |
| Initial boot sequencing | `AppBootstrap.svelte` | Start core, load config, first tick, ready event for tests | Required | Required | Required | Required | Required | Native tests need a replacement for `nvpn:boot-ready`. |
| Periodic refresh | `tick` every 1500ms | Prefer push updates; retain tick as fallback | Required | Required | Required | Required | Required | Mobile should avoid aggressive background polling. |
| Action lock/error recovery | `runAction`, action flags | Action in-flight state or shell-side lock | Required | Required | Required | Required | Required | Prevent overlapping config/VPN mutations. |
| Main status hero | `HeroStatusPanel.svelte` | Hero badge/subtext/detail helpers, active network projection | Required | Required | Required | Required | Required | Includes active network title, admin badge, mesh readiness, daemon/VPN/FIPS badges. |
| VPN on/off switch | `connect_vpn`, `disconnect_vpn` | Start/stop VPN action, service setup guidance | Required | Required | Required | Mobile | Mobile | Mobile uses platform VPN permission/control flow instead of desktop service. |
| Privacy disclosure | `shouldShowVpnDataDisclosure` | Capability/state flag and disclosure text | Required | Required | Required | Required | Required | Current copy should become a shared string or policy doc reference. |
| Own npub display/copy | `HeroStatusPanel.svelte` | `own_npub` in state | Required | Required | Required | Required | Required | Clipboard is native platform effect. |
| Device name editing | `update_settings.nodeName` | Typed settings patch | Required | Required | Required | Required | Required | Debounced edit, DNS-safe preview. |
| Device endpoint/tunnel summary | `UiState.endpoint`, `tunnelIp` | State fields | Required | Required | Required | Required | Required | Mobile may show platform-managed tunnel info. |
| Active network profile | `ActiveNetworkPanel.svelte` | Network name, mesh ID, local admin flag | Required | Required | Required | Required | Required | Non-admins must not edit shared network identity. |
| Mesh ID editing/validation | `mesh-id.js`, `set_network_mesh_id` | Move validation/canonicalization into Rust | Required | Required | Required | Required | Required | Current 5s idle commit plus blur/Enter commit should be preserved. |
| Mesh ID copy | `copyMeshId` | Current active network ID | Required | Required | Required | Required | Required | Copy raw canonical ID, not display grouping. |
| Network admin visibility | `networkAdminSummary`, badges | Admin summary and participant admin flags | Required | Required | Required | Required | Required | Keep admin-specific disabled states. |
| Join request generation | `joinRequestQrCodeOrLink` | Only unjoined devices expose their own join request link/QR | Required | Required | Required | Required | Required | Already-joined/admin devices must not show a join-request QR for themselves. |
| Admin join request import | `import_join_request` | Admin-side action directly adds the requester to the active admin network | Required | Required | Required | Required | Required | Paste/scan must show confirmation immediately, add the device on confirm, and avoid any pending request list. |
| Manual out-of-band join | `manual_add_network`, `add_participant` | Joiner enters admin Device ID + Network ID; admin adds joiner Device ID | Required | Required | Required | Required | Required | This explicit offline flow requires both sides to exchange identifiers. CLI mirrors it with `join-manual` and `add-device`. |
| Join request device name | `name` query value in join request links | Preserve requester device name when adding the participant alias | Required | Required | Required | Required | Required | Avoid hex/pubkey fallback when the requester supplied a usable device name. |
| Removed pending list | `inboundJoinRequests` compatibility only | Keep state parsing compatible, but do not mount the pending request list in app UI | Required | Required | Required | Required | Required | The product flow is admin scans/pastes/adds a join request. |
| Join-request QR image scan | file input + `jsQR` | Native file/image picker + decoder | Required | Required | Required | Required | Required | Keep image fallback when camera is denied/unavailable. |
| Join-request confirmation | request parser + confirmation sheet | Verify and display requester identity before approval | Required | Required | Required | Required | Required | Approval adds the requester and queues signed-roster delivery. |
| Approval completion | signed roster delivery | Joining device persists the approved network before acknowledging | Required | Required | Required | Required | Required | On mobile the Packet Tunnel hands the roster to the app through retryable chunked status messages. |
| Manual add participant | `add_participant` | Add participant with optional alias | Required | Required | Required | Required | Required | Admin-gated. |
| Participant alias editing | `set_participant_alias` | Alias action and MagicDNS suffix | Required | Required | Required | Required | Required | Debounced, admin-gated. |
| Participant npub copy | participant rows | Participant npub in state | Required | Required | Required | Required | Required | Present in active, saved, and join request rows. |
| Participant admin toggle | `add_admin`, `remove_admin` | Admin mutation actions | Required | Required | Required | Required | Required | Active network currently exposes toggle; saved network mainly shows admin state. |
| Participant remove | `remove_participant` | Remove participant action | Required | Required | Required | Required | Required | Admin-gated, icon button on native shells. |
| Participant status badges | `participantBadgeClass`, badge text helpers | Shared derived labels | Required | Required | Required | Required | Required | FIPS reachable/pending/offline plus mesh seen/unseen. |
| Participant traffic/path details | `participantTrafficText`, fields | tx/rx, FIPS path, runtime endpoint, routes | Required | Required | Required | Required | Required | Keep fallback and advertised route visibility. |
| Saved networks list | `SavedNetworksPanel.svelte` | All networks with enabled flag | Required | Required | Required | Required | Required | Active network separate; inactive networks collapsible/listed. |
| Add saved network | `add_network` | Add network action | Required | Required | Required | Required | Required | Optional name. |
| Activate saved network | `set_network_enabled` | Set active network action | Required | Required | Required | Required | Required | Ensure daemon reload/VPN state is correct. |
| Delete saved network | `remove_network` | Remove network action | Required | Required | Required | Required | Required | Deleting the final network returns the app to setup. |
| Edit saved network profile | `SavedNetworkCard.svelte` | Same name/mesh/admin actions as active network | Required | Required | Required | Required | Required | Inactive networks still receive join requests. |
| Saved network participants | `SavedNetworkParticipantRow.svelte` | Participant list and alias actions | Required | Required | Required | Required | Required | Minimal status for inactive profiles. |
| Exit Nodes mode summary | `Exit NodesPanel.svelte` | Derived exit-node status text | Required | Required | Required | Required | Required | Direct mesh, remote exit, local exit, or both. |
| Advertise private exit node | `advertiseExitNode` | Settings patch | Required | Required | Required | Required | Required | Affects default route advertisement. |
| Advanced route advertisement | `advertisedRoutes` | Settings patch + validation | Deferred | Deferred | Deferred | Deferred | Deferred | Hidden from current native shells; core still normalizes config values. |
| Exit node search/select | `exitNode` | Candidate projection and setting | Required | Required | Required | Required | Required | Search alias, npub, tunnel IP. Disable peers not offering exit. |
| No exit node selection | `onSelectExitNode('')` | Clear exit-node setting | Required | Required | Required | Required | Required | Also exposed in desktop tray. |
| Diagnostics panel | `AdvancedPanels.svelte` | Health issues, network summary, port mapping | Required | Required | Required | Required | Required | Auto-open when health count increases. |
| Health warnings | `health` | Health issue list with severity | Required | Required | Required | Required | Required | Keep empty state and severity mapping. |
| Network diagnostics | `NetworkSummary` | Interface, local IPs, gateway, captive portal | Required | Required | Required | Required | Required | Mobile may have reduced details if OS restricts APIs. |
| Port mapping status | `PortMappingStatus` | UPnP/NAT-PMP/PCP state | Required | Required | Required | Required | Required | Show active protocol and external endpoint. |
| Session options | `autoconnect` | Settings patch | Required | Required | Required | Required | Required | Text should be platform neutral. |
| Background service panel | `ServiceActionPanel.svelte` | Service status, service repair recommendation, actions | Desktop | Desktop | Desktop | N/A | N/A | Mobile should not show desktop service install/repair UI. |
| Install/reinstall service | `install_system_service` | Desktop service action | Required | Required | Required | N/A | N/A | May require admin/UAC/sudo/polkit flow. |
| Enable/disable service | `enable_system_service`, `disable_system_service` | Desktop service action | Required | Required | Required | N/A | N/A | Current macOS copy references launchd; native copy should use platform-specific terms. |
| Uninstall service | `uninstall_system_service` | Desktop service action | Required | Required | Required | N/A | N/A | Keep reachable after setup. |
| Service version repair prompt | `service-repair.js` | Core-derived repair prompt state | Required | Required | Required | N/A | N/A | Use native confirmation dialog; avoid repeated prompt per version key. |
| Service action settlement polling | `waitForServiceActionSettlement` | Core/service action status | Required | Required | Required | N/A | N/A | Native shell should show progress while launchd/service manager settles. |
| CLI install/uninstall | `install_cli`, `uninstall_cli` | Desktop CLI action | Required | Required | Required | N/A | N/A | Installs `nvpn` into PATH; may require elevation. |
| App version/config path display | `SystemPanel.svelte` | App version, config path | Required | Required | Required | Required | Required | Mobile may hide raw path behind support/debug view. |
| MagicDNS status | `magicDnsStatus` | Runtime DNS status string | Required | Required | Required | Required | Required | Mobile DNS behavior may be tunnel-scoped. |
| MagicDNS suffix editing | `magicDnsSuffix` | Settings patch | Required | Required | Required | Required | Required | Debounced. |
| Endpoint/tunnel IP/listen port settings | `SystemPanel.svelte` | Settings patch + validation | Required | Required | Required | Required | Required | Mobile may constrain endpoint/listen port by OS VPN APIs. |
| Launch on startup | Legacy autostart plugin | Native startup registration effect + config setting | Required | Required | Required | N/A | N/A | Android/iPhone use OS background/VPN behavior, not login startup. |
| Close to tray/status item | `closeToTrayOnClose` | Config setting + native close behavior | Required | Required | Required | N/A | N/A | macOS menu bar item; Windows/Linux tray/status notifier. |
| Desktop tray/status menu | `tray_runtime.rs` | Tray runtime projection and actions | Required | Required | Required | N/A | N/A | Menu: VPN status, toggle, this-device copy, network devices, exit nodes, open, quit. Manual refresh is intentionally not user-facing. |
| Tray left-click opens app | Legacy tray handler | Native shell action | Required | Required | Required | N/A | N/A | Keep menu/status item accessible. |
| Autostart hidden launch | `--autostart`, hide to tray | Launch-mode detection | Required | Required | Required | N/A | N/A | Current code mainly handles macOS conflict/defer behavior; port intentionally. |
| Single-instance handling | Legacy single-instance plugin | Native process/singleton coordination | Required | Required | Required | Mobile | Mobile | Mobile OS already single-instances app task but deep links must route to existing app. |
| Deep links | `nvpn://join-request`, `nvpn://debug/...` | Core deep-link parser/action dispatcher | Required | Required | Required | Required | Required | Support startup URLs and already-running app URLs. |
| Debug automation deep links | `nvpn://debug/tick`, request/accept join | Test-only action path | Required | Required | Required | Required | Required | Keep for e2e harness parity. |
| Update banner | `UpdateBanner.svelte`, hashtree updater | Update check/download/install API | Required | Required | Required | N/A | N/A | Mobile updates go through store/TestFlight/Zapstore unless a separate allowed updater exists. |
| Manual update panel | `SystemPanel.svelte` updater section | Same updater API + prefs | Required | Required | Required | N/A | N/A | Preserve auto-check/auto-install prefs on desktop. |
| Update prefs storage | `localStorage` | Native preference storage | Required | Required | Required | N/A | N/A | Move prefs into core or native settings store. |
| Window chrome/drag region | `App.svelte`, legacy overlay titlebar | Native window style | Required | Required | Required | N/A | N/A | Native shells can use platform chrome instead of custom overlay. |
| Responsive layout | Svelte CSS | Native adaptive layouts | Required | Required | Required | Required | Required | Desktop can use multi-panel; mobile should use navigation stack/sheets. |
| Copy feedback | `copiedValue` timeout | Native transient status | Required | Required | Required | Required | Required | Snackbar/toast/checkmark, clears after roughly 2s. |
| Collapsible panels | `<details>` panels | Local UI state only | Required | Required | Required | Required | Required | Diagnostics auto-opens on new health issues. |
| Mock/demo backend | `mock-backend.ts` | Native previews/test fixtures | Required | Required | Required | Required | Required | Replace with core fixture snapshots and platform preview states. |
| Mobile VPN permission/control | `android_vpn`, `ios_vpn`, `ios_packet_tunnel` | Platform-specific native VPN bridge | N/A | N/A | N/A | Required | Required | Must preserve current Android VpnService and iPhone Packet Tunnel behavior. |
| Mobile runtime status detail | `runtime_capabilities_for_platform` | Capability flags in state | N/A | N/A | N/A | Required | Required | Keep simulator/device distinction for iPhone. |

## macOS App Parity Status

This table tracks the SwiftUI/AppKit shell under `macos/` against the legacy
Tauri/Svelte feature contract. It is scoped to macOS only.

Status legend:

- `Ready`: implemented in the native macOS shell and build-verified.
- `Partial`: visible or wired, but missing behavior from the current app.
- `Missing`: no macOS native implementation yet.
- `Removed`: removed from current product behavior; no native parity work.

| Feature group | Legacy source | macOS status | Native macOS coverage | Remaining parity work |
| --- | --- | --- | --- | --- |
| Typed Rust core boundary | `nostr-vpn-app-core`, legacy commands | Ready | `FfiApp.state()`, `refresh()`, and typed `NativeAppAction` dispatch are used directly from Swift through UniFFI. Native state now projects service, diagnostics, exit-node, MagicDNS, join requests, and participant details. | Keep action/state additions typed; avoid reintroducing JSON bridge helpers. |
| Initial state load | `get_state`, `AppBootstrap.svelte` | Ready | `AppManager` constructs `FfiApp`, reads initial state synchronously, and starts the refresh loop on window appearance. | Add boot-ready automation event only if native e2e harness needs it. |
| Periodic refresh | `tick` interval | Ready | `AppManager.start()` refreshes every 1500ms. | Later replace polling with a core update stream if added. |
| Action lock/error recovery | `runAction`, action flags | Ready | `AppManager` serializes typed actions, shows in-flight status, and projects core errors into the shell. | Add per-control progress text if native e2e tests require it. |
| Main status hero | `HeroStatusPanel.svelte` | Ready | Shows active network title, admin badge, mesh state, daemon/VPN/FIPS badges, peer/tunnel/exit metrics, disclosure, identity, and VPN toggle. | Tune copy if product policy text changes. |
| VPN connect/disconnect | `connect_vpn`, `disconnect_vpn` | Ready | Connect/disconnect dispatches typed native actions; Rust runs elevated `nvpn` on macOS. | None. |
| Privacy disclosure | `shouldShowVpnDataDisclosure` | Ready | Native hero renders the VPN data disclosure when VPN control/mobile-like policy applies. | Move exact policy text into core if reused by more shells. |
| Own npub display/copy | `HeroStatusPanel.svelte` | Ready | Native hero renders `ownNpub`, supports selection, and gives transient copy feedback. | None. |
| Active network summary | `ActiveNetworkPanel.svelte` | Ready | Native active-network panel supports name edit, mesh ID edit/copy, admin summary, join-request controls, and admin-gated controls. | None. |
| Mesh ID editing | `mesh-id.js`, `set_network_mesh_id` | Ready | Mesh ID edits dispatch typed Rust action; Rust normalizes/canonicalizes and reports errors. | Add blur/Enter auto-commit if preferred over explicit save icon. |
| Join-request generation/copy | `joinRequestQrCodeOrLink` | Ready | Unjoined devices can copy/share their signed request and render it as a QR code. | None. |
| Join-request deep-link import | `nvpn://join-request/...` handler | Ready | Native handles running-app and startup request URLs and shows requester confirmation. | None. |
| Join-request paste/import | add-device request field | Ready | Pasted signed requests use the same typed approval action as QR scans. | None. |
| Join-request QR generation | `qrcode` | Ready | Native CoreImage QR exactly encodes the signed join request. | None. |
| Join-request QR scan | `jsQR`, camera/image input | Ready | Native image picker decodes QR images, and live AVFoundation scan uses the same approval path. | None. |
| Participant list | `ActiveNetworkPanel.svelte` | Ready | Shows participants, reachability, transport/presence badges, npub copy, alias, MagicDNS, traffic, routes, admin, exit-node, and remove controls. | None. |
| Manual add participant | `add_participant` | Ready | Admin can add participant npub with optional alias. | None. |
| Participant alias editing | `set_participant_alias` | Ready | Alias edits dispatch typed Rust action and show MagicDNS suffix/name. | Add debounce if explicit save feels too heavy. |
| Participant admin/remove actions | `add_admin`, `remove_admin`, `remove_participant` | Ready | Admin toggle and remove icon dispatch typed core actions with local-admin gating. | Add destructive confirmation if needed. |
| Participant traffic/path details | Participant runtime fields | Ready | `NativeParticipantState` now mirrors traffic, routes, exit-node capability, tunnel IP, FIPS transport, presence, and last-seen details. | None. |
| Saved networks list | `SavedNetworksPanel.svelte` | Ready | Sidebar and saved-networks disclosure support add, activate, rename, delete, mesh edit, participant preview, and participant removal. | Add inactive join-request detail expansion if needed. |
| Activate saved network | `set_network_enabled` | Ready | Inactive network rows dispatch typed activation and daemon reload handling from Rust. | None. |
| Delete saved network | `remove_network` | Ready | Native saved-network delete dispatches typed core removal; deleting the final network returns the app to setup. | Add confirmation if needed. |
| Exit Nodes summary | Exit-node page | Ready | Native exit-node section shows direct/exit mode, offer-exit toggle, and exit candidates. | Add richer route helper text from core if desired. |
| Advertise exit node | `advertiseExitNode` | Ready | Toggle dispatches typed settings patch from exit-node and menu bar surfaces. | None. |
| Advanced route advertisement | `advertisedRoutes` | Deferred | Native shells hide the CIDR string editor; Rust still normalizes and validates config values. | Reintroduce only behind an advanced affordance if needed. |
| Exit node search/select | `exitNode` | Ready | Searchable native candidate list supports no-exit selection and offered-exit peers. | None. |
| Diagnostics panel | `AdvancedPanels.svelte` | Ready | Native diagnostics disclosure renders health issues, interface/IP/gateway, captive portal, and port-mapping state; opens when health count increases. | None. |
| Session options | `autoconnect` | Ready | Native system panel includes autoconnect, launch-on-startup with LaunchAgent registration, and menu-bar-on-close settings toggles. | None. |
| Device settings | `SystemPanel.svelte` | Ready | Native system panel includes name, endpoint, tunnel IP, listen port, MagicDNS suffix/status, app/config/version fields, CLI controls, service controls, and updater controls. | None. |
| MagicDNS | `magicDnsStatus`, `magicDnsSuffix` | Ready | Native state projects MagicDNS status/name/suffix; UI exposes suffix editor and participant DNS labels. | None. |
| Background service panel | `ServiceActionPanel.svelte` | Ready | Native state queries `nvpn service status --json`; UI supports install/reinstall/enable/disable/uninstall, stale-version repair prompts, and settlement polling after service actions. | None. |
| CLI install/uninstall | `install_cli`, `uninstall_cli` | Ready | Native UI shows CLI status and runs elevated install/reinstall/uninstall actions. | None. |
| Launch on startup | Autostart plugin | Ready | Native UI persists the setting and writes/removes a per-user LaunchAgent with `--autostart`. | None. |
| Close to tray/status item | Tray runtime | Ready | Native menu bar item supports open, VPN toggle, exit toggle, copy this device, network devices, exit-node selection, and quit; close hides the main window when enabled. Manual refresh is intentionally not user-facing. | None. |
| Autostart hidden launch | `--autostart` | Ready | LaunchAgent starts the app with `--autostart`, and the main window hides after startup unless a deep link is being handled. | None. |
| Single-instance handling | Legacy singleton plugin | Ready | Native app holds a local lock and routes duplicate-process startup URLs into the existing instance through distributed notifications. | None. |
| Debug automation deep links | `nvpn://debug/...` | Ready | Native handler supports `nvpn://debug/tick`; join request automation should use the admin import action. | None. |
| Hashtree updater | `UpdateBanner.svelte`, updater panel | Ready | Native updater checks the hashtree release manifest, preserves auto-check/auto-install prefs, downloads macOS assets, and can install `.app.tar.gz` archives by relaunching into the replacement app. | None. |
| Responsive/adaptive layout | Svelte CSS | Ready | Native split-view desktop layout builds and was checked with an app-window screenshot at 1100x760. | Add compact-window and accessibility passes. |
| Copy feedback | `copiedValue` timeout | Ready | Clipboard writes show transient checkmark feedback for identity, mesh, join requests, and peer npub copy buttons. | None. |
| Collapsible panels | `<details>` state | Ready | Native saved networks, diagnostics, and system sections use disclosure groups; diagnostics opens when health issues increase. | Persist expanded state if users want it. |
| Mock/demo fixtures | `mock-backend.ts` | Ready | macOS launches with a built-in native state snapshot when `--nvpn-fixture-mode` or `NVPN_MACOS_FIXTURE_MODE=1` is set, for previews and screenshot tests without the old mock backend. | None. |
| Public relay fallback UI | Removed relay fallback/public services code | Removed | Removed upstream in `origin/master`; native shell also omits those fields and controls. | No parity work unless product reintroduces a public-service feature. |

## Windows App Parity Status

This table tracks the WPF/.NET shell under `windows/` against the current macOS
and Linux native shells.

| Feature group | Windows status | Native Windows coverage | Remaining parity work |
| --- | --- | --- | --- |
| Rust core boundary | Ready | `windows/NostrVpn.Windows` uses the explicit C ABI in `nostr-vpn-app-core/src/c_abi.rs` for JSON state, JSON actions, QR matrix generation, and QR image decode. | Replace with generated C# UniFFI only if UniFFI gains supported C# bindings in the pinned toolchain. |
| Main shell hierarchy | Ready | WPF two-pane shell renders Devices, Share, Exit Nodes, and Settings with the same high-level hierarchy as macOS/Linux. | Continue compact-width and accessibility polish. |
| Device roster | Partial | Shows participant identity, tunnel IP, status, admin/exit badges, npub copy, and add-device form. | Add inline alias/admin/remove management parity. |
| Join-request approval | Ready | Imports signed requests from paste or QR images and queues signed-roster delivery. | Add live camera scanning if a native Windows camera API is selected. |
| Exit Nodes | Ready | Direct route, exit-node candidate selection, exit-node offer toggle, and offer-exit toggle dispatch typed core actions. | Add search/filter polish like macOS. |
| Settings/service/updater | Partial | Device settings, autoconnect/startup/tray toggles, service/CLI actions, diagnostics, and hashtree update check are present. | Add richer service settlement/repair UX and auto-update preferences. |
| Tray/status area | Ready | Uses native `System.Windows.Forms.NotifyIcon` with open, VPN toggle, exit toggle, this-device copy, network devices, exit-node selection, and quit. | Add single-instance tray activation routing for already-running deep links. |
| Deep links/startup | Partial | Registers `nvpn://` under HKCU, handles startup join-request URLs, and writes HKCU Run startup entries. | Route deep links into an already-running instance. |
| Build/run harness | Ready | `scripts/windows-build.ps1` builds Rust DLL/CLI plus WPF and `just run-windows` runs it on Windows. Verified in the Windows 11 Parallels VM with `dotnet build`, Rust build, and an app-window screenshot. | Add packaged installer/MSIX/NSIS target. |

## Android App Parity Status

This table tracks the Kotlin/Jetpack Compose shell under `android/` against the
current native shell contract.

| Feature group | Android status | Native Android coverage | Remaining parity work |
| --- | --- | --- | --- |
| Rust core boundary | Ready | The Android app cross-compiles `nostr-vpn-app-core` to `arm64-v8a` and calls the shared JSON C ABI through JNI exports for state, refresh, action dispatch, QR generation, and QR image decode. | Add generated UniFFI Kotlin only if it becomes simpler than the explicit JNI bridge. |
| Build/install harness | Ready | `just android-build` builds a debug APK and `just android-install` installs it on a connected device; verified on a physical Android device with an app screenshot. | Add release signing/AAB/Zapstore packaging. |
| Main shell hierarchy | Partial | Compose renders Devices, Share, Exit Nodes, and Settings with the same simple top-level flow as the desktop native shells. | Add tablet/landscape layouts and compact accessibility passes. |
| Mobile app-core startup | Ready | Android now uses mobile app-core status and no longer shells out to the desktop `nvpn` binary during startup or config-only refreshes. | Replace polling with a core/mobile runtime update stream later. |
| Device roster | Partial | Shows local/peer identity, tunnel IP, reachability, admin/exit badges, npub copy, and join-request approval. | Add alias/admin/remove controls and richer traffic/path detail parity. |
| Join-request approval | Partial | Renders the joining device's request QR and approves signed requests from paste or deep links. | Add Android share sheet, camera live scan, and image picker QR import UI. |
| Exit Nodes | Partial | Direct/exit-node selection, offer-exit toggle dispatch core actions. | Add search/filter polish and mobile-specific route constraints. |
| Settings/diagnostics | Partial | Device settings, saved network activation, join-request toggle, runtime detail, MagicDNS, app version, and health rows are visible. | Add destructive actions, richer diagnostics, and mobile storage/keystore policy. |
| VPN runtime | Partial | Android `VpnService` permission surface and service declaration are present; app-core reports mobile VPN state without desktop CLI dependency. | Wire the packet tunnel data-plane loop to FIPS endpoint delivery before calling the mobile VPN path complete. |

## iOS App Parity Status

This table tracks the SwiftUI/UIKit shell under `ios/` against the current
native shell contract.

| Feature group | iOS status | Native iOS coverage | Remaining parity work |
| --- | --- | --- | --- |
| Rust core boundary | Ready | The iOS app builds `nostr-vpn-app-core` for simulator and device targets, packages it as `NostrVpnAppCore.xcframework`, and calls the shared JSON C ABI for state, refresh, action dispatch, QR generation, and QR image decode. | Add generated UniFFI Swift only if it becomes cleaner than the explicit C bridge. |
| Build/run harness | Ready | `just ios-build` builds Rust, generates the Xcode project, and builds the simulator app; `just ios-run` installs and launches it in the iPhone simulator. Verified with an iPhone simulator screenshot. | Add signed device/TestFlight packaging and release archive flow. |
| Main shell hierarchy | Partial | SwiftUI renders Devices, Share, Exit Nodes, and Settings with the same simple top-level flow as Android and the desktop native shells. | Add iPad/landscape layouts and compact accessibility passes. |
| Mobile app-core startup | Ready | iOS uses the mobile app-core status path and no longer shells out to the desktop `nvpn` binary during startup or config-only refreshes. | Replace polling with a core/mobile runtime update stream later. |
| Device roster | Partial | Shows local/peer identity, tunnel IP, reachability, admin/exit badges, npub copy, and join-request approval. | Add alias/admin/remove controls and richer traffic/path detail parity. |
| Join-request approval | Partial | Renders the joining device's request QR and approves signed requests from paste or deep links. | Add image picker and live camera QR scanning. |
| Exit Nodes | Partial | Direct/exit-node selection, offer-exit toggle dispatch core actions. | Add search/filter polish and mobile-specific route constraints. |
| Settings/diagnostics | Partial | Device settings, saved network activation, join-request toggle, runtime detail, MagicDNS, app version, and health rows are visible. | Add destructive actions, richer diagnostics, and iOS storage/keychain policy. |
| VPN runtime | Partial | A NetworkExtension Packet Tunnel target and manager wrapper are present; app-core reports mobile VPN state without desktop CLI dependency. | Wire the packet tunnel packet loop to FIPS endpoint delivery before calling the iOS VPN path complete. |

## Linux App Parity Status

This table tracks the GTK/libadwaita shell under `linux/` against the current
macOS shell. Tauri remains the feature inventory above, but Linux should look and
flow like the Swift app rather than the removed Svelte UI.

### macOS/Linux Desktop Parity Snapshot

| Feature area | macOS | Linux | Status / notes |
| --- | --- | --- | --- |
| Rust state/action boundary | UniFFI `FfiApp` state, refresh, typed actions | Direct Rust `FfiApp` state, refresh, typed actions | Matched. Keep future shell work behind the shared action/state contract. |
| Header VPN control | Status text, optional status dot, compact switch | Status text, optional status dot, compact switch | Matched. Linux no longer exposes a toolbar refresh button or a second hero Off/On button. |
| Devices and local identity | Device list/detail, status badges, npub copy, add-device sheet | Device list/detail, status badges, npub copy, add-device page | Feature matched; layout differs by toolkit. |
| Join-request flow | Request QR/copy/share, paste/import, live scan, file scan | Request QR/copy, paste/import, `zbarcam` live scan, file scan | Matched, with scanner implementation platform-specific. |
| Exit-node routing | Direct, WireGuard upstream, peer exit candidates, offer-exit, leak protection | Direct, WireGuard upstream, peer exit candidates, offer-exit, leak protection | Matched. WireGuard config remains visible even before a network is active. |
| WireGuard upstream config | Paste, import file, save, select as exit | Paste, import file, save, select as exit | Matched. |
| Relays | Add, enable/disable, delete | Add, enable/disable, delete | Matched. |
| Active network settings | Rename, edit/copy network ID, join-request toggle, delete network | Rename, edit/copy network ID, join-request toggle, delete network | Matched. |
| Saved networks | Activate/delete plus inactive profile detail surface | Activate/delete plus inactive profile detail surface | Matched. Linux inactive profiles expand to rename, copy network ID, toggle join requests, and manage participants. |
| Service/CLI/updater | CLI/service actions, update checks/install, auto-update prefs | CLI/service actions, update checks/download/open, auto-update prefs | Matched for the current Linux package policy: downloaded packages are opened instead of silently installed. |
| Diagnostics | Health, interfaces, IPs, gateway, mapping, paths | Health, interfaces, IPs, gateway, mapping, paths | Matched; diagnostics opens when new health warnings arrive. |
| Startup/tray/deep links | LaunchAgent, menu bar, single-instance URL routing | Desktop autostart, StatusNotifier tray, GApplication URL routing | Matched. |

| Feature group | Linux status | Native Linux coverage | Remaining parity work |
| --- | --- | --- | --- |
| Typed Rust core boundary | Ready | `linux/src/main.rs` uses `FfiApp.state()`, `refresh()`, and typed `NativeAppAction` directly from Rust. | Keep additions typed and shared with macOS. |
| Initial state and refresh | Ready | The GTK shell reads initial state synchronously and refreshes through `FfiApp.refresh()` on a two-second timer. | Add a boot-ready automation hook if native e2e needs it. |
| Main status hero | Ready | Matches the macOS hierarchy: active network title, admin badge, mesh/VPN/daemon/FIPS badges, identity copy, tunnel IP, and exit indication. The VPN toggle lives in the header like macOS. | Add richer service-repair prompt text if core exposes a shared helper. |
| Device roster | Ready | Shows participant name, admin/exit badges, tunnel IP, npub copy, reachability, admin toggle, remove action, and a Manage Devices disclosure. | Add destructive confirmations if needed. |
| Participant alias editing | Ready | Manage Devices includes per-participant alias save, admin toggle, and remove controls. | Add debounce if explicit save feels too heavy. |
| Join requests | Ready | Inbound request rows show requester info, npub copy, and admin-gated accept action. | None. |
| Join-request approval | Ready | Share page renders signed request QR codes and supports copy, paste/import, image QR import, and optional `zbarcam` live scan. | Add share portal support only if desktop share-sheet behavior becomes important. |
| Exit Nodes | Ready | Direct route, searchable exit-node candidates, WireGuard upstream config, exit-node offer toggle, and offer-exit toggle mirror the macOS Exit Nodes page. WireGuard settings are visible even before a network is active. | Add richer route helper text from core if added. |
| Active network settings | Ready | Settings exposes active network name, editable/copyable network ID, admin-gated join-request toggle, confirmed delete, and Enter-to-save for name/network ID edits. | None. |
| Saved networks | Ready | Saved Networks disclosure lists inactive networks with counts, activate/delete actions, expandable profile editing, network ID copy, join-request toggle, participant alias/admin/remove controls, and confirmed delete. | None. |
| Device/system settings | Ready | Name, tunnel IP, endpoint, listen port, MagicDNS suffix, autoconnect, startup desktop-entry registration, and tray preferences dispatch typed settings patches. | None. |
| CLI and service controls | Ready | Shows CLI/service status badges and install/reinstall/uninstall plus enable/disable service actions when supported; service actions show settlement progress and stale-version repair state. | Add a richer polkit prompt only if the CLI stops being launched through an already-elevated context. |
| Diagnostics | Ready | Advanced diagnostics shows interface/IP/gateway/mapping metrics, identity/config/runtime fields, MagicDNS, and health issue rows; the section opens when new health warnings arrive. | None. |
| Tray/status menu | Ready | Native StatusNotifierItem + DBusMenu implementation exposes open, VPN toggle, exit toggle, this-device copy, network devices, exit-node selection, and quit; close-to-tray and autostart-hidden launch are wired. | Verify with installed desktop environments beyond the Docker Fluxbox harness. |
| Deep links and single-instance | Ready | GApplication routes startup and already-running `nvpn://` URLs into the existing GTK app; the desktop entry registers `x-scheme-handler/nvpn`; join-request and debug automation links dispatch typed core actions. | Add installed-package smoke coverage once Linux packaging tests exist. |
| Updater | Ready | Linux checks the hashtree release manifest, shows current/update status, prefers Linux AppImage/deb assets, downloads with `curl`, marks AppImages executable, and opens the downloaded package with `xdg-open`. | Add automatic install only after Linux packaging policy is settled. |
| Screenshot/dev harness | Ready | Docker Xvfb/Fluxbox dev environment runs the GTK app and supports window screenshots over VNC on `localhost:5902`. | Add automated screenshot fixture states. |

## Native Implementation Phases

| Phase | Deliverable | Exit criteria |
| --- | --- | --- |
| 0. Contract extraction | Move backend state, settings patches, action handlers, derived labels, join-request parsing, mesh ID validation, and tray projections into a native-ready Rust app core | `crates/nostr-vpn-app-core` exposes typed UniFFI state/actions and the macOS shell consumes `FfiApp` directly. |
| 1. Desktop minimum | macOS, Windows, and Linux render the main status, signed join-request approval, participant management, exit-node, diagnostics, service panel, system settings, deep links, and tray/menu actions | Desktop smoke tests can approve signed requests, toggle VPN, and exercise tray actions. |
| 2. Mobile minimum | Android and iPhone render the same state/action surface with native VPN permission/control, join-request QR/share, saved networks, exit-node, diagnostics, and deep links | Android emulator/device and iPhone simulator/device smoke tests can complete signed join-request approval and start supported VPN flows |
| 3. Desktop niceties | Hashtree updater, CLI install/uninstall, startup registration, close-to-tray, service repair prompts, single-instance conflict handling | Legacy desktop e2e scenarios have native replacements |
| 4. Polish/parity hardening | Platform screenshots, accessibility pass, empty/error states, fixture preview coverage | All rows above are either implemented or explicitly marked removed/deferred in this file |

## Open Decisions

| Decision | Options | Current recommendation |
| --- | --- | --- |
| Push updates vs polling | Keep 1500ms polling, add core update stream, or hybrid | Use update stream with tick fallback; avoid mobile background polling |
| Linux shell API | Direct Rust GTK calls into the core or UniFFI like other shells | Direct Rust is simpler, but keep the same typed state/action structs so parity tests are shared |
| QR generation location | Native QR libraries per platform or Rust QR helper | Rust helper for QR bytes; native scanner APIs for camera/image decode |
| Derived text ownership | Keep per-shell text formatting or move helper text into core | Move policy-bearing derived labels into core; keep purely visual labels native |
| Desktop updater on Linux | Keep hashtree updater or only package-manager updates | Keep hashtree updater for parity unless Linux packaging policy says otherwise |
