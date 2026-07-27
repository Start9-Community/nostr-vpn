#!/usr/bin/env bash

release_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

NVPN_BUILTIN_APP_ID="fi.siriusbusiness.nvpn"
NVPN_BUILTIN_IOS_BUNDLE_ID="$NVPN_BUILTIN_APP_ID"

expand_env_file_value() {
  local value="$1"
  local home="${HOME:-}"

  if [[ -n "$home" ]]; then
    value="${value/#\~\//$home/}"
    value="${value/#\$HOME\//$home/}"
    value="${value/#\$\{HOME\}\//$home/}"
  fi

  printf '%s' "$value"
}

load_env_file_defaults() {
  local env_file="$1"
  local line
  local key
  local value

  [[ -f "$env_file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue

    if [[ "$line" == export[[:space:]]* ]]; then
      line="${line#export}"
      line="${line#"${line%%[![:space:]]*}"}"
    fi

    key="${line%%=*}"
    key="${key%"${key##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ -n "${!key:-}" ]] && continue

    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value="${value:1:${#value}-2}"
    fi
    value="$(expand_env_file_value "$value")"
    export "$key=$value"
  done < "$env_file"
}

load_release_env() {
  local root="$1"
  local env_file="${NVPN_RELEASE_ENV_FILE:-$root/release.env}"
  local local_env_file="$root/.env.release.local"

  load_env_file_defaults "$env_file"
  if [[ "$local_env_file" != "$env_file" ]]; then
    load_env_file_defaults "$local_env_file"
  fi

  export NVPN_DEFAULT_APP_ID="${NVPN_DEFAULT_APP_ID:-$NVPN_BUILTIN_APP_ID}"
  export NVPN_DEFAULT_IOS_BUNDLE_ID="${NVPN_DEFAULT_IOS_BUNDLE_ID:-$NVPN_DEFAULT_APP_ID}"
}

bool_is_true() {
  case "${1:-}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

epoch_to_iso8601() {
  local epoch="$1"
  if date -u -r 0 +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
    date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ"
  else
    date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

git_short_sha() {
  local root="$1"
  git -C "$root" rev-parse --short=12 HEAD 2>/dev/null || printf '%s\n' "unknown"
}

pin_exact_release_build_git_sha() {
  local root="$1"
  local expected_head="$2"
  local context="$3"
  local configured="${NVPN_BUILD_GIT_SHA:-}"
  local default_short
  default_short="$(git_short_sha "$root")"
  if [[ -n "$configured" \
    && "$configured" != "$expected_head" \
    && "$configured" != "$default_short" ]]
  then
    echo "$context build revision does not match the exact app checkout" >&2
    return 1
  fi
  export NVPN_BUILD_GIT_SHA="$expected_head"
}

select_generated_ios_release_xctestrun() {
  local products_root="$1"
  local context="$2"
  local path
  local -a matches=()
  [[ -z "${NVPN_MOBILE_IOS_RELEASE_XCTESTRUN:-}" ]] || {
    echo "$context refuses an external iOS xctestrun override" >&2
    return 1
  }
  [[ -d "$products_root" ]] || {
    echo "$context iOS test-products directory is missing" >&2
    return 1
  }
  while IFS= read -r path; do
    [[ -n "$path" ]] && matches+=("$path")
  done < <(
    find "$products_root" \
      -maxdepth 1 -type f -name 'NostrVpnIos_*.xctestrun' \
      | sort
  )
  [[ "${#matches[@]}" -eq 1 ]] || {
    echo "$context requires one generated iOS xctestrun; found ${#matches[@]}" >&2
    return 1
  }
  printf '%s\n' "${matches[0]}"
}

git_commit_timestamp_utc() {
  local root="$1"
  local epoch
  epoch="$(git -C "$root" log -1 --format=%ct HEAD 2>/dev/null || printf '%s' "")"
  if [[ -n "$epoch" ]]; then
    epoch_to_iso8601 "$epoch"
  else
    printf '%s\n' ""
  fi
}

git_commit_epoch() {
  local root="$1"
  git -C "$root" log -1 --format=%ct HEAD 2>/dev/null || printf '%s\n' ""
}

release_file_sha256() {
  shasum -a 256 "$1" | awk '{print tolower($1)}'
}

require_exact_release_fips_revision() {
  local observed="$1"
  local expected="${NVPN_EXPECTED_FIPS_GIT_SHA:-}"
  [[ "$expected" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Release gate requires an exact lowercase NVPN_EXPECTED_FIPS_GIT_SHA" >&2
    return 1
  }
  [[ "$observed" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Release gate could not resolve an exact local FIPS revision" >&2
    return 1
  }
  [[ "$observed" == "$expected" ]] || {
    echo "Release gate local FIPS revision does not match NVPN_EXPECTED_FIPS_GIT_SHA" >&2
    return 1
  }
}

assert_release_checkout_state() {
  local root="$1" expected_head="$2" expected_tree="$3" label="$4"
  local status manifest_sha lock_sha unexpected
  if [[ "$(git -C "$root" rev-parse HEAD)" != "$expected_head" \
    || "$(git -C "$root" rev-parse 'HEAD^{tree}')" != "$expected_tree" ]]
  then
    echo "$label source revision/tree changed" >&2
    return 1
  fi

  status="$(git -C "$root" status --porcelain --untracked-files=all)"
  if [[ -z "${NVPN_LOCAL_FIPS_SESSION_CARGO_LOCK_SHA256:-}" ]]; then
    [[ -z "$status" ]] || {
      echo "$label source checkout is dirty" >&2
      return 1
    }
    return 0
  fi

  manifest_sha="$(release_file_sha256 "$root/Cargo.toml")"
  lock_sha="$(release_file_sha256 "$root/Cargo.lock")"
  [[ "$manifest_sha" == "${NVPN_LOCAL_FIPS_SESSION_CARGO_TOML_SHA256:-}" ]] || {
    echo "$label Cargo.toml differs from the release-gate session" >&2
    return 1
  }
  [[ "$lock_sha" == "$NVPN_LOCAL_FIPS_SESSION_CARGO_LOCK_SHA256" ]] || {
    echo "$label Cargo.lock differs from the release-gate session" >&2
    return 1
  }
  unexpected="$(
    printf '%s\n' "$status" \
      | awk 'NF && $0 != " M Cargo.lock" { print }'
  )"
  [[ -z "$unexpected" ]] || {
    echo "$label source checkout has unrelated changes:" >&2
    printf '%s\n' "$unexpected" >&2
    return 1
  }
}

resolve_source_date_epoch() {
  local root="$1"
  local epoch="${SOURCE_DATE_EPOCH:-}"

  if [[ -z "$epoch" ]]; then
    epoch="$(git_commit_epoch "$root")"
  fi

  if [[ -z "$epoch" ]]; then
    epoch=0
  fi

  if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
    echo "SOURCE_DATE_EPOCH must be a Unix timestamp, got: $epoch" >&2
    return 1
  fi

  printf '%s\n' "$epoch"
}

enable_deterministic_build_env() {
  local root="$1"
  local epoch

  epoch="$(resolve_source_date_epoch "$root")"
  export SOURCE_DATE_EPOCH="$epoch"

  # Cargo incremental artifacts are cache- and path-sensitive. Keep release
  # outputs from depending on whatever happened to be in the local target dir.
  export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"

  # Apple archive tooling honors ZERO_AR_DATE by zeroing static-library member
  # timestamps, which keeps Rust staticlibs stable across rebuilds.
  export ZERO_AR_DATE="${ZERO_AR_DATE:-1}"

  # Keep locale/timezone-sensitive helper output stable when scripts package
  # release assets or derive build metadata.
  export LC_ALL="${LC_ALL:-C}"
  export TZ="${TZ:-UTC}"
}

package_version() {
  local root="$1"

  awk '
    /^\[workspace.package\]/ { inside = 1; next }
    /^\[/ { inside = 0 }
    inside && $1 == "version" {
      gsub(/"/, "", $3)
      print $3
      exit
    }
  ' "$root/Cargo.toml"
}

semantic_version_code() {
  local version="$1"
  local core major minor patch

  core="${version%%[-+]*}"
  if [[ ! "$core" =~ ^([0-9]+)(\.([0-9]+))?(\.([0-9]+))?$ ]]; then
    return 1
  fi

  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[3]:-0}"
  patch="${BASH_REMATCH[5]:-0}"

  printf '%d\n' "$((10#$major * 1000000 + 10#$minor * 1000 + 10#$patch))"
}

load_appstoreconnect_defaults() {
  local asc_root="${NVPN_ASC_ROOT:-$HOME/.appstoreconnect}"
  local key_path
  local key_name

  if [[ -z "${NVPN_ASC_AUTH_KEY_PATH:-}" ]]; then
    key_path="$(find "$asc_root/private_keys" -maxdepth 1 -type f -name 'AuthKey_*.p8' 2>/dev/null | sort | head -n 1 || true)"
    if [[ -n "$key_path" ]]; then
      NVPN_ASC_AUTH_KEY_PATH="$key_path"
    fi
  fi

  if [[ -z "${NVPN_ASC_AUTH_KEY_ID:-}" && -n "${NVPN_ASC_AUTH_KEY_PATH:-}" ]]; then
    key_name="$(basename "$NVPN_ASC_AUTH_KEY_PATH")"
    key_name="${key_name#AuthKey_}"
    NVPN_ASC_AUTH_KEY_ID="${key_name%.p8}"
  fi

  if [[ -z "${NVPN_ASC_AUTH_KEY_ISSUER_ID:-}" && -f "$asc_root/issuer.txt" ]]; then
    NVPN_ASC_AUTH_KEY_ISSUER_ID="$(tr -d '[:space:]' < "$asc_root/issuer.txt")"
  fi

  export NVPN_ASC_AUTH_KEY_PATH="${NVPN_ASC_AUTH_KEY_PATH:-}"
  export NVPN_ASC_AUTH_KEY_ID="${NVPN_ASC_AUTH_KEY_ID:-}"
  export NVPN_ASC_AUTH_KEY_ISSUER_ID="${NVPN_ASC_AUTH_KEY_ISSUER_ID:-}"
}

resolve_shared_build_metadata() {
  local root="$1"
  local derived_version_code
  local detected_version

  detected_version="$(package_version "$root" || true)"
  NVPN_APP_VERSION_NAME="${NVPN_APP_VERSION_NAME:-${detected_version:-0.1.0}}"
  derived_version_code="$(semantic_version_code "$NVPN_APP_VERSION_NAME" || true)"
  if [[ -z "${NVPN_APP_VERSION_CODE:-}" ]]; then
    NVPN_APP_VERSION_CODE="${derived_version_code:-1}"
  elif [[ -n "${derived_version_code:-}" && "$NVPN_APP_VERSION_CODE" != "$derived_version_code" ]] && ! bool_is_true "${NVPN_APP_VERSION_CODE_MANUAL:-false}"; then
    echo "Using derived version code $derived_version_code for $NVPN_APP_VERSION_NAME (was $NVPN_APP_VERSION_CODE)." >&2
    NVPN_APP_VERSION_CODE="$derived_version_code"
  fi
  NVPN_BUILD_GIT_SHA="${NVPN_BUILD_GIT_SHA:-$(git_short_sha "$root")}"

  if [[ -z "${NVPN_BUILD_TIMESTAMP_UTC:-}" ]]; then
    if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
      NVPN_BUILD_TIMESTAMP_UTC="$(epoch_to_iso8601 "$SOURCE_DATE_EPOCH")"
    else
      NVPN_BUILD_TIMESTAMP_UTC="$(git_commit_timestamp_utc "$root")"
    fi
  fi

  if [[ -z "${NVPN_BUILD_TIMESTAMP_UTC:-}" ]]; then
    NVPN_BUILD_TIMESTAMP_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  fi

  export NVPN_APP_VERSION_NAME
  export NVPN_APP_VERSION_CODE
  export NVPN_BUILD_GIT_SHA
  export NVPN_BUILD_TIMESTAMP_UTC
}

resolve_ios_build_metadata() {
  local root="$1"
  local build_number_file="$root/ios/app-store-build-number"
  local build_number="${NVPN_IOS_BUILD_NUMBER:-}"

  resolve_shared_build_metadata "$root"

  if [[ -z "$build_number" ]]; then
    if [[ ! -f "$build_number_file" ]]; then
      echo "Tracked iOS build number is missing: $build_number_file" >&2
      return 1
    fi
    build_number="$(tr -d '[:space:]' < "$build_number_file")"
  fi

  if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "iOS build number must be a positive integer, got: ${build_number:-<empty>}" >&2
    return 1
  fi

  # App Store Connect identifies an upload by marketing version plus build
  # number. Keep the Cargo/workspace marketing version stable while a tracked
  # iOS build number advances for corrected uploads of that same version.
  NVPN_APP_VERSION_CODE="$build_number"
  NVPN_IOS_BUILD_NUMBER="$build_number"
  NVPN_IOS_RELEASE_TAG="v${NVPN_APP_VERSION_NAME}+${build_number}"

  export NVPN_APP_VERSION_CODE
  export NVPN_IOS_BUILD_NUMBER
  export NVPN_IOS_RELEASE_TAG
}

release_slug() {
  local channel="$1"
  printf 'NostrVPN-%s-%s+%s-%s' \
    "$channel" \
    "$NVPN_APP_VERSION_NAME" \
    "$NVPN_APP_VERSION_CODE" \
    "$NVPN_BUILD_GIT_SHA"
}

ensure_dir() {
  mkdir -p "$1"
}

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "$name must be set" >&2
    return 1
  fi
}

write_manifest() {
  local path="$1"
  shift

  : > "$path"
  while [[ $# -gt 1 ]]; do
    printf '%s=%s\n' "$1" "$2" >> "$path"
    shift 2
  done
}
