#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"

echo "--- TC06 Wrapper: Docker Hardened Image (DHI) Assessment (docker-rootless) ---"
if [ -n "${RUNNER_ARTIFACTS_DIR:-}" ]; then
    export TEST_RESULTS_DIR="$RUNNER_ARTIFACTS_DIR"
fi
export TC57_CASE=06
exec bash "$REPO_ROOT/src/execute/escape-tests/docker-image-assessment-common.sh"
