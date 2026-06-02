#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"

TC18_RUNTIME_ID="${RUNNER_RUNTIME_ID:-docker-rootful}"
HELPER_IMAGE="$(resolve_helper_image alpine-shell)"
TC18_RESULTS_DIR="${RUNNER_ARTIFACTS_DIR:-$TEST_RESULTS_DIR}"
mkdir -p "$TC18_RESULTS_DIR"

tc18_result_targets=("${TC18_RESULTS_DIR}/tc18-results.txt")
if [ -n "${RUNNER_ARTIFACTS_DIR:-}" ] && [ "$TEST_RESULTS_DIR" != "$RUNNER_ARTIFACTS_DIR" ]; then
    tc18_result_targets+=("${TEST_RESULTS_DIR}/tc18-results.txt")
fi

echo "--- TC18: Post-Hardening Host Access Probe ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: ${TC18_RUNTIME_ID}"
echo ""

{
    echo "--- Direct host-access probe via host PID namespace ---"
    docker run --rm --pid=host -i --privileged \
        "$HELPER_IMAGE" sh -c '
            echo "Attempting host access via host PID namespace"
            ls -la /proc/1/root/etc/ 2>/dev/null || echo "Access blocked"
        '
} 2>&1 | tee "${tc18_result_targets[@]}"

echo "TC18 post-hardening probe completed" | tee -a "${tc18_result_targets[@]}"
