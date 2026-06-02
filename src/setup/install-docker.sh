#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_ROOT}/../profiles/profile-adapter.sh"
source "${SCRIPT_ROOT}/../../src/shared/terminal-colors.sh"
source "${SCRIPT_ROOT}/../../src/shared/log-pipe.sh"
source "${SCRIPT_ROOT}/../../src/shared/installer-bootstrap-helpers.sh"
source "${SCRIPT_ROOT}/../../src/shared/filesystem-helpers.sh"
source "${SCRIPT_ROOT}/../../src/shared/runtime-smoke-test-helpers.sh"
source "${SCRIPT_ROOT}/../../src/shared/storage-driver-helpers.sh"
source "${SCRIPT_ROOT}/../../src/shared/sysctl-helpers.sh"

resolve_preferred_user() {
    if [ -n "${1:-}" ]; then
        printf '%s\n' "$1"
    elif [ -n "${SUDO_USER:-}" ]; then
        printf '%s\n' "${SUDO_USER}"
    else
        whoami
    fi
}

resolve_user_home() {
    local user="$1"
    local user_home=""

    user_home="$(getent passwd "${user}" 2>/dev/null | cut -d: -f6 || true)"
    if [ -n "${user_home}" ]; then
        printf '%s\n' "${user_home}"
        return 0
    fi

    user_home="$(awk -F: -v target_user="${user}" '$1 == target_user { print $6; exit }' /etc/passwd 2>/dev/null || true)"
    if [ -n "${user_home}" ]; then
        printf '%s\n' "${user_home}"
        return 0
    fi

    printf '/home/%s\n' "${user}"
}

resolve_rootless_uid() {
    id -u "${ROOTLESS_USER}" 2>/dev/null || true
}

resolve_rootless_state_dir() {
    local rootless_uid=""

    rootless_uid="$(resolve_rootless_uid)"
    if [ -z "${rootless_uid}" ]; then
        printf '/run/user/0\n'
    else
        printf '/run/user/%s\n' "${rootless_uid}"
    fi
}

resolve_rootless_netns_dir() {
    printf '%s/docker/netns\n' "$(resolve_rootless_state_dir)"
}

resolve_rootless_dbus_address() {
    printf 'unix:path=%s/bus\n' "$(resolve_rootless_state_dir)"
}

resolve_rootless_docker_host() {
    printf 'unix://%s/docker.sock\n' "$(resolve_rootless_state_dir)"
}

readonly SCRIPT_NAME="install-docker"
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DATE="2026-05-16"
readonly RESEARCH_LABEL="cld6001.research.managed=true"

readonly DOCKER_REPO_BASE="https://download.docker.com"
readonly DOCKER_GPG_KEY="${DOCKER_REPO_BASE}/linux/centos/gpg"
readonly DOCKER_CONF_DIR="${DOCKER_CONF_DIR:-/etc/docker}"
readonly DOCKER_STATE_DIR="/var/lib/docker"
readonly DOCKER_SOCK="/var/run/docker.sock"
readonly DOCKER_SYSCTL_FILE="/etc/sysctl.d/99-docker.conf"
readonly DOCKER_LIMITS_DIR="/etc/systemd/system/docker.service.d"
readonly DOCKER_LIMITS_FILE="${DOCKER_LIMITS_DIR}/limits.conf"
readonly DOCKER_STORAGE_DRIVER="$(cld6001_expected_storage_driver "docker-rootful")"
readonly DOCKER_ROOTLESS_STORAGE_DRIVER="$(cld6001_expected_storage_driver "docker-rootless")"

readonly ROOTLESS_USER="$(resolve_preferred_user "${DOCKER_ROOTLESS_USER:-}")"
readonly ROOTLESS_HOME="$(resolve_user_home "${ROOTLESS_USER}")"
readonly ROOTLESS_STORAGE_DIR="${ROOTLESS_HOME}/docker-storage"
readonly ROOTLESS_DOCKER_CONF_DIR="${ROOTLESS_HOME}/.config/docker"
readonly ROOTLESS_DOCKER_DAEMON_JSON="${ROOTLESS_DOCKER_CONF_DIR}/daemon.json"
readonly ROOTLESS_SYSTEMD_DIR="${ROOTLESS_HOME}/.config/systemd/user"
readonly ROOTLESS_SYSTEMD_SERVICE_FILE="${ROOTLESS_SYSTEMD_DIR}/docker.service"
readonly ROOTLESS_SYSTEMD_OVERRIDE_DIR="${ROOTLESS_SYSTEMD_DIR}/docker.service.d"
readonly ROOTLESS_SYSTEMD_OVERRIDE_FILE="${ROOTLESS_SYSTEMD_OVERRIDE_DIR}/override.conf"

readonly DOCKER_ROOTFUL_PACKAGES=(
    "docker-ce"
    "docker-ce-cli"
    "docker-ce-rootless-extras"
    "containerd.io"
    "docker-buildx-plugin"
    "docker-compose-plugin"
)

readonly DOCKER_ROOTLESS_PACKAGES=(
    "docker-ce-rootless-extras"
    "slirp4netns"
    "fuse-overlayfs"
)

readonly KERNEL_PARAMETERS=(
    "net.ipv4.ip_forward=1"
    "net.bridge.bridge-nf-call-iptables=1"
    "net.bridge.bridge-nf-call-ip6tables=1"
    "net.bridge.bridge-nf-call-arptables=1"
)

readonly OVERLAY_MODULE_BLACKLIST_FILE="/etc/modprobe.d/blacklist-overlay.conf"
readonly OVERLAY_MODULE_INSTALL_DIRECTIVE="install overlay /bin/false"

readonly CONTAINER_NOFILE=65536
readonly CONTAINER_NPROC=65536

RUN_ID="${CLD6001_RUN_ID:-standalone}"

