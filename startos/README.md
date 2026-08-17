<p align="center">
  <img src="../icon.svg" alt="Nostr VPN Logo" width="21%">
</p>

# Nostr VPN on StartOS

> Everything not listed in this document should behave the same as upstream
> Nostr VPN. If a feature, setting, or behavior is not mentioned here, the
> upstream documentation is accurate and fully applicable — see the
> Documentation section of `instructions.md` for links.

[Nostr VPN](https://github.com/mmalmi/nostr-vpn) is a private mesh VPN whose
control plane — peer discovery and NAT traversal — runs over Nostr rather than a
central coordination server. This package runs the `nvpn` daemon and the
`nvpn-web` control panel together as one StartOS service, with the panel gated
behind a StartOS-managed credential.

> [!NOTE]
> This is the StartOS package README. The repository root `README.md` is
> upstream's multi-platform readme, and this file is its StartOS companion.

---

## Table of Contents

- [Image and Container Runtime](#image-and-container-runtime)
- [Volume and Data Layout](#volume-and-data-layout)
- [File Models](#file-models)
- [Dependencies](#dependencies)
- [Network Access and Interfaces](#network-access-and-interfaces)
- [Installation and First-Run Flow](#installation-and-first-run-flow)
- [Actions](#actions)
- [Tasks](#tasks)
- [Health Checks](#health-checks)
- [Backups and Restore](#backups-and-restore)
- [Limitations and Differences](#limitations-and-differences)
- [Quick Reference for AI Consumers](#quick-reference-for-ai-consumers)

---

## Image and Container Runtime

One image, built from the Dockerfile the upstream repository already ships for
its Umbrel packaging, carrying both compiled binaries and the prebuilt web
frontend. The upstream entrypoint is not used: StartOS runs the daemon and the
control panel as two separate daemons rather than one process.

| Property      | Value                                       |
| ------------- | ------------------------------------------- |
| Image         | built in-repo from `./umbrel/Dockerfile`    |
| Binaries      | `nvpn` (daemon and CLI), `nvpn-web` (panel) |
| Architectures | x86_64, aarch64                             |

| Subcontainer              | Purpose                                            |
| ------------------------- | -------------------------------------------------- |
| `nostr-vpn-daemon`        | the `daemon` mesh process — the one to `attach` to |
| `nostr-vpn-control-panel` | the `control-panel` web process                    |

Both subcontainers mount the same `main` volume, which is how the panel reads the
daemon's state. A `prepare-data` oneshot runs as root before either daemon and
creates the home and config directories.

**The manifest sets `nestedRuntime: true`, and the data plane depends on it.**
That grants the subcontainer the full capability set — including `CAP_NET_ADMIN`
— and mounts `/dev/net/tun`, which is what lets `nvpn` create its `utun100`
tunnel interface. No separate capability declaration exists or is needed; remove
the flag and the tunnel cannot come up.

## Volume and Data Layout

One volume holds everything: the node's identity, its network membership,
upstream's own config, and the package's state.

| Path                            | Written by | Contents                                      |
| ------------------------------- | ---------- | --------------------------------------------- |
| `/data`                         | —          | the `main` volume's mount point               |
| `/data/config/nvpn/config.toml` | `nvpn`     | networks, peers, roster — upstream's own file |
| `/data/home`                    | `nvpn`     | the process `HOME`                            |
| `/data/store.json`              | StartOS    | the package's own state                       |

`config.toml` is passed to both binaries with `--config` and is owned entirely by
the service. StartOS neither seeds nor rewrites it, and it is not modelled here.

## File Models

One model, `store.json`, holding state that belongs to the package rather than to
`nvpn`.

| Field                  | Seeded by                             | Rewritten by                              | Survives a hand edit |
| ---------------------- | ------------------------------------- | ----------------------------------------- | -------------------- |
| `controlPanelPassword` | nothing — absent until an action runs | the **Set Control Panel Password** action | yes                  |

The field is optional and starts unset, which is precisely what the critical
install task keys off. Nothing writes it except the action, so a value edited by
hand is read as-is. Writing it re-runs the interface setup, so a changed password
reaches the reverse proxy without restarting the service.

## Dependencies

None.

## Network Access and Interfaces

One interface, the web control panel. It is bound on a MultiHost, so the user
decides where it is reachable — LAN address, `.local`, Tor, or a public domain.

| Interface     | Id              | Type | Port  | Description             |
| ------------- | --------------- | ---- | ----- | ----------------------- |
| Control Panel | `control-panel` | ui   | 38080 | the Nostr VPN web panel |

**Authentication is enforced by the StartOS reverse proxy, not by `nvpn`.** The
interface declares HTTP basic auth with the fixed username `admin` and the
password from `store.json`, so an unauthenticated request is rejected before it
reaches the container. Until that password is set the auth gate is `null` — which
is why the package refuses to start without one.

## Installation and First-Run Flow

Install raises a critical task and the service will not start until it is
cleared. There is no upstream onboarding wizard to skip.

1. **Set the control panel password.** The task points at the action; running it
   generates the credential and shows it once.
2. **Open the panel and sign in** as `admin`.
3. **Create or join a network.** The daemon launches with `--paused`, so the
   tunnel interface exists but the node carries no traffic until a network is
   active.

## Actions

One action, which serves both first-run setup and later rotation.

**Set Control Panel Password** — run it when the install task asks, or any time
you want to rotate the credential. It generates a new random password, replaces
whatever was stored, and displays the username and password once; the password is
masked and copyable, and is not recoverable afterwards. It runs at any service
status and is safe to repeat, but each run invalidates the previous password, so
anyone signed in with the old one is locked out. There are no hidden actions.

## Tasks

One task, raised by the package against its own action.

**Set a control panel password** — raised on init whenever
`store.json` carries no password, which in practice is a fresh install. It is
**critical**, so it blocks the service from starting and suspends the ordinary
controls until it is cleared. Running the action clears it. It can return: clear
the stored password and the next init raises it again, which is the intended
behavior rather than an edge case.

## Health Checks

Two readiness checks, one per daemon. Both are real readiness probes rather than
process-presence checks.

| Check           | Displayed       | Method                              |
| --------------- | --------------- | ----------------------------------- |
| `daemon`        | "Mesh daemon"   | `nvpn status` exit code             |
| `control-panel` | "Control Panel" | port 38080 is accepting connections |

A failing **Mesh daemon** check means the daemon is not answering its control
socket — the process is gone, or it never got far enough to open the socket.
Deliberately, it does not require an active network, so it stays green while the
node is paused and idle, which is the normal state before you create one.

A failing **Control Panel** check means the web process is not listening. Because
it is ordered behind the daemon, it will also be down whenever the daemon is.

## Backups and Restore

The `main` volume is copied whole, with nothing excluded. That covers the node's
identity, its network membership, upstream's `config.toml`, and the stored
control panel password — so a restored node rejoins its mesh as the same peer,
with the same credential, rather than as a new device that has to be linked
again.

## Limitations and Differences

Three things behave differently here than a reader coming from upstream would
expect.

1. **The daemon starts paused.** The node is idle until you create or join a
   network in the control panel.
2. **Exit-node and full-tunnel routing are unverified on StartOS.** The mesh and
   the `utun100` tunnel come up, but the full-tunnel path — which also depends on
   host IP forwarding and routing — has not been validated here.
3. **Peers need the Nostr VPN client, not a generic WireGuard app.** Devices join
   through upstream's own clients; there is no standard WireGuard config to
   export.

---

## Quick Reference for AI Consumers

```yaml
package_id: nostr-vpn
architectures:
  - x86_64
  - aarch64
subcontainers:
  - nostr-vpn-daemon # the mesh daemon
  - nostr-vpn-control-panel # the web panel
volumes:
  main: /data
file_models:
  - store.json # controlPanelPassword
startos_managed_env_vars:
  - HOME
  - XDG_CONFIG_HOME
  - RUST_LOG
  - NVPN_CLI_PATH
  - NVPN_DAEMON_STATUS_MODE
  - NVPN_EXTERNAL_DAEMON
dependencies: []
interfaces:
  - control-panel # ui, port 38080, basic auth at the proxy
actions:
  - set-control-panel-password
tasks:
  - set-control-panel-password # critical, raised when no password is stored
health_checks:
  - daemon # displayed "Mesh daemon"
  - control-panel # displayed "Control Panel"
```
