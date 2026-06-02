#!/bin/bash
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../../" && pwd -P)"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/shared/string-helpers.sh"

TC21_RUNTIME_ID="${RUNNER_RUNTIME_ID:-docker-rootful}"
TC21_PROFILE_ID="${RUNNER_PROFILE_SLUG:-${RUNNER_ENVIRONMENT_STATE:-unscoped}}"
TEST_RESULTS_DIR="${TEST_RESULTS_DIR:?TEST_RESULTS_DIR is required}"
TC21_RESULTS_DIR="${RUNNER_RESULTS_DIR:?RUNNER_RESULTS_DIR is required}"
LOG_FILE="${TC21_RESULTS_DIR}/tc21-control-impact-matrix.log"
TC21_MATRIX_FILE="control-impact-matrix-${TC21_PROFILE_ID}.json"
TC21_RECOMMENDATION_FILE="generated-baseline-recommendation-${TC21_PROFILE_ID}.md"

mkdir -p "$TC21_RESULTS_DIR"

read_runner_paths() {
  local raw="$1"
  local line

  while IFS= read -r line; do
    [ -n "$line" ] && printf '%s\n' "$line"
  done <<<"$raw"
}

read_runner_words() {
  local raw="$1"
  local word

  for word in $raw; do
    printf '%s\n' "$word"
  done
}

read_runner_collections() {
  local raw="$1"
  local normalized="${raw//,/ }"
  local collection

  for collection in $normalized; do
    printf '%s\n' "$collection"
  done
}

canonical_test_id() {
  local raw="${1:-}"

  if [[ "$raw" =~ ^(tc[0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  printf '%s\n' "$raw"
}

TC18_RECORD="${RUNNER_TC18_RECORD:-}"
TC19_RECORD="${RUNNER_TC19_RECORD:-}"
TC20_RECORD="${RUNNER_TC20_RECORD:-}"

TC18_ARTIFACT_FILE="${RUNNER_TC18_ARTIFACT_FILE:-}"
TC19_ARTIFACTS_DIR="${RUNNER_TC19_ARTIFACTS_DIR:-}"
TC20_ARTIFACTS_DIR="${RUNNER_TC20_ARTIFACTS_DIR:-}"
CURRENT_RUN_SESSION_ID="${RUNNER_RUN_SESSION_ID:-}"

tc20_required_artifacts=(
  "tc20-supply-chain.log"
  "supply-chain-observations.tsv"
  "supply-chain-analysis-input.json"
)

tc21_generated_outputs=(
  "${TC21_MATRIX_FILE}"
  "${TC21_RECOMMENDATION_FILE}"
)

append_tc21_log() {
  printf '%s\n' "$1" | tee -a "$LOG_FILE"
}

record_input_section() {
  local title="$1"
  local body="$2"

  append_tc21_log ""
  append_tc21_log "### ${title}"
  printf '%s\n' "$body" >> "$LOG_FILE"
}

build_phase_manifest_log_body() {
  local body="RUNNER_DEPENDENCY_COLLECTIONS=${RUNNER_DEPENDENCY_COLLECTIONS:-}"
  local c env_suffix manifest_name expected_name manifest_val expected_val

  if [ -n "${RUNNER_DEPENDENCY_COLLECTIONS:-}" ]; then
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      env_suffix="${c^^}"
      env_suffix="${env_suffix//-/_}"
      manifest_name="RUNNER_COLLECTION_${env_suffix}_MANIFEST"
      expected_name="RUNNER_COLLECTION_${env_suffix}_EXPECTED_TESTS"

      manifest_val=""
      expected_val=""
      if [ "${!manifest_name+x}" = x ]; then
        manifest_val="${!manifest_name}"
      fi
      if [ "${!expected_name+x}" = x ]; then
        expected_val="${!expected_name}"
      fi

      body="${body}

${expected_name}=${expected_val}
${manifest_name}=${manifest_val}"
    done < <(read_runner_collections "${RUNNER_DEPENDENCY_COLLECTIONS:-}")
  fi

  printf '%s\n' "$body"
}

require_current_run_session_id() {
  if [ -z "$CURRENT_RUN_SESSION_ID" ]; then
    append_tc21_log "BLOCK: RUNNER_RUN_SESSION_ID is missing."
    exit 3
  fi
}

normalize_runner_result() {
  local raw="${1:-unknown}"
  local normalized=""

  normalized="$(cld6001_to_lower "$raw")"
  case "$normalized" in
    success|pass) printf 'pass' ;;
    blocked|block) printf 'block' ;;
    failure|fail) printf 'fail' ;;
    *) printf '%s' "$normalized" ;;
  esac
}

