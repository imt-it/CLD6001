#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"

TC18_RUNTIME_ID="${RUNNER_RUNTIME_ID:-podman-rootless}"
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

tc18_block_reason="rootless Podman cannot satisfy TC18 host-access preconditions (--privileged and --pid=host)"

{
    echo "--- Direct host-access probe unavailable ---"
    echo "BLOCK: ${tc18_block_reason}"
    echo "TC18 post-hardening probe blocked"
} | tee "${tc18_result_targets[@]}"

write_result_reason "block" "tc18_runtime_preconditions_unavailable" "$tc18_block_reason" "testcase-artifact"
exit "${BLOCK_EXIT_CODE:-3}"
