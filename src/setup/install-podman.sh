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

    if user_home="$(getent passwd "${user}" 2>/dev/null | cut -d: -f6)" && [ -n "${user_home}" ]; then
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

resolve_rootless_containers_runroot() {
    printf '%s/containers\n' "$(resolve_rootless_state_dir)"
}

readonly SCRIPT_NAME="install-podman"
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DATE="2026-05-16"
readonly RESEARCH_LABEL="cld6001.research.managed=true"
readonly CONTAINER_SELINUX_SCRIPT="${SCRIPT_ROOT}/configure-container-selinux.sh"

readonly PODMAN_CONF_DIR="${PODMAN_CONF_DIR:-/etc/containers}"
readonly PODMAN_CONF_FILE="${PODMAN_CONF_FILE:-/etc/containers/storage.conf}"
readonly PODMAN_POLICY_FILE="${PODMAN_POLICY_FILE:-/etc/containers/policy.json}"
readonly PODMAN_CONTAINERS_CONF="${PODMAN_CONTAINERS_CONF:-${PODMAN_CONF_DIR}/containers.conf.d/50-profile.conf}"
readonly PODMAN_SYSTEMD_DIR="/etc/systemd/system"
readonly PODMAN_STORAGE_DRIVER="$(cld6001_expected_storage_driver "podman-rootful")"
readonly PODMAN_STORAGE_ROOT="/var/lib/containers/storage"

readonly ROOTLESS_USER="$(resolve_preferred_user "${PODMAN_ROOTLESS_USER:-}")"
readonly ROOTLESS_HOME="$(resolve_user_home "${ROOTLESS_USER}")"
readonly ROOTLESS_STORAGE_DIR="${ROOTLESS_HOME}/.local/share/containers/storage"
readonly SUBID_BLOCK_SIZE=65536
readonly SUBID_MIN_START=65536
readonly SUBUID_FILE="${SUBUID_FILE:-/etc/subuid}"
readonly SUBGID_FILE="${SUBGID_FILE:-/etc/subgid}"

readonly PODMAN_PACKAGES=(
    "podman"
    "containers-common"
    "buildah"
    "crun"
    "slirp4netns"
    "fuse-overlayfs"
    "fuse3"
    "netavark"
    "aardvark-dns"
    "skopeo"
    "catatonit"
)

readonly PODMAN_TOOLS=(
    "podman-docker"
    "podman-compose"
    "docker-compose"
    "buildah"
    "skopeo"
)

readonly KERNEL_PARAMETERS=(
    "net.ipv4.ip_forward=1"
    "net.bridge.bridge-nf-call-iptables=1"
    "net.bridge.bridge-nf-call-ip6tables=1"
)

readonly CGROUP_VERSION="2"
readonly PODMAN_CGROUPS_BASE="/podman"

readonly PODMAN_NOFILE=65536
readonly PODMAN_NPROC=65536

RUN_ID="${CLD6001_RUN_ID:-standalone}"

readonly ROLLBACK_BASE_DIR="${CLD6001_ROLLBACK_BASE_DIR:-/var/lib/cld6001/${RUN_ID}/${SCRIPT_NAME}-rollback}"
readonly ROLLBACK_DIR="${CLD6001_ROLLBACK_DIR:-${ROLLBACK_BASE_DIR}/snapshot}"
readonly ROLLBACK_ARCHIVE_DIR="${CLD6001_ROLLBACK_ARCHIVE_DIR:-${ROLLBACK_BASE_DIR}/archives}"
readonly ROLLBACK_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly ROLLBACK_STATE_FILE="${ROLLBACK_ARCHIVE_DIR}/state_${ROLLBACK_TIMESTAMP}.tar.gz"

ACTION="install"
PROFILE_NAME=""
RESEARCH_OVERLAY=""
PROFILE_JSON=""
LOG_DIR=""
LOG_FILE=""
ERRORS=0
WARNINGS=0

initialize_log_paths() {
    cld6001_initialize_installer_log_paths "$RUN_ID" "$SCRIPT_NAME" "$ACTION" "$ROLLBACK_TIMESTAMP"
}

