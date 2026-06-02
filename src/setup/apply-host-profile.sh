#!/bin/bash
set -Eeuo pipefail

STATE_DIR="${CLD6001_HOST_PROFILE_STATE_DIR:-/var/lib/cld6001/host-profile}"
MARKER_FILE="$STATE_DIR/current"
PENDING_CIS_MARKER_FILE="$STATE_DIR/cis-rhel10-pending"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OPENSCAP_REMEDIATION_RUNBOOK="${CLD6001_OPENSCAP_REMEDIATION_RUNBOOK:-$SCRIPT_DIR/openscap-cis-level1-remediation.sh}"
OPENSCAP_MAX_ROUNDS="${CLD6001_OPENSCAP_MAX_ROUNDS:-3}"
SELINUX_CONFIG="${CLD6001_SELINUX_CONFIG:-/etc/selinux/config}"
OPENSCAP_ABORTED_BEFORE_SUMMARY_STOP_REASON="manual review required: OpenSCAP remediation aborted before summary emission after host mutation"
source "$SCRIPT_DIR/../shared/host-safety-guard.sh"

ACTION="apply"
PROFILE=""

usage() {
    cat <<'EOF'
Usage: sudo bash src/setup/apply-host-profile.sh [apply|verify|snapshot] --profile <baseline-host|cis-rhel10>
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        apply|verify|snapshot|reset)
            ACTION="$1"
            shift
            ;;
        --profile)
            PROFILE="${2:-}"
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

[ -n "$PROFILE" ] || { printf 'Missing --profile\n' >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || {
        printf 'Host profile %s requires root privileges\n' "$ACTION" >&2
        return 1
    }
}

current_profile() {
    if cis_pending; then
        printf 'cis-rhel10-pending\n'
    elif [ -f "$MARKER_FILE" ]; then
        cat "$MARKER_FILE"
    else
        printf 'baseline-host\n'
    fi
}

write_marker() {
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$1" > "$MARKER_FILE"
}

mark_cis_pending() {
    mkdir -p "$STATE_DIR"
    if [ $# -gt 0 ] && [ -n "$1" ]; then
        printf '%s\n' "$1" > "$PENDING_CIS_MARKER_FILE"
    else
        printf '%s\n' 'manual review required' > "$PENDING_CIS_MARKER_FILE"
    fi
}

clear_cis_pending() {
    rm -f "$PENDING_CIS_MARKER_FILE"
}

cis_pending() {
    [ -f "$PENDING_CIS_MARKER_FILE" ]
}

expected_selinux_mode_for_profile() {
    case "$1" in
        baseline-host) printf 'informational\n' ;;
        cis-rhel10) printf 'Enforcing\n' ;;
        *) return 1 ;;
    esac
}

read_selinux_mode() {
    command -v getenforce >/dev/null 2>&1 || return 2
    getenforce
}

report_selinux_mode() {
    local current_mode=""
    local status=0

    if current_mode="$(read_selinux_mode)"; then
        printf 'CLD6001_SELINUX_MODE=%s\n' "$current_mode"
    else
        status=$?
        case "$status" in
            2)
                printf 'CLD6001_SELINUX_MODE=unavailable\n'
                return 0
                ;;
            *)
                printf 'Unable to determine SELinux mode\n' >&2
                return 1
                ;;
        esac
    fi
}

read_openscap_remediation_stop_reason() {
    local summary_path="$1"

    [ -f "$summary_path" ] || return 1

    python3 - "$summary_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    summary = json.load(handle)

stop_reason = summary.get("stop_reason")
if stop_reason is None:
    sys.exit(1)

print(str(stop_reason))
PY
}

read_openscap_remediation_state_stop_reason() {
    local state_path="$1"

    [ -f "$state_path" ] || return 1

    python3 - "$state_path" "$OPENSCAP_ABORTED_BEFORE_SUMMARY_STOP_REASON" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    state = json.load(handle)

summary_written = state.get("summary_written")
host_mutation_possible = state.get("host_mutation_possible")
if not isinstance(summary_written, bool) or not isinstance(host_mutation_possible, bool):
    sys.exit(1)
if summary_written or not host_mutation_possible:
    sys.exit(1)

stop_reason = state.get("stop_reason")
if stop_reason is None or str(stop_reason).strip() == "":
    print(sys.argv[2])
else:
    print(str(stop_reason))
PY
}

