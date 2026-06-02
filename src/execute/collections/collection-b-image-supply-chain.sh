#!/bin/bash
set -Eeuo pipefail
cat <<'MANIFEST'
ACTIVE|baseline-system|cld6001_run_testcase tc05-standard-image-assessment baseline-system
ACTIVE|baseline-system|cld6001_run_testcase tc06-hardened-image-assessment baseline-system
INACTIVE|baseline-system|cld6001_run_testcase tc07-custom-hardened-image-assessment baseline-system
ACTIVE|baseline-system|cld6001_run_testcase tc20-supply-chain baseline-system
EXPERIMENTAL|cis-system|cld6001_run_testcase tc05-standard-image-assessment cis-system
EXPERIMENTAL|cis-system|cld6001_run_testcase tc06-hardened-image-assessment cis-system
EXPERIMENTAL|cis-system|cld6001_run_testcase tc20-supply-chain cis-system
MANIFEST