readonly ROLLBACK_BASE_DIR="${CLD6001_ROLLBACK_BASE_DIR:-/var/lib/cld6001/${RUN_ID}/${SCRIPT_NAME}-rollback}"
readonly ROLLBACK_DIR="${CLD6001_ROLLBACK_DIR:-${ROLLBACK_BASE_DIR}/snapshot}"
readonly ROLLBACK_ARCHIVE_DIR="${CLD6001_ROLLBACK_ARCHIVE_DIR:-${ROLLBACK_BASE_DIR}/archives}"
readonly ROLLBACK_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly ROLLBACK_STATE_FILE="${ROLLBACK_ARCHIVE_DIR}/state_${ROLLBACK_TIMESTAMP}.tar.gz"

ACTION="install"
MODE="both"
PROFILE_NAME=""
RESEARCH_OVERLAY=""
PROFILE_JSON=""
LOG_DIR=""
LOG_FILE=""
ERRORS=0
WARNINGS=0
ROOTLESS_SYSTEMD_SERVICE_REUSE_ALLOWED=false
ROOTLESS_SYSTEMD_SERVICE_NEEDS_REFRESH=false

initialize_log_paths() {
    cld6001_initialize_installer_log_paths "$RUN_ID" "$SCRIPT_NAME" "$ACTION" "$ROLLBACK_TIMESTAMP"
}

log() {
    local level="$1"
    shift
    cld6001_installer_log "$level" "setup" "docker" "$SCRIPT_NAME" "$LOG_FILE" "$@"
}

log_info() {
    log "INFO" "$@"
}

log_warn() {
    log "WARN" "$@"
    WARNINGS=$((WARNINGS + 1))
}

log_error() {
    log "ERROR" "$@"
    ERRORS=$((ERRORS + 1))
}

log_step() {
    cld6001_installer_log_step "${BLUE}" "${NC}" "setup" "docker" "$SCRIPT_NAME" "$LOG_FILE" "$@"
}

validate_rootless_user() {
    local user="${1:-}"
    local context="${2:-rootless setup}"

    if [ -z "${user}" ]; then
        log_error "${context} requires a non-empty target user"
        return 1
    fi

    if [ "${user}" = "root" ]; then
        log_error "${context} target user must not be root"
        return 1
    fi

    return 0
}

print_usage() {
    cat <<'EOF'
Usage:
  sudo bash install-docker.sh install [rootful|rootless|both] --profile <name> [--research-overlay <name>]
  sudo bash install-docker.sh verify [rootful|rootless|both] --profile <name>
  sudo bash install-docker.sh rollback [rootful|rootless|both]

Examples:
  sudo bash install-docker.sh install rootful --profile baseline-defaults
  sudo bash install-docker.sh install rootless --profile rootless-least-privilege
  sudo bash install-docker.sh install both --profile cis-hardened
  sudo bash install-docker.sh verify rootful --profile baseline-defaults
  sudo bash install-docker.sh rollback
EOF
}

parse_args() {
    cld6001_reset_installer_parse_state ACTION PROFILE_NAME RESEARCH_OVERLAY PROFILE_JSON LOG_DIR LOG_FILE MODE both
    local action_seen=0
    local mode_seen=0

    while [ $# -gt 0 ]; do
        case "$1" in
            install|verify|rollback)
                if [ $action_seen -eq 1 ]; then
                    log_error "Duplicate action argument: $1"
                    exit 1
                fi
                ACTION="$1"
                action_seen=1
                shift
                ;;
            rootful|rootless|both)
                if [ $mode_seen -eq 1 ]; then
                    log_error "Duplicate mode argument: $1"
                    exit 1
                fi
                MODE="$1"
                mode_seen=1
                shift
                ;;
            --profile)
                [ $# -ge 2 ] || {
                    log_error "Missing value for --profile"
                    exit 1
                }
                PROFILE_NAME="$2"
                shift 2
                ;;
            --research-overlay)
                [ $# -ge 2 ] || {
                    log_error "Missing value for --research-overlay"
                    exit 1
                }
                RESEARCH_OVERLAY="$2"
                shift 2
                ;;
            *)
                log_error "Unknown argument: $1"
                exit 1
                ;;
        esac
    done

initialize_log_paths
}

docker_mode_supported() {
    case "${MODE}" in
        both)
            profile_supports "$PROFILE_JSON" docker rootful | grep -qx 'true' &&
                profile_supports "$PROFILE_JSON" docker rootless | grep -qx 'true'
            ;;
        rootful|rootless)
            profile_supports "$PROFILE_JSON" docker "$MODE" | grep -qx 'true'
            ;;
        *)
            return 1
            ;;
    esac
}

load_selected_profile() {
    [ -n "$PROFILE_NAME" ] || {
        log_error "Missing required --profile"
        return 1
    }

    PROFILE_JSON="$(load_profile_json "$PROFILE_NAME")" || return 1
    docker_mode_supported || {
        log_error "Profile ${PROFILE_NAME} does not support docker/${MODE}"
        return 1
    }

    if [ -n "$RESEARCH_OVERLAY" ] && ! profile_allows_overlay "$PROFILE_JSON" "$RESEARCH_OVERLAY"; then
        log_error "Profile ${PROFILE_NAME} does not allow research overlay ${RESEARCH_OVERLAY}"
        return 1
    fi
}

validate_action_contract() {
    case "${ACTION}" in
        verify)
            [ -n "${PROFILE_NAME}" ] || {
                log_error "verify requires --profile <name>"
                return 1
            }
            [ -z "${RESEARCH_OVERLAY}" ] || {
                log_error "verify does not accept --research-overlay"
                return 1
            }
            ;;
        rollback)
            [ -z "${PROFILE_NAME}" ] || {
                log_error "rollback does not accept --profile"
                return 1
            }
            [ -z "${RESEARCH_OVERLAY}" ] || {
                log_error "rollback does not accept --research-overlay"
                return 1
            }
            ;;
    esac
}

