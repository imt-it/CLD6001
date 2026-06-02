#!/bin/bash

set -Eeuo pipefail

NETWORK_PROBE_READINESS_ATTEMPTS="${NETWORK_PROBE_READINESS_ATTEMPTS:-25}"
NETWORK_PROBE_READINESS_DELAY_SECONDS="${NETWORK_PROBE_READINESS_DELAY_SECONDS:-0.2}"
NETWORK_PROBE_UNAVAILABLE_EXIT_CODE="${NETWORK_PROBE_UNAVAILABLE_EXIT_CODE:-42}"

listening_socket_probe_script() {
    cat <<'EOF'
if command -v ss >/dev/null 2>&1; then
  ss -tlnp 2>&1
elif command -v netstat >/dev/null 2>&1; then
  netstat -tlnp 2>&1
else
  echo 'No ss or netstat available; recording /proc/net socket tables instead.'
  found_socket_table=0
  for socket_table in /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6; do
    if [ -r "$socket_table" ]; then
      echo "$socket_table"
      cat "$socket_table"
      found_socket_table=1
    fi
  done

  if [ "$found_socket_table" -eq 0 ]; then
    echo 'Cannot capture listening socket state'
  fi
fi
EOF
}

wait_for_command_success() {
    local attempt=1

    while [ "$attempt" -le "$NETWORK_PROBE_READINESS_ATTEMPTS" ]; do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi

        if [ "$attempt" -eq "$NETWORK_PROBE_READINESS_ATTEMPTS" ]; then
            return 1
        fi

        sleep "$NETWORK_PROBE_READINESS_DELAY_SECONDS"
        attempt=$((attempt + 1))
    done
}

wait_for_nonempty_command_output() {
    local output=""
    local attempt=1

    while [ "$attempt" -le "$NETWORK_PROBE_READINESS_ATTEMPTS" ]; do
        output="$("$@" 2>/dev/null || true)"
        if [ -n "$output" ]; then
            printf '%s\n' "$output"
            return 0
        fi

        if [ "$attempt" -eq "$NETWORK_PROBE_READINESS_ATTEMPTS" ]; then
            return 1
        fi

        sleep "$NETWORK_PROBE_READINESS_DELAY_SECONDS"
        attempt=$((attempt + 1))
    done
}

probe_localhost_tcp_port() {
    local port="$1"

    python3 - "$port" <<'PY' >/dev/null 2>&1
import socket
import sys

port = int(sys.argv[1])
socket.create_connection(("127.0.0.1", port), 1).close()
PY
}

wait_for_local_tcp_listener_ready() {
    local pid="$1"
    local port="$2"
    local attempt=1

    while [ "$attempt" -le "$NETWORK_PROBE_READINESS_ATTEMPTS" ]; do
        kill -0 "$pid" 2>/dev/null || return 1
        if probe_localhost_tcp_port "$port"; then
            return 0
        fi

        if [ "$attempt" -eq "$NETWORK_PROBE_READINESS_ATTEMPTS" ]; then
            return 1
        fi

        sleep "$NETWORK_PROBE_READINESS_DELAY_SECONDS"
        attempt=$((attempt + 1))
    done
}

start_host_tcp_helper_process() {
    local output_var="$1"
    local port="$2"

    python3 - "$port" <<'PY' &
import socket
import sys

port = int(sys.argv[1])
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port))
server.listen(5)

while True:
    client, _ = server.accept()
    client.close()
PY
    printf -v "$output_var" '%s' "$!"
}

capture_command_output() {
local output_var="$1"
local status_var="$2"
local output=""
local status=0

shift 2

set +e
output="$("$@" 2>&1)"
status=$?
set -e

printf -v "$output_var" '%s' "$output"
printf -v "$status_var" '%s' "$status"
}

tcp_target_probe_script() {
cat <<'EOF'
if ! command -v nc >/dev/null 2>&1; then
  echo "TC19_UNAVAILABLE:nc_missing"
  exit 42
fi

probe_output="$(nc -w 3 -z "$TARGET_HOST" "$TARGET_PORT" 2>&1)" && {
  echo "TC19_REACHABLE:${TARGET_HOST}:${TARGET_PORT}"
  exit 0
}
probe_status=$?

if [ -n "$probe_output" ]; then
  printf '%s\n' "$probe_output"
fi

case "$probe_output" in
  *"bad address"*|*"Name does not resolve"*|*"No address associated with hostname"*|*"Temporary failure in name resolution"*|*"Try again"*)
echo "TC19_UNAVAILABLE:target_unresolvable:${TARGET_HOST}"
exit 42
;;
esac

echo "TC19_BLOCKED:${TARGET_HOST}:${TARGET_PORT}"
exit "$probe_status"
EOF
}
