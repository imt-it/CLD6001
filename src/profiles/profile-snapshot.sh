#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/environment-states.sh"

STATE=""
RUNTIME=""
OUTPUT_DIR=""

usage() {
    cat <<'EOF'
Usage: bash src/profiles/profile-snapshot.sh --state <environment-state> --runtime <runtime> --output-dir <dir>
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --state)
            STATE="${2:-}"
            shift 2
            ;;
        --runtime)
            RUNTIME="${2:-}"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:-}"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

[ -n "$STATE" ] || { printf 'Missing --state\n' >&2; exit 1; }
[ -n "$RUNTIME" ] || { printf 'Missing --runtime\n' >&2; exit 1; }
[ -n "$OUTPUT_DIR" ] || { printf 'Missing --output-dir\n' >&2; exit 1; }
environment_state_exists "$STATE" || { printf 'Unknown environment state: %s\n' "$STATE" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"

HOST_PROFILE="$(environment_state_host_profile_for "$STATE")"
RUNTIME_PROFILE="$(environment_state_runtime_profile_for "$STATE")"

jq -n \
    --arg state "$STATE" \
    --arg host_profile "$HOST_PROFILE" \
    --arg runtime_profile "$RUNTIME_PROFILE" \
    --arg runtime "$RUNTIME" \
    --arg timestamp "$(date -Iseconds)" \
    '{
        environment_state: $state,
        host_profile: $host_profile,
        runtime_profile: $runtime_profile,
        runtime: $runtime,
        timestamp: $timestamp
    }' > "$OUTPUT_DIR/profile-snapshot.json"

if [ -f /etc/docker/daemon.json ]; then
    cp /etc/docker/daemon.json "$OUTPUT_DIR/docker-daemon.json" 2>/dev/null || true
else
    printf '{}\n' > "$OUTPUT_DIR/docker-daemon.json"
fi

if command -v docker >/dev/null 2>&1; then
    docker info --format '{{json .}}' > "$OUTPUT_DIR/docker-info.json" 2>/dev/null || true
fi

if command -v podman >/dev/null 2>&1; then
    podman info --format json > "$OUTPUT_DIR/podman-info.json" 2>/dev/null || true
else
    printf '{}\n' > "$OUTPUT_DIR/podman-info.json"
fi

if command -v sestatus >/dev/null 2>&1; then
    sestatus > "$OUTPUT_DIR/selinux-status.txt" 2>/dev/null || true
elif command -v getenforce >/dev/null 2>&1; then
    getenforce > "$OUTPUT_DIR/selinux-status.txt" 2>/dev/null || true
else
    printf 'SELinux tooling unavailable\n' > "$OUTPUT_DIR/selinux-status.txt"
fi

{
    sysctl kernel.dmesg_restrict 2>/dev/null || true
    sysctl kernel.kptr_restrict 2>/dev/null || true
    sysctl kernel.yama.ptrace_scope 2>/dev/null || true
    sysctl net.ipv4.conf.all.accept_redirects 2>/dev/null || true
    sysctl net.ipv4.conf.default.accept_redirects 2>/dev/null || true
    sysctl net.ipv4.conf.all.send_redirects 2>/dev/null || true
    sysctl net.ipv4.conf.default.send_redirects 2>/dev/null || true
} > "$OUTPUT_DIR/sysctl-container-hardening.txt"

printf 'Profile snapshot written to %s\n' "$OUTPUT_DIR"