check_root() {
    if [ $EUID -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_os() {
    local id=$(grep -i '^id=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    local version=$(grep -i '^version_id=' /etc/os-release | cut -d'=' -f2 | tr -d '"')

    if [ "${id}" != "almalinux" ]; then
        log_error "This script requires AlmaLinux. Found: ${id}"
        exit 1
    fi

    case "${version}" in
        10*)
            ;;
        *)
            log_error "This script requires AlmaLinux 10.x. Found: ${version}"
            exit 1
            ;;
    esac

    log_info "Operating system: AlmaLinux ${version}"
}

check_dependencies() {
    local missing=()

    for pkg in curl jq tar iptables; do
        if ! command -v "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_warn "Missing dependencies: ${missing[*]}"
        log_info "Installing missing dependencies..."
        dnf install -y "${missing[@]}" || {
            log_error "Failed to install dependencies"
            exit 1
        }
    fi
}

detect_compression_jobs() {
    local jobs=""

    jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
    case "$jobs" in
        ''|*[!0-9]*)
            jobs="1"
            ;;
        *)
            if [ "$jobs" -lt 1 ]; then
                jobs="1"
            fi
            ;;
    esac
    printf '%s\n' "$jobs"
}

create_rollback_archive() {
    mkdir -p "${ROLLBACK_ARCHIVE_DIR}"

    if command -v pigz >/dev/null 2>&1; then
        tar cf - --exclude='./state_*.tar.gz' -C "${ROLLBACK_DIR}" . | pigz -p "$(detect_compression_jobs)" > "${ROLLBACK_STATE_FILE}"
    else
        tar --exclude='./state_*.tar.gz' -czf "${ROLLBACK_STATE_FILE}" -C "${ROLLBACK_DIR}" .
    fi
}

snapshot_managed_path_state() {
    local live_path="$1"
    local snapshot_key="$2"
    local managed_dir="${ROLLBACK_DIR}/managed-path-state"
    local mode_file="${managed_dir}/${snapshot_key}.mode"
    local backup_path="${managed_dir}/${snapshot_key}.before"

    mkdir -p "${managed_dir}"

    if [ -e "${live_path}" ]; then
        if cp -a "${live_path}" "${backup_path}" 2>/dev/null; then
            printf 'restore\n' > "${mode_file}"
        else
            log_warn "Could not snapshot ${live_path}; rollback will preserve the live path instead of replacing it"
            rm -f "${backup_path}" 2>/dev/null || true
            printf 'preserve\n' > "${mode_file}"
        fi
    else
        rm -f "${backup_path}" 2>/dev/null || true
        printf 'created\n' > "${mode_file}"
    fi
}

snapshot_managed_directory_state() {
    local live_dir="$1"
    local snapshot_key="$2"
    local managed_dir="${ROLLBACK_DIR}/managed-path-state"
    local mode_file="${managed_dir}/${snapshot_key}.mode"

    mkdir -p "${managed_dir}"

    if [ -d "${live_dir}" ]; then
        printf 'restore\n' > "${mode_file}"
    else
        printf 'created\n' > "${mode_file}"
    fi
}

restore_or_remove_managed_path() {
    local live_path="$1"
    local snapshot_key="$2"
    local managed_dir="${ROLLBACK_DIR}/managed-path-state"
    local mode_file="${managed_dir}/${snapshot_key}.mode"
    local backup_path="${managed_dir}/${snapshot_key}.before"
    local mode=""

    if [ -f "${mode_file}" ]; then
        mode="$(tr -d '\n' < "${mode_file}")"
    fi

    case "${mode}" in
        restore)
            if [ ! -e "${backup_path}" ]; then
                log_warn "Could not restore ${live_path}; rollback backup is missing"
                return 1
            fi
            mkdir -p "$(dirname -- "${live_path}")"
            cp -a "${backup_path}" "${live_path}" 2>/dev/null || {
                log_warn "Could not restore ${live_path} from rollback backup"
                return 1
            }
            ;;
        created)
            rm -f "${live_path}" 2>/dev/null || true
            ;;
        preserve)
            if [ -e "${live_path}" ]; then
                log_warn "Preserving ${live_path}; rollback snapshot was not available"
            fi
            ;;
        *)
            if [ -e "${live_path}" ]; then
                log_warn "Preserving ${live_path}; rollback ownership metadata is missing"
            fi
            ;;
    esac
}

restore_or_remove_managed_directory() {
    local live_dir="$1"
    local snapshot_key="$2"
    local managed_dir="${ROLLBACK_DIR}/managed-path-state"
    local mode_file="${managed_dir}/${snapshot_key}.mode"
    local mode=""

    if [ -f "${mode_file}" ]; then
        mode="$(tr -d '\n' < "${mode_file}")"
    fi

    if [ "${mode}" = "created" ]; then
        rmdir "${live_dir}" 2>/dev/null || true
    fi
}

save_state() {
    log_step "Saving system state for rollback"

    mkdir -p "${ROLLBACK_DIR}"

    dnf list installed > "${ROLLBACK_DIR}/packages_before.txt" 2>/dev/null || true

    if [ -d "${DOCKER_CONF_DIR}" ]; then
        cp -r "${DOCKER_CONF_DIR}" "${ROLLBACK_DIR}/docker_conf_backup/" 2>/dev/null || true
    fi

    sysctl -a > "${ROLLBACK_DIR}/sysctl_before.txt" 2>/dev/null || true

    ulimit -a > "${ROLLBACK_DIR}/ulimit_before.txt" 2>/dev/null || true

    iptables-save > "${ROLLBACK_DIR}/iptables_before.txt" 2>/dev/null || true

    snapshot_managed_path_state "${DOCKER_SYSCTL_FILE}" "docker-sysctl-conf"
    snapshot_managed_directory_state "${DOCKER_LIMITS_DIR}" "docker-limits-dir"
    snapshot_managed_path_state "${DOCKER_LIMITS_FILE}" "docker-limits-conf"

    create_rollback_archive 2>/dev/null || {
        log_warn "Could not create rollback backup tarball"
    }

    log_info "Rollback state saved to: ${ROLLBACK_STATE_FILE}"
}

