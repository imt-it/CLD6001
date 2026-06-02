#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
source "${REPO_ROOT}/src/execute/run-context.sh"
source "${REPO_ROOT}/src/shared/log-pipe.sh"
source "${REPO_ROOT}/src/shared/docker-bench-helpers.sh"

HARDENING_SCRIPT="${1:?Usage: tc17-comparison.sh <hardening_script>}"
PHASE=3
TIMESTAMP="$(cld6001_generate_timestamped_id "%Y%m%d-%H%M%S" "-")"

print_severity_counts() {
  local json_file="$1"
  printf 'CRITICAL failures: %s\n' "$(count_docker_bench_level "$json_file" "CRITICAL")"
  printf 'HIGH failures: %s\n' "$(count_docker_bench_level "$json_file" "HIGH")"
  printf 'WARNING count: %s\n' "$(count_docker_bench_level "$json_file" "WARNING")"
  printf 'INFO count: %s\n' "$(count_docker_bench_level "$json_file" "INFO")"
}

echo "--- TC17: Pre/Post Hardening Comparison ---"
echo "Date: $(date -Iseconds)"
echo "Hardening script: $HARDENING_SCRIPT"
echo ""

RESULTS_DIR="${TEST_RESULTS_DIR:-.}/tc17-comparison/$TIMESTAMP"
PRE_BENCH_JSON="${RESULTS_DIR}/dbfs-pre.json"
POST_BENCH_JSON="${RESULTS_DIR}/dbfs-post.json"
COMPARISON_REPORT="${RESULTS_DIR}/comparison.html"
mkdir -p "$RESULTS_DIR"

echo "---"
echo "PRE-HARDENING MEASUREMENT"
echo "---"

run_docker_bench_capture "$PRE_BENCH_JSON"

echo "Pre-hardening scores:"
print_severity_counts "$PRE_BENCH_JSON"

echo ""
echo "---"
echo "APPLYING HARDENING"
echo "---"

if [ ! -f "$HARDENING_SCRIPT" ]; then
    log_pipe "ERROR" "setup" "hardening" "Hardening script not found: $HARDENING_SCRIPT"
    exit 1
fi

bash "$HARDENING_SCRIPT"
echo "Hardening applied"

sudo systemctl restart docker
sleep 10

echo ""
echo "---"
echo "POST-HARDENING MEASUREMENT"
echo "---"

run_docker_bench_capture "$POST_BENCH_JSON"

echo "Post-hardening scores:"
print_severity_counts "$POST_BENCH_JSON"

python3 "${REPO_ROOT}/src/analyze/reports/docker-bench-comparison-report.py" \
  --pre "$PRE_BENCH_JSON" \
  --post "$POST_BENCH_JSON" \
  --output "$COMPARISON_REPORT"

echo ""
echo "Comparison report generated: $COMPARISON_REPORT"