read_context_field() {
  local context_path="$1"
  local field="$2"

  [ -f "$context_path" ] || return 1
  python3 - "$context_path" "$field" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
value = data.get(field)
if value is None:
    sys.exit(1)
print(value)
PY
}

record_result_is_acceptable() {
  local test_id="$1"
  local result="$2"

  case "$test_id" in
    tc20)
      case "$result" in
        pass|block|fail) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *)
      case "$result" in
        pass|block|fail) return 0 ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

require_phase_manifest() {
  local collection_name="$1"
  local manifest_name="$2"
  local expected_name="$3"
  local required_tests_name="$4"

  local -n manifest_ref="$manifest_name"
  local -n expected_ref="$expected_name"
  local -n required_tests_ref="$required_tests_name"
  local manifest_count="${#manifest_ref[@]}"
  local expected_count="${#expected_ref[@]}"
  local required_count="${#required_tests_ref[@]}"
  local record
  local -A seen_tests=()
  local test_id
  local normalized_result
  local context_path
  local context_result
  local context_run_session_id

  if (( expected_count == 0 )); then
    append_tc21_log "BLOCK: ${collection_name} expected-test list is missing."
    exit 3
  fi

  if (( manifest_count == 0 )); then
    append_tc21_log "BLOCK: ${collection_name} manifest is missing."
    exit 3
  fi

  if (( manifest_count != expected_count )); then
    append_tc21_log "BLOCK: ${collection_name} manifest count (${manifest_count}) does not match expected count (${expected_count})."
    exit 3
  fi

  for record in "${manifest_ref[@]}"; do
    IFS='|' read -r test_id normalized_result _ _ context_path <<< "$record"
    normalized_result="$(normalize_runner_result "$normalized_result")"

    if [ -z "$test_id" ]; then
      append_tc21_log "BLOCK: ${collection_name} manifest contains an empty test identifier."
      exit 3
    fi

    if [ -n "${seen_tests[$test_id]:-}" ]; then
      append_tc21_log "BLOCK: ${collection_name} manifest contains duplicate entry for ${test_id}."
      exit 3
    fi
    seen_tests["$test_id"]=1

    if ! record_result_is_acceptable "$test_id" "$normalized_result"; then
      append_tc21_log "BLOCK: ${collection_name} manifest includes unacceptable result '${normalized_result}' for ${test_id}."
      exit 3
    fi

    if [ -z "$context_path" ] || [ ! -f "$context_path" ]; then
      append_tc21_log "BLOCK: ${collection_name} execution context is missing for ${test_id} (${context_path:-unset})."
      exit 3
    fi

    if context_result="$(read_context_field "$context_path" "result" 2>/dev/null)"; then
      context_result="$(normalize_runner_result "$context_result")"
      if [ "$context_result" != "$normalized_result" ]; then
        append_tc21_log "BLOCK: ${collection_name} context result mismatch for ${test_id} (manifest=${normalized_result}, context=${context_result})."
        exit 3
      fi
    fi

    if ! context_run_session_id="$(read_context_field "$context_path" "run_session_id" 2>/dev/null)"; then
      append_tc21_log "BLOCK: ${collection_name} current-run provenance is missing for ${test_id}."
      exit 3
    fi

    if [ "$context_run_session_id" != "$CURRENT_RUN_SESSION_ID" ]; then
      append_tc21_log "BLOCK: ${collection_name} current-run provenance mismatch for ${test_id} (expected=${CURRENT_RUN_SESSION_ID}, context=${context_run_session_id})."
      exit 3
    fi
  done

  for test_id in "${required_tests_ref[@]}"; do
    if [ -z "${seen_tests[$test_id]:-}" ]; then
      append_tc21_log "BLOCK: ${collection_name} manifest is missing required test ${test_id}."
      exit 3
    fi
  done
}

