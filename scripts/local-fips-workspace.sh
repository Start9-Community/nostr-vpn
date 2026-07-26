#!/usr/bin/env bash

nvpn_restore_local_fips_workspace() {
  if [[ -n "${NVPN_LOCAL_FIPS_LOCK_SNAPSHOT:-}" \
        && -f "$NVPN_LOCAL_FIPS_LOCK_SNAPSHOT" \
        && -f "$NVPN_LOCAL_FIPS_ROOT/Cargo.lock" ]]; then
    if ! cmp -s "$NVPN_LOCAL_FIPS_LOCK_SNAPSHOT" "$NVPN_LOCAL_FIPS_ROOT/Cargo.lock"; then
      cp -p "$NVPN_LOCAL_FIPS_LOCK_SNAPSHOT" "$NVPN_LOCAL_FIPS_ROOT/Cargo.lock"
      printf 'restored Cargo.lock after local-FIPS cargo run\n'
    fi
  fi
  if [[ -n "${NVPN_LOCAL_FIPS_MANIFEST_SNAPSHOT:-}" \
        && -f "$NVPN_LOCAL_FIPS_MANIFEST_SNAPSHOT" \
        && -f "$NVPN_LOCAL_FIPS_ROOT/Cargo.toml" ]]; then
    if ! cmp -s "$NVPN_LOCAL_FIPS_MANIFEST_SNAPSHOT" "$NVPN_LOCAL_FIPS_ROOT/Cargo.toml"; then
      cp -p "$NVPN_LOCAL_FIPS_MANIFEST_SNAPSHOT" "$NVPN_LOCAL_FIPS_ROOT/Cargo.toml"
      printf 'restored Cargo.toml after local-FIPS cargo run\n'
    fi
  fi
}

nvpn_validated_fips_repo_path() {
  local fips_path="${NVPN_FIPS_REPO_PATH:-}"
  [[ -n "$fips_path" ]] || return 1
  if [[ ! -d "$fips_path/crates/fips-core" \
        || ! -d "$fips_path/crates/fips-endpoint" \
        || ! -d "$fips_path/crates/fips-identity" ]]; then
    echo "NVPN_FIPS_REPO_PATH must point at a fips checkout with fips-core, fips-endpoint, and fips-identity" >&2
    exit 1
  fi
  printf '%s\n' "$fips_path"
}

nvpn_prepare_local_fips_workspace() {
  [[ -n "${NVPN_FIPS_REPO_PATH:-}" ]] || return 0
  [[ -z "${NVPN_LOCAL_FIPS_PREPARED:-}" ]] || return 0

  NVPN_LOCAL_FIPS_ROOT="$1"
  local fips_path
  fips_path="$(nvpn_validated_fips_repo_path)"

  NVPN_LOCAL_FIPS_LOCK_SNAPSHOT="$(mktemp)"
  NVPN_LOCAL_FIPS_MANIFEST_SNAPSHOT="$(mktemp)"
  cp -p "$NVPN_LOCAL_FIPS_ROOT/Cargo.lock" "$NVPN_LOCAL_FIPS_LOCK_SNAPSHOT"
  cp -p "$NVPN_LOCAL_FIPS_ROOT/Cargo.toml" "$NVPN_LOCAL_FIPS_MANIFEST_SNAPSHOT"
  if [[ -n "$(trap -p EXIT)" ]]; then
    echo "local FIPS workspace refuses to replace an existing EXIT cleanup" >&2
    exit 1
  fi
  trap nvpn_restore_local_fips_workspace EXIT

  printf '\n[patch.crates-io]\nfips-core = { path = "%s" }\nfips-endpoint = { path = "%s" }\nfips-identity = { path = "%s" }\n' \
    "$fips_path/crates/fips-core" \
    "$fips_path/crates/fips-endpoint" \
    "$fips_path/crates/fips-identity" \
    >>"$NVPN_LOCAL_FIPS_ROOT/Cargo.toml"

  NVPN_LOCAL_FIPS_PREPARED=1
  export NVPN_LOCAL_FIPS_PREPARED
  export NVPN_LOCAL_FIPS_ROOT
  export NVPN_LOCAL_FIPS_LOCK_SNAPSHOT
  export NVPN_LOCAL_FIPS_MANIFEST_SNAPSHOT
  printf 'using exact local FIPS checkout\n'
}

