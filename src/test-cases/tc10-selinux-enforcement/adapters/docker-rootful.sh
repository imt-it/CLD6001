#!/bin/bash
set -Eeuo pipefail
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"

echo "--- TC10: SELinux Enforcement ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: docker-rootful"
echo ""

if ! command -v getenforce &>/dev/null; then
    cld6001_block "selinux_tooling_unavailable" "SELinux tooling not available for TC10"
fi

SELINUX_MODE="$(getenforce)"
echo "Host SELinux mode: ${SELINUX_MODE}"

if [ "${SELINUX_MODE}" != "Enforcing" ]; then
    cld6001_block "selinux_not_enforcing" "SELinux must be enforcing for TC10 (current: ${SELINUX_MODE})"
fi

run_case() {
    local description="$1"
    shift

    echo "--- ${description} ---"
    docker run --rm -i "$@" -v /:/host:ro alpine sh -c '
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

run_case "Default container labeling"
run_case "SELinux labeling disabled" --security-opt label=disable

echo "SELinux enforcement comparison completed"