rollback_docker() {
    log_step "Rolling back Docker installation"
    local purge_docker_state="true"

    log_info "Stopping Docker services..."
    systemctl disable --now docker.socket docker.service 2>/dev/null || true

    pkill -f docker 2>/dev/null || true

    log_info "Removing Docker packages..."
    for pkg in "${DOCKER_ROOTFUL_PACKAGES[@]}" "${DOCKER_ROOTLESS_PACKAGES[@]}"; do
        dnf remove -y "$pkg" 2>/dev/null || true
    done

    log_info "Removing Docker repository..."
    rm -f /etc/yum.repos.d/docker*.repo

    if [ -t 0 ]; then
        purge_docker_state="false"
        read -r -p "Remove Docker data and state (this will delete all containers and images)? [N/y]: " -n 1
        echo
        case "${REPLY:-}" in
            [Yy])
                purge_docker_state="true"
                ;;
        esac
    fi

    if [ "${purge_docker_state}" = "true" ]; then
        log_info "Removing Docker data..."
        rm -rf "${DOCKER_STATE_DIR}" "${DOCKER_CONF_DIR}"
        remove_matching_paths_if_any "/home/*/.config/systemd/user/docker*"
        rm -rf "/run/docker" "/run/netns/docker"
    fi

    if [ -f "${ROLLBACK_DIR}/sysctl_before.txt" ]; then
        log_info "Restoring kernel parameters..."
        restore_saved_sysctl_value "${ROLLBACK_DIR}/sysctl_before.txt" "net.ipv4.ip_forward" || true
        restore_saved_sysctl_value "${ROLLBACK_DIR}/sysctl_before.txt" "net.bridge.bridge-nf-call-iptables" || true
        restore_saved_sysctl_value "${ROLLBACK_DIR}/sysctl_before.txt" "net.bridge.bridge-nf-call-ip6tables" || true
        restore_saved_sysctl_value "${ROLLBACK_DIR}/sysctl_before.txt" "net.bridge.bridge-nf-call-arptables" || true
    else
        log_warn "Could not restore kernel parameters; rollback snapshot is missing"
    fi

    if [ -f "${OVERLAY_MODULE_BLACKLIST_FILE}" ]; then
        log_info "Removing overlay module blacklist..."
        rm -f "${OVERLAY_MODULE_BLACKLIST_FILE}" || true
    fi

    restore_or_remove_managed_path "${DOCKER_SYSCTL_FILE}" "docker-sysctl-conf" || true
    restore_or_remove_managed_path "${DOCKER_LIMITS_FILE}" "docker-limits-conf" || true
    restore_or_remove_managed_directory "${DOCKER_LIMITS_DIR}" "docker-limits-dir" || true
    systemctl daemon-reload 2>/dev/null || true

    log_info "Removing Docker bridge network..."
    if ip link show docker0 &>/dev/null; then
        ip link delete docker0 2>/dev/null || true
    fi

    userdel docker 2>/dev/null || true
    groupdel docker 2>/dev/null || true

    log_info "Docker rollback completed..."
}

configure_overlay_module_blacklist() {
    log_info "Blocking overlay kernel module loading..."
    mkdir -p /etc/modprobe.d
    echo "${OVERLAY_MODULE_INSTALL_DIRECTIVE}" | tee "${OVERLAY_MODULE_BLACKLIST_FILE}" > /dev/null
}

configure_kernel() {
    log_step "Configuring kernel parameters"

    cat > "${DOCKER_SYSCTL_FILE}" << 'EOF'
# Container security research - Docker kernel parameters
# Generated by ${SCRIPT_NAME}
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-arptables = 1
net.bridge.bridge-nf-filter-accept-local = 0
EOF

    configure_overlay_module_blacklist

    sysctl --system

    if sysctl -q net.ipv4.ip_forward && [ $(sysctl -n net.ipv4.ip_forward) -eq 1 ]; then
        log_info "IP forwarding enabled successfully..."
    else
        log_warn "Could not enable IP forwarding"
    fi
}

configure_ulimits() {
    log_step "Configuring system limits"

    mkdir -p "${DOCKER_LIMITS_DIR}"
    cat > "${DOCKER_LIMITS_FILE}" << EOF
[Service]
LimitNOFILE=${CONTAINER_NOFILE}:${CONTAINER_NOFILE}
LimitNPROC=${CONTAINER_NPROC}:${CONTAINER_NPROC}
LimitCORE=1048576:1048576
LimitMEMLOCK=536870912:1073741824
LimitLOCKS=infinity
EOF

    systemctl daemon-reload

    log_info "System limits configured for Docker..."
}

configure_selinux() {
    log_step "Configuring SELinux for Docker"

    if ! command -v getenforce &>/dev/null; then
        log_warn "SELinux not installed, skipping configuration"
        return
    fi

    local current_mode=$(getenforce)
    log_info "Current SELinux mode: ${current_mode}"

    if [ "${current_mode}" = "Enforcing" ]; then
        log_info "Installing SELinux policy for Docker..."
        dnf install -y container-selinux || {
            log_error "Failed to install container-selinux"
            exit 1
        }
    fi

    log_info "SELinux configuration for Docker completed..."
}

configure_storage() {
    log_step "Configuring storage for Docker"

    mkdir -p "${DOCKER_STATE_DIR}"
    chmod 700 "${DOCKER_STATE_DIR}"

    if ! grep -q overlay /proc/filesystems; then
        log_warn "Overlay filesystem not available, overlay2 may not work"
    fi

    log_info "Storage configuration completed..."
}

add_docker_repository() {
    log_step "Adding Docker official repository"

    rm -f /etc/yum.repos.d/docker*.repo

    log_info "Adding Docker GPG key..."
    curl -fsSL "${DOCKER_GPG_KEY}" | gpg --dearmor --batch --yes --output /etc/pki/rpm-gpg/docker-ce.gpg

    cat > /etc/yum.repos.d/docker-ce.repo << 'EOF'
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://download.docker.com/linux/centos/$releasever/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg

[docker-ce-stable-debuginfo]
name=Docker CE Stable - $basearch - Debuginfo
baseurl=https://download.docker.com/linux/centos/$releasever/$basearch/stable-debuginfo
enabled=0
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg

[docker-ce-stable-source]
name=Docker CE Stable - $basearch - Sources
baseurl=https://download.docker.com/linux/centos/$releasever/$basearch/stable-source
enabled=0
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg
EOF

    if ! dnf clean all &>/dev/null; then
        log_error "Failed to clean DNF cache"
        exit 1
    fi

    log_info "Docker repository added successfully"
}