require_predecessor_record() {
  local label="$1"
  local record="$2"
  local required_context="$3"
  local expected_test_id="$4"

  local test_id
  local normalized_result
  local result_dir
  local log_path
  local context_path
  local context_result
  local context_run_session_id

  if [ -z "$record" ]; then
    append_tc21_log "BLOCK: ${label} predecessor record is missing."
    exit 3
  fi

  IFS='|' read -r test_id normalized_result result_dir log_path context_path <<< "$record"
  normalized_result="$(normalize_runner_result "$normalized_result")"

  if [ "$(canonical_test_id "$test_id")" != "$expected_test_id" ]; then
    append_tc21_log "BLOCK: ${label} predecessor record references ${test_id:-<empty>} instead of ${expected_test_id}."
    exit 3
  fi

  if [ -z "$result_dir" ] || [ ! -d "$result_dir" ]; then
    append_tc21_log "BLOCK: ${label} predecessor result directory is missing (${result_dir:-unset})."
    exit 3
  fi

  if [ -z "$log_path" ] || [ ! -f "$log_path" ]; then
    append_tc21_log "BLOCK: ${label} predecessor log file is missing (${log_path:-unset})."
    exit 3
  fi

  if [ "$required_context" = "required" ]; then
    if [ -z "$context_path" ] || [ ! -f "$context_path" ]; then
      append_tc21_log "BLOCK: ${label} predecessor execution context is missing (${context_path:-unset})."
      exit 3
    fi

    if context_result="$(read_context_field "$context_path" "result" 2>/dev/null)"; then
      context_result="$(normalize_runner_result "$context_result")"
      if [ "$context_result" != "$normalized_result" ]; then
        append_tc21_log "BLOCK: ${label} predecessor context mismatch (record=${normalized_result}, context=${context_result})."
        exit 3
      fi
    fi

    if ! context_run_session_id="$(read_context_field "$context_path" "run_session_id" 2>/dev/null)"; then
      append_tc21_log "BLOCK: ${label} predecessor current-run provenance is missing."
      exit 3
    fi

    if [ "$context_run_session_id" != "$CURRENT_RUN_SESSION_ID" ]; then
      append_tc21_log "BLOCK: ${label} predecessor current-run provenance mismatch (expected=${CURRENT_RUN_SESSION_ID}, context=${context_run_session_id})."
      exit 3
    fi
  fi

  if ! record_result_is_acceptable "$expected_test_id" "$normalized_result"; then
    append_tc21_log "BLOCK: ${label} predecessor result '${normalized_result}' is not accepted for synthesis."
    exit 3
  fi
}

