#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/snapshot-lib.sh"
source "$SCRIPT_DIR/../../shared/network-capture-helpers.sh"
set_private_snapshot_umask
enable_snapshot_error_trap

SNAPSHOT_DIR="${SNAPSHOT_DIR:-$(snapshot_root_dir)/config}"
TIMESTAMP="$(cld6001_unique_timestamp_id)"
SNAPSHOT_PATH="${SNAPSHOT_DIR}/config_snapshot_${TIMESTAMP}"

create_snapshot_directory() {
    create_private_snapshot_directories \
        "${SNAPSHOT_PATH}" \
        "${SNAPSHOT_PATH}/docker" \
        "${SNAPSHOT_PATH}/podman" \
        "${SNAPSHOT_PATH}/network" \
        "${SNAPSHOT_PATH}/security" \
        "${SNAPSHOT_PATH}/system" \
        "${SNAPSHOT_PATH}/hosts"
}

capture_docker_config() {
    snapshot_info "Capturing Docker configuration..."

    copy_optional_restorable_file "/etc/docker/daemon.json" "${SNAPSHOT_PATH}/docker/daemon.json" "Docker daemon config not captured"

    capture_optional_snapshot_output "${SNAPSHOT_PATH}/docker/docker-info.txt" "Docker info not available" docker info

    capture_optional_snapshot_output "${SNAPSHOT_PATH}/docker/docker-version.txt" "Docker version not available" docker version
 }

capture_podman_config() {
   if ! command -v podman >/dev/null 2>&1; then
       snapshot_info "Podman not installed, skipping config capture."
       write_snapshot_placeholder_file "${SNAPSHOT_PATH}/podman/containers.conf" "Podman containers config not found (Podman not installed)"
       write_snapshot_placeholder_file "${SNAPSHOT_PATH}/podman/podman-info.txt" "Podman info not available (Podman not installed)"
       write_snapshot_placeholder_file "${SNAPSHOT_PATH}/podman/podman-version.txt" "Podman version not available (Podman not installed)"
       return 0
   fi

   snapshot_info "Capturing Podman configuration..."

   copy_optional_snapshot_file "/etc/containers/containers.conf" "${SNAPSHOT_PATH}/podman/containers.conf" "Podman containers config not found"

   capture_optional_snapshot_output "${SNAPSHOT_PATH}/podman/podman-info.txt" "Podman info not available" podman info
   capture_optional_snapshot_output "${SNAPSHOT_PATH}/podman/podman-version.txt" "Podman version not available" podman version
}

capture_network_config() {
    snapshot_info "Capturing network configuration..."

    cld6001_capture_network_interfaces_snapshot "${SNAPSHOT_PATH}/network/interfaces.txt"

    if command -v ip >/dev/null 2>&1; then
       if ip route show table all > "${SNAPSHOT_PATH}/network/routes.txt" 2>/dev/null; then
           :
       elif ip route show > "${SNAPSHOT_PATH}/network/routes.txt" 2>/dev/null; then
           :
       else
           record_optional_snapshot_artifact_failure "${SNAPSHOT_PATH}/network/routes.txt" "Route information not available"
       fi
   else
       capture_optional_snapshot_output "${SNAPSHOT_PATH}/network/routes.txt" "Route information not available" route -n
   fi

   capture_optional_restorable_output "${SNAPSHOT_PATH}/network/dns-config.txt" "DNS config not captured" cat /etc/resolv.conf

   capture_optional_snapshot_output "${SNAPSHOT_PATH}/network/docker-networks.txt" "Docker network info not available" docker network ls

  if command -v podman >/dev/null 2>&1; then
      capture_optional_snapshot_output "${SNAPSHOT_PATH}/network/podman-networks.txt" "Podman network info not available" podman network ls
  else
      write_snapshot_placeholder_file "${SNAPSHOT_PATH}/network/podman-networks.txt" "Podman network info not available (Podman not installed)"
  fi
 }

capture_security_config() {
    snapshot_info "Capturing security configuration..."

    copy_optional_restorable_file "/etc/selinux/config" "${SNAPSHOT_PATH}/security/selinux-config.txt" "SELinux config not captured"

    write_sanitized_docker_security_options "${SNAPSHOT_PATH}/security/docker-security-config.txt"
   write_podman_security_config "${SNAPSHOT_PATH}/security/podman-security-config.txt"
 }

capture_system_config() {
    snapshot_info "Capturing system configuration..."

   copy_optional_restorable_file "/etc/hosts" "${SNAPSHOT_PATH}/hosts/hosts.txt" "Hosts file not captured"

   capture_optional_snapshot_output "${SNAPSHOT_PATH}/system/sysctl-config.txt" "Sysctl config not available" sysctl -a

    if command -v systemctl &>/dev/null; then
       capture_optional_snapshot_output "${SNAPSHOT_PATH}/system/systemd-services.txt" "Systemd services not available" systemctl list-units --type=service
   else
       record_optional_snapshot_artifact_failure "${SNAPSHOT_PATH}/system/systemd-services.txt" "Systemd services not available"
   fi
 }

main() {
    snapshot_info "Configuration security snapshot"
    snapshot_info "Timestamp: $TIMESTAMP"
    snapshot_info "Snapshot directory: $SNAPSHOT_PATH"

    create_snapshot_directory

    capture_docker_config
    capture_podman_config
    capture_network_config
    capture_security_config
    capture_system_config
    secure_snapshot_tree "$SNAPSHOT_PATH"

    snapshot_success "Configuration snapshot completed successfully"
    snapshot_success "Snapshot saved to: $SNAPSHOT_PATH successfully"
}

main "$@"
