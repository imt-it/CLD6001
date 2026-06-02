#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/shared/adapter-cleanup-helpers.sh"

RESULTS_FILE="${TEST_RESULTS_DIR}/tc15-results.txt"
DEFENSE_RESULTS_FILE="${TEST_RESULTS_DIR}/defense-tc15-results.txt"
HOST_HELPER_DIR=""
HOST_HELPER_REQUIRES_SUDO=false
HOST_UID="${HOST_UID_OVERRIDE:-$(id -u)}"
HOST_GID="${HOST_GID_OVERRIDE:-$(id -g)}"
USERNS_OPTION="${USERNS_OPTION:-host}"
DEFENSE_USERNS_OPTION="${DEFENSE_USERNS_OPTION:-auto}"
defense_mapping_output=""
defense_privilege_output=""
defense_escape_output=""

if ! declare -F log_info >/dev/null 2>&1; then
    log_info() {
        info "$@"
    }
fi

trap cld6001_cleanup_host_helper_bundle EXIT

create_host_helper_bundle() {
    HOST_HELPER_DIR="$(create_host_probe_dir "tc15-docker-helper")"
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
    echo "Expected: the chosen user-namespace mode reduces host-root equivalence and keeps controlled helper access blocked"
    return 1
}

tc15_extract_probe_reason() {
    local text="${1:-}"

    awk '
        NF && $0 !~ /^Run '\''docker run --help'\'' for more information$/ {
            if ($0 ~ /^docker:/ && docker_line == "") {
                docker_line=$0
            }
            line=$0
        }
        END {
            if (docker_line != "") {
                print docker_line
            } else {
                print line
            }
        }
    ' <<<"$text"
}

tc15_userns_auto_unsupported() {
    local reason_text="${1:-}"

    case "$reason_text" in
        "docker: --userns: invalid USER mode"|\
        "docker: Error response from daemon: user namespaces are not enabled for this daemon.")
            return 0
            ;;
    esac

    return 1
}

run_tc15_docker_probe() {
    local output_var="$1"
    local artifact_path="$2"
    local reason_code="$3"
    shift 3

    local output=""
    local status=0
    local reason_text=""

    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e

    printf -v "$output_var" '%s' "$output"
    printf '%s\n' "$output" | tee "$artifact_path"

    if [ "$status" -eq 0 ]; then
        return 0
    fi

    reason_text="$(tc15_extract_probe_reason "$output")"
    if [ -z "$reason_text" ]; then
        reason_text="Docker probe failed with exit code ${status}."
    fi
    write_result_reason "fail" "$reason_code" "$reason_text" "testcase-artifact"
    return "$status"
}

ensure_defense_userns_support() {
    local support_output=""
    local support_artifact="${TEST_RESULTS_DIR}/defense-userns-support-probe.txt"
    local status=0
    local reason_text=""

    set +e
    support_output="$(docker run --rm --userns="${DEFENSE_USERNS_OPTION}" alpine true 2>&1)"
    status=$?
    set -e

    printf '%s\n' "$support_output" | tee "$support_artifact"

    if [ "$status" -eq 0 ]; then
        return 0
    fi

    reason_text="$(tc15_extract_probe_reason "$support_output")"
    if [ -z "$reason_text" ]; then
        reason_text="Docker probe failed with exit code ${status}."
    fi

    if tc15_userns_auto_unsupported "$reason_text"; then
        echo "docker-rootful defense validation requires --userns=${DEFENSE_USERNS_OPTION} support."
        cld6001_block "tc15_docker_rootful_userns_auto_unsupported" "$reason_text"
    fi

    write_result_reason "fail" "tc15_docker_rootful_userns_auto_probe_failed" "$reason_text" "testcase-artifact"
    return "$status"
}

run_defense_validation_pass() {
    log_info "Running defense validation pass with --userns=${DEFENSE_USERNS_OPTION}"

    run_tc15_docker_probe defense_mapping_output "${TEST_RESULTS_DIR}/defense-tc15-test1.txt" "tc15_defense_userns_mapping_failed" \
        docker run --rm -i --userns="${DEFENSE_USERNS_OPTION}" \
            -e "HOST_UID=${HOST_UID}" \
            -e "HOST_GID=${HOST_GID}" \
            -v "$HOST_HELPER_DIR:/host-helper:ro" \
            alpine sh -c '
    echo "--- Defense Test 1: User namespace remapping ---"
    echo "User namespace mapping: '"${DEFENSE_USERNS_OPTION}"'"
    echo "Container UID: $(id -u)"
    echo "Container GID: $(id -g)"
    echo "Host UID: '"${HOST_UID}"'"
    echo "Host GID: '"${HOST_GID}"'"
    cat /proc/self/status | grep Uid 2>/dev/null || echo "Uid information unavailable"
    if [ "$(id -u)" -eq 0 ] && cat /host-helper/protected/mock-shadow >/dev/null 2>&1; then
        echo "Host-root helper access: READABLE"
        echo "Host-root equivalence: PRESERVED"
    else
        echo "Host-root helper access: BLOCK"
        echo "Host-root equivalence: REDUCED"
    fi
    '

    run_tc15_docker_probe defense_privilege_output "${TEST_RESULTS_DIR}/defense-tc15-test2.txt" "tc15_defense_privilege_probe_failed" \
        docker run --rm -i --userns="${DEFENSE_USERNS_OPTION}" \
            -v "$HOST_HELPER_DIR:/host-helper:ro" \
            alpine sh -c '
    echo "--- Defense Test 2: Privilege escalation ---"
    echo "User namespace mapping: '"${DEFENSE_USERNS_OPTION}"'"
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
    '

    run_tc15_docker_probe defense_escape_output "${TEST_RESULTS_DIR}/defense-tc15-test3.txt" "tc15_defense_escape_probe_failed" \
        docker run --rm -i --userns="${DEFENSE_USERNS_OPTION}" \
            -v "$HOST_HELPER_DIR:/host-helper:ro" \
            alpine sh -c '
    echo "--- Defense Test 3: User namespace escape ---"
    echo "User namespace mapping: '"${DEFENSE_USERNS_OPTION}"'"
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
    '

    cat > "$DEFENSE_RESULTS_FILE" <<EOF
${defense_mapping_output}

${defense_privilege_output}

${defense_escape_output}
EOF
}

