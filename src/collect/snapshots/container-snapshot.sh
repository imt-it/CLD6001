#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/snapshot-lib.sh"
set_private_snapshot_umask

REQUESTED_CONTAINER=${1:-}
REQUESTED_RUNTIME="${SNAPSHOT_RUNTIME:-}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-$(snapshot_root_dir)/container}"
TIMESTAMP="$(cld6001_unique_timestamp_id)"
PODMAN_CONTAINER_ID=""
SNAPSHOT_PATH=""

resolve_container_id_for_runtime() {
    local runtime="$1"
    local requested_container="${2:-}"
    local inspect_error=""

    if [ -z "$requested_container" ]; then
        requested_container=$("$runtime" ps -q -n 1)
    fi

    if [ -z "$requested_container" ]; then
        if [ -z "$REQUESTED_CONTAINER" ]; then
            return 2
        fi
        echo "ERROR: No container ID provided and no running containers found for $runtime" >&2
        return 1
    fi

    if ! inspect_error="$("$runtime" container inspect "$requested_container" 2>&1 >/dev/null)"; then
        case "$inspect_error" in
            *"No such container"*|*"No such object"*)
                echo "ERROR: No such container: $requested_container" >&2
                ;;
            *)
                printf '%s\n' "$inspect_error" >&2
                ;;
        esac
        return 1
    fi

    "$runtime" container inspect --format '{{.Id}}' "$requested_container"
}

resolve_available_container_ids() {
    local primary_status=1
    local docker_status=127
    local podman_status=127

    DOCKER_CONTAINER_ID=""
    PODMAN_CONTAINER_ID=""
    PRIMARY_RUNTIME=""
    PRIMARY_CONTAINER_ID=""

    if [ -n "$REQUESTED_RUNTIME" ]; then
        case "$REQUESTED_RUNTIME" in
            docker|podman)
                if PRIMARY_CONTAINER_ID="$(resolve_container_id_for_runtime "$REQUESTED_RUNTIME" "$REQUESTED_CONTAINER")"; then
                    if [ -n "$PRIMARY_CONTAINER_ID" ]; then
                        PRIMARY_RUNTIME="$REQUESTED_RUNTIME"
                    fi
                    return 0
                fi
                primary_status=$?
                if [ "$primary_status" -eq 2 ]; then
                    snapshot_info "No active container found to snapshot for $REQUESTED_RUNTIME."
                    exit 0
                fi
                return 1
                ;;
            *)
                snapshot_error "Unsupported snapshot runtime: $REQUESTED_RUNTIME"
                return 1
                ;;
        esac
    fi

    if command -v docker >/dev/null 2>&1; then
        if DOCKER_CONTAINER_ID="$(resolve_container_id_for_runtime docker "$REQUESTED_CONTAINER" 2>/dev/null)"; then
            docker_status=0
        else
            docker_status=$?
            DOCKER_CONTAINER_ID=""
        fi
    fi

    if command -v podman >/dev/null 2>&1; then
        if PODMAN_CONTAINER_ID="$(resolve_container_id_for_runtime podman "$REQUESTED_CONTAINER" 2>/dev/null)"; then
            podman_status=0
        else
            podman_status=$?
            PODMAN_CONTAINER_ID=""
        fi
    fi

    if [ -n "$DOCKER_CONTAINER_ID" ]; then
        PRIMARY_RUNTIME="docker"
        PRIMARY_CONTAINER_ID="$DOCKER_CONTAINER_ID"
        return 0
    fi

    if [ -n "$PODMAN_CONTAINER_ID" ]; then
        PRIMARY_RUNTIME="podman"
        PRIMARY_CONTAINER_ID="$PODMAN_CONTAINER_ID"
        return 0
    fi

    if [ -z "$REQUESTED_CONTAINER" ]; then
        if [ "$docker_status" -eq 2 ] && [ "$podman_status" -eq 2 ]; then
            snapshot_info "No active container found to snapshot for docker or podman."
            exit 0
        fi
        if [ "$docker_status" -eq 2 ]; then
            snapshot_info "No active container found to snapshot for docker."
            exit 0
        fi
        if [ "$podman_status" -eq 2 ]; then
            snapshot_info "No active container found to snapshot for podman."
            exit 0
        fi
    fi

    if [ -n "$REQUESTED_CONTAINER" ]; then
        if command -v docker >/dev/null 2>&1; then
            if resolve_container_id_for_runtime docker "$REQUESTED_CONTAINER" >/dev/null; then
                return 0
            fi
            return 1
        fi

        if command -v podman >/dev/null 2>&1; then
            if resolve_container_id_for_runtime podman "$REQUESTED_CONTAINER" >/dev/null; then
                return 0
            fi
            return 1
        fi
    fi

    snapshot_error "Container not found in Docker or Podman: $REQUESTED_CONTAINER"
    return 1
}

create_snapshot_directory() {
    create_private_snapshot_directories \
        "${SNAPSHOT_PATH}" \
        "${SNAPSHOT_PATH}/config" \
        "${SNAPSHOT_PATH}/state" \
        "${SNAPSHOT_PATH}/network" \
        "${SNAPSHOT_PATH}/logs" \
        "${SNAPSHOT_PATH}/security" \
        "${SNAPSHOT_PATH}/podman" \
        "${SNAPSHOT_PATH}/podman/config" \
        "${SNAPSHOT_PATH}/podman/state" \
        "${SNAPSHOT_PATH}/podman/network" \
        "${SNAPSHOT_PATH}/podman/logs" \
        "${SNAPSHOT_PATH}/podman/security"
}

