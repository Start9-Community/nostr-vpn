# Updating the upstream version

This is a **whole-repo fork** of [mmalmi/nostr-vpn](https://github.com/mmalmi/nostr-vpn).
Upstream maintains the StartOS package under `startos/` and bumps its version in
`startos/versions/current.ts`, so updating this package means **syncing from
upstream**, not bumping an image tag.

## Determining the upstream version

The package version tracks upstream's. Check the latest upstream release:

```sh
gh release view -R mmalmi/nostr-vpn --json tagName -q .tagName
```

**Sync to that tag, not to `upstream/master`.** Upstream bumps
`startos/versions/current.ts` when it opens a version, so master routinely
carries a version number that has no release behind it — following master
packages a version whose artifacts do not exist. The current pin lives in
`startos/versions/current.ts` (`current.version`).

## Applying the update

`master` carries Start9 commits that upstream does not have, so the sync is a
merge of the release tag:

```sh
git remote add upstream https://github.com/mmalmi/nostr-vpn.git   # first time only
git fetch upstream --tags
git merge v<latest>                    # the release tag, not upstream/master
```

Conflicts should only touch the package. Fold upstream's own `startos/`
changes into ours rather than taking either side whole; keep Start9's
`package.json`, `instructions.md` and workflows; keep `s9pk.mk` deleted, since
the SDK supplies it; take upstream's side everywhere else. Set
`startos/versions/current.ts` to the new upstream version with revision `:0`,
regenerate `package-lock.json`, rebuild, and test on a StartOS host:

```sh
make x86 install
```

## Keep divergence minimal

Upstream owns both the repo root and `startos/`. Confine Start9 changes to
`startos/` and prefer contributing improvements upstream over carrying a fork
delta. Two things sit outside it deliberately: the root `instructions.md`, which
documents the StartOS-specific setup and device-joining flow, and the Start9
packaging workflows, which run alongside upstream's rather than replacing them
(see `AGENTS.md`).
