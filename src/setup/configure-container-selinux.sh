#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_ROOT}/../../src/shared/terminal-colors.sh"
source "${SCRIPT_ROOT}/../../src/shared/log-pipe.sh"

readonly SCRIPT_NAME="configure-container-selinux"
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DATE="2026-05-27"
readonly SELINUX_POLICY_HANDLER="${SCRIPT_ROOT}/../../resources/templates/selinux-install.sh"
readonly PACKAGE_ONLY_PACKAGES=(
    "container-selinux"
)
readonly BASELINE_RUNTIME_PACKAGES=(
    "container-selinux"
    "docker-selinux"
    "podman-selinux"
)

ACTION="${1:-help}"
POLICY_FILE="${SELINUX_POLICY_FILE:-}"
SELINUX_HARDENED="${ENABLE_SELINUX_HARDENED:-no}"
LOG_FILE="${CONTAINER_SELINUX_LOG_FILE:-}"
GENERATED_POLICY_DIR=""

usage() {
    cat <<'EOF'
Usage: bash configure-container-selinux.sh <package-only|baseline-runtime|research-policy|help>

Environment variables:
  CONTAINER_SELINUX_LOG_FILE   Optional log file path used by delegated callers
  ENABLE_SELINUX_HARDENED      yes|no toggle for baseline-runtime mode
  SELINUX_POLICY_FILE          Optional custom .te/.pp policy path for research-policy mode
EOF
}

runtime_scope() {
    case "${ACTION}" in
        package-only)
            printf '%s\n' 'podman'
            ;;
        baseline-runtime|research-policy|custom-policy)
            printf '%s\n' 'infrastructure'
            ;;
        *)
            printf '%s\n' 'infrastructure'
            ;;
    esac
}

log() {
    local level="$1"
    shift

    log_pipe "$level" "setup" "$(runtime_scope)" "$*"

    local timestamp
    local normalized_level
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    normalized_level="$(terminal_normalize_level "$level")"
    if [ -n "${LOG_FILE}" ]; then
        printf '%s [%s] %s: %s\n' "$timestamp" "$normalized_level" "$SCRIPT_NAME" "$*" >> "${LOG_FILE}"
    fi
}

log_info() {
    log "INFO" "$@"
}

log_warn() {
    log "WARN" "$@"
}

log_error() {
    log "ERROR" "$@"
}

log_step() {
    printf '\n%b---%b\n' "${BLUE}" "${NC}"
    log "STEP" "$@"
    printf '%b---%b\n\n' "${BLUE}" "${NC}"
}

cleanup_generated_policy_dir() {
    if [ -n "${GENERATED_POLICY_DIR}" ] && [ -d "${GENERATED_POLICY_DIR}" ]; then
        rm -rf -- "${GENERATED_POLICY_DIR}"
    fi
}

trap cleanup_generated_policy_dir EXIT

install_selinux_packages() {
    dnf install -y "$@" || {
        log_error "Failed to install SELinux packages: $*"
        return 1
    }
}

write_default_generated_policy() {
    GENERATED_POLICY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cld6001-selinux-policy.XXXXXX")"
    local policy_path="${GENERATED_POLICY_DIR}/container-research.te"

    log_info "Using default generated SELinux policy: ${policy_path}"
    cat > "${policy_path}" << 'EOF'
module container-research 1.0;

require {
    type container_t;
    type container_runtime_t;
    type container_runtime_exec_t;
    type container_file_t;
    type user_home_t;
    type usr_t;
    type var_run_t;
    type var_lib_t;
    class file { read write create open getattr setattr unlink rename link };
    class dir { search read write open create getattr add_name remove_name };
}

# Allow container access to research directories
allow container_t user_home_t:file { read write open getattr };
allow container_t user_home_t:dir { search read open };
allow container_runtime_t container_runtime_exec_t:file { read open execute };
allow container_t container_runtime_exec_t:file { read open execute };
EOF

    printf '%s\n' "${policy_path}"
}

configure_package_only_policy() {
    if ! command -v getenforce &>/dev/null; then
        log_warn "SELinux not installed, skipping"
        return 0
    fi

    local current_mode
    current_mode="$(getenforce)"
    log_info "Current SELinux mode: ${current_mode}"

    if [ "${current_mode}" = "Enforcing" ]; then
        log_info "Installing SELinux policy for containers..."
        install_selinux_packages "${PACKAGE_ONLY_PACKAGES[@]}" || return 1
        log_info "Using distro-provided container-selinux policy only"
    fi

    log_info "SELinux configuration for Podman completed..."
}

configure_baseline_runtime() {
    install_selinux_packages "${BASELINE_RUNTIME_PACKAGES[@]}" || return 1

    if [ "${SELINUX_HARDENED}" = "yes" ]; then
        setenforce 1
        sed -i 's/^SELINUX=.*/SELINUX=enforcing/g' /etc/selinux/config
    else
        setenforce 0
        sed -i 's/^SELINUX=.*/SELINUX=permissive/g' /etc/selinux/config
    fi

    setsebool -P container_manage_cgroup on
    setsebool -P container_manage_tun on
    setsebool -P container_use_cifs on
    setsebool -P container_use_fusefs on
    setsebool -P container_use_nfs on
    setsebool -P container_use_samba on
    setsebool -P container_use_ssh_agent on
    setsebool -P container_use_virtiofs on
    setsebool -P container_disable_trans off

    log_info "Container SELinux runtime baseline configuration completed..."
}

configure_research_policy() {
    local policy_path=""

    if [ -n "${POLICY_FILE}" ]; then
        policy_path="${POLICY_FILE}"
        log_info "Using custom SELinux policy path: ${policy_path}"
    else
        policy_path="$(write_default_generated_policy)"
    fi

    bash "${SELINUX_POLICY_HANDLER}" install "${policy_path}"
    log_info "Research SELinux policy installation completed..."
}

main() {
    case "${ACTION}" in
        package-only)
            log_step "Configuring SELinux for Podman"
            configure_package_only_policy
            ;;
        baseline-runtime)
            log_step "Configuring SELinux runtime baseline"
            configure_baseline_runtime
            ;;
        research-policy|custom-policy)
            log_step "Installing research SELinux policy"
            configure_research_policy
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            log_error "Unknown action: ${ACTION}"
            usage
            return 1
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
