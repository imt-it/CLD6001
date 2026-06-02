#!/bin/bash
set -Eeuo pipefail
cat <<'MANIFEST'
ACTIVE|baseline-system|cld6001_run_testcase tc08-capability-abuse baseline-system
ACTIVE|baseline-system|cld6001_run_testcase tc09-capability-dropped baseline-system
ACTIVE|baseline-system|cld6001_run_testcase tc15-user-namespace baseline-system
ACTIVE|cis-system|cld6001_run_testcase tc08-capability-abuse cis-system
ACTIVE|cis-system|cld6001_run_testcase tc09-capability-dropped cis-system
ACTIVE|cis-system|cld6001_run_testcase tc15-user-namespace cis-system
MANIFEST
