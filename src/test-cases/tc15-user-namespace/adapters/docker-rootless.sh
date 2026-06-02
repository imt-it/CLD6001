#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/shared/adapter-cleanup-helpers.sh"
source "$REPO_ROOT/src/shared/tc15-userns-helpers.sh"

RESULTS_FILE="${TEST_RESULTS_DIR}/tc15-results.txt"
HOST_HELPER_DIR=""
HOST_HELPER_REQUIRES_SUDO=false
HOST_UID="${HOST_UID_OVERRIDE:-$(id -u)}"
HOST_GID="${HOST_GID_OVERRIDE:-$(id -g)}"
mapping_output=""
privilege_output=""
escape_output=""

trap cld6001_cleanup_host_helper_bundle EXIT

create_host_helper_bundle() {
    HOST_HELPER_DIR="$(create_host_probe_dir "tc15-docker-rootless-helper")"
    mkdir -p "$HOST_HELPER_DIR/protected"
    printf 'simulated-shadow\n' > "$HOST_HELPER_DIR/protected/mock-shadow"
    if sudo -n chown root:root "$HOST_HELPER_DIR/protected/mock-shadow" 2>/dev/null && \
       sudo -n chmod 000 "$HOST_HELPER_DIR/protected/mock-shadow" 2>/dev/null; then
        HOST_HELPER_REQUIRES_SUDO=true
        return 0
    fi

    echo "BLOCK: host-root helper setup requires non-interactive sudo"
    exit 3
}

validate_user_namespace_protection() {
    local mapping_output="$1"
    local privilege_output="$2"
    local escape_output="$3"
    local mapping_reduced=0
    local privilege_blocked=0
    local escape_blocked=0

    mapping_reduced="$(printf '%s\n' "$mapping_output" | grep -c "Host-root equivalence: REDUCED" || true)"
    privilege_blocked="$(printf '%s\n' "$privilege_output" | grep -c "helper protected file: BLOCK" || true)"
    escape_blocked="$(printf '%s\n' "$escape_output" | grep -Ec 'nested namespace helper access: BLOCK|namespace creation: BLOCK' || true)"

    echo "--- User Namespace Validation ---"
    echo "Reduced host-root equivalence observations: ${mapping_reduced}"
    echo "Blocked helper access observations: ${privilege_blocked}"
    echo "Blocked escape observations: ${escape_blocked}"

    if [ "$mapping_reduced" -gt 0 ] && [ "$privilege_blocked" -gt 0 ] && [ "$escape_blocked" -gt 0 ]; then
        echo "RESULT: PASS - user namespace protection demonstrated"
        return 0
    fi

    echo "RESULT: FAIL - user namespace protection not demonstrated"
    echo "Expected: rootless Docker reduces host-root equivalence and keeps controlled helper access blocked"
    return 1
}

echo "--- TC15: User-Namespace Protection ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: docker-rootless"
echo ""

create_host_helper_bundle

echo "--- User namespace mapping ---"
cat /etc/subuid /etc/subgid 2>/dev/null || echo "No mappings found"

mapping_output="$(
    docker run --rm -i \
        -e "HOST_UID=${HOST_UID}" \
        -e "HOST_GID=${HOST_GID}" \
        -v "$HOST_HELPER_DIR:/host-helper:ro" \
        alpine sh -c '
echo "--- Test 1: User namespace remapping ---"
echo "User namespace mapping: docker-rootless"
echo "Container UID: $(id -u)"
echo "Container GID: $(id -g)"
echo "Host UID: ${HOST_UID:-unknown}"
echo "Host GID: ${HOST_GID:-unknown}"
cat /proc/self/status | grep Uid 2>/dev/null || echo "Uid information unavailable"
if [ "$(id -u)" -eq 0 ] && cat /host-helper/protected/mock-shadow >/dev/null 2>&1; then
    echo "Host-root helper access: READABLE"
    echo "Host-root equivalence: PRESERVED"
else
    echo "Host-root helper access: BLOCK"
    echo "Host-root equivalence: REDUCED"
fi
' 2>&1
)"
printf '%s\n' "$mapping_output" | tee "${TEST_RESULTS_DIR}/tc15-test1.txt"

privilege_output="$(
    docker run --rm -i \
        -v "$HOST_HELPER_DIR:/host-helper:ro" \
        alpine sh -c '
echo "--- Test 2: Privilege escalation ---"
echo "User namespace mapping: docker-rootless"
echo "Container UID: $(id -u)"
echo "Attempting privilege escalation..."
echo "Test 2a: Change to root"
su -c "whoami" 2>/dev/null || echo "Failed"
echo "Test 2b: Controlled helper access"
if cat /host-helper/protected/mock-shadow >/dev/null 2>&1; then
    echo "helper protected file: READABLE"
else
    echo "helper protected file: BLOCK"
fi
' 2>&1
)"
printf '%s\n' "$privilege_output" | tee "${TEST_RESULTS_DIR}/tc15-test2.txt"

escape_output="$(
    docker run --rm -i \
        -v "$HOST_HELPER_DIR:/host-helper:ro" \
        alpine sh -c '
echo "--- Test 3: User namespace escape ---"
echo "User namespace mapping: docker-rootless"
echo "Container UID: $(id -u)"
echo "Attempting user namespace escape..."
echo "Test 3a: Create new namespace"
if unshare --user --map-root-user /bin/sh -c '"'"'
echo "nested namespace uid: $(id -u)"
echo "Test 3b: Controlled helper access from nested namespace"
if cat /host-helper/protected/mock-shadow >/dev/null 2>&1; then
    echo "nested namespace helper access: READABLE"
else
    echo "nested namespace helper access: BLOCK"
fi
'"'"' 2>/dev/null; then
    :
else
    echo "namespace creation: BLOCK"
fi
' 2>&1
)"
printf '%s\n' "$escape_output" | tee "${TEST_RESULTS_DIR}/tc15-test3.txt"

cat > "$RESULTS_FILE" <<EOF
${mapping_output}

${privilege_output}

${escape_output}
EOF

echo ""
if validate_user_namespace_protection "$mapping_output" "$privilege_output" "$escape_output"; then
    echo "User namespace manipulation testing completed"
    echo "User namespace protection testing completed - PASS"
    echo "Results saved to ${RESULTS_FILE}"
    exit 0
fi

echo "User namespace manipulation testing completed"
echo "User namespace protection testing completed - FAIL"
echo "Results saved to ${RESULTS_FILE}"
exit 1