read_cis_pending_stop_reason() {
    local output_dir="${CLD6001_OPENSCAP_REMEDIATION_OUTPUT_DIR:-}"
    local summary_path=""
    local state_path=""

    cis_pending || return 1

    if [ -s "$PENDING_CIS_MARKER_FILE" ]; then
        cat "$PENDING_CIS_MARKER_FILE"
        return 0
    fi

    if [ -n "$output_dir" ]; then
        summary_path="$output_dir/openscap-remediation-summary.json"
        state_path="$output_dir/openscap-remediation-state.json"
        read_openscap_remediation_stop_reason "$summary_path" && return 0
        read_openscap_remediation_state_stop_reason "$state_path"
        return $?
    fi

    return 1
}

openscap_stop_reason_blocks_rerun() {
    local stop_reason="${1:-}"

    case "$stop_reason" in
        "OpenSCAP CIS benchmark verified with failed remediation round(s)"|\
        *manual\ review*|*manual-review*)
            return 0
            ;;
    esac

    return 1
}

pending_cis_blocks_rerun() {
    local stop_reason=""

    if stop_reason="$(read_cis_pending_stop_reason 2>/dev/null)"; then
        openscap_stop_reason_blocks_rerun "$stop_reason"
        return $?
    fi

    return 0
}

fail_pending_cis_rerun() {
    local stop_reason=""

    printf 'CIS host profile is pending manual review/reset; refusing to rerun OpenSCAP remediation on unchanged host state' >&2
    if stop_reason="$(read_cis_pending_stop_reason 2>/dev/null)"; then
        printf ' (stop_reason=%s)' "$stop_reason" >&2
    fi
    printf '\n' >&2
    return 1
}

record_failed_cis_remediation_state() {
    local output_dir="${CLD6001_OPENSCAP_REMEDIATION_OUTPUT_DIR:-}"
    local summary_path=""
    local state_path=""
    local stop_reason=""

    [ -n "$output_dir" ] || {
        clear_cis_pending
        return 0
    }

    summary_path="$output_dir/openscap-remediation-summary.json"
    state_path="$output_dir/openscap-remediation-state.json"
    if stop_reason="$(read_openscap_remediation_stop_reason "$summary_path" 2>/dev/null)" \
        && openscap_stop_reason_blocks_rerun "$stop_reason"; then
        mark_cis_pending "$stop_reason"
        return 0
    fi
    if stop_reason="$(read_openscap_remediation_state_stop_reason "$state_path" 2>/dev/null)" \
        && openscap_stop_reason_blocks_rerun "$stop_reason"; then
        mark_cis_pending "$stop_reason"
        return 0
    fi

    clear_cis_pending
}

require_verified_openscap_remediation_summary() {
    local summary_path="$1"

    [ -f "$summary_path" ] || {
        printf 'Missing OpenSCAP remediation summary: %s\n' "$summary_path" >&2
        return 1
    }

    python3 - "$summary_path" <<'PY'
import json
import sys

summary_path = sys.argv[1]
with open(summary_path, "r", encoding="utf-8") as handle:
    summary = json.load(handle)

final_verified_raw = summary.get("final_verified")
if not isinstance(final_verified_raw, bool):
    print(
        "OpenSCAP remediation summary final_verified must be a JSON boolean",
        file=sys.stderr,
    )
    sys.exit(1)

final_verified = final_verified_raw
remediation_exit_status_raw = summary.get("remediation_exit_status", 1)
if not isinstance(remediation_exit_status_raw, int) or isinstance(remediation_exit_status_raw, bool):
    print(
        "OpenSCAP remediation summary remediation_exit_status must be a JSON integer",
        file=sys.stderr,
    )
    sys.exit(1)

remediation_exit_status = remediation_exit_status_raw
stop_reason = str(summary.get("stop_reason", "unknown"))

if final_verified and remediation_exit_status == 0:
    sys.exit(0)

if (
    remediation_exit_status == 0
    and stop_reason == "no further OpenSCAP remediation progress"
):
    print(
        "OpenSCAP remediation stabilized with residual findings; "
        "recording findings instead of blocking CIS host profile: "
        f"stop_reason={stop_reason}"
    )
    sys.exit(0)

print(
    "OpenSCAP remediation did not verify the CIS host profile: "
    f"final_verified={str(final_verified).lower()}; "
    f"remediation_exit_status={remediation_exit_status}; "
    f"stop_reason={stop_reason}",
    file=sys.stderr,
)
sys.exit(1)
PY
}

