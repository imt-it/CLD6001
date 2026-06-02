#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

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

readonly SCRIPT_NAME="setup-infrastructure"
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DATE="2026-05-16"
readonly RESEARCH_LABEL="cld6001.research.managed=true"
readonly SELINUX_RESEARCH_OVERLAY="selinux-research-policy"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../profiles/profile-adapter.sh"
source "${SCRIPT_DIR}/../../src/shared/terminal-colors.sh"
source "${SCRIPT_DIR}/../../src/shared/log-pipe.sh"
source "${SCRIPT_DIR}/../../src/shared/network-capture-helpers.sh"
source "${SCRIPT_DIR}/../../src/shared/runtime-smoke-test-helpers.sh"
source "${SCRIPT_DIR}/../../src/shared/sysctl-helpers.sh"
readonly CONTAINER_SELINUX_SCRIPT="${SCRIPT_DIR}/configure-container-selinux.sh"
readonly DOCKER_INSTALL_SCRIPT="${SCRIPT_DIR}/install-docker.sh"
readonly PODMAN_INSTALL_SCRIPT="${SCRIPT_DIR}/install-podman.sh"

readonly CONTAINER_USER="$(resolve_preferred_user "${CONTAINER_USER:-}")"
readonly ENABLE_DOCKER_ROOTFUL="${ENABLE_DOCKER_ROOTFUL:-yes}"
readonly ENABLE_DOCKER_ROOTLESS="${ENABLE_DOCKER_ROOTLESS:-yes}"
readonly ENABLE_PODMAN="${ENABLE_PODMAN:-yes}"
readonly ENABLE_SELINUX_HARDENED="${ENABLE_SELINUX_HARDENED:-no}"
readonly SKIP_VERIFICATION="${SKIP_VERIFICATION:-no}"

readonly SELINUX_POLICY_DIR="/etc/selinux/targeted/policy"

readonly CONTAINER_SUBNET="${CONTAINER_SUBNET:-10.89.0.0/24}"
readonly DOCKER_SUBNET="${DOCKER_SUBNET:-10.89.0.0/24}"
readonly PODMAN_SUBNET="${PODMAN_SUBNET:-10.90.0.0/24}"

readonly DOCKER_STORAGE_ROOT="${DOCKER_STORAGE_ROOT:-/var/lib/docker}"
readonly PODMAN_STORAGE_ROOT="${PODMAN_STORAGE_ROOT:-/var/lib/containers/storage}"

readonly SECCOMP_PROFILE="${SECCOMP_PROFILE:-/etc/docker/seccomp.json}"

readonly KERNEL_SECURITY_PARAMS=(
    "kernel.dmesg_restrict=2"
    "kernel.kptr_restrict=2"
    "kernel.perf_event_paranoid=1"
    "kernel.randomize_va_space=2"
    "kernel.yama.ptrace_scope=1"
    "kernel.core_uses_pid=1"
    "kernel.panic_on_oops=1"
    "kernel.panic=0"
)

readonly CONTAINER_NOFILE="${CONTAINER_NOFILE:-65536}"
readonly CONTAINER_NPROC="${CONTAINER_NPROC:-65536}"
readonly CONTAINER_MAX_MEMORY="${CONTAINER_MAX_MEMORY:-75}"  # percentage of total

readonly AUDIT_RULES_FILE="/etc/audit/audit-rules/container.rules"

RUN_ID="${CLD6001_RUN_ID:-standalone}"

readonly ROLLBACK_DIR="/var/lib/cld6001/${RUN_ID}/${SCRIPT_NAME}-rollback"
readonly ROLLBACK_TIMESTAMP=$(date +%Y%m%d_%H%M%S)

ACTION="setup"
COMPONENT="all"
PROFILE_NAME=""
RESEARCH_OVERLAY=""
ROLLBACK_STORAGE_POLICY="prompt"
ROLLBACK_STORAGE_POLICY_EXPLICIT=0
PROFILE_JSON=""
LOG_DIR=""
LOG_FILE=""
ERRORS=0
WARNINGS=0
START_TIME=0