log() {
    local level="$1"
    shift
    cld6001_installer_log "$level" "setup" "podman" "$SCRIPT_NAME" "$LOG_FILE" "$@"
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
    cld6001_installer_log_step "${BLUE}" "${NC}" "setup" "podman" "$SCRIPT_NAME" "$LOG_FILE" "$@"
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

align_subid_block_start() {
    local value="$1"
    printf '%s\n' $(( ((value + SUBID_BLOCK_SIZE - 1) / SUBID_BLOCK_SIZE) * SUBID_BLOCK_SIZE ))
}

parse_subid_file() {
    local file="$1"
    local user="$2"
    local label="$3"
    local starts_ref_name="$4"
    local counts_ref_name="$5"
    local names_ref_name="$6"
    local target_start_ref_name="$7"
    local -n starts_ref="${starts_ref_name}"
    local -n counts_ref="${counts_ref_name}"
    local -n names_ref="${names_ref_name}"
    local -n target_start_ref="${target_start_ref_name}"
    local raw_line=""
    local name=""
    local start=""
    local count=""
    local extra=""
    local index=0
    local previous_start=0
    local previous_count=0
    local previous_name=""

    starts_ref=()
    counts_ref=()
    names_ref=()
    target_start_ref=""

    if [ ! -e "${file}" ]; then
        : > "${file}" || {
            log_error "Could not create ${label} mapping file: ${file}"
            return 1
        }
    fi

    while IFS= read -r raw_line || [ -n "${raw_line}" ]; do
        [[ "${raw_line}" =~ ^[[:space:]]*$ ]] && continue
        [[ "${raw_line}" =~ ^[[:space:]]*# ]] && continue

        IFS=: read -r name start count extra <<< "${raw_line}"
        if [ -n "${extra:-}" ] || [ -z "${name:-}" ] || [ -z "${start:-}" ] || [ -z "${count:-}" ]; then
            log_error "Invalid ${label} entry in ${file}: ${raw_line}"
            return 1
        fi

        [[ "${start}" =~ ^[0-9]+$ ]] || {
            log_error "Invalid ${label} start in ${file}: ${raw_line}"
            return 1
        }
        [[ "${count}" =~ ^[0-9]+$ ]] || {
            log_error "Invalid ${label} count in ${file}: ${raw_line}"
            return 1
        }
        (( count > 0 )) || {
            log_error "Invalid ${label} count in ${file}: ${raw_line}"
            return 1
        }

        if [ "${name}" = "${user}" ] && [ -n "${target_start_ref}" ]; then
            log_error "Conflicting ${label} entries for ${user} in ${file}"
            return 1
        fi

        for index in "${!starts_ref[@]}"; do
            previous_start="${starts_ref[${index}]}"
            previous_count="${counts_ref[${index}]}"
            previous_name="${names_ref[${index}]}"

            if (( start < previous_start + previous_count && previous_start < start + count )); then
                log_error "Detected overlapping ${label} allocations in ${file}: ${previous_name}:${previous_start}:${previous_count} overlaps ${name}:${start}:${count}"
                return 1
            fi
        done

        if [ "${name}" = "${user}" ]; then
            if (( count != SUBID_BLOCK_SIZE )) || (( start < SUBID_MIN_START )) || (( start % SUBID_BLOCK_SIZE != 0 )); then
                log_error "Existing ${label} entry for ${user} in ${file} must use an aligned ${SUBID_BLOCK_SIZE} block"
                return 1
            fi
            target_start_ref="${start}"
        fi

        starts_ref+=("${start}")
        counts_ref+=("${count}")
        names_ref+=("${name}")
    done < "${file}"
}

subid_block_is_free() {
    local candidate="$1"
    local starts_ref_name="$2"
    local counts_ref_name="$3"
    local -n starts_ref="${starts_ref_name}"
    local -n counts_ref="${counts_ref_name}"
    local index=0
    local start=0
    local count=0

    for index in "${!starts_ref[@]}"; do
        start="${starts_ref[${index}]}"
        count="${counts_ref[${index}]}"

        if (( candidate < start + count && start < candidate + SUBID_BLOCK_SIZE )); then
            return 1
        fi
    done

    return 0
}

next_free_subid_candidate() {
    local candidate="$1"
    local starts_ref_name="$2"
    local counts_ref_name="$3"
    local -n starts_ref="${starts_ref_name}"
    local -n counts_ref="${counts_ref_name}"
    local index=0
    local start=0
    local count=0
    local next_candidate="${candidate}"
    local candidate_end=$((candidate + SUBID_BLOCK_SIZE))
    local range_end=0
    local aligned_end=0

    for index in "${!starts_ref[@]}"; do
        start="${starts_ref[${index}]}"
        count="${counts_ref[${index}]}"
        range_end=$((start + count))

        if (( candidate < range_end && start < candidate_end )); then
            aligned_end="$(align_subid_block_start "${range_end}")"
            if (( aligned_end > next_candidate )); then
                next_candidate="${aligned_end}"
            fi
        fi
    done

    printf '%s\n' "${next_candidate}"
}

configure_rootless_subid_mappings() {
    local -a subuid_starts=()
    local -a subuid_counts=()
    local -a subuid_names=()
    local -a subgid_starts=()
    local -a subgid_counts=()
    local -a subgid_names=()
    local subuid_existing_start=""
    local subgid_existing_start=""
    local selected_start=""
    local next_subuid_candidate=0
    local next_subgid_candidate=0

    parse_subid_file "${SUBUID_FILE}" "${ROOTLESS_USER}" "subuid" subuid_starts subuid_counts subuid_names subuid_existing_start || return 1
    parse_subid_file "${SUBGID_FILE}" "${ROOTLESS_USER}" "subgid" subgid_starts subgid_counts subgid_names subgid_existing_start || return 1

    if [ -n "${subuid_existing_start}" ] && [ -n "${subgid_existing_start}" ]; then
        if [ "${subuid_existing_start}" != "${subgid_existing_start}" ]; then
            log_error "Existing subordinate id mappings for ${ROOTLESS_USER} do not match between ${SUBUID_FILE} and ${SUBGID_FILE}"
            return 1
        fi

        selected_start="${subuid_existing_start}"
    elif [ -n "${subuid_existing_start}" ]; then
        subid_block_is_free "${subuid_existing_start}" subgid_starts subgid_counts || {
            log_error "Existing subuid entry for ${ROOTLESS_USER} conflicts with allocations in ${SUBGID_FILE}"
            return 1
        }
        selected_start="${subuid_existing_start}"
    elif [ -n "${subgid_existing_start}" ]; then
        subid_block_is_free "${subgid_existing_start}" subuid_starts subuid_counts || {
            log_error "Existing subgid entry for ${ROOTLESS_USER} conflicts with allocations in ${SUBUID_FILE}"
            return 1
        }
        selected_start="${subgid_existing_start}"
    else
        selected_start="${SUBID_MIN_START}"
        while :; do
            if subid_block_is_free "${selected_start}" subuid_starts subuid_counts && \
                subid_block_is_free "${selected_start}" subgid_starts subgid_counts; then
                break
            fi

            next_subuid_candidate="$(next_free_subid_candidate "${selected_start}" subuid_starts subuid_counts)"
            next_subgid_candidate="$(next_free_subid_candidate "${selected_start}" subgid_starts subgid_counts)"
            if (( next_subuid_candidate > next_subgid_candidate )); then
                selected_start="${next_subuid_candidate}"
            else
                selected_start="${next_subgid_candidate}"
            fi
        done
    fi

    if [ -z "${subuid_existing_start}" ]; then
        printf '%s:%s:%s\n' "${ROOTLESS_USER}" "${selected_start}" "${SUBID_BLOCK_SIZE}" >> "${SUBUID_FILE}"
    fi
    if [ -z "${subgid_existing_start}" ]; then
        printf '%s:%s:%s\n' "${ROOTLESS_USER}" "${selected_start}" "${SUBID_BLOCK_SIZE}" >> "${SUBGID_FILE}"
    fi

    log_info "Using subordinate id block ${selected_start}:${SUBID_BLOCK_SIZE} for ${ROOTLESS_USER}"
}

parse_args() {
    cld6001_reset_installer_parse_state ACTION PROFILE_NAME RESEARCH_OVERLAY PROFILE_JSON LOG_DIR LOG_FILE
    local action_seen=0

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

load_selected_profile() {
    [ -n "$PROFILE_NAME" ] || {
        log_error "Missing required --profile"
        return 1
    }

    PROFILE_JSON="$(load_profile_json "$PROFILE_NAME")" || return 1
    profile_supports "$PROFILE_JSON" podman rootless | grep -qx 'true' || {
        log_error "Profile ${PROFILE_NAME} does not support podman/rootless"
        return 1
    }

    if [ -n "$RESEARCH_OVERLAY" ] && ! profile_allows_overlay "$PROFILE_JSON" "$RESEARCH_OVERLAY"; then
        log_error "Profile ${PROFILE_NAME} does not allow research overlay ${RESEARCH_OVERLAY}"
        return 1
    fi
}

validate_action_contract() {
    case "${ACTION}" in
        verify|rollback)
            [ -z "${RESEARCH_OVERLAY}" ] || {
                log_error "${ACTION} does not accept --research-overlay"
                return 1
            }
            ;;
    esac
}

write_podman_policy_json() {
    local policy_mode
    policy_mode="$(profile_value "$PROFILE_JSON" '.podman.policy_mode')"

    case "$policy_mode" in
        permissive)
            cat > "${PODMAN_POLICY_FILE}" <<'EOF'
{
    "default": [{"type": "insecureAcceptAnything"}],
    "transports": {
        "docker-daemon": {
            "": [{"type": "insecureAcceptAnything"}]
        }
    }
}
EOF
            ;;
        restricted)
            cat > "${PODMAN_POLICY_FILE}" <<'EOF'
{
    "default": [{"type": "reject"}],
    "transports": {
        "docker": {
            "docker.io": [{"type": "insecureAcceptAnything"}],
            "quay.io": [{"type": "insecureAcceptAnything"}]
        },
        "docker-daemon": {
            "": [{"type": "insecureAcceptAnything"}]
        }
    }
}
EOF
            ;;
        *)
            log_error "Unsupported podman policy_mode: ${policy_mode}"
            return 1
            ;;
    esac

    chmod 644 "${PODMAN_POLICY_FILE}"
}

