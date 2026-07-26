#!/usr/bin/env bash

MOBILE_WG_FIXTURE_REMOTE=0
MOBILE_WG_FIXTURE_REMOTE_MODE=""
MOBILE_WG_FIXTURE_REMOTE_DIR=""
MOBILE_WG_FIXTURE_REMOTE_IMAGE_BUILT=0
MOBILE_WG_FIXTURE_VOLUME_DIR=""
MOBILE_WG_FIXTURE_REMOTE_INTERFACE=""
MOBILE_WG_FIXTURE_REMOTE_NFT_TABLE=""
MOBILE_WG_FIXTURE_STARTED=0
MOBILE_WG_FIXTURE_REMOTE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
MOBILE_WG_FIXTURE_SSH_CONTROL_PATH="/tmp/nvpn-wg-fixture-$PPID-$$"

mobile_wg_fixture_validate_ssh_host() {
  local host="$1"
  if [[ -z "$host" || "$host" == -* || "$host" =~ [[:space:]] ]]; then
    echo "remote mobile WireGuard fixture SSH host is invalid" >&2
    return 1
  fi
}

mobile_wg_remote_exec() {
  local host="${NVPN_MOBILE_WG_EXIT_FIXTURE_SSH_HOST:-}"
  local command="" quoted argument
  mobile_wg_fixture_validate_ssh_host "$host" || return 1
  for argument in "$@"; do
    printf -v quoted '%q' "$argument"
    command+="$quoted "
  done
  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o ConnectionAttempts=1 \
    -o ServerAliveInterval=3 \
    -o ServerAliveCountMax=2 \
    -o ControlMaster=auto \
    -o ControlPersist=60 \
    -o "ControlPath=$MOBILE_WG_FIXTURE_SSH_CONTROL_PATH" \
    "$host" "$command"
}

mobile_wg_remote_close_control() {
  local host="${NVPN_MOBILE_WG_EXIT_FIXTURE_SSH_HOST:-}"
  [[ -n "$host" ]] || return 0
  ssh \
    -o "ControlPath=$MOBILE_WG_FIXTURE_SSH_CONTROL_PATH" \
    -O exit "$host" >/dev/null 2>&1 || true
}

mobile_wg_remote_has_command() {
  mobile_wg_remote_exec \
    env "PATH=$MOBILE_WG_FIXTURE_REMOTE_PATH" \
    sh -c 'command -v "$1" >/dev/null 2>&1' sh "$1"
}

mobile_wg_remote_docker() {
  if bool_is_true "${NVPN_MOBILE_WG_EXIT_REMOTE_DOCKER_SUDO:-0}"; then
    mobile_wg_remote_exec sudo -n docker "$@"
  else
    mobile_wg_remote_exec docker "$@"
  fi
}

mobile_wg_fixture_docker() {
  if [[ "$MOBILE_WG_FIXTURE_REMOTE" -eq 1 ]]; then
    if [[ "$MOBILE_WG_FIXTURE_REMOTE_MODE" != "docker" ]]; then
      echo "remote native fixture cannot execute an arbitrary Docker command" >&2
      return 2
    fi
    mobile_wg_remote_docker "$@"
  else
    docker "$@"
  fi
}

