#!/bin/bash

tc10_run_case() {
    local engine="$1"
    local description="$2"
    shift 2

    echo "--- ${description} ---"
    "$engine" run --rm -i "$@" -v /:/host:ro alpine sh -c '
    echo "Container label: $(id -Z 2>/dev/null || echo unavailable)"
    echo "Mounted host path labels:"
    ls -Zd /host /host/etc /host/root 2>/dev/null || true

    echo "Attempting to read host SELinux config"
    if cat /host/etc/selinux/config >/dev/null 2>&1; then
        echo "host SELinux config: READABLE"
    else
        echo "host SELinux config: BLOCK"
    fi

    echo "Attempting to inspect host root home"
    if ls /host/root >/dev/null 2>&1; then
        echo "host root home: READABLE"
    else
        echo "host root home: BLOCK"
    fi
    '
    echo ""
}