require_selinux_mode_for_profile() {
    local profile="$1"
    local expected_mode=""
    local current_mode=""

    expected_mode="$(expected_selinux_mode_for_profile "$profile")" || return 1

    [ "$expected_mode" = "informational" ] && {
        report_selinux_mode
        return 0
    }

    command -v getenforce >/dev/null 2>&1 || {
        printf 'SELinux tooling (getenforce) is not available\n' >&2
        return 1
    }

    current_mode="$(getenforce)"

    [ "$current_mode" = "$expected_mode" ] || {
        printf 'Expected SELinux mode %s, found %s\n' "$expected_mode" "$current_mode" >&2
        return 1
    }

    printf 'CLD6001_SELINUX_MODE=%s\n' "$current_mode"
}

apply_openscap_cis_l1_profile() {
    local output_dir="${CLD6001_OPENSCAP_REMEDIATION_OUTPUT_DIR:-}"
    local summary_path=""

    [ -n "$output_dir" ] || {
        printf 'CLD6001_OPENSCAP_REMEDIATION_OUTPUT_DIR is required for canonical runs\n' >&2
        return 1
    }

    [ -f "$OPENSCAP_REMEDIATION_RUNBOOK" ] || {
        printf 'Missing OpenSCAP remediation runbook: %s\n' "$OPENSCAP_REMEDIATION_RUNBOOK" >&2
        return 1
    }

    bash "$OPENSCAP_REMEDIATION_RUNBOOK" --output-dir "$output_dir" --max-rounds "$OPENSCAP_MAX_ROUNDS" || return 1
    summary_path="$output_dir/openscap-remediation-summary.json"
    require_verified_openscap_remediation_summary "$summary_path" || return 1
    printf 'CLD6001_OPENSCAP_REMEDIATION_OUTPUT_DIR=%s\n' "$output_dir"
}

validate_openscap_cis_l1_profile() {
    local output_dir="${CLD6001_OPENSCAP_REMEDIATION_OUTPUT_DIR:-}"
    local datastream="${CLD6001_OPENSCAP_DATASTREAM:-/usr/share/xml/scap/ssg/content/ssg-almalinux10-ds.xml}"

    [ -n "$output_dir" ] || {
        printf 'CLD6001_OPENSCAP_REMEDIATION_OUTPUT_DIR is required for canonical runs\n' >&2
        return 1
    }

    mkdir -p "$output_dir" 2>/dev/null && [ -d "$output_dir" ] && [ -w "$output_dir" ] || {
        printf 'OpenSCAP remediation output dir is not usable: %s\n' "$output_dir" >&2
        return 1
    }

    [ -f "$OPENSCAP_REMEDIATION_RUNBOOK" ] || {
        printf 'Missing OpenSCAP remediation runbook: %s\n' "$OPENSCAP_REMEDIATION_RUNBOOK" >&2
        return 1
    }

    command -v oscap >/dev/null 2>&1 || {
        printf 'Missing oscap; install openscap-scanner\n' >&2
        return 1
    }

    [ -f "$datastream" ] || {
        printf 'Missing OpenSCAP data stream: %s\n' "$datastream" >&2
        return 1
    }

    command -v python3 >/dev/null 2>&1 || {
        printf 'Missing python3 for OpenSCAP remediation summary validation\n' >&2
        return 1
    }

    printf '%s\n' "$OPENSCAP_MAX_ROUNDS" | grep -Eq '^[1-9][0-9]*$' || {
        printf 'Invalid CLD6001_OPENSCAP_MAX_ROUNDS: %s\n' "$OPENSCAP_MAX_ROUNDS" >&2
        return 1
    }
}