mobile_wg_fixture_initialize() {
  local root="$1" local_fixture_dir="$2"
  local remote_host="${NVPN_MOBILE_WG_EXIT_FIXTURE_SSH_HOST:-}"
  if [[ -z "$remote_host" ]]; then
    command -v docker >/dev/null 2>&1 || {
      echo "local mobile WireGuard fixture requires docker" >&2
      return 1
    }
    MOBILE_WG_FIXTURE_VOLUME_DIR="$local_fixture_dir"
    return 0
  fi

  MOBILE_WG_FIXTURE_REMOTE=1
  MOBILE_WG_FIXTURE_REMOTE_MODE="${NVPN_MOBILE_WG_EXIT_REMOTE_MODE:-native}"
  mobile_wg_fixture_validate_ssh_host "$remote_host" || return 1
  : "${NVPN_MOBILE_WG_EXIT_HOST_IP:?remote fixture requires its reachable public address}"
  command -v ssh >/dev/null 2>&1 \
    && command -v scp >/dev/null 2>&1 \
    || {
      echo "remote mobile WireGuard fixture requires ssh and scp" >&2
      return 1
    }
  case "$MOBILE_WG_FIXTURE_REMOTE_MODE" in
    native)
      if [[ "$(mobile_wg_remote_exec uname -s)" != "Linux" ]]; then
        echo "remote native mobile WireGuard fixture requires Linux" >&2
        return 1
      fi
      if ! mobile_wg_remote_exec sudo -n true >/dev/null; then
        echo "remote native mobile WireGuard fixture requires passwordless sudo" >&2
        return 1
      fi
      local missing_packages=()
      mobile_wg_remote_has_command wg \
        || missing_packages+=(wireguard-tools)
      mobile_wg_remote_has_command dnsmasq \
        || missing_packages+=(dnsmasq-base)
      mobile_wg_remote_has_command nft \
        || missing_packages+=(nftables)
      if ((${#missing_packages[@]} > 0)); then
        if ! bool_is_true "${NVPN_MOBILE_WG_EXIT_REMOTE_INSTALL_PACKAGES:-1}"; then
          echo "remote native fixture is missing required packages: ${missing_packages[*]}" >&2
          return 1
        fi
        mobile_wg_remote_exec \
          sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update -qq
        mobile_wg_remote_exec \
          sudo -n env DEBIAN_FRONTEND=noninteractive \
          apt-get install -y -qq "${missing_packages[@]}"
      fi
      ;;
    docker)
      mobile_wg_remote_exec command -v docker >/dev/null \
        || {
          echo "remote mobile WireGuard fixture host has no docker" >&2
          return 1
        }
      mobile_wg_remote_docker info >/dev/null \
        || {
          echo "remote mobile WireGuard fixture cannot access Docker" >&2
          return 1
        }
      ;;
    *)
      echo "NVPN_MOBILE_WG_EXIT_REMOTE_MODE must be native or docker" >&2
      return 2
      ;;
  esac
  MOBILE_WG_FIXTURE_REMOTE_DIR="$(
    mobile_wg_remote_exec mktemp -d /tmp/nvpn-mobile-wg-exit.XXXXXX
  )"
  case "$MOBILE_WG_FIXTURE_REMOTE_DIR" in
    /tmp/nvpn-mobile-wg-exit.*) ;;
    *)
      echo "remote mobile WireGuard fixture returned an unsafe temp path" >&2
      MOBILE_WG_FIXTURE_REMOTE_DIR=""
      return 1
      ;;
  esac
  mobile_wg_remote_exec \
    mkdir -p \
    "$MOBILE_WG_FIXTURE_REMOTE_DIR/scripts" \
    "$MOBILE_WG_FIXTURE_REMOTE_DIR/fixture"
  scp -q \
    "$root/Dockerfile.mobile-wireguard-exit-e2e" \
    "$remote_host:$MOBILE_WG_FIXTURE_REMOTE_DIR/" \
    || return 1
  scp -q \
    "$root/scripts/mobile-wireguard-exit-server.sh" \
    "$remote_host:$MOBILE_WG_FIXTURE_REMOTE_DIR/scripts/" \
    || return 1
  if [[ "$MOBILE_WG_FIXTURE_REMOTE_MODE" == "native" ]]; then
    scp -q \
      "$root/scripts/mobile-wireguard-exit-remote-native.sh" \
      "$root/scripts/mobile-wireguard-udp-echo.py" \
      "$root/scripts/mobile-wireguard-http-probe.py" \
      "$remote_host:$MOBILE_WG_FIXTURE_REMOTE_DIR/" \
      || return 1
    MOBILE_WG_FIXTURE_REMOTE_INTERFACE="nwg$HOST_PORT"
    MOBILE_WG_FIXTURE_REMOTE_NFT_TABLE="nvpnwg$HOST_PORT"
    mobile_wg_remote_exec \
      chmod 700 \
      "$MOBILE_WG_FIXTURE_REMOTE_DIR/mobile-wireguard-exit-remote-native.sh"
  fi
  scp -q \
    "$local_fixture_dir/server.key" \
    "$local_fixture_dir/server.pub" \
    "$local_fixture_dir/client.key" \
    "$local_fixture_dir/client.pub" \
    "$remote_host:$MOBILE_WG_FIXTURE_REMOTE_DIR/fixture/" \
    || return 1
  mobile_wg_remote_exec chmod 700 "$MOBILE_WG_FIXTURE_REMOTE_DIR/fixture"
  mobile_wg_remote_exec \
    chmod 600 \
    "$MOBILE_WG_FIXTURE_REMOTE_DIR/fixture/server.key" \
    "$MOBILE_WG_FIXTURE_REMOTE_DIR/fixture/client.key"
  MOBILE_WG_FIXTURE_VOLUME_DIR="$MOBILE_WG_FIXTURE_REMOTE_DIR/fixture"
}

