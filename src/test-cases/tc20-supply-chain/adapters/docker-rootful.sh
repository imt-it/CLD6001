#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/shared/adapter-result-helpers.sh"
source "$REPO_ROOT/src/shared/adapter-image-helpers.sh"
source "$REPO_ROOT/src/execute/image-registry.sh"
TC20_REVERSIBLE_VARIANT_PROBE="$(resolve_source_repo_path "resources/exploits/cve2026_31431_reversible/copy_fail_exp_reversible.py")"

TC20_RUNTIME_ID="${RUNNER_RUNTIME_ID:-docker-rootful}"
RESULTS_DIR="${RUNNER_PHASE_RESULTS_DIR:?RUNNER_PHASE_RESULTS_DIR is required}"
TC20_ARTIFACTS_DIR="${RUNNER_ARTIFACTS_DIR:-}"

if [ -n "$TC20_ARTIFACTS_DIR" ]; then
  TC20_ARTIFACTS_DIR="$(resolve_results_repo_root "$TC20_ARTIFACTS_DIR")"
fi

source "$REPO_ROOT/src/shared/adapter-artifact-helpers.sh"

if [ ! -f "$TC20_REVERSIBLE_VARIANT_PROBE" ]; then
    printf 'TC20 reversible variant helper not found: %s\n' "$TC20_REVERSIBLE_VARIANT_PROBE" >&2
    exit 1
fi

verify_sbom_quality() {
    local image="$1"
    local sbom_file="$2"
    echo "Verifying SBOM quality for image $image"

    if [ ! -f "$sbom_file" ] || [ -z "$(cat "$sbom_file")" ]; then
        echo "FAIL: SBOM missing or empty"
        cld6001_record_result "sbom_quality_$image" "FAIL"
        return 1
    fi

    local required_fields=("packages" "components" "dependencies")
    for field in "${required_fields[@]}"; do
        if ! grep -q "$field" "$sbom_file"; then
            echo "FAIL: SBOM missing required field: $field"
            cld6001_record_result "sbom_quality_$image" "FAIL"
            return 1
        fi
    done

    local entry_count=$(grep -c "component\|package" "$sbom_file")
    if [ $entry_count -lt 10 ]; then
        echo "WARNING: SBOM has very few entries ($entry_count)"
        cld6001_record_result "sbom_quality_$image" "WARN"
    fi

    echo "PASS: SBOM meets quality standards"
    cld6001_record_result "sbom_quality_$image" "PASS"
    return 0
}