apply_baseline_host_profile() {
    require_root
    if [ "$(current_profile)" != "baseline-host" ]; then
        printf 'Cannot safely downgrade %s to baseline-host without host reset or explicit rollback\n' "$(current_profile)" >&2
        return 1
    fi
    write_marker "baseline-host"
    report_selinux_mode
    printf 'CLD6001_HOST_PROFILE=baseline-host\n'
}

reset_baseline_host_profile() {
    require_root
    local rollback_args=(rollback system)

    if [ "$(current_profile)" = "cis-rhel10" ] || cis_pending; then
        cld6001_require_safe_host_reset "baseline-host reset" || return 1
        if cld6001_host_reset_context_approved; then
            rollback_args+=(--rollback-storage keep)
        fi
        bash "$SCRIPT_DIR/setup-infrastructure.sh" "${rollback_args[@]}"
        rm -f /etc/sysctl.d/90-cld6001-cis-rhel10.co* 2>/dev/null || true
        sysctl --system >/dev/null 2>&1 || true
    fi

    write_marker "baseline-host"
    clear_cis_pending
    report_selinux_mode
    printf 'CLD6001_HOST_PROFILE=baseline-host\n'
}

apply_cis_rhel10_profile() {
    local active_profile=""

    require_root
    mkdir -p "$STATE_DIR"

    if cis_pending; then
        if pending_cis_blocks_rerun; then
            fail_pending_cis_rerun
            return 1
        fi
        clear_cis_pending
    fi

    active_profile="$(current_profile)"

    case "$active_profile" in
        cis-rhel10)
            require_selinux_mode_for_profile "cis-rhel10"
            printf 'CIS host profile already verified; skipping OpenSCAP rerun\n'
            printf 'CLD6001_HOST_PROFILE=cis-rhel10\n'
            return 0
            ;;
    esac

    validate_openscap_cis_l1_profile || return 1
    if ! apply_openscap_cis_l1_profile; then
        record_failed_cis_remediation_state
        return 1
    fi
    require_selinux_mode_for_profile "cis-rhel10"
    write_marker "cis-rhel10"
    clear_cis_pending
    printf 'CLD6001_HOST_PROFILE=cis-rhel10\n'
}

verify_cis_rhel10_profile() {
    [ "$(current_profile)" = "cis-rhel10" ] || {
        printf 'Expected CLD6001_HOST_PROFILE=cis-rhel10, found %s\n' "$(current_profile)" >&2
        return 1
    }
    require_selinux_mode_for_profile "cis-rhel10"
    printf 'CLD6001_HOST_PROFILE=cis-rhel10 verified\n'
}

verify_baseline_host_profile() {
    [ "$(current_profile)" = "baseline-host" ] || {
        printf 'Expected CLD6001_HOST_PROFILE=baseline-host, found %s\n' "$(current_profile)" >&2
        return 1
    }
    require_selinux_mode_for_profile "baseline-host"
    printf 'CLD6001_HOST_PROFILE=baseline-host verified\n'
}

case "$ACTION:$PROFILE" in
    apply:baseline-host)
        apply_baseline_host_profile
        ;;
    reset:baseline-host)
        reset_baseline_host_profile
        ;;
    apply:cis-rhel10)
        apply_cis_rhel10_profile
        ;;
    verify:baseline-host)
        verify_baseline_host_profile
        ;;
    verify:cis-rhel10)
        verify_cis_rhel10_profile
        ;;
    snapshot:*)
        printf 'CLD6001_HOST_PROFILE=%s\n' "$(current_profile)"
        ;;
    *)
        printf 'Unsupported host profile action: %s --profile %s\n' "$ACTION" "$PROFILE" >&2
        exit 1
        ;;
esac