mobile_wg_fixture_assert_available() {
  local container="$1" host_port="$2"
  if [[ "$MOBILE_WG_FIXTURE_REMOTE_MODE" != "native" ]] \
    && mobile_wg_fixture_docker container inspect "$container" >/dev/null 2>&1
  then
    echo "mobile WireGuard fixture container name is already in use: $container" >&2
    return 1
  fi
  if [[ "$MOBILE_WG_FIXTURE_REMOTE_MODE" == "native" ]]; then
    if mobile_wg_remote_exec \
        sudo -n ip link show "$MOBILE_WG_FIXTURE_REMOTE_INTERFACE" \
        >/dev/null 2>&1 \
      || mobile_wg_remote_exec \
        sudo -n nft list table inet "$MOBILE_WG_FIXTURE_REMOTE_NFT_TABLE" \
        >/dev/null 2>&1
    then
      echo "remote fixture interface or nft table is already in use" >&2
      return 1
    fi
  fi
  local listeners
  if [[ "$MOBILE_WG_FIXTURE_REMOTE" -eq 1 ]]; then
    listeners="$(mobile_wg_remote_exec ss -H -lun 2>/dev/null)" || {
      echo "remote fixture could not inspect UDP listeners before mutation" >&2
      return 1
    }
  elif command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iUDP:"$host_port" 2>/dev/null | grep -q .; then
      echo "mobile WireGuard fixture UDP port is already occupied: $host_port" >&2
      return 1
    fi
    return 0
  else
    listeners="$(netstat -an -p udp 2>/dev/null || true)"
  fi
  if python3 - "$host_port" "$listeners" <<'PY'
import re
import sys

port, listeners = sys.argv[1:]
for line in listeners.splitlines():
    if any(
        re.search(rf"[\].:]{re.escape(port)}$", field)
        for field in line.split()
    ):
        raise SystemExit(0)
raise SystemExit(1)
PY
  then
    echo "mobile WireGuard fixture UDP port is already occupied: $host_port" >&2
    return 1
  fi
}

mobile_wg_fixture_build() {
  local root="$1" image="$2" image_ready="$3"
  if [[ "$MOBILE_WG_FIXTURE_REMOTE_MODE" == "native" ]]; then
    return 0
  elif [[ "$MOBILE_WG_FIXTURE_REMOTE" -eq 1 ]]; then
    if mobile_wg_fixture_docker image inspect "$image" >/dev/null 2>&1; then
      echo "remote fixture image tag is already in use: $image" >&2
      return 1
    fi
    mobile_wg_fixture_docker build -q \
      -f "$MOBILE_WG_FIXTURE_REMOTE_DIR/Dockerfile.mobile-wireguard-exit-e2e" \
      -t "$image" \
      "$MOBILE_WG_FIXTURE_REMOTE_DIR" >/dev/null
    MOBILE_WG_FIXTURE_REMOTE_IMAGE_BUILT=1
  elif ! bool_is_true "$image_ready"; then
    docker build -q \
      -f "$root/Dockerfile.mobile-wireguard-exit-e2e" \
      -t "$image" \
      "$root" >/dev/null
  fi
}

mobile_wg_remote_native() {
  mobile_wg_remote_exec \
    sudo -n env \
    "PATH=$MOBILE_WG_FIXTURE_REMOTE_PATH" \
    "NVPN_MOBILE_WG_REMOTE_STATE_DIR=$MOBILE_WG_FIXTURE_REMOTE_DIR/fixture" \
    "NVPN_MOBILE_WG_REMOTE_INTERFACE=$MOBILE_WG_FIXTURE_REMOTE_INTERFACE" \
    "NVPN_MOBILE_WG_REMOTE_NFT_TABLE=$MOBILE_WG_FIXTURE_REMOTE_NFT_TABLE" \
    "NVPN_MOBILE_WG_SERVER_PRIVATE_KEY_FILE=$MOBILE_WG_FIXTURE_REMOTE_DIR/fixture/server.key" \
    "NVPN_MOBILE_WG_CLIENT_PUBLIC_KEY_FILE=$MOBILE_WG_FIXTURE_REMOTE_DIR/fixture/client.pub" \
    "NVPN_MOBILE_WG_TUNNEL_CIDR=$TUNNEL_SERVER_IP/24" \
    "NVPN_MOBILE_WG_CLIENT_IP=$TUNNEL_CLIENT_IP" \
    "NVPN_MOBILE_WG_LISTEN_PORT=$HOST_PORT" \
    "NVPN_MOBILE_WG_DNS_NAME=$DNS_NAME" \
    "NVPN_MOBILE_WG_HTTP_PROBE_PORT=$HTTP_PROBE_PORT" \
    "NVPN_MOBILE_WG_HTTP_TOKEN=$HTTP_PROBE_TOKEN" \
    "$MOBILE_WG_FIXTURE_REMOTE_DIR/mobile-wireguard-exit-remote-native.sh" \
    "$@"
}