initialize_log_paths() {
    LOG_DIR="/var/log/cld6001/${RUN_ID}"
    mkdir -p "${LOG_DIR}"
    LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_${ACTION}_${ROLLBACK_TIMESTAMP}.log"
}

log() {
    local level="$1"
    shift
    local elapsed_msg=""

    if [ -n "${START_TIME}" ]; then
        local elapsed=$(( $(date +%s) - START_TIME ))
        local mins=$((elapsed / 60))
        local secs=$((elapsed % 60))
        elapsed_msg=" [+${mins}:${secs}s]"
    fi

    log_pipe "$level" "setup" "infrastructure" "${*}${elapsed_msg}"

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local normalized_level
    normalized_level="$(terminal_normalize_level "$level")"
    if [ -n "${LOG_FILE}" ]; then
        printf '%s%s [%s] %s: %s\n' "$timestamp" "$elapsed_msg" "$normalized_level" "$SCRIPT_NAME" "$*" >> "${LOG_FILE}"
    fi
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
    printf '\n%b---%b\n' "${CYAN}" "${NC}"
    log "STEP" "$@"
    printf '%b---%b\n\n' "${CYAN}" "${NC}"
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

parse_args() {
    ACTION="setup"
    COMPONENT="all"
    PROFILE_NAME=""
    RESEARCH_OVERLAY=""
    PROFILE_JSON=""
    ROLLBACK_STORAGE_POLICY="prompt"
    ROLLBACK_STORAGE_POLICY_EXPLICIT=0
    local action_seen=0
    local component_seen=0

    while [ $# -gt 0 ]; do
        case "$1" in
            setup|verify|rollback)
                if [ $action_seen -eq 1 ]; then
                    log_error "Duplicate action argument: $1"
                    exit 1
                fi
                ACTION="$1"
                action_seen=1
                shift
                ;;
            all|docker|podman|system)
                if [ $component_seen -eq 1 ]; then
                    log_error "Duplicate component argument: $1"
                    exit 1
                fi
                COMPONENT="$1"
                component_seen=1
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
            --rollback-storage)
                [ $# -ge 2 ] || {
                    log_error "Missing value for --rollback-storage"
                    exit 1
                }
                ROLLBACK_STORAGE_POLICY="$2"
                ROLLBACK_STORAGE_POLICY_EXPLICIT=1
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

setup_requires_profile() {
    case "${COMPONENT}" in
        system)
            return 1
            ;;
        docker)
            [ "${ENABLE_DOCKER_ROOTFUL}" = "yes" ] || [ "${ENABLE_DOCKER_ROOTLESS}" = "yes" ]
            ;;
        podman)
            [ "${ENABLE_PODMAN}" = "yes" ]
            ;;
        all)
            [ "${ENABLE_DOCKER_ROOTFUL}" = "yes" ] || [ "${ENABLE_DOCKER_ROOTLESS}" = "yes" ] || [ "${ENABLE_PODMAN}" = "yes" ]
            ;;
        *)
            return 1
            ;;
    esac
}

load_selected_profile() {
    [ -n "${PROFILE_NAME}" ] || {
        log_error "Missing required --profile"
        return 1
    }

    PROFILE_JSON="$(load_profile_json "${PROFILE_NAME}")" || return 1

    if [ -n "${RESEARCH_OVERLAY}" ] && ! profile_allows_overlay "${PROFILE_JSON}" "${RESEARCH_OVERLAY}"; then
        log_error "Profile ${PROFILE_NAME} does not allow research overlay ${RESEARCH_OVERLAY}"
        return 1
    fi
}