install_docker_rootful() {
    log_step "Installing Docker rootful"

    if command -v docker &>/dev/null && docker version &>/dev/null; then
        log_warn "Docker is already installed (idempotent check)"
        ensure_docker_operator_group_access
        log_info "Reusing existing installation; daemon config will be reconciled before final verification..."
        return 0
    fi

    add_docker_repository

    log_info "Installing Docker packages..."
    dnf install -y "${DOCKER_ROOTFUL_PACKAGES[@]}" || {
        log_error "Failed to install Docker packages"
        exit 1
    }

    if ! getent passwd docker &>/dev/null; then
        if getent group docker &>/dev/null; then
            useradd -r -g docker -s /usr/sbin/nologin -c "Docker user" docker
        else
            useradd -r -s /usr/sbin/nologin -c "Docker user" docker
        fi
        log_info "Created Docker system user..."
    fi

    systemctl enable docker.socket docker.service
    ensure_docker_operator_group_access

    log_info "docker-rootful installation completed successfully..."
}

ensure_docker_operator_group_access() {
    local operator_user="${DOCKER_OPERATOR_USER:-${ROOTLESS_USER}}"

    if [ -z "${operator_user}" ] || [ "${operator_user}" = "root" ]; then
        log_warn "Skipping Docker group membership update because no non-root operator user was resolved"
        return 0
    fi

    if ! id "${operator_user}" &>/dev/null; then
        log_warn "Skipping Docker group membership update because user does not exist: ${operator_user}"
        return 0
    fi

    groupadd -f docker

    if id -nG "${operator_user}" | tr ' ' '\n' | grep -Fx docker >/dev/null; then
        log_info "Docker operator user already has docker group access: ${operator_user}"
        return 0
    fi

    usermod -aG docker "${operator_user}"
    log_info "Added Docker operator user to docker group: ${operator_user}..."
}

configure_docker_daemon() {
    log_step "Configuring Docker daemon"

    mkdir -p "${DOCKER_CONF_DIR}"

    write_docker_daemon_config

    if [ ! -f "${DOCKER_CONF_DIR}/storage-driver.json" ]; then
        echo "{\"storage-driver\": \"${DOCKER_STORAGE_DRIVER}\"}" > \
            "${DOCKER_CONF_DIR}/storage-driver.json"
    fi

    activate_rootful_docker_units || {
        log_error "Failed to activate Docker system service"
        exit 1
    }

    log_info "Docker daemon configuration completed..."
}

activate_rootful_docker_units() {
    systemctl daemon-reload || return 1
    systemctl enable docker.socket docker.service || return 1
    systemctl reset-failed docker.socket docker.service 2>/dev/null || true

    if systemctl is-active --quiet docker.service; then
        systemctl restart docker.socket docker.service || return 1
    else
        systemctl start docker.socket docker.service || return 1
    fi
}

write_docker_daemon_config() {
    [ -n "$PROFILE_JSON" ] || {
        log_error "Docker daemon configuration requires a loaded profile"
        return 1
    }

    local no_new_privileges
    local seccomp_profile
    local live_restore

    no_new_privileges="$(profile_value "$PROFILE_JSON" '.docker.no_new_privileges')"
    seccomp_profile="$(profile_value "$PROFILE_JSON" '.docker.seccomp_profile')"
    live_restore="$(profile_value "$PROFILE_JSON" '.docker.live_restore')"

    jq -n \
        --arg storage "$DOCKER_STORAGE_DRIVER" \
        --arg sock "$DOCKER_SOCK" \
        --argjson no_new_privileges "$no_new_privileges" \
        --arg seccomp_profile "$seccomp_profile" \
        --argjson live_restore "$live_restore" \
        --arg label "$RESEARCH_LABEL" \
        --argjson nofile "$CONTAINER_NOFILE" \
        --argjson nproc "$CONTAINER_NPROC" \
        '{
            "storage-driver": $storage,
            "log-driver": "journald",
            "default-ulimits": {
                "nofile": {"Name": "nofile", "Hard": $nofile, "Soft": $nofile},
                "nproc": {"Name": "nproc", "Hard": $nproc, "Soft": $nproc}
            },
            "userland-proxy": false,
            "live-restore": $live_restore,
            "no-new-privileges": $no_new_privileges,
            "labels": [$label]
        } + (if $seccomp_profile == "" then {} else {"seccomp-profile": $seccomp_profile} end)' \
        > "${DOCKER_CONF_DIR}/daemon.json"
}

format_verify_value() {
    case "${1:-}" in
        __missing__)
            printf '<missing>'
            ;;
        true|false)
            printf '%s' "$1"
            ;;
        *)
            printf '"%s"' "$1"
            ;;
    esac
}

run_rootless_user_command() {
    local command="${1:?rootless command required}"
    local rootless_state_dir=""
    local rootless_dbus_address=""
    local rootless_docker_host=""

    rootless_state_dir="$(resolve_rootless_state_dir)"
    rootless_dbus_address="$(resolve_rootless_dbus_address)"
    rootless_docker_host="$(resolve_rootless_docker_host)"

    su - "${ROOTLESS_USER}" -c "export PATH=/usr/bin:/bin:\$PATH; export XDG_RUNTIME_DIR='${rootless_state_dir}'; export DBUS_SESSION_BUS_ADDRESS='${rootless_dbus_address}'; export DOCKER_HOST='${rootless_docker_host}'; ${command}"
}

read_docker_daemon_setting() {
    local key="$1"
    local default_mode="${2:-missing}"

    jq -r --arg key "$key" --arg default_mode "$default_mode" '
        if has($key) then .[$key]
        elif $default_mode == "empty" then ""
        else "__missing__"
        end
        | if type == "boolean" then tostring else . end
    ' "${DOCKER_CONF_DIR}/daemon.json"
}

