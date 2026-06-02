#!/bin/bash

if [ -n "${NETWORK_CAPTURE_HELPERS_LOADED:-}" ]; then
    return 0
fi
readonly NETWORK_CAPTURE_HELPERS_LOADED=1

cld6001_capture_network_interfaces_snapshot() {
    local output_path="${1:-}"

    if [ -z "${output_path}" ]; then
        printf 'Network interfaces output path is required\n' >&2
        return 1
    fi

    if ! ip addr show > "${output_path}"; then
        return 1
    fi
}

cld6001_capture_network_netlink_dump() {
    local output_path="${1:-}"

    if [ -z "${output_path}" ]; then
        printf 'Network netlink dump output path is required\n' >&2
        return 1
    fi

    if ! ip addr save > "${output_path}"; then
        return 1
    fi
}

cld6001_record_network_netlink_kernel() {
    local output_path="${1:-}"

    if [ -z "${output_path}" ]; then
        printf 'Network netlink kernel output path is required\n' >&2
        return 1
    fi

    if ! uname -r > "${output_path}"; then
        return 1
    fi
}

cld6001_capture_network_state_bundle() {
    local interfaces_output_path="${1:-}"
    local netlink_output_path="${2:-}"
    local netlink_kernel_output_path="${3:-}"

    cld6001_capture_network_interfaces_snapshot "${interfaces_output_path}" || return 1

    if [ -n "${netlink_output_path}" ]; then
        cld6001_capture_network_netlink_dump "${netlink_output_path}" || return 1
    fi

    if [ -n "${netlink_kernel_output_path}" ]; then
        cld6001_record_network_netlink_kernel "${netlink_kernel_output_path}" || return 1
    fi
}
