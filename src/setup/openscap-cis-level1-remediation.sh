#!/bin/bash
set -Eeuo pipefail

OUTPUT_DIR=""
PROFILE_ID="${CLD6001_OPENSCAP_PROFILE_ID:-xccdf_org.ssgproject.content_profile_cis_server_l1}"
DATASTREAM="${CLD6001_OPENSCAP_DATASTREAM:-/usr/share/xml/scap/ssg/content/ssg-almalinux10-ds.xml}"
MAX_ROUNDS="${CLD6001_OPENSCAP_MAX_ROUNDS:-3}"

usage() {
    cat <<'EOF'
Usage: sudo bash src/setup/openscap-cis-level1-remediation.sh --output-dir <dir> [--max-rounds <n>]

Runs the official OpenSCAP AlmaLinux 10 CIS Server L1 workflow:
  1. evaluate and export before-state evidence
  2. generate failed-rule remediation from that result set
  3. apply the generated remediation script
  4. re-evaluate and export after-state evidence
  5. repeat while OpenSCAP still reports failures and remediation makes progress

This workflow targets the host OS only. Container images are not evaluated or modified.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="${2:-}"
            shift 2
            ;;
        --profile)
            PROFILE_ID="${2:-}"
            shift 2
            ;;
        --datastream)
            DATASTREAM="${2:-}"
            shift 2
            ;;
        --max-rounds)
            MAX_ROUNDS="${2:-}"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

[ -n "$OUTPUT_DIR" ] || { printf 'Missing --output-dir\n' >&2; exit 1; }
printf '%s\n' "$MAX_ROUNDS" | grep -Eq '^[1-9][0-9]*$' || { printf 'Invalid --max-rounds: %s\n' "$MAX_ROUNDS" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { printf 'OpenSCAP remediation requires root privileges\n' >&2; exit 1; }
command -v oscap >/dev/null 2>&1 || { printf 'Missing oscap; install openscap-scanner\n' >&2; exit 1; }
[ -f "$DATASTREAM" ] || { printf 'Missing OpenSCAP data stream: %s\n' "$DATASTREAM" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"

printf '%s\n' 'Warning: OpenSCAP evaluation may take several minutes and can look stalled while benchmark scans and generated remediation scripts run.'

BEFORE_ARF="$OUTPUT_DIR/openscap-before-results-arf.xml"
BEFORE_RESULTS="$OUTPUT_DIR/openscap-before-results.xml"
BEFORE_REPORT="$OUTPUT_DIR/openscap-before-report.html"
BEFORE_LOG="$OUTPUT_DIR/openscap-before-eval.log"
REMEDIATION_SCRIPT="$OUTPUT_DIR/openscap-generated-remediation.sh"
REMEDIATION_LOG="$OUTPUT_DIR/openscap-generated-remediation.log"
AFTER_ARF="$OUTPUT_DIR/openscap-after-results-arf.xml"
AFTER_RESULTS="$OUTPUT_DIR/openscap-after-results.xml"
AFTER_REPORT="$OUTPUT_DIR/openscap-after-report.html"
AFTER_LOG="$OUTPUT_DIR/openscap-after-eval.log"
SUMMARY_JSON="$OUTPUT_DIR/openscap-remediation-summary.json"
STATE_JSON="$OUTPUT_DIR/openscap-remediation-state.json"
ABORTED_BEFORE_SUMMARY_STOP_REASON="manual review required: OpenSCAP remediation aborted before summary emission after host mutation"

rm -f "$SUMMARY_JSON" "$STATE_JSON"

copy_round_aliases() {
    local round_dir="$1"

    cp -f "$round_dir/openscap-before-results-arf.xml" "$BEFORE_ARF"
    cp -f "$round_dir/openscap-before-results.xml" "$BEFORE_RESULTS"
    cp -f "$round_dir/openscap-before-report.html" "$BEFORE_REPORT"
    cp -f "$round_dir/openscap-before-eval.log" "$BEFORE_LOG"
    cp -f "$round_dir/openscap-generated-remediation.sh" "$REMEDIATION_SCRIPT"
    cp -f "$round_dir/openscap-generated-remediation.log" "$REMEDIATION_LOG"
    cp -f "$round_dir/openscap-after-results-arf.xml" "$AFTER_ARF"
    cp -f "$round_dir/openscap-after-results.xml" "$AFTER_RESULTS"
    cp -f "$round_dir/openscap-after-report.html" "$AFTER_REPORT"
    cp -f "$round_dir/openscap-after-eval.log" "$AFTER_LOG"
}

run_eval() {
    local results_arf="$1"
    local results_xml="$2"
    local report_html="$3"
    local log_file="$4"
    local status=0

    set +e
    oscap xccdf eval \
        --profile "$PROFILE_ID" \
        --results-arf "$results_arf" \
        --results "$results_xml" \
        --report "$report_html" \
        "$DATASTREAM" \
        > "$log_file" 2>&1
    status=$?
    set -e

    case "$status" in
        0|2) return 0 ;;
        *) return "$status" ;;
    esac
}