mobile_wg_fixture_run() {
  local image="$1" container="$2" volume_dir="$3"
  MOBILE_WG_FIXTURE_STARTED=1
  if [[ "$MOBILE_WG_FIXTURE_REMOTE_MODE" == "native" ]]; then
    mobile_wg_remote_native start
    return
  fi
  mobile_wg_fixture_docker run -d \
    --name "$container" \
    --cap-add NET_ADMIN \
    --device /dev/net/tun \
    --sysctl net.ipv4.ip_forward=1 \
    -p "$HOST_PORT:51820/udp" \
    -v "$volume_dir:/fixture" \
    -e "NVPN_MOBILE_WG_TUNNEL_CIDR=$TUNNEL_SERVER_IP/24" \
    -e "NVPN_MOBILE_WG_CLIENT_IP=$TUNNEL_CLIENT_IP" \
    -e "NVPN_MOBILE_WG_DNS_NAME=$DNS_NAME" \
    -e "NVPN_MOBILE_WG_HTTP_PROBE_PORT=$HTTP_PROBE_PORT" \
    -e "NVPN_MOBILE_WG_HTTP_TOKEN=$HTTP_PROBE_TOKEN" \
    "$image" >/dev/null
}

mobile_wg_fixture_ready() {
  local container="$1"
  if [[ "$MOBILE_WG_FIXTURE_REMOTE_MODE" == "native" ]]; then
    mobile_wg_remote_native ready
  else
    mobile_wg_fixture_docker exec "$container" test -f /fixture/ready
  fi
}

mobile_wg_fixture_running() {
  local container="$1"
  if [[ "$MOBILE_WG_FIXTURE_REMOTE_MODE" == "native" ]]; then
    mobile_wg_remote_native ready
  else
    [[ "$(mobile_wg_fixture_docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" == "true" ]]
  fi
}

mobile_wg_fixture_logs() {
  local container="$1"
  if [[ "$MOBILE_WG_FIXTURE_REMOTE_MODE" == "native" ]]; then
    mobile_wg_remote_exec \
      tail -n 100 \
      "$MOBILE_WG_FIXTURE_REMOTE_DIR/fixture/dns.log" \
      "$MOBILE_WG_FIXTURE_REMOTE_DIR/fixture/udp-echo.log" \
      2>/dev/null || true
  else
    mobile_wg_fixture_docker logs "$container"
  fi
}

mobile_wg_fixture_wg_bytes() {
  local container="$1"
  if [[ "$MOBILE_WG_FIXTURE_REMOTE_MODE" == "native" ]]; then
    mobile_wg_remote_native wg-bytes
  else
    mobile_wg_fixture_docker exec "$container" wg show wg0 transfer \
      | awk '{ rx += $2; tx += $3 } END { printf "%d\t%d\n", rx, tx }'
  fi
}

mobile_wg_fixture_forward_packets() {
  local container="$1"
  if [[ "$MOBILE_WG_FIXTURE_REMOTE_MODE" == "native" ]]; then
    mobile_wg_remote_native forward-packets
  else
    mobile_wg_fixture_docker exec "$container" \
      iptables -L nvpn-mobile-wg-forward -v -n -x \
      | awk '$3 == "ACCEPT" && ($7 == "wg0" || $8 == "wg0") { packets += $1 } END { print packets + 0 }'
  fi
}

mobile_wg_fixture_dns_count() {
  local container="$1" name="$2"
  if [[ "$MOBILE_WG_FIXTURE_REMOTE_MODE" == "native" ]]; then
    mobile_wg_remote_native dns-count "$name"
  else
    mobile_wg_fixture_docker exec "$container" \
      sh -c 'grep -Fci "$1" /fixture/dns.log 2>/dev/null || true' sh "$name"
  fi
}

