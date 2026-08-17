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

The current pin lives in `startos/versions/current.ts` (`currentVersion.version`,
e.g. `4.0.47:0`). The fast-forward below brings it along automatically.

## Applying the update

`master` carries no Start9 commits ahead of upstream, so the sync is a
fast-forward:

```sh
git remote add upstream https://github.com/mmalmi/nostr-vpn.git   # first time only
git fetch upstream
git merge --ff-only upstream/master
```

Then reapply any in-flight Start9 changes (kept under `startos/`) on top, rebuild,
and test on a StartOS host:

```sh
make x86 install
```

> If Start9-specific commits have been landed on `master` (a hard fork), the
> fast-forward will fail; `git rebase upstream/master` instead and resolve any
> conflicts — which should only ever touch `startos/`.

## Keep divergence minimal

Upstream owns both the repo root and `startos/`. Confine Start9 changes to
`startos/`, keep upstream's `.github/` workflows, and prefer contributing
improvements upstream over carrying a fork delta. The one intentional
out-of-`startos/` change is the augmented root `instructions.md` (it documents
the StartOS-specific auth/critical-task setup flow).