analyze_test_results() {
    local test_results_dir="$1"
    echo "Performing statistical analysis of test results"

    local pass_count=$(grep -c "PASS" "$test_results_dir"/*.txt 2>/dev/null || echo 0)
    local fail_count=$(grep -c "FAIL" "$test_results_dir"/*.txt 2>/dev/null || echo 0)

    local total=$((pass_count + fail_count))
    local pass_rate=0
    if [ $total -gt 0 ]; then
        pass_rate=$((pass_count * 100 / total))
        echo "Pass rate: ${pass_rate}%"
    fi

    cat > "${test_results_dir}/statistics.json" << EOF
{
  "total_tests": $total,
  "passed": $pass_count,
  "failed": $fail_count,
  "pass_rate_percent": $pass_rate,
  "confidence_interval": 0.95,
  "timestamp": "$(date -Iseconds)"
}
EOF
}

echo "--- TC20: Supply-Chain Validation ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: ${TC20_RUNTIME_ID}"
echo ""

STANDARD_IMAGES="nginx:1.30.1-alpine3.23 alpine:3.23.0 node:24.16.0-alpine3.23"
DHI_IMAGES="dhi.io/nginx:1.30.1-alpine3.23 dhi.io/alpine-base:3.23 dhi.io/node:24.16.0-alpine3.23"

cld6001_ensure_images docker $STANDARD_IMAGES $DHI_IMAGES || exit 1

reset_collection_results_dir "$RESULTS_DIR"

cld6001_mirror_artifacts_on_exit "TC20_ARTIFACTS_DIR" "TC20 supply-chain"

touch "$RESULTS_DIR/test-results.txt"

LOG_FILE="${RESULTS_DIR}/tc20-supply-chain.log"
ANALYSIS_ROWS_FILE="${RESULTS_DIR}/supply-chain-observations.tsv"
BOUNDARY_ROWS_FILE="${RESULTS_DIR}/supply-chain-trust-boundaries.tsv"
ANALYSIS_INPUT_FILE="${RESULTS_DIR}/supply-chain-analysis-input.json"
ANALYSIS_OUTPUT_FILE="${RESULTS_DIR}/supply-chain-analysis.json"
TC20_ANALYSIS_HELPER="$(resolve_repo_path "src/analyze/reports/security-control-analysis.py")"
date "+%Y-%m-%d %H:%M:%S" > "$LOG_FILE" 2>&1
rm -f "$ANALYSIS_ROWS_FILE" "$BOUNDARY_ROWS_FILE" "$ANALYSIS_INPUT_FILE" "$ANALYSIS_OUTPUT_FILE"
echo "Standard images: $STANDARD_IMAGES" >> "$LOG_FILE"
echo "DHI images: $DHI_IMAGES" >> "$LOG_FILE"
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
  "family" "image" "status" "canonical_registry" "digest_baseline" "digest_match" "reason" "observed_repo_digests" \
  > "$BOUNDARY_ROWS_FILE"

log_line() {
  echo "$1" | tee -a "$LOG_FILE"
}

get_image_archive_listing() {
  local image="$1"
  local archive_listing

  if ! archive_listing=$(docker save "$image" 2>>"$LOG_FILE" | tar -t 2>>"$LOG_FILE"); then
    log_line "  ERROR: docker save failed for $image"
    return 1
  fi

  printf '%s\n' "$archive_listing"
}

get_image_labels() {
  local image="$1"
  local labels_json

  if ! labels_json=$(docker inspect "$image" --format '{{json .Config.Labels}}' 2>>"$LOG_FILE"); then
    log_line "  ERROR: docker inspect failed for $image"
    return 1
  fi

  printf '%s\n' "$labels_json"
}

get_image_repo_digests() {
  local image="$1"
  local repo_digests_json

  if ! repo_digests_json=$(docker inspect "$image" --format '{{json .RepoDigests}}' 2>>"$LOG_FILE"); then
    log_line "  ERROR: docker inspect RepoDigests failed for $image"
    return 1
  fi

  printf '%s\n' "$repo_digests_json"
}

sanitize_result_key() {
  printf '%s' "$1" | tr '/:.-' '_'
}

canonical_repo_candidates() {
  local image="$1"
  local repository="${image%%:*}"

  if [[ "$repository" == dhi.io/* ]]; then
    printf '%s\n' "$repository"
  elif [[ "$repository" == */* ]]; then
    printf '%s\n' "$repository" "docker.io/$repository" "index.docker.io/$repository"
  else
    printf '%s\n' "$repository" "docker.io/library/$repository" "index.docker.io/library/$repository"
  fi
}

assess_trust_boundary() {
  local family="$1"
  local image="$2"
  local repo_digests_json
  local expected_digest
  local assessment
  local status
  local canonical_status
  local digest_baseline
  local digest_match
  local reason
  local observed_refs
  local result_key
  local artifact_file
  local allowed_repo
  local -a allowed_repo_values=()
  local -a allowed_repo_args=()
  local -a expected_digest_args=()

  log_line "Assessing trust boundary for: $image"

  if ! repo_digests_json=$(get_image_repo_digests "$image"); then
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$family" "$image" "FAIL" "fail" "error" "error" "repo-digest-inspect-failed" "inspect-error" \
      >> "$BOUNDARY_ROWS_FILE"
    cld6001_record_result "trust_boundary_$(sanitize_result_key "$image")" "FAIL"
    return 1
  fi

  expected_digest="$(get_registry_digest_by_image_tag "$image" 2>/dev/null || true)"
  mapfile -t allowed_repo_values < <(canonical_repo_candidates "$image")
  for allowed_repo in "${allowed_repo_values[@]}"; do
    allowed_repo_args+=(--allowed-repo "$allowed_repo")
  done
  if [ -n "$expected_digest" ]; then
    expected_digest_args=(--expected-digest "$expected_digest")
  fi
  artifact_file="$RESULTS_DIR/tc20-$(sanitize_result_key "$image")-reversible-variant.json"
  if ! assessment="$(
    python3 "$TC20_REVERSIBLE_VARIANT_PROBE" trust-boundary \
      --scenario "tc20-supply-chain" \
      --runtime "$TC20_RUNTIME_ID" \
      --mode "reversible" \
      --thesis-safe \
      --family "$family" \
      --image "$image" \
      --repo-digests-json "$repo_digests_json" \
      "${allowed_repo_args[@]}" \
      "${expected_digest_args[@]}" \
      --artifact-file "$artifact_file" \
      --format tsv
  )"; then
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$family" "$image" "FAIL" "fail" "error" "error" "reversible-helper-failed" "helper-error" \
      >> "$BOUNDARY_ROWS_FILE"
    cld6001_record_result "trust_boundary_$(sanitize_result_key "$image")" "FAIL"
    return 1
  fi

  IFS=$'\t' read -r status canonical_status digest_baseline digest_match reason observed_refs <<< "$assessment"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$family" "$image" "$status" "$canonical_status" "$digest_baseline" "$digest_match" "$reason" "$observed_refs" \
    >> "$BOUNDARY_ROWS_FILE"

  log_line "  Observed repo digests: $observed_refs"
  if [ -n "$expected_digest" ]; then
    log_line "  Curated digest baseline: $expected_digest"
  else
    log_line "  No curated digest baseline is available in the harness for $image."
  fi
  log_line "  Trust-boundary outcome: $status ($reason)"

  result_key="trust_boundary_$(sanitize_result_key "$image")"
  cld6001_record_result "$result_key" "$status"
}

