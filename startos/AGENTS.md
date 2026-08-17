# AGENTS.md

This directory is a StartOS service package — it builds a `.s9pk` for StartOS. The
rest of the repository is upstream's multi-platform Nostr VPN project.

Develop it inside a StartOS packaging workspace created by
`start-cli s9pk init-workspace`, which provides the packaging guide and agent
context one level up. If you're reading this in a bare clone with no workspace,
the full guide is at <https://docs.start9.com/packaging>.

Work this package's `TODO.md` from top to bottom. Keep `README.md` (technical
reference for an AI support or administering agent) and the repository root
`instructions.md` (end-user docs) in sync with your changes.

## This repo

- **This is a whole-repo fork of `mmalmi/nostr-vpn`, and upstream maintains the
  `startos/` package.** `master` carries zero Start9 commits ahead of upstream, so
  updating means syncing from upstream — see `UPDATING.md`. Don't treat this as a
  Start9-authored package or as a normal single-package repo.

- **Keep Start9 changes confined to `startos/`.** Keep upstream's `.github/`
  workflows rather than swapping in the Start9 packaging CI. The one intentional
  change outside `startos/` is the augmented root `instructions.md`. Prefer
  sending an improvement upstream over growing the fork delta.

- **`instructions.md`, `icon.svg`, and `LICENSE` are read from the repository
  ROOT** by `s9pk.mk`, which runs `pack` and `list-ingredients` with no path
  flags. They must stay there — moving them breaks packing, and the build fails
  outright without `instructions.md` at root.

- **The StartOS package README is `startos/README.md`.** The root `README.md` is
  upstream's multi-platform readme; don't overwrite it.

- **`nestedRuntime: true` is load-bearing.** It is what grants `CAP_NET_ADMIN`
  and mounts `/dev/net/tun`, without which `nvpn` cannot create `utun100`. There
  is no separate capability declaration to look for.
