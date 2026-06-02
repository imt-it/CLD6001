#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"

PROBE_IMAGE="$(resolve_helper_image python-probe)"
SENDFILE_PROBE=$(cat <<'PY'
import os

try:
    probe_file = f"{os.environ['CONTAINER_PROBE_TMP_DIR']}/test"
    os.makedirs(os.environ["CONTAINER_PROBE_TMP_DIR"], exist_ok=True)
    fd1 = os.open("/dev/null", os.O_RDONLY)
    fd2 = os.open(probe_file, os.O_CREAT | os.O_WRONLY, 0o644)
    os.sendfile(fd2, fd1, 0, 4096)
    os.close(fd1)
    os.close(fd2)
    print("Sendfile: SUCCESS")
except Exception as e:
    print(f"Sendfile: {e}")
PY
)

emit_probe_summary() {
  cat <<'EOF'
--- Seccomp Probe Summary ---
Test 1 status: BLOCK - host ptrace preconditions unavailable in rootless Podman
Test 2 status: BLOCK - peer ptrace preconditions unavailable in rootless Podman
Test 3 status: EXECUTED - relaxed seccomp syscall probe recorded
Scope note: exploratory only - no restrictive-profile enforcement claim
EOF
}

echo "--- TC14: Seccomp Bypass Probe ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: podman-rootless"
echo ""

echo "--- Test 1: Cross-process memory read probe ---"
{
  echo "Seccomp profile: Unconfined"
  echo "BLOCK: rootless Podman cannot satisfy host ptrace preconditions (--pid=host and SYS_PTRACE)"
} 2>&1 | tee "${TEST_RESULTS_DIR}/tc14-test1.txt"

echo "--- Test 2: Indirect system calls ---"
{
  echo "Seccomp profile: Unconfined"
  echo "BLOCK: rootless Podman cannot satisfy peer ptrace preconditions (CAP_SYS_PTRACE)"
} 2>&1 | tee "${TEST_RESULTS_DIR}/tc14-test2.txt"

echo "--- Test 3: Kernel exploit via syscalls ---"
test3_output="$({
  echo "Seccomp profile: Unconfined"
  echo "Testing kernel exploits via syscalls..."
  podman run --rm -i --security-opt seccomp=unconfined -e CONTAINER_PROBE_TMP_DIR="$CONTAINER_PROBE_TMP_DIR" "$PROBE_IMAGE" python3 -c "$SENDFILE_PROBE"
} 2>&1)"
printf '%s\n' "$test3_output" | tee "${TEST_RESULTS_DIR}/tc14-test3.txt"

echo ""
probe_summary="$(emit_probe_summary)"
printf '%s\n' "$probe_summary"
cat "${TEST_RESULTS_DIR}/tc14-test1.txt" "${TEST_RESULTS_DIR}/tc14-test2.txt" "${TEST_RESULTS_DIR}/tc14-test3.txt" > "${TEST_RESULTS_DIR}/tc14-results.txt"
{
  echo ""
  printf '%s\n' "$probe_summary"
} >> "${TEST_RESULTS_DIR}/tc14-results.txt"
echo "Seccomp bypass probing completed"
echo "Results saved to ${TEST_RESULTS_DIR}/tc14-results.txt"
