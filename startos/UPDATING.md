# Updating the upstream version

This is a **whole-repo fork** of [mmalmi/nostr-vpn](https://github.com/mmalmi/nostr-vpn).
Upstream maintains the StartOS package under `startos/`, so updating means syncing
its released source, not bumping an image tag or carrying separate Rust dependency fixes.

## Determining the upstream version

List stable upstream tags, newest first:

```sh
gh api --paginate repos/mmalmi/nostr-vpn/tags --jq '.[].name' \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -Vr
```

Choose the newest stable tag with a published release and both StartOS architecture
assets, not the release marked Latest. Check a candidate explicitly:

```sh
gh release view v<version> -R mmalmi/nostr-vpn \
  --json tagName,isDraft,isPrerelease,assets
```

The assets are `nostr-vpn-v<version>-startos-x86_64.s9pk` and
`nostr-vpn-v<version>-startos-aarch64.s9pk`. They establish the released upstream
version; the Start9 package is rebuilt with its own integration and signing identity.

Sync to the selected tag, not `upstream/master`, which can carry an unreleased
version. The package pin is `current.version` in `startos/versions/current.ts`.

## Applying the bump

Merge the release tag into the Start9 branch:

```sh
git remote add upstream https://github.com/mmalmi/nostr-vpn.git   # first time only
git fetch upstream tag v<version>
git merge v<version>
```

Fold upstream's `startos/` changes into the Start9 package. Keep the SDK-provided
Makefile include, package dependencies/configuration, root `instructions.md` and
Start9 workflows; keep the repository's `s9pk.mk` deleted. Preserve the `current`
export consumed by `startos/versions/index.ts`. Set the selected upstream version
with revision `:0`, and refresh the packaging lockfile with `npm install`.
Take upstream's source, Cargo locks, tests and image-build recipe, retaining only
the existing exceptions below.

### Carried integration exceptions

- `startos/`, root `Makefile`, `package.json`, `package-lock.json`, `.prettierrc`,
  `tsconfig.json` and `assets/.gitkeep` integrate the published SDK packaging flow.
  Root `instructions.md` describes the StartOS setup and joining flow;
  `CONTRIBUTING.md` distinguishes SDK builds from the standalone release validator.
- The Start9 `build.yml`, `pr-retarget.yml`, `tagAndRelease.yml` and `syncNext.yml`
  workflows coexist with upstream's workflows; `release.yml` remains upstream's.
- `umbrel/Dockerfile` adds `socat` for the mesh forwarders and checks the final
  runtime `/etc/ssl/certs/ca-certificates.crt` for compromised G3. Preserve that
  check when upstream changes its bootstrap/index stages. Remove each addition
  when upstream provides it or the package no longer needs it; upstream must
  provide an equivalent final-runtime trust check before the guard retires.
- `scripts/e2e-web-startos-manual-join-docker.sh` omits upstream's `--paused`
  source assertion: this package starts the production daemon active. Retire the
  exception when upstream's gate accepts that integration.
- `scripts/release-publication-bundle.test.mjs` derives the fixture version from
  the StartOS source, including its package revision, rather than assuming the
  workspace marketing version. Retire it when upstream reads that same owner.
- `scripts/startos-release.test.mjs` checks SDK delegation and package architectures
  instead of upstream's removed local helper recipe. Retire it when upstream's
  tests support this packaging integration.
- `crates/nostr-vpn-cli/src/config_bootstrap.rs` carries a Linux cfg-tail lint
  correction required by CI's pinned Clippy. Retire it when upstream includes it.

Prefer upstream releases or upstream contributions over additional fork delta.
