#!/bin/bash
set -Eeuo pipefail
cat <<'MANIFEST'
ACTIVE|baseline-system|cld6001_run_testcase tc01-privileged-mode baseline-system
ACTIVE|baseline-system|cld6001_run_testcase tc02-namespace-manipulation baseline-system
ACTIVE|baseline-system|cld6001_run_testcase tc03-cgroup-escape baseline-system
ACTIVE|baseline-system|cld6001_run_testcase tc04-kernel-exploits baseline-system
BLOCKED|cis-system|cld6001_run_testcase tc01-privileged-mode cis-system
BLOCKED|cis-system|cld6001_run_testcase tc02-namespace-manipulation cis-system
OPTIONAL|cis-system|cld6001_run_testcase tc03-cgroup-escape cis-system
OPTIONAL|cis-system|cld6001_run_testcase tc04-kernel-exploits cis-system
MANIFEST