write_podman_containers_conf() {
    local seccomp_profile
    local pids_limit

    seccomp_profile="$(profile_value "$PROFILE_JSON" '.podman.seccomp_profile')"
    pids_limit="$(profile_value "$PROFILE_JSON" '.podman.pids_limit')"

    mkdir -p -- "$(dirname -- "${PODMAN_CONTAINERS_CONF}")"
    chmod 755 "$(dirname -- "${PODMAN_CONTAINERS_CONF}")"
    cat > "${PODMAN_CONTAINERS_CONF}" <<EOF
# Generated by install-podman.sh - profile-managed runtime settings
[containers]
pids_limit = ${pids_limit}
seccomp_profile = "${seccomp_profile}"

[engine]
EOF
    chmod 644 "${PODMAN_CONTAINERS_CONF}"
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
        dnf install -y "${missing[@]}" || {
            log_error "Failed to install dependencies"
            exit 1
        }
    fi
}

check_cgroup_version() {
    if host_has_unified_cgroup_v2; then
        log_info "CGroup version 2 is available"
    else
        log_warn "CGroup version 2 not detected, some features may not work"
    fi
}

detect_cgroup_root_fs_type() {
    stat -fc %T /sys/fs/cgroup 2>/dev/null || true
}

host_has_unified_cgroup_v2() {
    local fs_type=""

    fs_type="$(detect_cgroup_root_fs_type)"
    if [ "${fs_type}" = "cgroup2fs" ]; then
        return 0
    fi

    if grep -Eq '^[^[:space:]]+[[:space:]]+/sys/fs/cgroup[[:space:]]+cgroup2[[:space:]]' /proc/mounts 2>/dev/null; then
        return 0
    fi

    awk '
        $5 == "/sys/fs/cgroup" {
            found_mount = 1
            for (i = 1; i <= NF; i++) {
                if ($i == "-") {
                    if ((i + 1) <= NF && $(i + 1) == "cgroup2") {
                        found_cgroup2 = 1
                    }
                    break
                }
            }
        }
        END {
            exit !(found_mount && found_cgroup2)
        }
    ' /proc/self/mountinfo 2>/dev/null
}