emit_matches_or_absence() {
  local matches="$1"
  local none_message="$2"

  if [ -n "$matches" ]; then
    printf '%s\n' "$matches" | tee -a "$LOG_FILE"
  else
    log_line "$none_message"
  fi
}

count_matches() {
  local haystack="$1"
  local pattern="$2"
  local matches
  local count

  matches=$(printf '%s\n' "$haystack" | grep -ioE "$pattern" || true)
  if [ -n "$matches" ]; then
    count=$(printf '%s\n' "$matches" | wc -l | tr -d '[:space:]')
  else
    count="0"
  fi

  printf '%s' "$count"
}

generate_supply_chain_analysis_input() {
  python3 - "$ANALYSIS_ROWS_FILE" "$ANALYSIS_INPUT_FILE" <<'PY'
import csv
import json
import sys
from pathlib import Path

rows_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
images = []

with rows_path.open("r", encoding="utf-8", newline="") as handle:
    reader = csv.reader(handle, delimiter="\t")
    for family, image, sbom, attestation, provenance in reader:
        images.append(
            {
                "family": family,
                "image": image,
                "sbom": sbom,
                "attestation": attestation,
                "provenance": provenance,
            }
        )

output_path.parent.mkdir(parents=True, exist_ok=True)
with output_path.open("w", encoding="utf-8") as handle:
    json.dump({"analysis_type": "supply-chain", "images": images}, handle, indent=2)

print(f"Wrote supply-chain analysis input to {output_path}")
PY
}

echo "--- TC20.1:: SBOM extraction from standard images ---"
for image in $STANDARD_IMAGES; do
  log_line "Analyzing: $image"

  if archive_listing=$(get_image_archive_listing "$image"); then
    sbom_matches=$(printf '%s\n' "$archive_listing" | grep -iE "sbom|spdx|cyclonedx|sbom-" || true)
    emit_matches_or_absence "$sbom_matches" "  No SBOM found"
  fi

  if labels_json=$(get_image_labels "$image"); then
    label_matches=$(printf '%s\n' "$labels_json" | grep -iE "sbom|spdx|cyclonedx" || true)
    emit_matches_or_absence "$label_matches" "  No SBOM labels found"
  fi
done

echo "--- TC20.2:: SBOM extraction from DHI images ---"
for image in $DHI_IMAGES; do
  log_line "Analyzing: $image"

  if archive_listing=$(get_image_archive_listing "$image"); then
    sbom_matches=$(printf '%s\n' "$archive_listing" | grep -iE "sbom|spdx|cyclonedx|sbom-" || true)
    emit_matches_or_absence "$sbom_matches" "  No SBOM found"
  fi

  if labels_json=$(get_image_labels "$image"); then
    label_matches=$(printf '%s\n' "$labels_json" | grep -iE "sbom|spdx|cyclonedx" || true)
    emit_matches_or_absence "$label_matches" "  No SBOM labels found"
  fi
done

