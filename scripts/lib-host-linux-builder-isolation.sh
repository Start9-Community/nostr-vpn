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

host_linux_builder_target_volume_matches() {
  local volume_name="$1"
  local expected_cache_id="$2"
  local expected_generation="$3"
  local role cache_id generation driver mountpoint
  role="$(
    docker volume inspect \
      --format '{{ index .Labels "to.nostrvpn.release-builder" }}' \
      "$volume_name"
  )" || return
  cache_id="$(
    docker volume inspect \
      --format '{{ index .Labels "to.nostrvpn.release-builder-cache" }}' \
      "$volume_name"
  )" || return
  generation="$(
    docker volume inspect \
      --format '{{ index .Labels "to.nostrvpn.release-builder-generation" }}' \
      "$volume_name"
  )" || return
  driver="$(docker volume inspect --format '{{ .Driver }}' "$volume_name")" \
    || return
  mountpoint="$(
    docker volume inspect --format '{{ .Mountpoint }}' "$volume_name"
  )" || return
  [[ "$role" == "host-linux-vm-bundle-target" \
    && "$cache_id" == "$expected_cache_id" \
    && "$generation" == "$expected_generation" \
    && "$driver" == "local" \
    && "$mountpoint" == /* ]]
}

host_linux_builder_ensure_target_volume() {
  local volume_name="$1"
  local expected_cache_id="$2"
  local expected_generation="$3"
  if ! docker volume inspect "$volume_name" >/dev/null 2>&1; then
    docker volume create \
      --label "to.nostrvpn.release-builder=host-linux-vm-bundle-target" \
      --label "to.nostrvpn.release-builder-cache=$expected_cache_id" \
      --label "to.nostrvpn.release-builder-generation=$expected_generation" \
      "$volume_name" >/dev/null
  fi
  if ! host_linux_builder_target_volume_matches \
    "$volume_name" "$expected_cache_id" "$expected_generation"
  then
    echo "Refusing mismatched Linux builder target volume: $volume_name" >&2
    return 1
  fi
}
