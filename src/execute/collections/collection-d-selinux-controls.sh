#!/bin/bash
set -Eeuo pipefail
cat <<'MANIFEST'
ACTIVE|baseline-system|cld6001_run_testcase tc10-selinux-enforcement baseline-system
ACTIVE|baseline-system|cld6001_run_testcase tc11-selinux-violations baseline-system
ACTIVE|baseline-system|cld6001_run_testcase tc12-selinux-bypass baseline-system
ACTIVE|cis-system|cld6001_run_testcase tc10-selinux-enforcement cis-system
ACTIVE|cis-system|cld6001_run_testcase tc11-selinux-violations cis-system
ACTIVE|cis-system|cld6001_run_testcase tc12-selinux-bypass cis-system
MANIFEST