latest_test_result_id() {
    local results_xml="$1"
    python3 - "$results_xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
ids = []
for elem in root.iter():
    if elem.tag.rsplit("}", 1)[-1] == "TestResult":
        result_id = elem.attrib.get("id")
        if result_id:
            ids.append(result_id)
if ids:
    print(ids[-1])
PY
}

fail_count() {
    local results_xml="$1"
    python3 - "$results_xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
failures = 0
for elem in root.iter():
    if elem.tag.rsplit("}", 1)[-1] != "rule-result":
        continue
    for child in elem:
        if child.tag.rsplit("}", 1)[-1] == "result" and (child.text or "").strip() == "fail":
            failures += 1
            break
print(failures)
PY
}

failing_rule_signature() {
    local results_xml="$1"
    python3 - "$results_xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
failures = []
for elem in root.iter():
    if elem.tag.rsplit("}", 1)[-1] != "rule-result":
        continue
    for child in elem:
        if child.tag.rsplit("}", 1)[-1] == "result" and (child.text or "").strip() == "fail":
            rule_id = (elem.attrib.get("idref") or elem.attrib.get("id") or "").strip()
            if rule_id:
                failures.append(rule_id)
            break
print("|".join(sorted(dict.fromkeys(failures))))
PY
}

write_state() {
    local phase="$1"
    local host_mutation_possible="$2"
    local summary_written="$3"
    local stop_reason="$4"
    local current_round="$5"
    local rounds_completed="$6"
    local remediation_status="$7"
    local final_verified="$8"

    python3 - "$STATE_JSON" "$phase" "$host_mutation_possible" "$summary_written" "$stop_reason" "$current_round" "$rounds_completed" "$MAX_ROUNDS" "$remediation_status" "$final_verified" <<'PY'
import json
import sys
from datetime import datetime, timezone

state_path, phase, host_mutation_possible, summary_written, stop_reason, current_round, rounds_completed, max_rounds, remediation_status, final_verified = sys.argv[1:11]
payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "phase": phase,
    "host_mutation_possible": host_mutation_possible == "true",
    "summary_written": summary_written == "true",
    "stop_reason": stop_reason or None,
    "current_round": int(current_round),
    "rounds_completed": int(rounds_completed),
    "max_rounds": int(max_rounds),
    "remediation_exit_status": int(remediation_status),
    "final_verified": final_verified == "true",
}
with open(state_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
}

signature_seen() {
    local needle="$1"
    local seen_signatures="$2"
    local candidate=""

    [ -n "$needle" ] || return 1

    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        [ "$candidate" = "$needle" ] && return 0
    done <<EOF
$seen_signatures
EOF

    return 1
}

append_signature() {
    local seen_signatures="$1"
    local signature="$2"

    [ -n "$signature" ] || {
        printf '%s' "$seen_signatures"
        return 0
    }

    if [ -n "$seen_signatures" ]; then
        printf '%s\n%s' "$seen_signatures" "$signature"
    else
        printf '%s' "$signature"
    fi
}