write_rootless_docker_daemon_config() {
    mkdir -p "${ROOTLESS_DOCKER_CONF_DIR}"

    jq -n \
        --arg storage "${DOCKER_ROOTLESS_STORAGE_DRIVER}" \
        --arg data_root "${ROOTLESS_STORAGE_DIR}" \
        '{
            "storage-driver": $storage,
            "data-root": $data_root
        }' \
        > "${ROOTLESS_DOCKER_DAEMON_JSON}"
}

read_rootless_docker_daemon_setting() {
    local key="$1"

    jq -r --arg key "$key" '
        if has($key) then .[$key] else "__missing__" end
    ' "${ROOTLESS_DOCKER_DAEMON_JSON}"
}

rootless_systemd_service_looks_reusable() {
    [ -f "${ROOTLESS_SYSTEMD_SERVICE_FILE}" ] || return 1

    grep -Eq '^Description=(Docker Application Container Engine \(Rootless\)|Refreshed Docker Application Container Engine \(Rootless\)|Generated by dockerd-rootless-setuptool)$' "${ROOTLESS_SYSTEMD_SERVICE_FILE}" || return 1
    grep -Fxq '[Unit]' "${ROOTLESS_SYSTEMD_SERVICE_FILE}" || return 1
    grep -Fxq '[Service]' "${ROOTLESS_SYSTEMD_SERVICE_FILE}" || return 1
    grep -Eq '^[[:space:]]*ExecStart=/usr/bin/dockerd-rootless\.sh[[:space:]]*$' "${ROOTLESS_SYSTEMD_SERVICE_FILE}" || return 1
    grep -Fxq '[Install]' "${ROOTLESS_SYSTEMD_SERVICE_FILE}" || return 1
    grep -Eq '^[[:space:]]*WantedBy=default\.target[[:space:]]*$' "${ROOTLESS_SYSTEMD_SERVICE_FILE}"
}

install_docker_rootless() {
    log_step "Installing Docker rootless"
    local rootless_already_installed=false
    local rootless_service_preexisting=false
    local rootless_service_reusable=false

    validate_rootless_user "${ROOTLESS_USER}" "docker-rootless" || return 1

    ROOTLESS_SYSTEMD_SERVICE_REUSE_ALLOWED=false
    ROOTLESS_SYSTEMD_SERVICE_NEEDS_REFRESH=false

    if [ -f "${ROOTLESS_SYSTEMD_SERVICE_FILE}" ]; then
        rootless_service_preexisting=true
        if rootless_systemd_service_looks_reusable; then
            rootless_service_reusable=true
        else
            ROOTLESS_SYSTEMD_SERVICE_NEEDS_REFRESH=true
            log_warn "Docker rootless user unit looks stale or broken on disk; refreshing it before reuse: ${ROOTLESS_SYSTEMD_SERVICE_FILE}"
        fi
    fi

    if [ -x /usr/bin/docker ] && \
       id "${ROOTLESS_USER}" &>/dev/null && \
       [ "${rootless_service_preexisting}" = "true" ] && \
       [ "${rootless_service_reusable}" = "true" ] && \
       run_rootless_user_command "/usr/bin/docker version" &>/dev/null; then
        rootless_already_installed=true
        ROOTLESS_SYSTEMD_SERVICE_REUSE_ALLOWED=true
        log_warn "docker-rootless is already installed for ${ROOTLESS_USER}; reconciling fuse-overlayfs configuration"
    fi

    log_info "Installing rootless dependencies..."
    dnf install -y "${DOCKER_ROOTLESS_PACKAGES[@]}" || {
        log_error "Failed to install rootless dependencies"
        exit 1
    }

    if ! id "${ROOTLESS_USER}" &>/dev/null; then
        log_info "Creating rootless user: ${ROOTLESS_USER}..."
        useradd -m -s /bin/bash "${ROOTLESS_USER}"
    fi

    mkdir -p "${ROOTLESS_STORAGE_DIR}"
    chown -R "${ROOTLESS_USER}":"${ROOTLESS_USER}" "${ROOTLESS_STORAGE_DIR}"

    log_info "Setting up Docker rootless..."
    loginctl enable-linger "${ROOTLESS_USER}" || {
        log_error "Failed to enable linger for Docker rootless user"
        exit 1
    }

    if [ "${rootless_already_installed}" != "true" ]; then
        if [ "${rootless_service_preexisting}" = "true" ] && [ -f "${ROOTLESS_SYSTEMD_SERVICE_FILE}" ]; then
            log_info "Removing stale Docker rootless user unit before re-running setup: ${ROOTLESS_SYSTEMD_SERVICE_FILE}"
            rm -f "${ROOTLESS_SYSTEMD_SERVICE_FILE}"
        fi

        run_rootless_user_command "dockerd-rootless-setuptool.sh --force install" || {
            log_error "Failed to initialize Docker rootless"
            exit 1
        }

        if [ -f "${ROOTLESS_SYSTEMD_SERVICE_FILE}" ]; then
            ROOTLESS_SYSTEMD_SERVICE_REUSE_ALLOWED=true
        elif [ "${rootless_service_preexisting}" = "true" ]; then
            ROOTLESS_SYSTEMD_SERVICE_NEEDS_REFRESH=true
        fi
    fi

    log_info "docker-rootless installation completed..."
}

