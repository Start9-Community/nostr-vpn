# AGENTS.md

This directory is a StartOS service package — it builds a `.s9pk` for StartOS. The
rest of the repository is upstream's multi-platform Nostr VPN project.

Develop it inside a StartOS packaging workspace created by
`start-cli s9pk init-workspace`, which provides the packaging guide and agent
context above this repo. If you're reading this in a bare clone with no
workspace, the full guide is at <https://docs.start9.com/packaging>.

**Start every task at the recipe index** —
<https://docs.start9.com/packaging/recipes.html>. It maps an intent ("prompt the
user to create admin credentials", "expose a web UI") to the constructs, the
reference pages, and a named production package to copy. The recipe outranks a
neighbouring package you reached by grepping.

Keep `README.md` (technical reference for an AI support or administering agent)
and the repository root `instructions.md` (end-user docs) in sync with your
changes.

**Bugs and feature requests are GitHub issues on this repo** — file them as you
find them. Don't record work in the repo instead: no `TODO.md`, no `NOTES.md`, no
`PLAN.md`. What you verified, tried, and decided belongs in the commit message
and the PR body.

## This repo

- **This is a whole-repo fork of `mmalmi/nostr-vpn`, and upstream maintains the
  `startos/` package too.** `master` tracks upstream, so updating means syncing
  from it — see `UPDATING.md`. Don't treat this as a normal single-package repo.

- **Keep Start9 changes confined to `startos/`**, plus the packaging workflows and
  the root `instructions.md`. Prefer sending an improvement upstream over growing
  the fork delta.

- **The Start9 packaging workflows sit alongside upstream's, not in place of
  them.** `build.yml`, `tagAndRelease.yml` and `syncNext.yml` are ours;
  `ci.yml`, `release.yml` and `windows-smoke.yml` are upstream's. There is
  deliberately **no Start9 `release.yml`** — that name is upstream's
  multi-platform release pipeline, and `tagAndRelease.yml` already deploys every
  push to `master`.

- **`instructions.md`, `icon.svg`, and `LICENSE` are read from the repository
  ROOT** by `s9pk.mk`, which runs `pack` and `list-ingredients` with no path
  flags. They must stay there — moving them breaks packing, and the build fails
  outright without `instructions.md` at root.

- **The StartOS package README is `startos/README.md`.** The root `README.md` is
  upstream's multi-platform readme; don't overwrite it.

- **`virtualNetworking: true` is load-bearing.** It mounts `/dev/net/tun`,
  without which `nvpn` cannot create `utun100`. `CAP_NET_ADMIN` comes from the
  service LXC's own user namespace, so there is no separate capability
  declaration to look for.

- **Forwarders bind the mesh device, never an address.** `nvpn` destroys and
  recreates `utun100` when the first peer joins, so a socket bound to its
  address dies silently. `SO_BINDTODEVICE` plus the interface-index supervisor
  in `main.ts` is what survives that — don't simplify either away.

- **Both share actions must call `syncExportedUrls` after writing.** Init's
  reactive read of `exposures.json` / `mesh-status.json` does not re-fire the
  url-v0 export when those files change, so without the explicit call a share
  only reaches the target service's URL list after the next `package rebuild`.
  `main`'s own watch on `exposures.json` does fire — the forwarder appearing is
  not evidence the export did.

- **A share targets the plaintext bridge port.** No certificate names a tunnel
  address, and the mesh already encrypts end to end.