write_summary() {
    local before_fail_count="$1"
    local after_fail_count="$2"
    local remediation_status="$3"
    local rounds_completed="$4"
    local stop_reason="$5"

    python3 - "$SUMMARY_JSON" "$PROFILE_ID" "$DATASTREAM" "$before_fail_count" "$after_fail_count" "$remediation_status" "$OUTPUT_DIR" "$rounds_completed" "$stop_reason" "$MAX_ROUNDS" <<'PY'
import json
import sys
from datetime import datetime, timezone

summary_path, profile, datastream, before, after, remediation_status, output_dir, rounds_completed, stop_reason, max_rounds = sys.argv[1:11]
after_count = int(after)
data = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "profile_id": profile,
    "datastream": datastream,
    "scope": "host-os-only",
    "image_scope": "excluded",
    "before_fail_count": int(before),
    "after_fail_count": after_count,
    "remediation_exit_status": int(remediation_status),
    "rounds_completed": int(rounds_completed),
    "max_rounds": int(max_rounds),
    "stop_reason": stop_reason,
    "final_verified": after_count == 0 and int(remediation_status) == 0,
    "output_dir": output_dir,
    "artifacts": {
        "before_results": "openscap-before-results.xml",
        "before_report": "openscap-before-report.html",
        "remediation_script": "openscap-generated-remediation.sh",
        "remediation_log": "openscap-generated-remediation.log",
        "after_results": "openscap-after-results.xml",
        "after_report": "openscap-after-report.html",
    },
}
with open(summary_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

round=1
rounds_completed=0
initial_fail_count=""
after_fail_count=""
remediation_status=0
stop_reason="maximum OpenSCAP remediation rounds reached"
seen_fail_signatures=""

write_state "starting" "false" "false" "" "$round" "$rounds_completed" "$remediation_status" "false"

while [[ "$round" -le "$MAX_ROUNDS" ]]; do # [[:
    round_label="$(printf 'round-%02d' "$round")"
    round_dir="$OUTPUT_DIR/$round_label"
    mkdir -p "$round_dir"

    round_before_arf="$round_dir/openscap-before-results-arf.xml"
    round_before_results="$round_dir/openscap-before-results.xml"
    round_before_report="$round_dir/openscap-before-report.html"
    round_before_log="$round_dir/openscap-before-eval.log"
    round_remediation_script="$round_dir/openscap-generated-remediation.sh"
    round_remediation_log="$round_dir/openscap-generated-remediation.log"
    round_after_arf="$round_dir/openscap-after-results-arf.xml"
    round_after_results="$round_dir/openscap-after-results.xml"
    round_after_report="$round_dir/openscap-after-report.html"
    round_after_log="$round_dir/openscap-after-eval.log"

    run_eval "$round_before_arf" "$round_before_results" "$round_before_report" "$round_before_log"
    before_fail_count="$(fail_count "$round_before_results")"
    before_fail_signature="$(failing_rule_signature "$round_before_results")"
    if [ -z "$initial_fail_count" ]; then
        initial_fail_count="$before_fail_count"
        seen_fail_signatures="$(append_signature "$seen_fail_signatures" "$before_fail_signature")"
    fi
    if [ "$before_fail_count" -eq 0 ]; then
        cp -f "$round_before_arf" "$round_after_arf"
        cp -f "$round_before_results" "$round_after_results"
        cp -f "$round_before_report" "$round_after_report"
        cp -f "$round_before_log" "$round_after_log"
        : > "$round_remediation_script"
        : > "$round_remediation_log"
        after_fail_count=0
        stop_reason="OpenSCAP CIS benchmark verified"
        copy_round_aliases "$round_dir"
        break
    fi

    result_id="$(latest_test_result_id "$round_before_results")"
    [ -n "$result_id" ] || { printf 'Could not determine OpenSCAP TestResult ID from %s\n' "$round_before_results" >&2; exit 1; }

    oscap xccdf generate fix \
        --fix-type bash \
        --result-id "$result_id" \
        --output "$round_remediation_script" \
        "$round_before_results"
    chmod 0700 "$round_remediation_script"
    write_state "applying-generated-remediation" "true" "false" "$ABORTED_BEFORE_SUMMARY_STOP_REASON" "$round" "$rounds_completed" "$remediation_status" "false"

    round_remediation_status=0
    set +e
    bash "$round_remediation_script" > "$round_remediation_log" 2>&1
    round_remediation_status=$?
    set -e
    if [ "$round_remediation_status" -ne 0 ] && [ "$remediation_status" -eq 0 ]; then
        remediation_status="$round_remediation_status"
    fi
    write_state "evaluating-post-remediation" "true" "false" "$ABORTED_BEFORE_SUMMARY_STOP_REASON" "$round" "$rounds_completed" "$remediation_status" "false"

    run_eval "$round_after_arf" "$round_after_results" "$round_after_report" "$round_after_log"
    after_fail_count="$(fail_count "$round_after_results")"
    after_fail_signature="$(failing_rule_signature "$round_after_results")"
    rounds_completed=$((rounds_completed + 1))
    copy_round_aliases "$round_dir"

    if [ "$after_fail_count" -eq 0 ]; then
        stop_reason="OpenSCAP CIS benchmark verified"
        if [ "$remediation_status" -ne 0 ]; then
            stop_reason="OpenSCAP CIS benchmark verified with failed remediation round(s)"
        fi
        break
    fi
    if [ "$after_fail_signature" = "$before_fail_signature" ]; then
        printf 'Warning: OpenSCAP remediation made no progress in %s; refusing to rerun the same host state without manual review.\n' "$round_label" >&2
        stop_reason="no further OpenSCAP remediation progress"
        break
    fi
    if signature_seen "$after_fail_signature" "$seen_fail_signatures"; then
        printf 'Warning: OpenSCAP remediation made no progress and returned to a previously observed failing state in %s; refusing to rerun the same host state without manual review.\n' "$round_label" >&2
        stop_reason="no further OpenSCAP remediation progress"
        break
    fi

    seen_fail_signatures="$(append_signature "$seen_fail_signatures" "$after_fail_signature")"

    round=$((round + 1))
done

if [ -z "$after_fail_count" ]; then
    after_fail_count="$initial_fail_count"
fi
write_summary "$initial_fail_count" "$after_fail_count" "$remediation_status" "$rounds_completed" "$stop_reason"
if [ "$after_fail_count" -eq 0 ] && [ "$remediation_status" -eq 0 ]; then
    final_verified="true"
else
    final_verified="false"
fi
write_state "complete" "false" "true" "$stop_reason" "$round" "$rounds_completed" "$remediation_status" "$final_verified"

printf 'OpenSCAP CIS L1 remediation workflow complete\n'
printf 'before_fail_count=%s\n' "$before_fail_count"
printf 'after_fail_count=%s\n' "$after_fail_count"
printf 'remediation_exit_status=%s\n' "$remediation_status"
printf 'artifacts=%s\n' "$OUTPUT_DIR"