podman_cgroup_version() {
    podman info --format '{{.Host.CgroupsVersion}}' 2>/dev/null || true
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

save_state() {
    log_step "Saving system state for rollback"

    mkdir -p "${ROLLBACK_DIR}"

    dnf list installed > "${ROLLBACK_DIR}/packages_before.txt" 2>/dev/null || true

    if [ -d "${PODMAN_CONF_DIR}" ]; then
        cp -r "${PODMAN_CONF_DIR}" "${ROLLBACK_DIR}/podman_conf_backup/" 2>/dev/null || true
    fi

    sysctl -a > "${ROLLBACK_DIR}/sysctl_before.txt" 2>/dev/null || true

    iptables-save > "${ROLLBACK_DIR}/iptables_before.txt" 2>/dev/null || true

    create_rollback_archive 2>/dev/null || {
        log_warn "Could not create rollback backup tarball"
    }

    log_info "Rollback state saved to: ${ROLLBACK_STATE_FILE}"
}

rollback_podman() {
    log_step "Rolling back Podman installation"

    log_info "Stopping all Podman containers..."
    podman stop -a -t 30 2>/dev/null || true

    log_info "Removing all Podman containers..."
    podman rm -f -a 2>/dev/null || true

    systemctl disable --now podman.socket podman.service 2>/dev/null || true
    systemctl disable --now buildah.service 2>/dev/null || true

    log_info "Removing Podman packages..."
    for pkg in "${PODMAN_PACKAGES[@]}" "${PODMAN_TOOLS[@]}"; do
        dnf remove -y "$pkg" 2>/dev/null || true
    done

    if [ -t 0 ]; then
        read -r -p "Remove Podman data and state? [N/y]: " -n 1
        echo
        case "${REPLY:-}" in
            [Yy])
                log_info "Removing Podman data..."
                rm -rf "${PODMAN_STORAGE_ROOT}"
                remove_matching_paths_if_any "/home/*/.config/containers"
                remove_matching_paths_if_any "/home/*/.local/share/containers"
                ;;
        esac
    fi

    if [ -f "${ROLLBACK_DIR}/sysctl_before.txt" ]; then
        restore_saved_sysctl_value "${ROLLBACK_DIR}/sysctl_before.txt" "net.ipv4.ip_forward" || true
    else
        log_warn "Could not restore kernel parameters; rollback snapshot is missing"
    fi

    podman network prune -f 2>/dev/null || true

    log_info "Podman rollback completed..."
}

