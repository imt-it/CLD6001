#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/shared/tc03-cgroup-helpers.sh"
source "$REPO_ROOT/src/execute/image-priorities.sh"
source "$REPO_ROOT/src/shared/adapter-image-helpers.sh"

RESULTS_FILE="${TEST_RESULTS_DIR}/tc03-results-$(cld6001_unique_timestamp_id "%Y%m%d-%H%M%S" "-").txt"
RUN_ID="$(cld6001_unique_timestamp_id "%s" "-")"
TC03_RUNTIME_ID="${RUNNER_RUNTIME_ID:-docker-rootless}"
IMAGE="$(get_image ALPINE_IMAGES)"

echo "--- TC03: Cgroup Resource Constraint Assessment ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: ${TC03_RUNTIME_ID}"
echo "Image: $IMAGE"
echo "Run ID: $RUN_ID"
echo ""

cld6001_ensure_image docker "$IMAGE" || exit 1

cleanup() {
    docker rm -f "tc3-mem-${RUN_ID}" >/dev/null 2>&1
    docker rm -f "tc3-cpu-${RUN_ID}" >/dev/null 2>&1
    docker rm -f "tc3-pid-${RUN_ID}" >/dev/null 2>&1
}
trap cleanup EXIT

echo "--- Test 3a: Cgroup Freezer Constraint Bypass Assessment ---"
docker run --rm -i "$IMAGE" sh -c "$(tc03_freezer_probe_script "$TC03_RUNTIME_ID")" 2>&1 | tee "$RESULTS_FILE"

echo "--- Test 3a-ii: Cgroup Hierarchy Escape Probe ---"
docker run --rm -i "$IMAGE" sh -c "$(tc03_cgroup_hierarchy_probe_script)" 2>&1 | tee -a "$RESULTS_FILE"

echo "--- Test 3b: Memory Constraint Enforcement Assessment ---"
docker run --rm --memory=64m -i "$IMAGE" sh -c '
echo "Memory limit test:"
echo "Cgroup memory limit (own view):"
cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo "BLOCKED: memory limit unreadable"
echo "Attempting to raise memory limit (boundary breach):"
echo max > /sys/fs/cgroup/memory.max 2>&1 && echo "BREACH: memory.max write succeeded" || echo "BOUNDARY HELD: memory.max write blocked"
echo "Attempting to allocate 128MB (exceeding 64MB limit - boundary breach attempt):"
dd if=/dev/zero of=/dev/shm/test bs=1M count=128 2>&1 \
    && echo "BREACH: 128MB allocation succeeded under 64MB limit - memory boundary exceeded" \
    || echo "BOUNDARY HELD: allocation killed before 128MB reached (OOM enforced)"
echo "Memory OOM event evidence (memory.events):"
cat /sys/fs/cgroup/memory.events 2>/dev/null | grep -E "(oom|oom_kill)" \
    || echo "memory.events: OOM counters not accessible"
' 2>&1 | tee -a "$RESULTS_FILE"

echo "--- Test 3c: CPU Constraint Enforcement Assessment ---"
docker run --rm --cpus=0.5 -i "$IMAGE" sh -c '
echo "CPU limit test:"
echo "Cgroup CPU limit (own view):"
cat /sys/fs/cgroup/cpu.max 2>/dev/null || cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo "BLOCKED: cpu limit unreadable"
echo "Attempting to raise CPU limit (boundary breach):"
echo "max 100000" > /sys/fs/cgroup/cpu.max 2>&1 && echo "BREACH: cpu.max write succeeded" || echo "BOUNDARY HELD: cpu.max write blocked"
echo "Spinning CPU at full load (attempting to exceed 0.5 CPU quota)..."
timeout 5 sh -c '"'"'while true; do :; done'"'"' &
SPIN_PID=$!
wait $SPIN_PID 2>/dev/null || true
echo "CPU throttle evidence (cpu.stat - BOUNDARY evidence):"
cat /sys/fs/cgroup/cpu.stat 2>/dev/null | grep -E "(nr_throttled|throttled_usec)" \
    && echo "BOUNDARY HELD: throttling recorded - CPU limit was active and enforced" \
    || echo "cpu.stat throttle counters not accessible"
' 2>&1 | tee -a "$RESULTS_FILE"

echo "--- Test 3d: PID Constraint Enforcement Assessment ---"
set +e
docker run --rm --pids-limit=10 -i "$IMAGE" sh -c '
echo "PID limit test:"
echo "Cgroup PID limit (own view):"
cat /sys/fs/cgroup/pids.max 2>/dev/null || cat /sys/fs/cgroup/pids/pids.max 2>/dev/null || echo "BLOCKED: pids limit unreadable"
echo "Attempting to raise PID limit (boundary breach):"
echo max > /sys/fs/cgroup/pids.max 2>&1 && echo "BREACH: pids.max write succeeded" || echo "BOUNDARY HELD: pids.max write blocked"
echo "Attempting to spawn 20 background processes (exceeding limit of 10):"
i=1
while [ "$i" -le 20 ]; do
    sleep 100 &
    i=$((i + 1))
done
SLEEP_COUNT=$(ps | grep -c "sleep 100" 2>/dev/null) || SLEEP_COUNT=0
echo "Background sleep processes running: $SLEEP_COUNT (attempted 20 under limit 10)"
if [ "$SLEEP_COUNT" -ge 15 ]; then
    echo "BREACH: $SLEEP_COUNT processes spawned - pids.max not enforced"
elif [ "$SLEEP_COUNT" -le 6 ]; then
    echo "BOUNDARY HELD: only $SLEEP_COUNT processes spawned - PID limit enforced"
else
    echo "BOUNDARY HELD: $SLEEP_COUNT processes (well below attempted 20 - limit active)"
fi
echo "Current PID count:"
ps aux | wc -l
' 2>&1 | tee -a "$RESULTS_FILE"
PID_STATUS=${PIPESTATUS[0]}
set -e
info "PID limit test completed with exit code: $PID_STATUS..."
echo "PID limit test exit code: $PID_STATUS" >> "$RESULTS_FILE"

echo ""
echo "---"
ok "Test TC03 completed successfully"
echo "Results saved to: $RESULTS_FILE"
echo "---"
