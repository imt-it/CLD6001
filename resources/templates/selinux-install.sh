#!/bin/bash

set -Eeuo pipefail

SELINUX_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SELINUX_INSTALL_DIR/../.." && pwd -P)"
source "$REPO_ROOT/src/shared/terminal-colors.sh"

usage() {
    cat <<EOF
Usage: $0 <command> [args]

Commands:
  install <policy_file>  Install a policy module from a .te source file or .pp package
  remove <policy_name>   Remove an installed policy module
  status [filter]        Show SELinux mode and installed container policies
  help                   Show this help
EOF
}

require_commands() {
    local missing=()
    local command_name

    for command_name in "$@"; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            missing+=("${command_name}")
        fi
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        error "Missing required command(s): ${missing[*]}"
        return 1
    fi

    return 0
}

policy_name_from_file() {
    local policy_file="$1"
    local policy_basename
    policy_basename="$(basename -- "${policy_file}")"
    printf '%s\n' "${policy_basename%.*}"
}

policy_mod_path() {
    local policy_file="$1"
    local policy_dir policy_name
    policy_dir="$(dirname -- "${policy_file}")"
    policy_name="$(policy_name_from_file "${policy_file}")"
    printf '%s/%s.mod\n' "${policy_dir}" "${policy_name}"
}

policy_package_path() {
    local policy_file="$1"
    local policy_dir policy_name
    policy_dir="$(dirname -- "${policy_file}")"
    policy_name="$(policy_name_from_file "${policy_file}")"
    printf '%s/%s.pp\n' "${policy_dir}" "${policy_name}"
}

policy_installed() {
    local policy_name="$1"
    semodule -l | awk '{print $1}' | grep -Fxq "${policy_name}"
}

install_policy_from_source() {
    local policy_file="${1:-}"
    local policy_name mod_file package_file

    require_commands checkmodule semodule_package semodule || return 1

    policy_name="$(policy_name_from_file "${policy_file}")"
    mod_file="$(policy_mod_path "${policy_file}")"
    package_file="$(policy_package_path "${policy_file}")"

    info "Compiling policy module: ${policy_name}..."
    checkmodule -M -m -o "${mod_file}" "${policy_file}"

    [[ -f "${mod_file}" ]] || {
        error "Compiled module not created: ${mod_file}"
        return 1
    }

    info "Creating policy package: ${package_file}..."
    semodule_package -o "${package_file}" -m "${mod_file}"

    [[ -f "${package_file}" ]] || {
        error "Policy package not created: ${package_file}"
        return 1
    }

    if policy_installed "${policy_name}"; then
        warn "Policy ${policy_name} already installed. Replacing it."
        semodule -r "${policy_name}"
    fi

    info "Installing policy package..."
    semodule -i "${package_file}"

    if policy_installed "${policy_name}"; then
        ok "Policy ${policy_name} installed successfully"
        return 0
    fi

    error "Policy ${policy_name} installation failed"
    return 1
}

install_policy_package() {
    local policy_file="${1:-}"

    require_commands semodule || return 1

    info "Installing prebuilt policy package: ${policy_file}..."
    semodule -i "${policy_file}"
    ok "Policy package installed successfully"
}

install_policy() {
    local policy_file="${1:-}"

    [[ -n "${policy_file}" ]] || {
        error "Usage: $0 install <policy_file>"
        return 1
    }
    [[ -f "${policy_file}" ]] || {
        error "Policy file not found: ${policy_file}"
        return 1
    }

    case "${policy_file##*.}" in
        te)
            install_policy_from_source "${policy_file}"
            ;;
        pp)
            install_policy_package "${policy_file}"
            ;;
        *)
            error "Unsupported policy format: ${policy_file}"
            return 1
            ;;
    esac
}

remove_policy() {
    local policy_name="${1:-}"

    [[ -n "${policy_name}" ]] || {
        error "Usage: $0 remove <policy_name>"
        return 1
    }

    require_commands semodule || return 1

    if ! policy_installed "${policy_name}"; then
        warn "Policy ${policy_name} is not installed"
        return 0
    fi

    info "Removing SELinux policy: ${policy_name}..."
    semodule -r "${policy_name}"
    ok "Policy ${policy_name} removed successfully"
}

show_status() {
    local filter="${1:-container|docker|podman}"

    require_commands semodule getenforce || return 1

    echo "---"
    echo "SELinux Policy Status"
    echo "---"

    info "Current SELinux mode: $(getenforce)"
    info "Installed policies matching: ${filter}"

    if ! semodule -l | grep -E "${filter}"; then
        warn "No installed policy modules matched: ${filter}"
    fi
}

main() {
    case "${1:-help}" in
        install)
            install_policy "${2:-}"
            ;;
        remove)
            remove_policy "${2:-}"
            ;;
        status)
            if [[ -n "${2:-}" ]]; then
                show_status "$2"
            else
                show_status
            fi
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            error "Unknown command: ${1:-}"
            usage
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