configure_kernel() {
    log_step "Configuring kernel parameters"

    modprobe overlay &>/dev/null || true
    modprobe br_netfilter &>/dev/null || true

    cat > /etc/sysctl.d/99-podman.conf << 'EOF'
# Container security research - Podman kernel parameters
# Generated by install-podman.sh
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-arptables = 1

kernel.memory_failure_early_kill = 0
kernel.panic_on_oops = 1
kernel.panic = 0
kernel.randomize_va_space = 2

net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.tcp_syncookies = 1
EOF

    sysctl --system

    log_info "Kernel parameters configured for Podman..."
}

configure_cgroups() {
    log_step "Configuring CGroups for Podman"

    cat > /etc/systemd/system/podman-cgroup-manager.service << 'EOF'
[Unit]
Description=Podman CGroup Manager
After=systemd-udevd.service
Wants=network.target

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

    mkdir -p /etc/systemd/system/user@.service.d
    cat > /etc/systemd/system/user@.service.d/cgroup-delegate.conf << 'EOF'
[Service]
Delegate=cgroup_blkio cgroup_cpu cgroup_cpuacct cgroup_cpuset cgroup_devices cgroup_hugetlb cgroup_memory cgroup_pids cgroup_perf_event cgroup_net_cls cgroup_net_prio cgroup_net_prio cgroup_freezer cgroup_net_cls cgroup_net_prio cgroup_pids cgroup_devices cgroup_memory cgroup_cpu cgroup_cpuacct cgroup_cpu cgroup_cpu cgroup_cpu
DelegateYes=true
EOF

    systemctl daemon-reload

    log_info "CGroups configured for Podman..."
}

