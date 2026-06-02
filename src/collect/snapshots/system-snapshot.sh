#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/snapshot-lib.sh"
source "$SCRIPT_DIR/../../shared/network-capture-helpers.sh"
set_private_snapshot_umask
enable_snapshot_error_trap

SNAPSHOT_DIR="${SNAPSHOT_DIR:-$(snapshot_root_dir)/system}"
COMMAND="${1:-create}"
TARGET_SNAPSHOT="${2:-}"
TIMESTAMP="$(cld6001_unique_timestamp_id)"
SNAPSHOT_PATH="${SNAPSHOT_DIR}/system_${TIMESTAMP}"

create_snapshot_directory() {
    create_private_snapshot_directories \
        "${SNAPSHOT_PATH}" \
        "${SNAPSHOT_PATH}/system" \
        "${SNAPSHOT_PATH}/docker" \
        "${SNAPSHOT_PATH}/podman" \
        "${SNAPSHOT_PATH}/network" \
        "${SNAPSHOT_PATH}/security" \
        "${SNAPSHOT_PATH}/containers" \
        "${SNAPSHOT_PATH}/restore" \
        "${SNAPSHOT_PATH}/restore/etc" \
        "${SNAPSHOT_PATH}/restore/etc/docker" \
        "${SNAPSHOT_PATH}/restore/etc/containers" \
        "${SNAPSHOT_PATH}/restore/etc/selinux"
}

capture_system_info() {
    snapshot_info "Capturing system information..."

    capture_optional_snapshot_output "${SNAPSHOT_PATH}/system/os-release.txt" "OS release not found" cat /etc/os-release

    uname -r > "${SNAPSHOT_PATH}/system/kernel-version.txt"

    capture_optional_snapshot_output "${SNAPSHOT_PATH}/system/cpu-info.txt" "CPU info not available" lscpu

    free -h > "${SNAPSHOT_PATH}/system/memory-info.txt"

    df -h > "${SNAPSHOT_PATH}/system/disk-usage.txt"

    cld6001_capture_network_interfaces_snapshot "${SNAPSHOT_PATH}/network/interfaces.txt"

    capture_optional_snapshot_output "${SNAPSHOT_PATH}/docker/docker-info.txt" "Docker info not available" docker info

    capture_optional_snapshot_output "${SNAPSHOT_PATH}/docker/docker-version.txt" "Docker version not available" docker version

    capture_optional_snapshot_output "${SNAPSHOT_PATH}/containers/running-containers.txt" "Container list not available" docker ps -a

    if command -v podman >/dev/null 2>&1; then
        capture_optional_snapshot_output "${SNAPSHOT_PATH}/podman/podman-info.txt" "Podman info not available" podman info
        capture_optional_snapshot_output "${SNAPSHOT_PATH}/podman/podman-version.txt" "Podman version not available" podman version
        capture_optional_snapshot_output "${SNAPSHOT_PATH}/containers/podman-running-containers.txt" "Podman container list not available" podman ps -a
        return 0
    else
        write_snapshot_placeholder_file "${SNAPSHOT_PATH}/podman/podman-info.txt" "Podman info not available (Podman not installed)"
        write_snapshot_placeholder_file "${SNAPSHOT_PATH}/podman/podman-version.txt" "Podman version not available (Podman not installed)"
        write_snapshot_placeholder_file "${SNAPSHOT_PATH}/containers/podman-running-containers.txt" "Podman container list not available (Podman not installed)"
    fi
}

capture_security_config() {
    snapshot_info "Capturing security configuration..."

    if command -v sestatus &>/dev/null; then
        capture_optional_snapshot_output "${SNAPSHOT_PATH}/security/selinux-status.txt" "SELinux not available" sestatus
    else
        write_snapshot_placeholder_file "${SNAPSHOT_PATH}/security/selinux-status.txt" "SELinux status not available (sestatus not installed)"
    fi

    write_sanitized_docker_security_options "${SNAPSHOT_PATH}/security/docker-security-config.txt"
    write_podman_security_config "${SNAPSHOT_PATH}/security/podman-security-config.txt"
}