nvpn_verify_local_fips_metadata() {
  local root="$1" receipt="$2"
  [[ -n "${NVPN_FIPS_REPO_PATH:-}" ]] || return 0
  [[ -z "${NVPN_LOCAL_FIPS_METADATA_VERIFIED:-}" ]] || return 0
  local fips_path head tree version metadata metadata_log
  fips_path="$(nvpn_validated_fips_repo_path)"
  head="$(git -C "$fips_path" rev-parse HEAD)"
  tree="$(git -C "$fips_path" rev-parse 'HEAD^{tree}')"
  [[ -z "$(git -C "$fips_path" status --porcelain --untracked-files=all)" ]] || {
    echo "local FIPS linkage refuses a dirty checkout" >&2
    return 1
  }
  if [[ -n "${NVPN_EXPECTED_FIPS_GIT_SHA:-}" \
    && "$NVPN_EXPECTED_FIPS_GIT_SHA" != "$head" ]]
  then
    echo "local FIPS linkage HEAD does not match the required revision" >&2
    return 1
  fi
  version="$(
    awk '
      $0 == "[package]" { package = 1; next }
      package && /^\[/ { exit }
      package && /^version = "/ {
        value = $0
        sub(/^version = "/, "", value)
        sub(/".*$/, "", value)
        print value
        exit
      }
    ' "$fips_path/crates/fips-core/Cargo.toml"
  )"
  [[ -n "$version" ]] || {
    echo "local FIPS linkage could not read the fips-core package version" >&2
    return 1
  }
  if [[ -n "${NVPN_EXPECTED_FIPS_VERSION:-}" \
    && "$NVPN_EXPECTED_FIPS_VERSION" != "$version" ]]
  then
    echo "local FIPS linkage version does not match the required version" >&2
    return 1
  fi
  metadata="$(mktemp "${TMPDIR:-/tmp}/nvpn-fips-metadata.XXXXXX.json")"
  metadata_log="$(mktemp "${TMPDIR:-/tmp}/nvpn-fips-metadata.XXXXXX.log")"
  if ! (cd "$root" && cargo metadata --format-version 1 \
    >"$metadata" 2>"$metadata_log")
  then
    rm -f "$metadata" "$metadata_log"
    echo "Cargo metadata could not resolve the exact local FIPS checkout" >&2
    return 1
  fi
  rm -f "$metadata_log"
  mkdir -p "$(dirname "$receipt")"
  if ! python3 - \
    "$metadata" "$receipt" "$fips_path" "$version" "$head" "$tree" <<'PY'
import json
import hashlib
import os
import sys

metadata_path, receipt_path, checkout, version, head, tree = sys.argv[1:]
payload = json.load(open(metadata_path, encoding="utf-8"))
manifest = os.path.realpath(
    os.path.join(checkout, "crates", "fips-core", "Cargo.toml")
)
matches = [
    package
    for package in payload.get("packages", [])
    if package.get("name") == "fips-core"
]
if len(matches) != 1:
    raise SystemExit(f"Cargo metadata resolved {len(matches)} fips-core packages")
package = matches[0]
if os.path.realpath(package.get("manifest_path", "")) != manifest:
    raise SystemExit("Cargo metadata did not resolve fips-core to the exact checkout")
if package.get("version") != version:
    raise SystemExit("Cargo metadata resolved the wrong fips-core version")
if package.get("source") is not None:
    raise SystemExit("Cargo metadata resolved a registry fips-core package")
package_id = package.get("id")
nodes = payload.get("resolve", {}).get("nodes", [])
if not any(node.get("id") == package_id for node in nodes):
    raise SystemExit("Cargo dependency graph does not contain exact local fips-core")
with open(receipt_path, "w", encoding="utf-8") as output:
    checkout_path = os.path.realpath(checkout)
    json.dump(
        {
            "checkoutHead": head,
            "checkoutPathSha256": hashlib.sha256(
                checkout_path.encode()
            ).hexdigest(),
            "checkoutTree": tree,
            "fipsCoreManifestPathSha256": hashlib.sha256(
                manifest.encode()
            ).hexdigest(),
            "fipsCorePackageIdSha256": hashlib.sha256(
                package_id.encode()
            ).hexdigest(),
            "fipsCoreVersion": version,
            "source": "exact clean local Cargo path dependency",
        },
        output,
        indent=2,
        sort_keys=True,
    )
    output.write("\n")
PY
  then
    rm -f "$metadata"
    return 1
  fi
  rm -f "$metadata"
  NVPN_LOCAL_FIPS_METADATA_VERIFIED=1
  NVPN_VERIFIED_FIPS_HEAD="$head"
  NVPN_VERIFIED_FIPS_TREE="$tree"
  NVPN_VERIFIED_FIPS_VERSION="$version"
}

nvpn_force_rebuild_local_fips_target() {
  local root="$1" target="$2" profile="$3" marker="$4"
  [[ -n "${NVPN_FIPS_REPO_PATH:-}" ]] || return 0
  local key="NVPN_LOCAL_FIPS_CLEANED_${target//-/_}_${profile}"
  [[ -z "${!key:-}" ]] || return 0
  local -a profile_args=()
  [[ "$profile" != "release" ]] || profile_args+=(--release)
  (
    cd "$root"
    cargo clean -p fips-core -p fips-endpoint -p fips-identity \
      --target "$target" "${profile_args[@]}"
  ) >/dev/null
  mkdir -p "$(dirname "$marker")"
  touch "$marker"
  printf -v "$key" 1
}