echo "--- TC20.3:: Attestation verification ---"
for image in $STANDARD_IMAGES $DHI_IMAGES; do
  log_line "Checking attestations for: $image"
  if labels_json=$(get_image_labels "$image"); then
    attestation_matches=$(printf '%s\n' "$labels_json" | grep -iE "attest|sign|verified|integrity" || true)
    emit_matches_or_absence "$attestation_matches" "  No attestation labels found"
  fi
done

echo "--- TC20.4:: Bounded trust-boundary validation ---"
for image in $STANDARD_IMAGES; do
  assess_trust_boundary "standard" "$image"
done

for image in $DHI_IMAGES; do
  assess_trust_boundary "dhi" "$image"
done

echo "--- TC20.5:: Evidence presence comparison ---"
echo "--- Evidence Comparison Summary ---" >> "$LOG_FILE"
printf "%-30s | %s | %s | %s\n" "Image" "SBOM" "Attestation" "Provenance" >> "$LOG_FILE"
printf "%-30s | %s | %s | %s\n" "----------" "----" "------------" "----------" >> "$LOG_FILE"

for image in $STANDARD_IMAGES; do
  sbom="ERROR"
  attest="ERROR"
  provenance="ERROR"
  sbom_archive_count="0"
  sbom_label_count="0"
  archive_ok=false
  labels_ok=false

  if archive_listing=$(get_image_archive_listing "$image"); then
    archive_ok=true
    sbom_archive_count=$(count_matches "$archive_listing" "sbom|spdx|cyclonedx|sbom-")
  fi

  if labels_json=$(get_image_labels "$image"); then
    labels_ok=true
    sbom_label_count=$(count_matches "$labels_json" "sbom|spdx|cyclonedx")
    attest=$(count_matches "$labels_json" "attest|sign|verified|integrity")
    provenance=$(count_matches "$labels_json" "provenance|origin")
  fi

  if $archive_ok || $labels_ok; then
    sbom=$((sbom_archive_count + sbom_label_count))
  fi

  printf "%s\t%s\t%s\t%s\t%s\n" "standard" "$image" "$sbom" "$attest" "$provenance" >> "$ANALYSIS_ROWS_FILE"
  printf "%-30s | %s | %s | %s\n" "$image" "$sbom" "$attest" "$provenance" >> "$LOG_FILE"
done

for image in $DHI_IMAGES; do
  sbom="ERROR"
  attest="ERROR"
  provenance="ERROR"
  sbom_archive_count="0"
  sbom_label_count="0"
  archive_ok=false
  labels_ok=false

  if archive_listing=$(get_image_archive_listing "$image"); then
    archive_ok=true
    sbom_archive_count=$(count_matches "$archive_listing" "sbom|spdx|cyclonedx|sbom-")
  fi

  if labels_json=$(get_image_labels "$image"); then
    labels_ok=true
    sbom_label_count=$(count_matches "$labels_json" "sbom|spdx|cyclonedx")
    attest=$(count_matches "$labels_json" "attest|sign|verified|integrity")
    provenance=$(count_matches "$labels_json" "provenance|origin")
  fi

  if $archive_ok || $labels_ok; then
    sbom=$((sbom_archive_count + sbom_label_count))
  fi

  printf "%s\t%s\t%s\t%s\t%s\n" "dhi" "$image" "$sbom" "$attest" "$provenance" >> "$ANALYSIS_ROWS_FILE"
  printf "%-30s | %s | %s | %s\n" "$image" "$sbom" "$attest" "$provenance" >> "$LOG_FILE"
done

echo "--- TC20.6:: Supply chain analysis generation ---"
if ! generate_supply_chain_analysis_input 2>&1 | tee -a "$LOG_FILE"; then
  log_line "  ERROR: failed to prepare supply-chain analysis input"
elif [ -f "$TC20_ANALYSIS_HELPER" ]; then
  if ! python3 "$TC20_ANALYSIS_HELPER" "$ANALYSIS_INPUT_FILE" \
    --output "$ANALYSIS_OUTPUT_FILE" \
    2>&1 | tee -a "$LOG_FILE"; then
    log_line "  ERROR: supply-chain analysis helper failed"
  fi
else
  log_line "  Supply-chain analysis helper not available; skipping optional JSON report"
fi

echo ""
echo "--- TC20: Supply-Chain Validation ---"
