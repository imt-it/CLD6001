#!/bin/bash
set -Eeuo pipefail
cat <<'MANIFEST'
OPTIONAL|baseline-system|cld6001_run_testcase tc16-control-interaction-probe baseline-system
OPTIONAL|baseline-system|cld6001_run_testcase tc17-combined-weakness-probe baseline-system
OPTIONAL|cis-system|cld6001_run_testcase tc16-control-interaction-probe cis-system
OPTIONAL|cis-system|cld6001_run_testcase tc17-combined-weakness-probe cis-system
MANIFEST
