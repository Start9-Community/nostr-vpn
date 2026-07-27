#!/usr/bin/env bash

# Exact cleanup for the daemon-owned container used by the host Linux release
# builder. Callers serialize a cache root before invoking this helper.

host_linux_builder_container_matches() {
  local container_id="$1"
  local expected_cache_id="$2"
  local role cache_id
  role="$(
    docker container inspect \
      --format '{{ index .Config.Labels "to.nostrvpn.release-builder" }}' \
      "$container_id"
  )" || return
  cache_id="$(
    docker container inspect \
      --format '{{ index .Config.Labels "to.nostrvpn.release-builder-cache" }}' \
      "$container_id"
  )" || return
  [[ "$role" == "host-linux-vm-bundle" \
    && "$cache_id" == "$expected_cache_id" ]]
}

host_linux_builder_stop_container() {
  local container_name="$1"
  local expected_cache_id="$2"
  local container_id="$container_name"

  [[ -n "$container_id" ]] || return 0
  if ! docker container inspect "$container_id" >/dev/null 2>&1; then
    return 0
  fi
  if ! host_linux_builder_container_matches \
    "$container_id" "$expected_cache_id"
  then
    echo "Refusing to remove mismatched Linux builder container: $container_id" >&2
    return 1
  fi
  docker rm --force "$container_id" >/dev/null
  ! docker container inspect "$container_id" >/dev/null 2>&1
}