capture_runtime_container_config() {
    local runtime="$1"
    local container_id="$2"
    local runtime_snapshot_path="$3"

    "$runtime" inspect "$container_id" > "${runtime_snapshot_path}/config/container-inspect.json"
    "$runtime" inspect --format '{{.Config}}' "$container_id" > "${runtime_snapshot_path}/config/container-config.json"
    "$runtime" inspect --format '{{.State}}' "$container_id" > "${runtime_snapshot_path}/state/container-state.json"
    "$runtime" inspect --format '{{.Config.Image}}' "$container_id" > "${runtime_snapshot_path}/config/image-info.txt"
}

capture_runtime_container_state() {
    local runtime="$1"
    local container_id="$2"
    local runtime_snapshot_path="$3"

    "$runtime" top "$container_id" > "${runtime_snapshot_path}/state/container-processes.txt"
    "$runtime" stats --no-stream "$container_id" > "${runtime_snapshot_path}/state/container-stats.txt"
    "$runtime" inspect --format '{{json .NetworkSettings.Networks}}' "$container_id" > "${runtime_snapshot_path}/network/container-network.json"
    "$runtime" port "$container_id" > "${runtime_snapshot_path}/state/container-ports.txt"
}

capture_runtime_security_context() {
    local runtime="$1"
    local container_id="$2"
    local runtime_snapshot_path="$3"

    "$runtime" inspect "$container_id" | jq -r '.[0] | (.HostConfig.SecurityOpt // .Config.SecurityOpt // [])' > "${runtime_snapshot_path}/security/security-options.txt"
    "$runtime" inspect "$container_id" | jq -r '.[0] | (.HostConfig.CapAdd // .Config.Capabilities // [])' > "${runtime_snapshot_path}/security/capabilities.txt"
    "$runtime" inspect "$container_id" | jq -r '.[0] | ((.HostConfig.SecurityOpt // .Config.SecurityOpt // []) | map(select(type == "string" and startswith("seccomp="))) | .[0]) // .Config.SeccompProfile // ""' > "${runtime_snapshot_path}/security/seccomp-profile.txt"
    "$runtime" inspect "$container_id" | jq -r '.[0] | (.HostConfig.NetworkMode // .Config.NetworkMode // "")' > "${runtime_snapshot_path}/security/network-mode.txt"
    "$runtime" inspect "$container_id" | jq -r '.[0] | (.HostConfig.ReadonlyRootfs // .HostConfig.ReadOnlyRootfs // .Config.ReadOnlyRootfs // false)' > "${runtime_snapshot_path}/security/read-only.txt"
}

capture_runtime_container_logs() {
    local runtime="$1"
    local container_id="$2"
    local runtime_snapshot_path="$3"

    "$runtime" logs --tail 1000 "$container_id" > "${runtime_snapshot_path}/logs/container-logs.txt"
}

capture_container_config() {
    snapshot_info "Capturing container configuration..."
    capture_runtime_container_config "$PRIMARY_RUNTIME" "$PRIMARY_CONTAINER_ID" "$SNAPSHOT_PATH"
}

capture_container_state() {
    snapshot_info "Capturing container state..."
    capture_runtime_container_state "$PRIMARY_RUNTIME" "$PRIMARY_CONTAINER_ID" "$SNAPSHOT_PATH"
}

capture_security_context() {
    snapshot_info "Capturing security context..."
    capture_runtime_security_context "$PRIMARY_RUNTIME" "$PRIMARY_CONTAINER_ID" "$SNAPSHOT_PATH"
}

capture_container_logs() {
    snapshot_info "Capturing container logs..."
    capture_runtime_container_logs "$PRIMARY_RUNTIME" "$PRIMARY_CONTAINER_ID" "$SNAPSHOT_PATH"
}

capture_podman_container_snapshot() {
    [ -n "$PODMAN_CONTAINER_ID" ] && [ "$PRIMARY_RUNTIME" != "podman" ] || return 0

    snapshot_info "Capturing Podman container snapshot..."
    capture_runtime_container_config podman "$PODMAN_CONTAINER_ID" "${SNAPSHOT_PATH}/podman"
    capture_runtime_container_state podman "$PODMAN_CONTAINER_ID" "${SNAPSHOT_PATH}/podman"
    capture_runtime_security_context podman "$PODMAN_CONTAINER_ID" "${SNAPSHOT_PATH}/podman"
    capture_runtime_container_logs podman "$PODMAN_CONTAINER_ID" "${SNAPSHOT_PATH}/podman"
}

main() {
    if [ -n "$REQUESTED_RUNTIME" ] && [ -z "$REQUESTED_CONTAINER" ]; then
        if [ -z "$("$REQUESTED_RUNTIME" ps -q -n 1 2>/dev/null || true)" ]; then
            snapshot_info "No active container found to snapshot for $REQUESTED_RUNTIME."
            exit 0
        fi
    fi

    resolve_available_container_ids
    SNAPSHOT_PATH="${SNAPSHOT_DIR}/container_${PRIMARY_CONTAINER_ID}_snapshot_${TIMESTAMP}"

    snapshot_info "Container security snapshot"
    snapshot_info "Container runtime: $PRIMARY_RUNTIME"
    snapshot_info "Container ID: $PRIMARY_CONTAINER_ID"
    snapshot_info "Timestamp: $TIMESTAMP"
    snapshot_info "Snapshot directory: $SNAPSHOT_PATH"

    create_snapshot_directory

    capture_container_config
    capture_container_state
    capture_security_context
    capture_container_logs
    capture_podman_container_snapshot
    secure_snapshot_tree "$SNAPSHOT_PATH"

    snapshot_success "Container snapshot completed successfully"
    snapshot_success "Snapshot saved to: $SNAPSHOT_PATH successfully"
}

main "$@"