mobile_wg_fixture_doh_count() {
  local container="$1" provider="$2"
  if [[ "$MOBILE_WG_FIXTURE_REMOTE_MODE" == "native" ]]; then
    mobile_wg_remote_native doh-count "$provider"
    return
  fi
  local chain
  case "$provider" in
    cloudflare) chain="nvpn-wg-doh-cf" ;;
    quad9) chain="nvpn-wg-doh-q9" ;;
    *) echo "unknown DoH counter provider: $provider" >&2; return 2 ;;
  esac
  mobile_wg_fixture_docker exec "$container" iptables -L "$chain" -v -n -x \
    | awk '$3 == "ACCEPT" { packets += $1 } END { print packets + 0 }'
}

mobile_wg_fixture_cleanup() {
  local container="$1" image="$2"
  local cleanup_failed=0 inspect_status=0 remote_dir=""
  if [[ "$MOBILE_WG_FIXTURE_STARTED" -eq 1 ]]; then
    if [[ "$MOBILE_WG_FIXTURE_REMOTE_MODE" == "native" ]]; then
      mobile_wg_remote_native stop >/dev/null 2>&1 || true
      if ! mobile_wg_remote_exec \
        sudo -n sh -c \
        '! ip link show "$1" >/dev/null 2>&1 && ! nft list table inet "$2" >/dev/null 2>&1' \
        sh "$MOBILE_WG_FIXTURE_REMOTE_INTERFACE" \
        "$MOBILE_WG_FIXTURE_REMOTE_NFT_TABLE" >/dev/null 2>&1
      then
        echo "remote native WireGuard interface or nft table survived cleanup" >&2
        cleanup_failed=1
      else
        MOBILE_WG_FIXTURE_STARTED=0
      fi
    else
      mobile_wg_fixture_docker rm -f "$container" >/dev/null 2>&1 || true
      if mobile_wg_fixture_docker container inspect "$container" \
        >/dev/null 2>&1
      then
        inspect_status=0
      else
        inspect_status=$?
      fi
      if [[ "$inspect_status" -eq 1 ]]; then
        MOBILE_WG_FIXTURE_STARTED=0
      else
        echo "WireGuard fixture container survived cleanup or could not be verified" >&2
        cleanup_failed=1
      fi
    fi
  fi
  if [[ "$MOBILE_WG_FIXTURE_REMOTE_IMAGE_BUILT" -eq 1 ]]; then
    mobile_wg_fixture_docker image rm "$image" >/dev/null 2>&1 || true
    if mobile_wg_fixture_docker image inspect "$image" >/dev/null 2>&1; then
      inspect_status=0
    else
      inspect_status=$?
    fi
    if [[ "$inspect_status" -eq 1 ]]; then
      MOBILE_WG_FIXTURE_REMOTE_IMAGE_BUILT=0
    else
      echo "remote WireGuard fixture image survived cleanup or could not be verified" >&2
      cleanup_failed=1
    fi
  fi
  if [[ -n "$MOBILE_WG_FIXTURE_REMOTE_DIR" ]]; then
    remote_dir="$MOBILE_WG_FIXTURE_REMOTE_DIR"
    mobile_wg_remote_exec sudo -n rm -f \
      "$remote_dir/fixture/server.key" \
      "$remote_dir/fixture/client.key" >/dev/null 2>&1 || true
    if ! mobile_wg_remote_exec test ! -e \
      "$remote_dir/fixture/server.key" >/dev/null 2>&1
    then
      echo "remote WireGuard fixture private keys survived cleanup" >&2
      cleanup_failed=1
    fi
    if ! mobile_wg_remote_exec test ! -e \
      "$remote_dir/fixture/client.key" >/dev/null 2>&1
    then
      echo "remote WireGuard fixture private keys survived cleanup" >&2
      cleanup_failed=1
    fi
    if [[ "$MOBILE_WG_FIXTURE_STARTED" -eq 0 ]]; then
      mobile_wg_remote_exec \
        sudo -n find "$remote_dir" \
        -xdev -depth -mindepth 1 -delete \
        >/dev/null 2>&1 || true
      mobile_wg_remote_exec sudo -n rmdir "$remote_dir" \
        >/dev/null 2>&1 || true
      if mobile_wg_remote_exec test ! -e "$remote_dir" >/dev/null 2>&1; then
        MOBILE_WG_FIXTURE_REMOTE_DIR=""
      else
        echo "remote WireGuard fixture directory survived cleanup or could not be verified" >&2
        cleanup_failed=1
      fi
    else
      cleanup_failed=1
    fi
  fi
  mobile_wg_remote_close_control
  return "$cleanup_failed"
}
