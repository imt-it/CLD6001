#!/bin/bash

if [ -n "${CLD6001_TC02_NAMESPACE_HELPERS_LOADED:-}" ]; then
    return 0
fi
readonly CLD6001_TC02_NAMESPACE_HELPERS_LOADED=1

tc02_cleanup_host_pid_helper() {
    local helper_pid="${1:-}"

    if [ -n "$helper_pid" ]; then
        kill "$helper_pid" 2>/dev/null || true
        wait "$helper_pid" 2>/dev/null || true
    fi
}

tc02_start_host_pid_helper() {
    local output_var="${1:?output variable required}"
    local helper_pid=""

    (sleep 600) &
    helper_pid=$!

    if ! kill -0 "$helper_pid" 2>/dev/null; then
        return 1
    fi

    printf -v "$output_var" '%s' "$helper_pid"
}

tc02_cleanup_host_loopback_helper() {
    local helper_pid="${1:-}"

    if [ -n "$helper_pid" ]; then
        kill "$helper_pid" 2>/dev/null || true
        wait "$helper_pid" 2>/dev/null || true
    fi
}

tc02_fetch_host_loopback_token() {
    local port="${1:?port required}"

    python3 - "$port" <<'PY'
import socket
import sys

port = int(sys.argv[1])
with socket.create_connection(("127.0.0.1", port), 1) as client:
    data = client.recv(4096)
sys.stdout.buffer.write(data)
PY
}

tc02_start_host_loopback_helper() {
    local pid_var="${1:?pid variable required}"
    local port_var="${2:?port variable required}"
    local token_var="${3:?token variable required}"
    local seed="${4:?seed required}"
    local attempt=""
    local helper_pid=""
    local port=""
    local token=""
    local response=""

    for attempt in $(seq 1 10); do
        port="$((35000 + ((seed + (attempt * 137)) % 20000)))"
        token="tc02-loopback-${seed}-${attempt}"

        python3 - "$port" "$token" <<'PY' &
import socket
import sys

port = int(sys.argv[1])
token = sys.argv[2].encode()
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port))
server.listen(5)

while True:
    client, _ = server.accept()
    with client:
        client.sendall(token)
PY
        helper_pid=$!

        if wait_for_local_tcp_listener_ready "$helper_pid" "$port"; then
            response="$(tc02_fetch_host_loopback_token "$port" 2>/dev/null || true)"
        else
            response=""
        fi

        if [ "$response" = "$token" ]; then
            printf -v "$pid_var" '%s' "$helper_pid"
            printf -v "$port_var" '%s' "$port"
            printf -v "$token_var" '%s' "$token"
            return 0
        fi

        tc02_cleanup_host_loopback_helper "$helper_pid"
    done

    return 1
}