configure_selinux() {
    CONTAINER_SELINUX_LOG_FILE="${LOG_FILE}" \
        bash "${CONTAINER_SELINUX_SCRIPT}" package-only
    log_info "Podman SELinux package configuration owned by configure-container-selinux.sh"
}

configure_storage() {
    log_step "Configuring storage for Podman"

    mkdir -p "${PODMAN_STORAGE_ROOT}"
    chmod 700 "${PODMAN_STORAGE_ROOT}"

    if [ ! -f "${PODMAN_CONF_FILE}" ] || ! grep -q "# generated by install-podman.sh" "${PODMAN_CONF_FILE}"; then
        mkdir -p "$(dirname -- "${PODMAN_CONF_FILE}")"
        cat > "${PODMAN_CONF_FILE}" << EOF
# Generated by install-podman.sh - Container Security Research
# Podman storage configuration for AlmaLinux 10.1

[storage]
driver = "${PODMAN_STORAGE_DRIVER}"
graphroot = "${PODMAN_STORAGE_ROOT}"
runroot = "/run/containers/storage"

[storage.options]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "nodev,metacopy=on"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "nodev,metacopy=on"
EOF
    fi

    log_info "Storage configuration completed..."
}

configure_network() {
    log_step "Configuring network for Podman"

    mkdir -p /etc/containers

    cat > /etc/containers/netavark.conf << 'EOF'
{
    "network_backend": "netavark",
    "firewall_backend": "iptables",
    "firewall_enabled": true,
    "dns": {
        "servers": ["1.1.1.1", "8.8.8.8"],
        "search": []
    },
    "networks": {
        "podman": {
            "driver": "bridge",
            "ipam_driver": "host-local",
            "ipam_options": {
                "driver": "default"
            },
            "ipam_config": [
                {
                    "subnet": "10.89.0.0/24"
                }
            ],
            "gateway_enabled": true,
            "gateway_config": {
                "enabled": true
            }
        }
    }
}
EOF

    if ! iptables -L FORWARD -n | grep -q "FORWARD.*DOCKER" 2>/dev/null; then
        iptables -A FORWARD -d 10.89.0.0/24 -j ACCEPT
        iptables -A FORWARD -s 10.89.0.0/24 -j ACCEPT
        iptables -A FORWARD -i cni+ -j ACCEPT
        iptables -A FORWARD -o cni+ -j ACCEPT
    fi

    log_info "Network configuration completed..."
}

configure_security_policy() {
    log_step "Configuring security policy"

    write_podman_policy_json || return 1
    write_podman_containers_conf || return 1

    log_info "Security policy configured..."
}

install_podman() {
    log_step "Installing Podman"

    if command -v podman &>/dev/null && podman --version &>/dev/null; then
        log_warn "Podman command is already present; ensuring packages are fully installed"
    fi

    log_info "Installing Podman packages..."
    dnf install -y "${PODMAN_PACKAGES[@]}" || {
        log_error "Failed to install Podman packages"
        exit 1
    }

    log_info "Installing additional tools..."
    dnf install -y "${PODMAN_TOOLS[@]}" 2>/dev/null || {
        log_warn "Some optional tools may not be installed"
    }

    systemctl enable podman.socket podman.service 2>/dev/null || true
    systemctl start podman.socket podman.service 2>/dev/null || true

    configure_rootless_user

    verify_podman || {
        log_error "Podman verification failed"
        exit 1
    }

    log_info "Podman installation completed successfully"
}

