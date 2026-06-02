#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../../src/shared/noninteractive-runtime.sh"
source "$SCRIPT_DIR/../profiles/environment-states.sh"

ACTION="apply"
STATE=""
RUNTIME=""
RESULTS_DIR=""

usage() {
    cat <<'EOF'
Usage: bash src/setup/apply-state.sh [apply|verify|snapshot] --state <state> --runtime <runtime> --results-dir <dir>
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        apply|verify|snapshot)
            ACTION="$1"
            shift
            ;;
        --state)
            STATE="${2:-}"
            shift 2
            ;;
        --runtime)
            RUNTIME="${2:-}"
            shift 2
            ;;
        --results-dir)
            RESULTS_DIR="${2:-}"
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

[ -n "$STATE" ] || { printf 'Missing --state\n' >&2; exit 1; }
[ -n "$RUNTIME" ] || { printf 'Missing --runtime\n' >&2; exit 1; }
[ -n "$RESULTS_DIR" ] || { printf 'Missing --results-dir\n' >&2; exit 1; }
environment_state_exists "$STATE" || { printf 'Unknown environment state: %s\n' "$STATE" >&2; exit 1; }

STATE_ROOT="$RESULTS_DIR"
if [ -n "${CLD6001_RUN_ROOT:-}" ]; then
    STATE_ROOT="${CLD6001_RUN_ROOT}/environment-state/${STATE}/${RUNTIME}"
fi

mkdir -p "$STATE_ROOT"

HOST_PROFILE="$(environment_state_host_profile_for "$STATE")"
RUNTIME_PROFILE="$(environment_state_runtime_profile_for "$STATE")"

runtime_engine_for() {
    case "$1" in
        docker-rootful|docker-rootless) printf 'docker\n' ;;
        podman-rootless) printf 'podman\n' ;;
        *) return 1 ;;
    esac
}

docker_mode_for() {
    case "$1" in
        docker-rootful) printf 'rootful\n' ;;
        docker-rootless) printf 'rootless\n' ;;
        *) return 1 ;;
    esac
}

sudo_prefix=()
if [ "$(id -u)" -ne 0 ]; then
    sudo_prefix=(sudo -n)
fi

sudo_refresh() {
    cld6001_sudo_refresh "src/setup/apply-state.sh"
}

run_sudo_noninteractive() {
    sudo_refresh
    "${sudo_prefix[@]}" "$@"
}

apply_host_profile() {
    local host_profile_action="apply"

    if [ "$HOST_PROFILE" = "baseline-host" ]; then
        host_profile_action="reset"
    fi

    if [ "$(id -u)" -eq 0 ]; then
        CLD6001_OPENSCAP_REMEDIATION_OUTPUT_DIR="$STATE_ROOT/openscap-remediation" \
        CLD6001_OPENSCAP_MAX_ROUNDS="${CLD6001_OPENSCAP_MAX_ROUNDS:-3}" \
        CLD6001_UNSAFE_NONTHESIS_ALLOW_LIVE_HOST_RESET="${CLD6001_UNSAFE_NONTHESIS_ALLOW_LIVE_HOST_RESET:-}" \
            bash "$SCRIPT_DIR/apply-host-profile.sh" "$host_profile_action" --profile "$HOST_PROFILE"
    else
        sudo_refresh
        sudo -n env \
            CLD6001_OPENSCAP_REMEDIATION_OUTPUT_DIR="$STATE_ROOT/openscap-remediation" \
            CLD6001_OPENSCAP_MAX_ROUNDS="${CLD6001_OPENSCAP_MAX_ROUNDS:-3}" \
            CLD6001_UNSAFE_NONTHESIS_ALLOW_LIVE_HOST_RESET="${CLD6001_UNSAFE_NONTHESIS_ALLOW_LIVE_HOST_RESET:-}" \
            bash "$SCRIPT_DIR/apply-host-profile.sh" "$host_profile_action" --profile "$HOST_PROFILE"
    fi
}

verify_host_profile() {
    run_sudo_noninteractive bash "$SCRIPT_DIR/apply-host-profile.sh" verify --profile "$HOST_PROFILE"
}

apply_runtime_profile() {
    case "$(runtime_engine_for "$RUNTIME")" in
        docker)
            run_sudo_noninteractive bash "$SCRIPT_DIR/install-docker.sh" install "$(docker_mode_for "$RUNTIME")" --profile "$RUNTIME_PROFILE"
            ;;
        podman)
            run_sudo_noninteractive bash "$SCRIPT_DIR/install-podman.sh" install --profile "$RUNTIME_PROFILE"
            ;;
    esac
}

verify_runtime_profile() {
    case "$(runtime_engine_for "$RUNTIME")" in
        docker)
            run_sudo_noninteractive bash "$SCRIPT_DIR/install-docker.sh" verify "$(docker_mode_for "$RUNTIME")" --profile "$RUNTIME_PROFILE"
            ;;
        podman)
            run_sudo_noninteractive bash "$SCRIPT_DIR/install-podman.sh" verify --profile "$RUNTIME_PROFILE"
            ;;
    esac
}

snapshot_environment_state() {
    bash "$SCRIPT_DIR/../profiles/profile-snapshot.sh" --state "$STATE" --runtime "$RUNTIME" --output-dir "$STATE_ROOT"
}

run_cis_system_benchmark_audit() {
    bash "$SCRIPT_DIR/cis-system-benchmark-audit.sh" --state "$STATE" --runtime "$RUNTIME" --output-dir "$STATE_ROOT"
}

apply_environment_state() {
    apply_host_profile
    apply_runtime_profile
    verify_environment_state
}

verify_environment_state() {
    verify_host_profile
    verify_runtime_profile
    snapshot_environment_state
    run_cis_system_benchmark_audit
}

case "$ACTION" in
    apply)
        apply_environment_state
        ;;
    verify)
        verify_environment_state
        ;;
    snapshot)
        snapshot_environment_state
        ;;
    *)
        printf 'Unsupported action: %s\n' "$ACTION" >&2
        exit 1
        ;;
esac
