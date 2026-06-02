#!/bin/bash
set -Eeuo pipefail
cat <<'MANIFEST'
ACTIVE|baseline-system|cld6001_run_testcase tc13-syscall-abuse baseline-system
ACTIVE|baseline-system|cld6001_run_testcase tc14-seccomp-bypass baseline-system
ACTIVE|cis-system|cld6001_run_testcase tc13-syscall-abuse cis-system
ACTIVE|cis-system|cld6001_run_testcase tc14-seccomp-bypass cis-system
MANIFEST