validate_action_contract() {
    if [ "${ACTION}" = "setup" ] && setup_requires_profile && [ -z "${PROFILE_NAME}" ]; then
        log_error "setup ${COMPONENT} requires --profile <name>"
        return 1
    fi

    if [ "${ACTION}" = "setup" ] && [ -n "${RESEARCH_OVERLAY}" ] && [ -z "${PROFILE_NAME}" ]; then
        log_error "setup with --research-overlay requires --profile <name>"
        return 1
    fi

    if [ "${ACTION}" = "setup" ] && [ "${RESEARCH_OVERLAY}" = "${SELINUX_RESEARCH_OVERLAY}" ] && [ "${ENABLE_SELINUX_HARDENED}" != "yes" ]; then
        log_error "--research-overlay ${SELINUX_RESEARCH_OVERLAY} requires ENABLE_SELINUX_HARDENED=yes"
        return 1
    fi

    case "${ACTION}" in
        verify|rollback)
            [ -z "${RESEARCH_OVERLAY}" ] || {
                log_error "${ACTION} does not accept --research-overlay"
                return 1
            }
            ;;
    esac

    case "${ROLLBACK_STORAGE_POLICY}" in
        prompt|keep|remove)
            ;;
        *)
            log_error "Invalid --rollback-storage value: ${ROLLBACK_STORAGE_POLICY}"
            return 1
            ;;
    esac

    if [ "${ACTION}" != "rollback" ] && [ "${ROLLBACK_STORAGE_POLICY_EXPLICIT}" -eq 1 ]; then
        log_error "--rollback-storage is only valid with rollback"
        return 1
    fi
}

selinux_research_policy_requested() {
    if [ -n "${SELINUX_POLICY_FILE:-}" ]; then
        return 0
    fi

    [ "${RESEARCH_OVERLAY:-}" = "${SELINUX_RESEARCH_OVERLAY}" ]
}

rootless_setup_requested() {
    if [ "${COMPONENT}" = "podman" ]; then
        return 0
    fi

    if [ "${COMPONENT}" = "docker" ] && [ "${ENABLE_DOCKER_ROOTLESS}" = "yes" ]; then
        return 0
    fi

    if [ "${COMPONENT}" = "all" ] && { [ "${ENABLE_DOCKER_ROOTLESS}" = "yes" ] || [ "${ENABLE_PODMAN}" = "yes" ]; }; then
        return 0
    fi

    return 1
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

    if [ "${version:0:2}" != "10" ]; then
        log_error "This script requires AlmaLinux 10.x. Found: ${version}"
        exit 1
    fi

    log_info "Operating system: AlmaLinux ${version}"
}

check_dependencies() {
    local missing=()

    for pkg in curl jq tar iptables wget git python3; do
        if ! command -v "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if ! python3 -c 'import scipy' &>/dev/null; then
        missing+=("python3-scipy")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_warn "Missing dependencies: ${missing[*]}"
        dnf install -y "${missing[@]}" || {
            log_error "Failed to install dependencies"
            exit 1
        }
    fi
}

check_scripts_exist() {
    if [ ! -f "${DOCKER_INSTALL_SCRIPT}" ]; then
        log_error "Docker installation script not found: ${DOCKER_INSTALL_SCRIPT}"
        exit 1
    fi
    if [ ! -f "${PODMAN_INSTALL_SCRIPT}" ]; then
        log_error "Podman installation script not found: ${PODMAN_INSTALL_SCRIPT}"
        exit 1
    fi
}

save_system_state() {
    log_step "Saving system state for rollback"

    mkdir -p "${ROLLBACK_DIR}"

    local state_file="${ROLLBACK_DIR}/state_${ROLLBACK_TIMESTAMP}"
    mkdir -p "${state_file}"

    dnf list installed > "${state_file}/packages.txt" 2>/dev/null || true
    rpm -qa --last > "${state_file}/rpm_last_install.txt" 2>/dev/null || true

    sysctl -a > "${state_file}/sysctl_before.txt" 2>/dev/null || true

    if command -v getenforce &>/dev/null; then
        getenforce > "${state_file}/selinux_mode.txt" 2>/dev/null || true
        getsebool -a > "${state_file}/selinux_booleans.txt" 2>/dev/null || true
        cat "${SELINUX_POLICY_DIR}/current" > "${state_file}/selinux_policy.txt" 2>/dev/null || true
    fi

    iptables-save > "${state_file}/iptables_before.txt" 2>/dev/null || true
    cld6001_capture_network_state_bundle \
        "${state_file}/network_before.txt" \
        "${state_file}/network_before.netlink.bin" \
        "${state_file}/network_before.netlink.kernel.txt" \
        2>/dev/null || true

    systemctl list-units --type=service --state=enabled > "${state_file}/enabled_services.txt" 2>/dev/null || true

    getent passwd > "${state_file}/passwd_before.txt" 2>/dev/null || true
    getent group > "${state_file}/group_before.txt" 2>/dev/null || true

    cat /etc/security/limits.conf > "${state_file}/limits_before.txt" 2>/dev/null || true

    auditctl -l > "${state_file}/audit_rules_before.txt" 2>/dev/null || true

    df -h > "${state_file}/disk_space.txt" 2>/dev/null || true

    tar czf "${ROLLBACK_DIR}/state_${ROLLBACK_TIMESTAMP}.tar.gz" -C "${ROLLBACK_DIR}" . 2>/dev/null || {
        log_warn "Could not create state archive"
    }

    log_info "System state saved to: ${ROLLBACK_DIR}/state_${ROLLBACK_TIMESTAMP}.tar.gz"
}

