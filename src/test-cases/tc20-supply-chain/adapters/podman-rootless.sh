#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"

TIMESTAMP="$(date -Iseconds)"
TC20_RUNTIME_ID="${RUNNER_RUNTIME_ID:-podman-rootless}"
RESULTS_DIR="${RUNNER_PHASE_RESULTS_DIR:?RUNNER_PHASE_RESULTS_DIR is required}"
TC20_ARTIFACTS_DIR="${RUNNER_ARTIFACTS_DIR:-}"
LOG_FILE="$RESULTS_DIR/test-output.log"
SKIP_FILE="$RESULTS_DIR/podman-skip-transcript.log"
APPLICABILITY_FILE="$RESULTS_DIR/tc20-applicability.json"

if [ -n "$TC20_ARTIFACTS_DIR" ]; then
  TC20_ARTIFACTS_DIR="$(resolve_results_repo_root "$TC20_ARTIFACTS_DIR")"
fi

reset_collection_results_dir "$RESULTS_DIR"

source "$REPO_ROOT/src/shared/adapter-artifact-helpers.sh"
cld6001_mirror_artifacts_on_exit "TC20_ARTIFACTS_DIR" "TC20 supply-chain"

cat > "$APPLICABILITY_FILE" <<EOF
{
  "test_case": "TC20",
  "runtime": "$TC20_RUNTIME_ID",
  "timestamp": "$TIMESTAMP",
  "applicability": "docker-only",
  "reason": "Docker Hardened Images tooling and Docker image export commands are not applicable under Podman.",
  "skip_transcript": "podman-skip-transcript.log",
  "outcome": "blocked"
}
EOF

cat > "$SKIP_FILE" <<EOF
Timestamp: $TIMESTAMP
Runtime: $TC20_RUNTIME_ID
Applicability: Docker-only
Reason: TC20 depends on Docker Hardened Images tooling and Docker image export commands.
Outcome: BLOCK - Docker-only applicability boundary recorded.
EOF

{
  echo "--- TC20: Supply-Chain Validation ---"
  echo "Date: $TIMESTAMP"
  echo "Runtime: $TC20_RUNTIME_ID"
  echo ""
  echo "# Description: Record Docker-only applicability boundary for $TC20_RUNTIME_ID"
  cat "$SKIP_FILE"
  echo "Recorded applicability artifact: $APPLICABILITY_FILE"
  echo "Recorded Podman skip transcript: $SKIP_FILE"
} | tee "$LOG_FILE"

exit "${BLOCK_EXIT_CODE:-3}"