configure_rootless_systemd() {
    log_step "Configuring rootless systemd"

    mkdir -p "${ROOTLESS_SYSTEMD_DIR}"
    mkdir -p "${ROOTLESS_SYSTEMD_OVERRIDE_DIR}"
    mkdir -p "${ROOTLESS_STORAGE_DIR}"

    write_rootless_docker_daemon_config

    if [ "${ROOTLESS_SYSTEMD_SERVICE_REUSE_ALLOWED}" = "true" ] && [ -f "${ROOTLESS_SYSTEMD_SERVICE_FILE}" ]; then
        log_info "Reusing existing Docker rootless user unit: ${ROOTLESS_SYSTEMD_SERVICE_FILE}"
    else
        if [ "${ROOTLESS_SYSTEMD_SERVICE_NEEDS_REFRESH}" = "true" ] && [ -f "${ROOTLESS_SYSTEMD_SERVICE_FILE}" ]; then
            rm -f "${ROOTLESS_SYSTEMD_SERVICE_FILE}"
        fi
        run_rootless_user_command 'dockerd-rootless.sh --copy-unit-file' || {
            log_error "Failed to refresh Docker rootless user unit"
            exit 1
        }
    fi

    cat > "${ROOTLESS_SYSTEMD_OVERRIDE_FILE}" << EOF
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd-rootless.sh --config-file ${ROOTLESS_DOCKER_DAEMON_JSON}
EOF

    chown -R "${ROOTLESS_USER}":"${ROOTLESS_USER}" "${ROOTLESS_DOCKER_CONF_DIR}" "${ROOTLESS_SYSTEMD_DIR}" "${ROOTLESS_STORAGE_DIR}"

    activate_rootless_docker_service || {
        log_error "Failed to activate Docker rootless user service"
        exit 1
    }

    log_info "Rootless systemd configuration completed..."
}

activate_rootless_docker_service() {
    run_rootless_user_command 'systemctl --user daemon-reload' || return 1
    run_rootless_user_command 'systemctl --user enable docker' || return 1
    run_rootless_user_command 'systemctl --user reset-failed docker' || true

    if run_rootless_user_command 'systemctl --user is-active --quiet docker'; then
        run_rootless_user_command 'systemctl --user restart docker' || return 1
    else
        run_rootless_user_command 'systemctl --user start docker' || return 1
    fi
}

verify_rootful_docker_service_active() {
    local description="$1"
    if ! systemctl is-active --quiet docker.service; then
        log_error "[ ] Docker service is not active before ${description}"
        return 1
    fi
}

verify_docker_rootful() {
    log_step "Verifying Docker rootful installation"

    local checks=0
    local passed=0
    local current_driver=""
    local expected_driver=""

    expected_driver="$(cld6001_expected_storage_driver "docker-rootful")" || return 1

    ((checks+=1)); if systemctl is-active --quiet docker.service; then
        ((passed+=1)); log_info "[x] Docker service is active"
    else
        log_error "[ ] Docker service is not active"
        return 1
    fi

    ((checks+=1))
    verify_rootful_docker_service_active "Docker version check" || return 1
    if docker version &>/dev/null; then
        ((passed+=1)); log_info "[x] Docker version check passed"
    else
        log_error "[ ] Docker version check failed"
    fi

    ((checks+=1))
    verify_rootful_docker_service_active "Docker info check" || return 1
    if docker info &>/dev/null; then
        ((passed+=1)); log_info "[x] Docker info check passed"
    else
        log_error "[ ] Docker info check failed"
    fi

    ((checks+=1))
    verify_rootful_docker_service_active "storage driver check" || return 1
    if current_driver="$(docker info --format '{{.Driver}}')"; then
        if cld6001_storage_driver_matches "docker-rootful" "${current_driver}"; then
            ((passed+=1)); log_info "[x] Storage driver is ${current_driver}"
        else
            log_error "[ ] Storage driver is ${current_driver}, expected ${expected_driver}"
        fi
    else
        log_error "[ ] Storage driver check failed"
    fi

    ((checks+=1))
    verify_rootful_docker_service_active "container smoke test" || return 1
    if cld6001_run_runtime_smoke_test docker &>/dev/null; then
        ((passed+=1)); log_info "[x] Container test passed"
    else
        log_error "[ ] Container test failed"
    fi

    local daemon_config="${DOCKER_CONF_DIR}/daemon.json"
    if [ -n "${PROFILE_JSON}" ] && { [ "${ACTION}" = "verify" ] || [ -f "${daemon_config}" ]; }; then
        if [ ! -f "${daemon_config}" ]; then
            ((checks+=1))
            log_error "[ ] Docker daemon config not found: ${daemon_config}"
        else
            local expected_no_new_privileges
            local expected_seccomp_profile
            local expected_live_restore
            local actual_no_new_privileges
            local actual_seccomp_profile
            local actual_live_restore

            expected_no_new_privileges="$(profile_value "$PROFILE_JSON" '.docker.no_new_privileges')"
            expected_seccomp_profile="$(profile_value "$PROFILE_JSON" '.docker.seccomp_profile')"
            expected_live_restore="$(profile_value "$PROFILE_JSON" '.docker.live_restore')"

            actual_no_new_privileges="$(read_docker_daemon_setting 'no-new-privileges')"
            ((checks+=1)); if [ "${actual_no_new_privileges}" = "${expected_no_new_privileges}" ]; then
                ((passed+=1)); log_info "[x] Docker daemon no-new-privileges matches profile ${PROFILE_NAME}"
            else
                log_error "[ ] Docker daemon config mismatch for profile ${PROFILE_NAME}: no-new-privileges is $(format_verify_value "${actual_no_new_privileges}"), expected $(format_verify_value "${expected_no_new_privileges}")"
            fi

            actual_seccomp_profile="$(read_docker_daemon_setting 'seccomp-profile' empty)"
            ((checks+=1)); if [ "${actual_seccomp_profile}" = "${expected_seccomp_profile}" ]; then
                ((passed+=1)); log_info "[x] Docker daemon seccomp-profile matches profile ${PROFILE_NAME}"
            else
                log_error "[ ] Docker daemon config mismatch for profile ${PROFILE_NAME}: seccomp-profile is $(format_verify_value "${actual_seccomp_profile}"), expected $(format_verify_value "${expected_seccomp_profile}")"
            fi

            actual_live_restore="$(read_docker_daemon_setting 'live-restore')"
            ((checks+=1)); if [ "${actual_live_restore}" = "${expected_live_restore}" ]; then
                ((passed+=1)); log_info "[x] Docker daemon live-restore matches profile ${PROFILE_NAME}"
            else
                log_error "[ ] Docker daemon config mismatch for profile ${PROFILE_NAME}: live-restore is $(format_verify_value "${actual_live_restore}"), expected $(format_verify_value "${expected_live_restore}")"
            fi
        fi
    fi

    log_info "docker-rootful verification: ${passed}/${checks} checks passed"

    if [ ${passed} -ne ${checks} ]; then
        return 1
    fi
    return 0
}

