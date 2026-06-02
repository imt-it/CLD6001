#!/bin/bash

tc14_host_ptrace_attach_probe() {
cat <<'PY'
import ctypes
import os
import signal
import sys

PTRACE_ATTACH = 16
PTRACE_DETACH = 17
PTRACE_PEEKDATA = 2

libc = ctypes.CDLL(None, use_errno=True)
libc.ptrace.argtypes = [ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p]
libc.ptrace.restype = ctypes.c_long

def first_readable_mapping_address(pid):
    try:
        with open(f"/proc/{pid}/maps", "r", encoding="utf-8") as handle:
            for line in handle:
                fields = line.split()
                if len(fields) < 2:
                    continue
                perms = fields[1]
                if "r" not in perms:
                    continue
                start_address = int(fields[0].split("-")[0], 16)
                if start_address != 0:
                    return start_address
    except PermissionError as exc:
        print(f"BLOCK: host PID maps are not readable from this runtime context: {exc}")
        return None
    return None

target_pid_text = os.environ.get("HOST_PTRACE_TARGET_PID", "")
if not target_pid_text.isdigit():
    print("ERROR: invalid HOST_PTRACE_TARGET_PID")
    sys.exit(1)

target_pid = int(target_pid_text)
target_address = first_readable_mapping_address(target_pid)
if target_address is None:
    print(f"BLOCK: no readable mapping available for host PID {target_pid}")
    sys.exit(0)

print(f"Targeting host helper process: {target_pid}")
print(f"Target address: 0x{target_address:x}")

attached = False
try:
    ctypes.set_errno(0)
    attach_result = libc.ptrace(PTRACE_ATTACH, target_pid, None, None)
    attach_errno = ctypes.get_errno()
    if attach_result == -1 and attach_errno != 0:
        print(f"PTRACE_ATTACH errno={attach_errno} {os.strerror(attach_errno)}")
    else:
        attached = True
        print(f"PTRACE_ATTACH result={attach_result}")
        try:
            _, wait_status = os.waitpid(target_pid, 0)
            print(f"waitpid status={wait_status}")
        except ChildProcessError as exc:
            print(f"waitpid error={exc}")
        ctypes.set_errno(0)
        peek_result = libc.ptrace(PTRACE_PEEKDATA, target_pid, ctypes.c_void_p(target_address), None)
        peek_errno = ctypes.get_errno()
        if peek_result == -1 and peek_errno != 0:
            print(f"PTRACE_PEEKDATA errno={peek_errno} {os.strerror(peek_errno)}")
        else:
            print(f"PTRACE_PEEKDATA result={peek_result}")
finally:
    if attached:
        ctypes.set_errno(0)
        detach_result = libc.ptrace(PTRACE_DETACH, target_pid, None, None)
        detach_errno = ctypes.get_errno()
        if detach_result == -1 and detach_errno != 0:
            print(f"PTRACE_DETACH errno={detach_errno} {os.strerror(detach_errno)}")
        else:
            print(f"PTRACE_DETACH result={detach_result}")
PY
}

tc14_peer_ptrace_syscall_probe() {
cat <<'PY'
import ctypes
import os
import signal
import subprocess

PTRACE_ATTACH = 16
PTRACE_DETACH = 17
PTRACE_SYSCALL = 24

libc = ctypes.CDLL(None, use_errno=True)
libc.ptrace.argtypes = [ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p]
libc.ptrace.restype = ctypes.c_long

peer = subprocess.Popen(["sleep", "3600"])
print(f"Targeting non-traced peer process: {peer.pid}")

attached = False
try:
    ctypes.set_errno(0)
    attach_result = libc.ptrace(PTRACE_ATTACH, peer.pid, None, None)
    attach_errno = ctypes.get_errno()
    if attach_result == -1 and attach_errno != 0:
        print(f"PTRACE_ATTACH errno={attach_errno} {os.strerror(attach_errno)}")
    else:
        attached = True
        print(f"PTRACE_ATTACH result={attach_result}")
        try:
            _, wait_status = os.waitpid(peer.pid, 0)
            print(f"waitpid status={wait_status}")
        except ChildProcessError as exc:
            print(f"waitpid error={exc}")
        ctypes.set_errno(0)
        ptrace_result = libc.ptrace(PTRACE_SYSCALL, peer.pid, None, None)
        ptrace_errno = ctypes.get_errno()
        if ptrace_result == -1 and ptrace_errno != 0:
            print(f"PTRACE_SYSCALL errno={ptrace_errno} {os.strerror(ptrace_errno)}")
        else:
            print(f"PTRACE_SYSCALL result={ptrace_result}")
finally:
    if attached:
        ctypes.set_errno(0)
        detach_result = libc.ptrace(PTRACE_DETACH, peer.pid, None, None)
        detach_errno = ctypes.get_errno()
        if detach_result == -1 and detach_errno != 0:
            print(f"PTRACE_DETACH errno={detach_errno} {os.strerror(detach_errno)}")
        else:
            print(f"PTRACE_DETACH result={detach_result}")
    try:
        peer.send_signal(signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        peer.wait(timeout=5)
    except subprocess.TimeoutExpired:
        peer.kill()
        peer.wait(timeout=5)
PY
}

tc14_sendfile_probe() {
cat <<'PY'
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
}
