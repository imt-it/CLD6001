#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"

echo "--- TC10: SELinux Enforcement ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: podman-rootless"
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
    podman run --rm -i "$@" -v /:/host:ro alpine sh -c '
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

validate_enforcement() {
    local labeled_output="$1"
    local disabled_output="$2"

    local labeled_blocked=0
    local disabled_readable=0

    labeled_blocked=$(echo "$labeled_output" | grep -c "BLOCK" || true)

    disabled_readable=$(echo "$disabled_output" | grep -c "READABLE" || true)

    echo "--- Enforcement Validation ---"
    echo "Labeled case - BLOCK actions: ${labeled_blocked}"
    echo "Disabled case - READABLE actions: ${disabled_readable}"

    if [ "$labeled_blocked" -gt 0 ] && [ "$disabled_readable" -gt 0 ]; then
        echo "RESULT: PASS - SELinux enforcement effective"
        return 0
    fi

    echo "RESULT: FAIL - SELinux enforcement not demonstrated"
    echo "Expected: labeled case blocks access, disabled case allows access"
    return 1
}

labeled_output="$(run_case "Default container labeling")"
disabled_output="$(run_case "SELinux labeling disabled" --security-opt label=disable)"

printf '%s\n' "$labeled_output"
printf '%s\n' "$disabled_output"

if validate_enforcement "$labeled_output" "$disabled_output"; then
    echo "SELinux enforcement comparison completed - PASS"
    exit 0
else
    echo "SELinux enforcement comparison completed - FAIL"
    exit 1
fi