configure_rootless_user() {
    log_step "Configuring rootless Podman for user: ${ROOTLESS_USER}"
    local rootless_storage_parent=""
    local rootless_runroot=""

    validate_rootless_user "${ROOTLESS_USER}" "podman rootless" || return 1

    if ! id "${ROOTLESS_USER}" &>/dev/null; then
        log_info "Creating rootless user: ${ROOTLESS_USER}..."
        useradd -m -s /bin/bash "${ROOTLESS_USER}"
    fi

    rootless_storage_parent="$(dirname -- "${ROOTLESS_STORAGE_DIR}")"
    mkdir -p "${ROOTLESS_STORAGE_DIR}"
    chown -R "${ROOTLESS_USER}":"${ROOTLESS_USER}" "${rootless_storage_parent}"
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -RF "${rootless_storage_parent}" 2>/dev/null || {
            log_warn "Could not restore SELinux labels for ${rootless_storage_parent}"
        }
    fi

    mkdir -p "${ROOTLESS_HOME}/.config/containers"
    chown -R "${ROOTLESS_USER}":"${ROOTLESS_USER}" "${ROOTLESS_HOME}/.config"

    rootless_runroot="$(resolve_rootless_containers_runroot)"
    cat > "${ROOTLESS_HOME}/.config/containers/storage.conf" << EOF
# Generated by install-podman.sh
[storage]
driver = "overlay"
graphroot = "${ROOTLESS_STORAGE_DIR}"
runroot = "${rootless_runroot}"
EOF

    chown "${ROOTLESS_USER}":"${ROOTLESS_USER}" \
        "${ROOTLESS_HOME}/.config/containers/storage.conf"

    su - "${ROOTLESS_USER}" -c 'systemctl --user enable --now podman' 2>/dev/null || {
        log_warn "Could not enable rootless Podman service"
    }

    su - "${ROOTLESS_USER}" -c 'podman network create --driver bridge podman-rootless-net' 2>/dev/null || {
        log_warn "Could not create rootless Podman network"
    }

    configure_rootless_subid_mappings || return 1

    mkdir -p "${ROOTLESS_HOME}/.local/bin"
    chown -R "${ROOTLESS_USER}":"${ROOTLESS_USER}" "${ROOTLESS_HOME}/.local"

    if ! command -v docker >/dev/null 2>&1; then
        su - "${ROOTLESS_USER}" -c 'ln -sf "$(command -v podman)" ~/.local/bin/docker' 2>/dev/null || {
            log_warn "Could not create docker symlink"
        }
    else
        log_info "Skipping docker compatibility symlink because Docker CLI already exists"
    fi

    log_info "Rootless Podman configuration completed..."
}

container_selinux_policy_installed() {
    if ! command -v semodule &>/dev/null; then
        return 1
    fi

    semodule -l 2>/dev/null | awk '{print $1}' | grep -Eq '^(container|container-rootless|container-research)$'
}

verify_podman() {
    log_step "Verifying Podman installation"

    local checks=0
    local passed=0
    local hard_failures=0
    local current_driver=""
    local expected_driver=""
    local podman_cgroups_version=""

    expected_driver="$(cld6001_expected_storage_driver "podman-rootful")" || return 1
    podman_cgroups_version="$(podman_cgroup_version)"

    ((checks+=1)); if podman --version &>/dev/null; then
        ((passed+=1)); log_info "[x] Podman version check passed"
    else
        log_error "[ ] Podman version check failed"
    fi

    ((checks+=1)); if podman info &>/dev/null; then
        ((passed+=1)); log_info "[x] Podman info check passed"
    else
        log_error "[ ] Podman info check failed"
    fi

    ((checks+=1)); current_driver="$(podman info --format '{{.Store.GraphDriverName}}')"
    if cld6001_storage_driver_matches "podman-rootful" "${current_driver}"; then
        ((passed+=1)); log_info "[x] Storage driver is ${current_driver}"
    else
        ((hard_failures+=1)); log_error "[ ] Storage driver is ${current_driver}, expected ${expected_driver}"
    fi

    ((checks+=1)); if host_has_unified_cgroup_v2 || [ "${podman_cgroups_version}" = "v2" ]; then
        ((passed+=1)); log_info "[x] CGroup version 2 is available"
    else
        log_warn "[ ] CGroup version 2 not fully available"
    fi

    ((checks+=1)); if cld6001_run_runtime_smoke_test podman &>/dev/null; then
        ((passed+=1)); log_info "[x] Container test passed"
    else
        log_error "[ ] Container test failed"
    fi

    ((checks+=1)); if podman network list &>/dev/null; then
        ((passed+=1)); log_info "[x] Network check passed"
    else
        log_error "[ ] Network check failed"
    fi

    ((checks+=1)); if command -v getenforce >/dev/null 2>&1 && getenforce 2>/dev/null | grep -iq '^enforcing$'; then
        ((passed+=1)); log_info "[x] SELinux is in Enforcing mode"
    else
        log_warn "[ ] SELinux not in Enforcing mode"
    fi

    ((checks+=1)); if container_selinux_policy_installed; then
        ((passed+=1)); log_info "[x] Container SELinux policy configured"
    else
        log_warn "[ ] Container SELinux policy not configured"
    fi

    log_info "Podman verification: ${passed}/${checks} checks passed"

    if [ ${hard_failures} -gt 0 ] || [ ${passed} -lt 4 ]; then
        return 1
    fi
    return 0
}

