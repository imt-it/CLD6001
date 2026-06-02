#!/bin/bash
set -Eeuo pipefail
cat <<'MANIFEST'
EXPERIMENTAL|baseline-system|cld6001_run_testcase tc18-host-access-probe baseline-system
EXPERIMENTAL|baseline-system|cld6001_run_testcase tc19-network-isolation baseline-system
ACTIVE|cis-system|cld6001_run_testcase tc18-host-access-probe cis-system
ACTIVE|cis-system|cld6001_run_testcase tc19-network-isolation cis-system
MANIFEST
