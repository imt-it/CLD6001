#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"

echo "--- TC07 Wrapper: Custom Hardened Image Assessment (De-scoped) ---"
if [ -n "${RUNNER_ARTIFACTS_DIR:-}" ]; then
    export TEST_RESULTS_DIR="$RUNNER_ARTIFACTS_DIR"
fi
export TC57_CASE=07
exec bash "$REPO_ROOT/src/execute/escape-tests/docker-image-assessment-common.sh"