verify_docker_rootless() {
    log_step "Verifying Docker rootless installation"
    local current_driver=""
    local expected_driver=""
    local configured_driver=""
    local configured_data_root=""

    validate_rootless_user "${ROOTLESS_USER}" "docker-rootless" || return 1
    expected_driver="$(cld6001_expected_storage_driver "docker-rootless")" || return 1

    if run_rootless_user_command "systemctl --user status docker" &>/dev/null; then
        log_info "[x] Rootless Docker service is active"
    else
        log_error "[ ] Rootless Docker service is not active"
        return 1
    fi

    if run_rootless_user_command "/usr/bin/docker version" &>/dev/null; then
        log_info "[x] Rootless Docker version check passed"
    else
        log_error "[ ] Rootless Docker version check failed"
        return 1
    fi

    if current_driver="$(run_rootless_user_command "/usr/bin/docker info --format '{{.Driver}}'")"; then
        if cld6001_storage_driver_matches "docker-rootless" "${current_driver}"; then
            log_info "[x] Rootless Docker storage driver is ${current_driver}"
        else
            log_error "[ ] Rootless Docker storage driver is ${current_driver}, expected ${expected_driver}"
            return 1
        fi
    else
        log_error "[ ] Rootless Docker storage driver check failed"
        return 1
    fi

    if [ ! -f "${ROOTLESS_DOCKER_DAEMON_JSON}" ]; then
        log_error "[ ] Rootless Docker daemon config not found: ${ROOTLESS_DOCKER_DAEMON_JSON}"
        return 1
    fi

    configured_driver="$(read_rootless_docker_daemon_setting 'storage-driver')"
    if [ "${configured_driver}" = "${expected_driver}" ]; then
        log_info "[x] Rootless Docker daemon config storage-driver matches ${expected_driver}"
    else
        log_error "[ ] Rootless Docker daemon config storage-driver is $(format_verify_value "${configured_driver}"), expected $(format_verify_value "${expected_driver}")"
        return 1
    fi

    configured_data_root="$(read_rootless_docker_daemon_setting 'data-root')"
    if [ "${configured_data_root}" = "${ROOTLESS_STORAGE_DIR}" ]; then
        log_info "[x] Rootless Docker daemon config data-root matches ${ROOTLESS_STORAGE_DIR}"
    else
        log_error "[ ] Rootless Docker daemon config data-root is $(format_verify_value "${configured_data_root}"), expected $(format_verify_value "${ROOTLESS_STORAGE_DIR}")"
        return 1
    fi

    if grep -Fq -- "--config-file ${ROOTLESS_DOCKER_DAEMON_JSON}" "${ROOTLESS_SYSTEMD_OVERRIDE_FILE}" 2>/dev/null; then
        log_info "[x] Rootless Docker systemd override pins ${ROOTLESS_DOCKER_DAEMON_JSON}"
    else
        log_error "[ ] Rootless Docker systemd override missing expected config-file: ${ROOTLESS_SYSTEMD_OVERRIDE_FILE}"
        return 1
    fi

    log_info "docker-rootless verification completed"
}

verify_installation() {
    log_step "Verifying all Docker configurations"

    if [ "${MODE}" = "rootful" ] || [ "${MODE}" = "both" ]; then
        verify_docker_rootful || log_warn "Rootful verification failed"
    fi

    if [ "${MODE}" = "rootless" ] || [ "${MODE}" = "both" ]; then
        verify_docker_rootless || log_warn "Rootless verification failed"
    fi

    log_step "Installation Summary"
    echo "---"
    echo "Mode:              ${MODE}"
    echo "Profile:           ${PROFILE_NAME:-n/a}"
    echo "Research overlay:  ${RESEARCH_OVERLAY:-n/a}"
    echo "Errors:            ${ERRORS}"
    echo "Warnings:          ${WARNINGS}"
    echo "Log file:          ${LOG_FILE}"
    echo "Rollback state:    ${ROLLBACK_STATE_FILE}"
    echo "---"
}

main() {
    validate_action_contract || exit 1

    mkdir -p /var/log
    touch "${LOG_FILE}"

    log_step "Docker Installation - ${ACTION}"
    log_info "Mode: ${MODE}"
    if [ -n "${PROFILE_NAME}" ]; then
        log_info "Profile: ${PROFILE_NAME}"
    fi
    if [ -n "${RESEARCH_OVERLAY}" ]; then
        log_info "Research overlay: ${RESEARCH_OVERLAY}"
    fi
    log_info "Date: ${SCRIPT_DATE}"
    log_info "Version: ${SCRIPT_VERSION}"

    check_root
    if [ "${ACTION}" = "install" ] || [ "${ACTION}" = "verify" ]; then
        load_selected_profile || exit 1
    fi
    check_os
    check_dependencies

    if [ "${ACTION}" != "rollback" ]; then
        save_state
    fi

    case "${ACTION}" in
        install)
            if [ "${MODE}" = "rootful" ] || [ "${MODE}" = "both" ]; then
                configure_kernel
                configure_ulimits
                configure_selinux
                configure_storage

                install_docker_rootful
                configure_docker_daemon
            fi

            if [ "${MODE}" = "rootless" ] || [ "${MODE}" = "both" ]; then
                install_docker_rootless
                configure_rootless_systemd
            fi

                    verify_installation
            ;;

        verify)
            verify_installation
            ;;

        rollback)
            rollback_docker
            ;;

        *)
            print_usage
            exit 1
            ;;
    esac

    if [ ${ERRORS} -gt 0 ]; then
        log_error "Installation completed with ${ERRORS} errors"
        exit 1
    fi

    log_info "Installation completed successfully"
    exit 0
}

if [ "${BASH_SOURCE[0]}" == "$0" ]; then
    parse_args "$@"
    main "$@"
fi
