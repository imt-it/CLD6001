#!/bin/bash

cld6001_cleanup_host_helper_bundle() {
    if [ -n "${HOST_HELPER_DIR:-}" ] && [ -d "$HOST_HELPER_DIR" ]; then
        if [ "${HOST_HELPER_REQUIRES_SUDO:-false}" = "true" ]; then
            sudo -n chmod -R u+rwX "$HOST_HELPER_DIR" 2>/dev/null || true
            sudo -n rm -rf -- "$HOST_HELPER_DIR" 2>/dev/null || true
        else
            chmod -R u+rwX "$HOST_HELPER_DIR" 2>/dev/null || true
            rm -rf -- "$HOST_HELPER_DIR"
        fi
    fi
}