find_latest_sysctl_snapshot() {
    find "${ROLLBACK_DIR}" -maxdepth 2 -type f -name 'sysctl_before.txt' 2>/dev/null | sort | tail -n 1
}

rollback_system() {
    log_step "Rolling back infrastructure setup"

    log_info "Cleaning up all containers..."
    podman rm -f -a 2>/dev/null || true
    docker rm -f -a 2>/dev/null || true

    log_info "Stopping container services..."
    systemctl disable --now docker.socket docker.service 2>/dev/null || true
    systemctl disable --now podman.socket podman.service 2>/dev/null || true

    log_info "Removing container packages..."
    for pkg in \
        docker-ce docker-ce-cli docker-ce-rootless-extras \
        containerd.io docker-buildx-plugin docker-compose-plugin \
        podman containers-common \
        buildah crun slirp4netns fuse-overlayfs fuse3 \
        netavark runc catatonit container-selinux; do
        dnf remove -y "$pkg" 2>/dev/null || true
    done

    rm -f /etc/yum.repos.d/docker*.repo

    log_info "Removing container configurations..."
    rm -rf /etc/docker /etc/containers /etc/systemd/system/podman-cgroup-manager.service 2>/dev/null || true
    rm -f /etc/sysctl.d/99-docker.conf /etc/sysctl.d/99-podman.conf 2>/dev/null || true
    rm -f /etc/systemd/system/user@.service.d/cgroup-delegate.conf 2>/dev/null || true

    log_info "Restoring kernel parameters..."
    local sysctl_snapshot=""
    sysctl_snapshot="$(find_latest_sysctl_snapshot)"
    if [ -n "${sysctl_snapshot}" ]; then
        restore_saved_sysctl_value "${sysctl_snapshot}" "net.ipv4.ip_forward" || true
        restore_saved_sysctl_value "${sysctl_snapshot}" "net.bridge.bridge-nf-call-iptables" || true
    else
        log_warn "Could not restore kernel parameters; rollback snapshot is missing"
    fi

    rm -f /etc/cni/net.d/*docker* 2>/dev/null || true
    rm -f /etc/cni/net.d/*podman* 2>/dev/null || true

    iptables -F FORWARD 2>/dev/null || true

    case "${ROLLBACK_STORAGE_POLICY}" in
        prompt)
            if [ -t 0 ]; then
                read -r -p "Remove container storage directories? [N/y]: " -n 1
                echo
                case "${REPLY:-}" in
                    [Yy])
                        rm -rf "${DOCKER_STORAGE_ROOT}" "${PODMAN_STORAGE_ROOT}"
                        ;;
                esac
            else
                log_info "Keeping container storage directories (rollback storage policy: prompt)"
            fi
            ;;
        keep)
            log_info "Keeping container storage directories (rollback storage policy: keep)"
            ;;
        remove)
            rm -rf "${DOCKER_STORAGE_ROOT}" "${PODMAN_STORAGE_ROOT}"
            ;;
    esac

    log_info "System rollback completed..."
}

configure_firewall() {
    log_step "Configuring firewall for containers"

    if ! rpm -q firewalld &>/dev/null; then
        dnf install -y firewalld || {
            log_error "Failed to install firewalld"
            exit 1
        }
    fi

    systemctl enable --now firewalld || {
        log_error "Failed to enable firewalld"
        exit 1
    }

    log_info "Adding firewall rules for containers..."

    firewall-cmd --permanent --direct --add-rule ipv4 filter \
        FORWARD 0 -i docker0 -j ACCEPT || true

    firewall-cmd --permanent --direct --add-rule ipv4 filter \
        FORWARD 0 -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true

    firewall-cmd --permanent --direct --add-rule ipv4 filter \
        FORWARD 0 -i cni+ -j ACCEPT || true

    firewall-cmd --permanent --direct --add-rule ipv4 filter \
        FORWARD 0 -o cni+ -j ACCEPT || true

    firewall-cmd --reload

    log_info "Firewall configuration completed..."
}

configure_audit() {
    log_step "Configuring audit rules for containers"

    dnf install -y audit || {
        log_warn "Failed to install audit packages"
        return
    }

    mkdir -p "$(dirname "${AUDIT_RULES_FILE}")"
    cat > "${AUDIT_RULES_FILE}" << 'EOF'
# Container Security Research - Audit Rules
# Generated by setup-infrastructure.sh

# Monitor container runtime actions
-w /etc/containers/ -p wa -k container_config
-w /var/run/containers/ -p wa -k container_runtime

# Monitor Docker actions
-w /etc/docker/ -p wa -k docker_config
-w /var/run/docker/ -p wa -k docker_runtime

# Monitor containerd
-w /run/containerd/ -p wa -k containerd_runtime

# Monitor systemd container unit files
-w /etc/systemd/system/podman.service -p wa -k podman_service
-w /etc/systemd/system/docker.service -p wa -k docker_service

# Monitor seccomp profiles
-w /etc/seccomp.json -p wa -k seccomp_profile
-w /etc/docker/seccomp.json -p wa -k docker_seccomp

# Monitor capabilities
-w /usr/bin/setcap -p x -k cap_setcap

# Monitor namespace operations
-a always,exit -F arch=b64 -S unshare -k namespace_unshare
-a always,exit -F arch=b64 -S clone -k process_clone
EOF

    augenrules --load || {
        log_warn "Failed to load audit rules"
    }

    systemctl restart auditd || true

    log_info "Audit configuration completed..."
}

configure_seccomp() {
    log_step "Configuring seccomp profile"
    log_info "Docker seccomp remains runtime builtin; no repo-managed seccomp profile is deployed"
}

configure_system_limits() {
    log_step "Configuring system limits"

    mkdir -p /etc/security/limits.d
    cat > /etc/security/limits.d/99-container-limits.conf << EOF
# Container security research - System limits
# Generated by setup-infrastructure.sh
* soft nofile ${CONTAINER_NOFILE}
* hard nofile ${CONTAINER_NOFILE}
* soft nproc ${CONTAINER_NPROC}
* hard nproc ${CONTAINER_NPROC}
EOF

    log_info "System limits configured..."
}

install_docker() {
    if [ "${ENABLE_DOCKER_ROOTFUL}" = "no" ] && [ "${ENABLE_DOCKER_ROOTLESS}" = "no" ]; then
        log_info "Docker installation disabled"
        return
    fi

    log_step "Installing Docker"

    if [ "${ENABLE_DOCKER_ROOTLESS}" = "yes" ]; then
        validate_rootless_user "${CONTAINER_USER}" "docker-rootless" || return 1
    fi

    local mode=""
    if [ "${ENABLE_DOCKER_ROOTFUL}" = "yes" ] && [ "${ENABLE_DOCKER_ROOTLESS}" = "yes" ]; then
        mode="both"
    elif [ "${ENABLE_DOCKER_ROOTFUL}" = "yes" ]; then
        mode="rootful"
    else
        mode="rootless"
    fi

    export DOCKER_ROOTLESS_USER="${CONTAINER_USER}"
    export DOCKER_STORAGE_ROOT

    if [ -n "${RESEARCH_OVERLAY}" ]; then
        bash "${DOCKER_INSTALL_SCRIPT}" install "${mode}" --profile "${PROFILE_NAME}" --research-overlay "${RESEARCH_OVERLAY}" || {
            log_error "Docker installation failed"
            return 1
        }
    else
        bash "${DOCKER_INSTALL_SCRIPT}" install "${mode}" --profile "${PROFILE_NAME}" || {
            log_error "Docker installation failed"
            return 1
        }
    fi

    log_info "Docker profile configuration owned by install-docker.sh"
}

configure_docker_security() {
    log_info "Docker profile configuration owned by install-docker.sh"
}

install_podman() {
    if [ "${ENABLE_PODMAN}" = "no" ]; then
        log_info "Podman installation disabled"
        return
    fi

    log_step "Installing Podman"

    validate_rootless_user "${CONTAINER_USER}" "podman rootless" || return 1

    export PODMAN_ROOTLESS_USER="${CONTAINER_USER}"
    export PODMAN_STORAGE_ROOT

    if [ -n "${RESEARCH_OVERLAY}" ]; then
        bash "${PODMAN_INSTALL_SCRIPT}" install --profile "${PROFILE_NAME}" --research-overlay "${RESEARCH_OVERLAY}" || {
            log_error "Podman installation failed"
            return 1
        }
    else
        bash "${PODMAN_INSTALL_SCRIPT}" install --profile "${PROFILE_NAME}" || {
            log_error "Podman installation failed"
            return 1
        }
    fi

    log_info "Podman profile configuration owned by install-podman.sh"
}

configure_podman_security() {
    log_info "Podman profile configuration owned by install-podman.sh"
}

configure_selinux() {
    if ! env \
        CONTAINER_SELINUX_LOG_FILE="${LOG_FILE}" \
        ENABLE_SELINUX_HARDENED="${ENABLE_SELINUX_HARDENED}" \
        bash "${CONTAINER_SELINUX_SCRIPT}" baseline-runtime; then
        log_warn "Failed to configure container SELinux runtime baseline via configure-container-selinux.sh"
        return 0
    fi

    log_info "Container SELinux runtime baseline owned by configure-container-selinux.sh"

    if ! selinux_research_policy_requested; then
        log_info "Research SELinux policy not requested; retaining the package-only baseline by default"
        return 0
    fi

    if ! env \
        CONTAINER_SELINUX_LOG_FILE="${LOG_FILE}" \
        SELINUX_POLICY_FILE="${SELINUX_POLICY_FILE:-}" \
        bash "${CONTAINER_SELINUX_SCRIPT}" research-policy; then
        log_warn "Failed to install research SELinux policy via configure-container-selinux.sh"
        return 0
    fi

    log_info "Research SELinux policy installation owned by configure-container-selinux.sh"
}

configure_network() {
    log_step "Configuring container network"

    local network_backend=""
    network_backend="$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || echo "unknown")"

    if [[ "${network_backend}" == "cni" ]]; then
        mkdir -p /etc/cni/net.d

        cat > /etc/cni/net.d/10-docker.conflist << EOF
{
    "name": "docker",
    "plugins": [
        {
            "type": "bridge",
            "bridge": "docker0",
            "isGateway": true,
            "ipMasq": true,
            "ipam": {
                "type": "host-local",
                "subnet": "${DOCKER_SUBNET}",
                "routes": [{ "dst": "0.0.0.0/0" }]
            },
            "capabilities": {
                "portMappings": true
            }
        }
    ]
}
EOF

        cat > /etc/cni/net.d/20-podman.conflist << EOF
{
    "name": "podman",
    "plugins": [
        {
            "type": "bridge",
            "bridge": "cni-podman0",
            "isGateway": true,
            "ipMasq": true,
            "ipam": {
                "type": "host-local",
                "subnet": "${PODMAN_SUBNET}",
                "routes": [{ "dst": "0.0.0.0/0" }]
            },
            "capabilities": {
                "portMappings": true
            }
        }
    ]
}
EOF

        mkdir -p /run/netns/{docker,podman}

        log_info "Container network configuration completed..."
    else
        log_info "Network backend is '${network_backend}' - skipping CNI configuration"
    fi
}

setup_container_users() {
    log_step "Setting up container users and permissions"

    if rootless_setup_requested; then
        validate_rootless_user "${CONTAINER_USER}" "container rootless flows" || return 1
    fi

    if ! id "${CONTAINER_USER}" &>/dev/null; then
        log_info "Creating container user: ${CONTAINER_USER}..."
        useradd -m -s /bin/bash "${CONTAINER_USER}"
    fi

    if ! getent group docker &>/dev/null; then
        groupadd docker
    fi

    usermod -aG docker "${CONTAINER_USER}" 2>/dev/null || true

    cat > /etc/sudoers.d/99-containers << EOF
# Container security research - sudo permissions
${CONTAINER_USER} ALL=(ALL) NOPASSWD: /usr/bin/docker, /usr/bin/podman, /usr/bin/crun
EOF

    chmod 440 /etc/sudoers.d/99-containers

    for user in "${CONTAINER_USER}"; do
        local user_home
        user_home="$(resolve_user_home "${user}")"
        mkdir -p "${user_home}"/{docker,containers,containers-storage}
        chmod 700 "${user_home}"/{docker,containers,containers-storage}
        chown -R "${user}":"${user}" "${user_home}"/{docker,containers,containers-storage}
    done

    log_info "Container users configured..."
}

verify_system_hardening() {
    log_step "Verifying system hardening"

    local checks=0
    local passed=0

    ((checks+=1)); if [ -f "/etc/selinux/config" ]; then
        ((passed+=1)); log_info "[x] SELinux configuration exists"
    else
        log_error "[ ] SELinux configuration missing"
    fi

    ((checks+=1)); if systemctl is-active --quiet firewalld; then
        ((passed+=1)); log_info "[x] Firewall is active"
    else
        log_error "[ ] Firewall not active"
    fi

    ((checks+=1)); if [ -f "${AUDIT_RULES_FILE}" ]; then
        ((passed+=1)); log_info "[x] Container audit rules exist"
    else
        log_error "[ ] Container audit rules missing"
    fi

    ((checks+=1)); if [ -f "/etc/security/limits.d/99-container-limits.conf" ]; then
        ((passed+=1)); log_info "[x] Container limits configured"
    else
        log_error "[ ] Container limits missing"
    fi

    ((checks+=1)); if [ -f "/etc/sysctl.d/99-docker.conf" ]; then
        ((passed+=1)); log_info "[x] Docker kernel parameters configured"
    else
        log_error "[ ] Docker kernel parameters missing"
    fi

    log_info "System hardening verification: ${passed}/${checks} checks passed"
}

verify_docker() {
    log_step "Verifying Docker installation"

    local checks=0
    local passed=0

    ((checks+=1)); if systemctl is-active --quiet docker.service; then
        ((passed+=1)); log_info "[x] Docker service is active"
    else
        log_error "[ ] Docker service not active"
    fi

    ((checks+=1)); if docker version &>/dev/null; then
        ((passed+=1)); log_info "[x] Docker version check passed"
    else
        log_error "[ ] Docker version check failed"
    fi

    ((checks+=1)); if cld6001_run_runtime_smoke_test docker &>/dev/null; then
        ((passed+=1)); log_info "[x] Docker container test passed"
    else
        log_error "[ ] Docker container test failed"
    fi

    if [ "${ENABLE_DOCKER_ROOTLESS}" = "yes" ]; then
        ((checks+=1)); if su - "${CONTAINER_USER}" -c 'docker version' &>/dev/null; then
            ((passed+=1)); log_info "[x] Docker rootless check passed"
        else
            log_error "[ ] Docker rootless check failed"
        fi
    fi

    log_info "Docker verification: ${passed}/${checks} checks passed"
}

verify_podman() {
    log_step "Verifying Podman installation"

    local checks=0
    local passed=0

    ((checks+=1)); if podman --version &>/dev/null; then
        ((passed+=1)); log_info "[x] Podman version check passed"
    else
        log_error "[ ] Podman version check failed"
    fi

    ((checks+=1)); if cld6001_run_runtime_smoke_test podman &>/dev/null; then
        ((passed+=1)); log_info "[x] Podman container test passed"
    else
        log_error "[ ] Podman container test failed"
    fi

    ((checks+=1)); if su - "${CONTAINER_USER}" -c "$(cld6001_runtime_smoke_test_shell_command podman)" &>/dev/null; then
        ((passed+=1)); log_info "[x] podman-rootless check passed"
    else
        log_error "[ ] podman-rootless check failed"
    fi

    ((checks+=1)); if podman network list &>/dev/null; then
        ((passed+=1)); log_info "[x] Podman network check passed"
    else
        log_error "[ ] Podman network check failed"
    fi

    log_info "Podman verification: ${passed}/${checks} checks passed"
}

verify_all() {
    log_step "Running all verification tests"

    if [ "${SKIP_VERIFICATION}" = "no" ]; then
        verify_system_hardening || true
        if [ "${COMPONENT}" = "all" ] || [ "${COMPONENT}" = "docker" ]; then
            verify_docker || true
        fi
        if [ "${COMPONENT}" = "all" ] || [ "${COMPONENT}" = "podman" ]; then
            verify_podman || true
        fi
    else
        log_info "Verification skipped (SKIP_VERIFICATION=yes)"
    fi
}

main() {
    START_TIME=$(date +%s)
    validate_action_contract || exit 1
    if [ "${ACTION}" = "setup" ] && { setup_requires_profile || [ -n "${RESEARCH_OVERLAY}" ]; }; then
        load_selected_profile || exit 1
    fi
    mkdir -p /var/log
    touch "${LOG_FILE}"

    log_step "Container Security Research - Infrastructure Setup"
    echo "---"
    echo "Action:           ${ACTION}"
    echo "Component:        ${COMPONENT}"
    echo "Date:             ${SCRIPT_DATE}"
    echo "Version:          ${SCRIPT_VERSION}"
    echo "Container User:   ${CONTAINER_USER}"
    echo "docker-rootful:   ${ENABLE_DOCKER_ROOTFUL}"
    echo "docker-rootless: ${ENABLE_DOCKER_ROOTLESS}"
    echo "Podman:           ${ENABLE_PODMAN}"
    echo "Profile:          ${PROFILE_NAME:-n/a}"
    echo "Research Overlay: ${RESEARCH_OVERLAY:-n/a}"
    echo "SELinux Hardened: ${ENABLE_SELINUX_HARDENED}"
    echo "Skip Verification: ${SKIP_VERIFICATION}"
    echo "---"

    check_root
    check_os
    check_dependencies
    check_scripts_exist

    save_system_state

    case "${ACTION}" in
        setup)
            configure_audit
            configure_seccomp
            configure_system_limits
            configure_firewall

            setup_container_users

            if [ "${ENABLE_SELINUX_HARDENED}" = "yes" ]; then
                configure_selinux
            fi

            configure_network

            if [ "${COMPONENT}" = "all" ] || [ "${COMPONENT}" = "docker" ]; then
                install_docker
            fi

            if [ "${COMPONENT}" = "all" ] || [ "${COMPONENT}" = "podman" ]; then
                install_podman
            fi

            if [ "${SKIP_VERIFICATION}" = "no" ]; then
                verify_all
            fi
            ;;

        verify)
            verify_all
            ;;

        rollback)
            rollback_system
            ;;

        *)
            echo "Usage: $0 {setup|verify|rollback} [all|docker|podman|system]"
            exit 1
            ;;
    esac

    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))

    log_step "Setup Completed"
    echo "---"
    echo "Errors:     ${ERRORS}"
    echo "Warnings:   ${WARNINGS}"
    echo "Elapsed:    ${mins}m ${secs}s"
    echo "Log File:   ${LOG_FILE}"
    echo "Rollback:   ${ROLLBACK_DIR}/state_${ROLLBACK_TIMESTAMP}.tar.gz"
    echo "---"

    if [ ${ERRORS} -gt 0 ]; then
        log_error "Setup completed with ${ERRORS} errors"
        exit 1
    fi

    log_info "Setup completed successfully"
    exit 0
}

if [ "${BASH_SOURCE[0]}" == "$0" ]; then
    parse_args "$@"
    main "$@"
fi
