#!/bin/bash

if [ -n "${DOCKER_BENCH_HELPERS_LOADED:-}" ]; then
    return 0
fi
readonly DOCKER_BENCH_HELPERS_LOADED=1

docker_bench_output_base() {
    local output_json="$1"
    printf '%s\n' "${output_json%.json}"
}

run_docker_bench_capture() {
    local output_json="$1"
    local output_base=""

    mkdir -p -- "$(dirname -- "$output_json")"
    output_base="$(docker_bench_output_base "$output_json")"

    if ! command -v docker-bench-security >/dev/null 2>&1; then
        printf 'docker-bench-security is not installed or not on PATH.\n' >&2
        return 1
    fi

    if ! docker-bench-security -l "$output_base" >/dev/null 2>&1; then
        printf 'Docker Bench execution failed for %s.\n' "$output_json" >&2
        return 1
    fi

    if [ ! -s "$output_json" ]; then
        printf 'Docker Bench JSON output missing: %s\n' "$output_json" >&2
        return 1
    fi

    return 0
}

normalize_docker_bench_level() {
    local requested_level="${1:-}"

    case "${requested_level^^}" in
        WARNING)
            printf 'WARN\n'
            ;;
        *)
            printf '%s\n' "${requested_level^^}"
            ;;
    esac
}

count_docker_bench_level() {
    local json_file="$1"
    local requested_level=""
    local count=""

    requested_level="$(normalize_docker_bench_level "${2:-}")"

    count="$(python3 - "$json_file" "$requested_level" <<'PY'
import json
import sys

json_path = sys.argv[1]
requested_level = sys.argv[2]

with open(json_path, encoding="utf-8") as handle:
    payload = json.load(handle)

checks = payload.get("Checks", [])
if not isinstance(checks, list):
    raise SystemExit(f"Unexpected Docker Bench JSON structure in {json_path}")

count = 0
for item in checks:
    if not isinstance(item, dict):
        continue
    level = str(item.get("Level", "")).upper()
    if level == requested_level:
        count += 1

print(count)
PY
)" || return 1

    case "$count" in
        ''|*[!0-9]*)
            printf 'Invalid Docker Bench count output for %s: %s\n' "$requested_level" "$count" >&2
            return 1
            ;;
    esac

    printf '%s\n' "$count"
}