capture_network_snapshot() {
    snapshot_info "Capturing network configuration..."

    capture_optional_snapshot_output "${SNAPSHOT_PATH}/network/docker-networks.txt" "Docker network info not available" docker network ls

    local docker_container_ids=""
    docker_container_ids="$(docker ps -q 2>/dev/null || true)"
    if [ -n "$docker_container_ids" ]; then
        capture_optional_snapshot_output "${SNAPSHOT_PATH}/network/container-networking.txt" "Container networking not available" docker inspect --format '{{.NetworkSettings}}' $docker_container_ids
    else
        write_snapshot_placeholder_file "${SNAPSHOT_PATH}/network/container-networking.txt" "Container networking not available (No running containers)"
    fi

    if command -v podman >/dev/null 2>&1; then
        capture_optional_snapshot_output "${SNAPSHOT_PATH}/network/podman-networks.txt" "Podman network info not available" podman network ls

        local podman_container_ids=""
        podman_container_ids="$(podman ps -q 2>/dev/null || true)"
        if [ -n "$podman_container_ids" ]; then
            capture_optional_snapshot_output "${SNAPSHOT_PATH}/network/podman-container-networking.txt" "Podman container networking not available" podman inspect --format '{{.NetworkSettings}}' $podman_container_ids
        else
            write_snapshot_placeholder_file "${SNAPSHOT_PATH}/network/podman-container-networking.txt" "Podman container networking not available (No running containers)"
        fi
        return 0
    else
        write_snapshot_placeholder_file "${SNAPSHOT_PATH}/network/podman-networks.txt" "Podman network info not available (Podman not installed)"
        write_snapshot_placeholder_file "${SNAPSHOT_PATH}/network/podman-container-networking.txt" "Podman container networking not available (Podman not installed)"
    fi
}

capture_restorable_files() {
    snapshot_info "Capturing restorable configuration..."

    copy_optional_restorable_file "/etc/docker/daemon.json" "${SNAPSHOT_PATH}/restore/etc/docker/daemon.json" "Docker daemon config not captured"
    copy_optional_restorable_file "/etc/containers/containers.conf" "${SNAPSHOT_PATH}/restore/etc/containers/containers.conf" "Podman containers config not captured"
    copy_optional_restorable_file "/etc/hosts" "${SNAPSHOT_PATH}/restore/etc/hosts" "Hosts file not captured"
    copy_optional_restorable_file "/etc/resolv.conf" "${SNAPSHOT_PATH}/restore/etc/resolv.conf" "DNS config not captured"
    copy_optional_restorable_file "/etc/selinux/config" "${SNAPSHOT_PATH}/restore/etc/selinux/config" "SELinux config not captured"
}

list_snapshots() {
    snapshot_info "Available snapshots"

    local listed=false
    local snapshot_name
    while IFS= read -r snapshot_name; do
        listed=true
        echo "$snapshot_name"
    done < <(list_snapshot_directories)

    if [ "$listed" = false ]; then
        snapshot_warn "No snapshots found"
    fi
}

delete_snapshot() {
    [ -n "$TARGET_SNAPSHOT" ] || {
        echo "ERROR: Snapshot name required for delete" >&2
        return 1
    }

    delete_snapshot_directory "$TARGET_SNAPSHOT" || {
        snapshot_error "Snapshot not found: $TARGET_SNAPSHOT"
        return 1
    }

    snapshot_success "Deleted snapshot: $TARGET_SNAPSHOT successfully"
}

restore_snapshot() {
    local snapshot_path
    snapshot_path="$(resolve_snapshot_path "$TARGET_SNAPSHOT")" || {
        snapshot_error "No restorable snapshot found"
        return 1
    }

    snapshot_info "Restoring snapshot: $(basename -- "$snapshot_path")..."
    restore_snapshot_path "$snapshot_path"
    snapshot_success "Snapshot restored: $(basename -- "$snapshot_path") successfully"
}

create_snapshot() {
    snapshot_info "Container security system snapshot"
    snapshot_info "Timestamp: $TIMESTAMP"
    snapshot_info "Snapshot directory: $SNAPSHOT_PATH"

    create_snapshot_directory

    capture_system_info
    capture_security_config
    capture_network_snapshot
    capture_restorable_files
    secure_snapshot_tree "$SNAPSHOT_PATH"

    snapshot_success "System snapshot completed successfully"
    snapshot_success "Snapshot saved to: $SNAPSHOT_PATH successfully"
}

main() {
    case "$COMMAND" in
        create)
            create_snapshot
            ;;
        list)
            list_snapshots
            ;;
        delete)
            delete_snapshot
            ;;
        restore)
            restore_snapshot
            ;;
        *)
            echo "Usage: $0 {create|list|delete <snapshot-name>|restore [snapshot-name]}" >&2
            return 1
            ;;
    esac
}

main "$@"
