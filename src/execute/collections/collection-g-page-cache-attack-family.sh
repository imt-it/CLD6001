#!/bin/bash
set -Eeuo pipefail
cat <<'MANIFEST'
ACTIVE|baseline-system|cld6001_run_testcase tc22-page-cache-poisoning baseline-system
ACTIVE|baseline-system|cld6001_run_testcase tc23-cross-container-attack baseline-system
ACTIVE|baseline-system|cld6001_run_testcase tc24-runc-container-escape baseline-system
OPTIONAL|cis-system|cld6001_run_testcase tc22-page-cache-poisoning cis-system
OPTIONAL|cis-system|cld6001_run_testcase tc23-cross-container-attack cis-system
OPTIONAL|cis-system|cld6001_run_testcase tc24-runc-container-escape cis-system
MANIFEST