verify_rootless() {
    log_step "Verifying rootless Podman"
    local rootless_state_dir=""
    local current_driver=""
    local expected_driver=""

    validate_rootless_user "${ROOTLESS_USER}" "podman rootless" || return 1
    rootless_state_dir="$(resolve_rootless_state_dir)"
    expected_driver="$(cld6001_expected_storage_driver "podman-rootless")" || return 1

    if su - "${ROOTLESS_USER}" -c "export PATH=/usr/bin:/bin:\$PATH; export XDG_RUNTIME_DIR='${rootless_state_dir}'; podman --version" &>/dev/null; then
        log_info "[x] Rootless Podman version check passed"
    else
        log_error "[ ] Rootless Podman version check failed"
        return 1
    fi

    if current_driver="$(su - "${ROOTLESS_USER}" -c "export PATH=/usr/bin:/bin:\$PATH; export XDG_RUNTIME_DIR='${rootless_state_dir}'; podman info --format '{{.Store.GraphDriverName}}'")"; then
        if cld6001_storage_driver_matches "podman-rootless" "${current_driver}"; then
            log_info "[x] Rootless Podman storage driver is ${current_driver}"
        else
            log_error "[ ] Rootless Podman storage driver is ${current_driver}, expected ${expected_driver}"
            return 1
        fi
    else
        log_error "[ ] Rootless Podman storage driver check failed"
        return 1
    fi

    if su - "${ROOTLESS_USER}" -c "export PATH=/usr/bin:/bin:\$PATH; export XDG_RUNTIME_DIR='${rootless_state_dir}'; $(cld6001_runtime_smoke_test_shell_command podman)" &>/dev/null; then
        log_info "[x] Rootless container test passed"
    else
        log_error "[ ] Rootless container test failed"
        return 1
    fi

    log_info "Rootless Podman verification completed"
}

verify_installation() {
    log_step "Verifying all Podman configurations"

    verify_podman || log_warn "Podman verification failed"
    verify_rootless || log_warn "Rootless verification failed"

    log_step "Installation Summary"
    echo "---"
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

    log_step "Podman Installation - ${ACTION}"
    if [ -n "${PROFILE_NAME}" ]; then
        log_info "Profile: ${PROFILE_NAME}"
    fi
    if [ -n "${RESEARCH_OVERLAY}" ]; then
        log_info "Research overlay: ${RESEARCH_OVERLAY}"
    fi
    log_info "Date: ${SCRIPT_DATE}"
    log_info "Version: ${SCRIPT_VERSION}"

    check_root
    if [ "${ACTION}" = "install" ]; then
        load_selected_profile || exit 1
    fi
    check_os
    check_dependencies
    check_cgroup_version

    save_state

    case "${ACTION}" in
        install)
            configure_kernel
            configure_cgroups
            configure_selinux
            configure_storage
            configure_network
            configure_security_policy

            install_podman

                    verify_installation
            ;;

        verify)
            verify_installation
            ;;

        rollback)
            rollback_podman
            ;;

        *)
            echo "Usage: $0 {install|verify|rollback}"
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