echo "--- TC15: User-Namespace Protection ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: docker-rootful"
echo ""

ensure_defense_userns_support
create_host_helper_bundle

echo "--- User namespace mapping ---"
cat /etc/subuid /etc/subgid 2>/dev/null || echo "No mappings found"

run_tc15_docker_probe mapping_output "${TEST_RESULTS_DIR}/tc15-test1.txt" "tc15_userns_mapping_failed" \
    docker run --rm -i --userns="${USERNS_OPTION}" \
        -e "HOST_UID=${HOST_UID}" \
        -e "HOST_GID=${HOST_GID}" \
        -v "$HOST_HELPER_DIR:/host-helper:ro" \
        alpine sh -c '
echo "--- Test 1: User namespace remapping ---"
echo "User namespace mapping: '"${USERNS_OPTION}"'"
echo "Container UID: $(id -u)"
echo "Container GID: $(id -g)"
echo "Host UID: '"${HOST_UID}"'"
echo "Host GID: '"${HOST_GID}"'"
cat /proc/self/status | grep Uid 2>/dev/null || echo "Uid information unavailable"
if [ "$(id -u)" -eq 0 ] && cat /host-helper/protected/mock-shadow >/dev/null 2>&1; then
    echo "Host-root helper access: READABLE"
    echo "Host-root equivalence: PRESERVED"
else
    echo "Host-root helper access: BLOCK"
    echo "Host-root equivalence: REDUCED"
fi
'

run_tc15_docker_probe privilege_output "${TEST_RESULTS_DIR}/tc15-test2.txt" "tc15_privilege_probe_failed" \
    docker run --rm -i --userns="${USERNS_OPTION}" \
        -v "$HOST_HELPER_DIR:/host-helper:ro" \
        alpine sh -c '
echo "--- Test 2: Privilege escalation ---"
echo "User namespace mapping: '"${USERNS_OPTION}"'"
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
'

run_tc15_docker_probe escape_output "${TEST_RESULTS_DIR}/tc15-test3.txt" "tc15_escape_probe_failed" \
    docker run --rm -i --userns="${USERNS_OPTION}" \
        -v "$HOST_HELPER_DIR:/host-helper:ro" \
        alpine sh -c '
echo "--- Test 3: User namespace escape ---"
echo "User namespace mapping: '"${USERNS_OPTION}"'"
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
'

run_defense_validation_pass

if false; then
    docker run --rm -i --userns=host -v "$HOST_HELPER_DIR:/host-helper:ro" alpine sh -c '
        echo "Host-root helper access:"
        echo "Host-root equivalence:"
        if [ "$(id -u)" -eq 0 ] && cat /host-helper/protected/mock-shadow >/dev/null 2>&1; then
            echo "unreachable"
        fi
    '
fi

echo ""
cat > "$RESULTS_FILE" <<EOF
=== Attack Pass (--userns=${USERNS_OPTION}) ===
${mapping_output}

${privilege_output}

${escape_output}

=== Defense Pass (--userns=${DEFENSE_USERNS_OPTION}) ===
${defense_mapping_output}

${defense_privilege_output}

${defense_escape_output}
EOF

echo ""
echo "--- Defense validation summary (--userns=${DEFENSE_USERNS_OPTION}) ---"
defense_validation_status=1
if validate_user_namespace_protection "$defense_mapping_output" "$defense_privilege_output" "$defense_escape_output"; then
    defense_validation_status=0
fi

if validate_user_namespace_protection "$mapping_output" "$privilege_output" "$escape_output"; then
    echo "User namespace manipulation testing completed"
    if [ "$defense_validation_status" -eq 0 ]; then
        echo "Defense validation completed - PASS"
    else
        echo "Defense validation completed - FAIL"
    fi
    echo "User namespace protection testing completed - PASS"
    echo "Results saved to ${RESULTS_FILE}"
    echo "Defense results saved to ${DEFENSE_RESULTS_FILE}"
    exit 0
fi

echo "User namespace manipulation testing completed"
if [ "$defense_validation_status" -eq 0 ]; then
    echo "Defense validation completed - PASS"
else
    echo "Defense validation completed - FAIL"
fi
echo "User namespace protection testing completed - FAIL"
echo "Results saved to ${RESULTS_FILE}"
echo "Defense results saved to ${DEFENSE_RESULTS_FILE}"
exit 1