require_tc21_inputs() {
  local artifact_name

  require_current_run_session_id

  if [ -z "${RUNNER_DEPENDENCY_COLLECTIONS:-}" ]; then
    append_tc21_log "BLOCK: RUNNER_DEPENDENCY_COLLECTIONS is missing."
    exit 3
  fi

  local c env_suffix manifest_name expected_name manifest_val expected_val
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    env_suffix="${c^^}"
    env_suffix="${env_suffix//-/_}"
    manifest_name="RUNNER_COLLECTION_${env_suffix}_MANIFEST"
    expected_name="RUNNER_COLLECTION_${env_suffix}_EXPECTED_TESTS"

    manifest_val=""
    expected_val=""
    if [ "${!manifest_name+x}" = x ]; then
      manifest_val="${!manifest_name}"
    fi
    if [ "${!expected_name+x}" = x ]; then
      expected_val="${!expected_name}"
    fi

    local -a path_records=()
    local -a expected_list=()
    mapfile -t path_records < <(read_runner_paths "$manifest_val")
    mapfile -t expected_list < <(read_runner_words "$expected_val")

    if [ ${#expected_list[@]} -eq 0 ] && [ ${#path_records[@]} -eq 0 ]; then
      append_tc21_log "BLOCK: Collection $c is listed but empty."
      exit 3
    fi

    if [ ${#expected_list[@]} -gt 0 ] || [ ${#path_records[@]} -gt 0 ]; then
      require_phase_manifest "Collection $c" path_records expected_list expected_list
    fi
  done < <(read_runner_collections "${RUNNER_DEPENDENCY_COLLECTIONS:-}")

  require_predecessor_record "TC18" "$TC18_RECORD" required tc18
  if [ -z "$TC18_ARTIFACT_FILE" ] || [ ! -f "$TC18_ARTIFACT_FILE" ]; then
    append_tc21_log "BLOCK: TC18 predecessor artifact is missing (${TC18_ARTIFACT_FILE:-unset})."
    exit 3
  fi

  require_predecessor_record "TC19" "$TC19_RECORD" required tc19
  if [ -z "$TC19_ARTIFACTS_DIR" ] || [ ! -d "$TC19_ARTIFACTS_DIR" ]; then
    append_tc21_log "BLOCK: TC19 predecessor artifact directory is missing (${TC19_ARTIFACTS_DIR:-unset})."
    exit 3
  fi
  for artifact_name in "tc19-network-isolation.log" "test-results.txt"; do
    if [ ! -f "${TC19_ARTIFACTS_DIR}/${artifact_name}" ]; then
      append_tc21_log "BLOCK: missing current-run TC19 predecessor evidence (${artifact_name})"
      exit 3
    fi
  done

  require_predecessor_record "TC20" "$TC20_RECORD" required tc20
  if [ -z "$TC20_ARTIFACTS_DIR" ] || [ ! -d "$TC20_ARTIFACTS_DIR" ]; then
    append_tc21_log "BLOCK: TC20 predecessor artifact directory is missing (${TC20_ARTIFACTS_DIR:-unset})."
    exit 3
  fi
  for artifact_name in "${tc20_required_artifacts[@]}"; do
    if [ ! -f "${TC20_ARTIFACTS_DIR}/${artifact_name}" ]; then
      append_tc21_log "BLOCK: TC20 predecessor artifact '${artifact_name}' is missing."
      exit 3
    fi
  done
}

resolve_repo_path() {
  local input_path="$1"

  if [ -z "$input_path" ]; then
    return 1
  fi

  case "$input_path" in
    /*)
      printf '%s\n' "$input_path"
      ;;
    *)
      printf '%s\n' "${REPO_ROOT}/${input_path}"
      ;;
  esac
}

collect_runner_artifact_targets() {
  local targets=()
  local candidate
  local resolved

  for candidate in "${RUNNER_ARTIFACTS_DIR:-}" "${ARTIFACTS_DIR:-}"; do
    if [ -n "$candidate" ]; then
      if resolved="$(resolve_repo_path "$candidate" 2>/dev/null)"; then
        targets+=("$resolved")
      fi
    fi
  done

  if [ ${#targets[@]} -eq 0 ]; then
    targets+=("${TC21_RESULTS_DIR}")
  fi

  printf '%s\n' "${targets[@]}"
}

mapfile -t artifact_targets < <(collect_runner_artifact_targets)

mirror_tc21_artifact() {
  local source_path="$1"
  local target_dir
  local source_dir

  [ -f "$source_path" ] || return 1
  source_dir="$(cd "$(dirname "$source_path")" && pwd)"

  for target_dir in "${artifact_targets[@]}"; do
    mkdir -p "$target_dir"
    if [ "$source_dir" = "$(cd "$target_dir" && pwd)" ]; then
      continue
    fi
    cp "$source_path" "${target_dir}/"
  done
}

clear_prior_outputs() {
  local output_name

  for output_name in "${tc21_generated_outputs[@]}"; do
    rm -f "${TC21_RESULTS_DIR}/${output_name}"
  done
}

append_tc21_log "--- TC21: docker-rootful Current-Run Control-Impact Synthesis ---"
append_tc21_log "Results directory: ${TC21_RESULTS_DIR}"
append_tc21_log "Profile axis: ${TC21_PROFILE_ID}"

record_input_section "Phase manifests" "$(build_phase_manifest_log_body)"

record_input_section "Predecessor records" \
"RUNNER_RUN_SESSION_ID=${CURRENT_RUN_SESSION_ID:-}

RUNNER_TC18_RECORD=${TC18_RECORD:-}
RUNNER_TC18_ARTIFACT_FILE=${TC18_ARTIFACT_FILE:-}

RUNNER_TC19_RECORD=${TC19_RECORD:-}
RUNNER_TC19_ARTIFACTS_DIR=${TC19_ARTIFACTS_DIR:-}

RUNNER_TC20_RECORD=${TC20_RECORD:-}
RUNNER_TC20_ARTIFACTS_DIR=${TC20_ARTIFACTS_DIR:-}"

append_tc21_log "--- TC21.1:: Validate current-run prerequisites ---"
require_tc21_inputs
append_tc21_log "Current-run prerequisite chain verified."

append_tc21_log "--- TC21.2:: Generate runtime-scoped control-impact synthesis ---"
clear_prior_outputs

if ! python3 "${SCRIPT_DIR}/../generator.py" \
  --runtime "${TC21_RUNTIME_ID}" \
  --matrix-path "${TC21_RESULTS_DIR}/${TC21_MATRIX_FILE}" \
  --recommendation-path "${TC21_RESULTS_DIR}/${TC21_RECOMMENDATION_FILE}"; then
  append_tc21_log "FAIL: Current-run synthesis generation failed."
  exit 1
fi

append_tc21_log "--- TC21.3:: Mirror generated artifacts ---"
for artifact_name in "${tc21_generated_outputs[@]}"; do
  mirror_tc21_artifact "${TC21_RESULTS_DIR}/${artifact_name}"
  append_tc21_log "Generated TC21 artifact: ${artifact_name}"
done

append_tc21_log ""
append_tc21_log "Docker current-run control-impact synthesis completed."
append_tc21_log "Artifacts:"
append_tc21_log "  - ${TC21_RESULTS_DIR}/${TC21_MATRIX_FILE}"
append_tc21_log "  - ${TC21_RESULTS_DIR}/${TC21_RECOMMENDATION_FILE}"
