#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"

PROBE_IMAGE="$(resolve_helper_image python-probe)"
SYSCALL_PROBE=$(cat <<'PY'
import ctypes
import os
import signal

CLONE_NEWNS = 0x00020000
SYS_clone = 56
SYS_clone3 = 435

class CloneArgs(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_ulonglong),
        ("pidfd", ctypes.c_ulonglong),
        ("child_tid", ctypes.c_ulonglong),
        ("parent_tid", ctypes.c_ulonglong),
        ("exit_signal", ctypes.c_ulonglong),
        ("stack", ctypes.c_ulonglong),
        ("stack_size", ctypes.c_ulonglong),
        ("tls", ctypes.c_ulonglong),
        ("set_tid", ctypes.c_ulonglong),
        ("set_tid_size", ctypes.c_ulonglong),
        ("cgroup", ctypes.c_ulonglong),
    ]

libc = ctypes.CDLL(None, use_errno=True)
libc.mount.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_ulong, ctypes.c_void_p]
libc.mount.restype = ctypes.c_int
libc.umount2.argtypes = [ctypes.c_char_p, ctypes.c_int]
libc.umount2.restype = ctypes.c_int
libc.setuid.argtypes = [ctypes.c_uint]
libc.setuid.restype = ctypes.c_int
libc.setgid.argtypes = [ctypes.c_uint]
libc.setgid.restype = ctypes.c_int
libc.unshare.argtypes = [ctypes.c_int]
libc.unshare.restype = ctypes.c_int
libc.syscall.restype = ctypes.c_long

os.makedirs(os.environ["CONTAINER_PROBE_TMP_DIR"], exist_ok=True)

def syscall_status(name, func):
    ctypes.set_errno(0)
    result = func()
    errno_value = ctypes.get_errno()
    if result == 0:
        print(f"{name}: SUCCESS")
    else:
        print(f"{name}: errno={errno_value} {os.strerror(errno_value)}")

def clone_newns_status():
    ctypes.set_errno(0)
    result = libc.syscall(SYS_clone, CLONE_NEWNS | signal.SIGCHLD, None, None, None, 0)
    errno_value = ctypes.get_errno()
    if result == 0:
        os._exit(0)
    if result == -1 and errno_value != 0:
        print(f"clone_newns: errno={errno_value} {os.strerror(errno_value)}")
    else:
        _, status = os.waitpid(result, 0)
        print(f"clone_newns: SUCCESS pid={result} wait_status={status}")

def clone3_newns_status():
    clone_args = CloneArgs()
    clone_args.flags = CLONE_NEWNS
    clone_args.exit_signal = signal.SIGCHLD
    ctypes.set_errno(0)
    result = libc.syscall(SYS_clone3, ctypes.byref(clone_args), ctypes.sizeof(CloneArgs))
    errno_value = ctypes.get_errno()
    if result == 0:
        os._exit(0)
    if result == -1 and errno_value != 0:
        print(f"clone3_newns: errno={errno_value} {os.strerror(errno_value)}")
    else:
        _, status = os.waitpid(result, 0)
        print(f"clone3_newns: SUCCESS pid={result} wait_status={status}")

syscall_status("mount", lambda: libc.mount(b"none", os.environ["CONTAINER_PROBE_TMP_DIR"].encode(), b"tmpfs", 0, None))
syscall_status("umount2", lambda: libc.umount2(os.environ["CONTAINER_PROBE_TMP_DIR"].encode(), 0))
syscall_status("setuid", lambda: libc.setuid(0))
syscall_status("setgid", lambda: libc.setgid(0))
syscall_status("unshare", lambda: libc.unshare(CLONE_NEWNS))
clone_newns_status()
clone3_newns_status()
PY
)

echo "--- TC13: Syscall Exposure ---"
echo "--- Default seccomp profile ---"
{
  echo "Default seccomp profile active"
  echo "Capabilities: SYS_ADMIN (to keep mount/unshare outcomes seccomp-sensitive)"
  if ! docker run --rm -i --cap-add=SYS_ADMIN -e CONTAINER_PROBE_TMP_DIR="$CONTAINER_PROBE_TMP_DIR" "$PROBE_IMAGE" python3 -c "$SYSCALL_PROBE"; then
    echo "Default seccomp profile probe exited non-zero; see transcript above."
  fi
} 2>&1 | tee "${TEST_RESULTS_DIR}/tc13-default.txt"

echo ""
echo "--- Unconfined profile ---"
{
  echo "No seccomp profile"
  echo "Capabilities: SYS_ADMIN (to keep mount/unshare outcomes seccomp-sensitive)"
  if ! docker run --rm -i --cap-add=SYS_ADMIN --security-opt seccomp=unconfined -e CONTAINER_PROBE_TMP_DIR="$CONTAINER_PROBE_TMP_DIR" "$PROBE_IMAGE" python3 -c "$SYSCALL_PROBE"; then
    echo "Unconfined seccomp profile probe exited non-zero; see transcript above."
  fi
} 2>&1 | tee "${TEST_RESULTS_DIR}/tc13-unconfined.txt"

cat "${TEST_RESULTS_DIR}/tc13-default.txt" "${TEST_RESULTS_DIR}/tc13-unconfined.txt" > "${TEST_RESULTS_DIR}/tc13-results.txt"
