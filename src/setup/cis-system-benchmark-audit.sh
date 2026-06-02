#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../profiles/environment-states.sh"
source "$SCRIPT_DIR/../../src/shared/docker-bench-helpers.sh"

STATE=""
RUNTIME=""
OUTPUT_DIR=""

HOST_MARKER="${CLD6001_HOST_PROFILE_MARKER:-/var/lib/cld6001/host-profile/current}"
CIS_SYSCTL_CONF="${CLD6001_CIS_SYSCTL_CONF:-/etc/sysctl.d/90-cld6001-cis-rhel10.conf}"
CIS_SSHD_CONF="${CLD6001_CIS_SSHD_CONF:-/etc/ssh/sshd_config.d/90-cld6001-cis.conf}"
CIS_AUDIT_RULES="${CLD6001_CIS_AUDIT_RULES:-/etc/audit/rules.d/90-cld6001-container.rules}"
CIS_SELINUX_CONFIG="${CLD6001_CIS_SELINUX_CONFIG:-/etc/selinux/config}"
DOCKER_DAEMON_JSON="${CLD6001_DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"
PODMAN_CONTAINERS_CONF="${CLD6001_PODMAN_CONTAINERS_CONF:-/etc/containers/containers.conf.d/50-profile.conf}"

usage() {
    cat <<'EOF'
Usage: bash src/setup/cis-system-benchmark-audit.sh --state <state> --runtime <runtime> --output-dir <dir>

Produces system-only CIS evidence for:
  - AlmaLinux host OS hardening
  - Docker daemon/program configuration
  - Podman program/configuration applicability

When openscap-scanner and scap-security-guide are installed, the script also
runs an audit-only OpenSCAP evaluation against the AlmaLinux 10 data stream.
Container artifact selection and tested workload images are intentionally out of scope.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --state)
            STATE="${2:-}"
            shift 2
            ;;
        --runtime)
            RUNTIME="${2:-}"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:-}"
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
[ -n "$OUTPUT_DIR" ] || { printf 'Missing --output-dir\n' >&2; exit 1; }
environment_state_exists "$STATE" || { printf 'Unknown environment state: %s\n' "$STATE" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
CHECKS_JSONL="$OUTPUT_DIR/cis-system-checks.jsonl"
RESULT_JSON="$OUTPUT_DIR/cis-system-benchmark-results.json"
RESULT_MD="$OUTPUT_DIR/cis-system-benchmark-results.md"
DOCKER_BENCH_JSON="$OUTPUT_DIR/docker-bench-results.json"
OPENSCAP_DATASTREAM="${CLD6001_OPENSCAP_DATASTREAM:-/usr/share/xml/scap/ssg/content/ssg-almalinux10-ds.xml}"
OPENSCAP_INFO="$OUTPUT_DIR/openscap-info.txt"
OPENSCAP_ARF="$OUTPUT_DIR/openscap-results-arf.xml"
OPENSCAP_RESULTS="$OUTPUT_DIR/openscap-results.xml"
OPENSCAP_REPORT="$OUTPUT_DIR/openscap-report.html"
: > "$CHECKS_JSONL"

HOST_PROFILE="$(environment_state_host_profile_for "$STATE")"
RUNTIME_PROFILE="$(environment_state_runtime_profile_for "$STATE")"

runtime_engine_for() {
    case "$1" in
        docker-rootful|docker-rootless) printf 'docker\n' ;;
        podman-rootless) printf 'podman\n' ;;
        *) return 1 ;;
    esac
}

emit_check() {
    local category="$1"
    local id="$2"
    local benchmark="$3"
    local title="$4"
    local status="$5"
    local evidence="${6:-}"

    jq -cn \
        --arg category "$category" \
        --arg id "$id" \
        --arg benchmark "$benchmark" \
        --arg title "$title" \
        --arg status "$status" \
        --arg evidence "$evidence" \
        '{category: $category, id: $id, benchmark: $benchmark, title: $title, status: $status, evidence: $evidence}' \
        >> "$CHECKS_JSONL"
}

file_contains() {
    local path="$1"
    local needle="$2"
    [ -f "$path" ] && grep -Fq -- "$needle" "$path"
}

host_marker_matches() {
    [ -f "$HOST_MARKER" ] && [ "$(tr -d '\r\n' < "$HOST_MARKER")" = "$HOST_PROFILE" ]
}

collect_host_checks() {
    local benchmark="CIS AlmaLinux OS 10 Benchmark v1.0.0"

    if [ "$HOST_PROFILE" = "baseline-host" ]; then
        emit_check host-os host.profile.baseline "$benchmark" "Baseline host profile selected" pass "$STATE"
        return 0
    fi

    if host_marker_matches; then
        emit_check host-os host.profile.marker "$benchmark" "Host profile marker records CIS host state" pass "$HOST_MARKER"
    else
        emit_check host-os host.profile.marker "$benchmark" "Host profile marker records CIS host state" fail "$HOST_MARKER"
    fi

    file_contains "$CIS_SYSCTL_CONF" 'kernel.dmesg_restrict = 1' \
        && emit_check host-os host.kernel.dmesg_restrict "$benchmark" "Kernel message disclosure is restricted" pass "$CIS_SYSCTL_CONF" \
        || emit_check host-os host.kernel.dmesg_restrict "$benchmark" "Kernel message disclosure is restricted" fail "$CIS_SYSCTL_CONF"
    file_contains "$CIS_SYSCTL_CONF" 'kernel.kptr_restrict = 2' \
        && emit_check host-os host.kernel.kptr_restrict "$benchmark" "Kernel pointer disclosure is restricted" pass "$CIS_SYSCTL_CONF" \
        || emit_check host-os host.kernel.kptr_restrict "$benchmark" "Kernel pointer disclosure is restricted" fail "$CIS_SYSCTL_CONF"
    file_contains "$CIS_SYSCTL_CONF" 'net.ipv4.conf.all.accept_redirects = 0' \
        && emit_check host-os host.network.accept_redirects "$benchmark" "IPv4 ICMP redirects are disabled" pass "$CIS_SYSCTL_CONF" \
        || emit_check host-os host.network.accept_redirects "$benchmark" "IPv4 ICMP redirects are disabled" fail "$CIS_SYSCTL_CONF"
    file_contains "$CIS_SELINUX_CONFIG" 'SELINUX=enforcing' \
        && emit_check host-os host.selinux.enforcing "$benchmark" "SELinux persistent mode is enforcing" pass "$CIS_SELINUX_CONFIG" \
        || emit_check host-os host.selinux.enforcing "$benchmark" "SELinux persistent mode is enforcing" fail "$CIS_SELINUX_CONFIG"
    file_contains "$CIS_SSHD_CONF" 'PermitRootLogin no' \
        && emit_check host-os host.ssh.permit_root_login "$benchmark" "SSH root login is disabled" pass "$CIS_SSHD_CONF" \
        || emit_check host-os host.ssh.permit_root_login "$benchmark" "SSH root login is disabled" fail "$CIS_SSHD_CONF"
    file_contains "$CIS_AUDIT_RULES" '/etc/docker/daemon.json' \
        && emit_check host-os host.audit.docker_config "$benchmark" "Docker daemon config audit rule exists" pass "$CIS_AUDIT_RULES" \
        || emit_check host-os host.audit.docker_config "$benchmark" "Docker daemon config audit rule exists" fail "$CIS_AUDIT_RULES"
    file_contains "$CIS_AUDIT_RULES" '/etc/containers/' \
        && emit_check host-os host.audit.containers_config "$benchmark" "Container program config audit rule exists" pass "$CIS_AUDIT_RULES" \
        || emit_check host-os host.audit.containers_config "$benchmark" "Container program config audit rule exists" fail "$CIS_AUDIT_RULES"
}

openscap_profile_from_info() {
    local info_file="$1"

    awk '
        /Id:[[:space:]]+.*cis.*server_l1/ { print $2; found=1; exit }
        /Id:[[:space:]]+.*cis/ && !candidate { candidate=$2 }
        END {
            if (!found && candidate) {
                print candidate
            }
        }
    ' "$info_file"
}

collect_openscap_checks() {
    local benchmark="CIS AlmaLinux OS 10 Benchmark v1.0.0 via OpenSCAP"
    local profile_id=""
    local oscap_status=0

    if [ "$HOST_PROFILE" != "cis-rhel10" ]; then
        emit_check host-os openscap.almalinux10.cis "$benchmark" "OpenSCAP AlmaLinux 10 CIS evaluation" not-applicable "$HOST_PROFILE"
        return 0
    fi

    if ! command -v oscap >/dev/null 2>&1; then
        emit_check host-os openscap.almalinux10.cis "$benchmark" "OpenSCAP AlmaLinux 10 CIS evaluation" not-testable "openscap-scanner not installed"
        return 0
    fi

    if [ ! -f "$OPENSCAP_DATASTREAM" ]; then
        emit_check host-os openscap.almalinux10.cis "$benchmark" "OpenSCAP AlmaLinux 10 CIS evaluation" not-testable "scap-security-guide data stream not found: $OPENSCAP_DATASTREAM"
        return 0
    fi

    if ! oscap info "$OPENSCAP_DATASTREAM" > "$OPENSCAP_INFO"; then
        emit_check host-os openscap.almalinux10.cis "$benchmark" "OpenSCAP AlmaLinux 10 CIS evaluation" fail "oscap info failed for $OPENSCAP_DATASTREAM"
        return 0
    fi

    profile_id="$(openscap_profile_from_info "$OPENSCAP_INFO")"
    if [ -z "$profile_id" ]; then
        emit_check host-os openscap.almalinux10.cis "$benchmark" "OpenSCAP AlmaLinux 10 CIS evaluation" not-testable "No CIS profile ID found in $OPENSCAP_INFO"
        return 0
    fi

    set +e
    oscap xccdf eval \
        --profile "$profile_id" \
        --results-arf "$OPENSCAP_ARF" \
        --results "$OPENSCAP_RESULTS" \
        --report "$OPENSCAP_REPORT" \
        "$OPENSCAP_DATASTREAM" \
        > "$OUTPUT_DIR/openscap-eval.log" 2>&1
    oscap_status=$?
    set -e

    case "$oscap_status" in
        0)
            emit_check host-os openscap.almalinux10.cis "$benchmark" "OpenSCAP AlmaLinux 10 CIS evaluation" pass "$profile_id; $OPENSCAP_ARF"
            ;;
        2)
            emit_check host-os openscap.almalinux10.cis "$benchmark" "OpenSCAP AlmaLinux 10 CIS evaluation" fail "$profile_id; non-compliant results recorded in $OPENSCAP_ARF"
            ;;
        *)
            emit_check host-os openscap.almalinux10.cis "$benchmark" "OpenSCAP AlmaLinux 10 CIS evaluation" fail "$profile_id; oscap exited $oscap_status; see $OUTPUT_DIR/openscap-eval.log"
            ;;
    esac
}

collect_docker_checks() {
    local benchmark="CIS Docker Benchmark v1.8.0"

    if [ "$(runtime_engine_for "$RUNTIME")" != "docker" ]; then
        return 0
    fi

    if [ "$RUNTIME_PROFILE" = "baseline-defaults" ]; then
        emit_check docker-daemon docker.profile.baseline "$benchmark" "Baseline Docker daemon profile selected" pass "$STATE"
        return 0
    fi

    file_contains "$DOCKER_DAEMON_JSON" '"no-new-privileges": true' \
        && emit_check docker-daemon docker.daemon.no_new_privileges "$benchmark" "Docker daemon restricts privilege escalation" pass "$DOCKER_DAEMON_JSON" \
        || emit_check docker-daemon docker.daemon.no_new_privileges "$benchmark" "Docker daemon restricts privilege escalation" fail "$DOCKER_DAEMON_JSON"
    file_contains "$DOCKER_DAEMON_JSON" '"live-restore": true' \
        && emit_check docker-daemon docker.daemon.live_restore "$benchmark" "Docker daemon live-restore is enabled" pass "$DOCKER_DAEMON_JSON" \
        || emit_check docker-daemon docker.daemon.live_restore "$benchmark" "Docker daemon live-restore is enabled" fail "$DOCKER_DAEMON_JSON"
    file_contains "$DOCKER_DAEMON_JSON" '"userland-proxy": false' \
        && emit_check docker-daemon docker.daemon.userland_proxy "$benchmark" "Docker userland proxy is disabled" pass "$DOCKER_DAEMON_JSON" \
        || emit_check docker-daemon docker.daemon.userland_proxy "$benchmark" "Docker userland proxy is disabled" fail "$DOCKER_DAEMON_JSON"

    if command -v docker-bench-security >/dev/null 2>&1; then
        if run_docker_bench_capture "$DOCKER_BENCH_JSON"; then
            emit_check docker-daemon docker-bench.available "$benchmark via Docker Bench for Security" "Docker Bench for Security completed" pass "$DOCKER_BENCH_JSON"
        else
            emit_check docker-daemon docker-bench.available "$benchmark via Docker Bench for Security" "Docker Bench for Security completed" fail "$DOCKER_BENCH_JSON"
        fi
    else
        emit_check docker-daemon docker-bench.available "$benchmark via Docker Bench for Security" "Docker Bench for Security is available" not-testable "docker-bench-security not installed"
    fi
}

collect_podman_checks() {
    local benchmark="podman-system-applicability"

    if [ "$(runtime_engine_for "$RUNTIME")" != "podman" ]; then
        return 0
    fi

    emit_check podman-program podman.docker_cis_scope "$benchmark" "Docker CIS daemon controls are not applied one-for-one to daemonless Podman" not-applicable "$RUNTIME"

    if [ "$RUNTIME_PROFILE" = "baseline-defaults" ]; then
        emit_check podman-program podman.profile.baseline "$benchmark" "Baseline Podman program profile selected" pass "$STATE"
        return 0
    fi

    file_contains "$PODMAN_CONTAINERS_CONF" 'pids_limit = 1024' \
        && emit_check podman-program podman.containers.pids_limit "$benchmark" "Podman default pids limit is configured" pass "$PODMAN_CONTAINERS_CONF" \
        || emit_check podman-program podman.containers.pids_limit "$benchmark" "Podman default pids limit is configured" fail "$PODMAN_CONTAINERS_CONF"
    file_contains "$PODMAN_CONTAINERS_CONF" 'seccomp_profile = "/usr/share/containers/seccomp.json"' \
        && emit_check podman-program podman.containers.seccomp "$benchmark" "Podman default seccomp profile is configured" pass "$PODMAN_CONTAINERS_CONF" \
        || emit_check podman-program podman.containers.seccomp "$benchmark" "Podman default seccomp profile is configured" fail "$PODMAN_CONTAINERS_CONF"
}

write_results_json() {
    local runtime_engine=""
    runtime_engine="$(runtime_engine_for "$RUNTIME")"

    jq -s \
        --arg state "$STATE" \
        --arg runtime "$RUNTIME" \
        --arg runtime_engine "$runtime_engine" \
        --arg host_profile "$HOST_PROFILE" \
        --arg runtime_profile "$RUNTIME_PROFILE" \
        --arg generated_at "$(date -Iseconds)" \
        '{
            metadata: {
                state: $state,
                runtime: $runtime,
                runtime_engine: $runtime_engine,
                host_profile: $host_profile,
                runtime_profile: $runtime_profile,
                generated_at: $generated_at,
                scope: "system-only",
                image_scope: "excluded"
            },
            host_benchmark: {
                source: "CIS AlmaLinux OS 10 Benchmark v1.0.0",
                checks: [ .[] | select(.category == "host-os") ],
                summary: ([ .[] | select(.category == "host-os") ] | group_by(.status) | map({(.[0].status): length}) | add // {})
            },
            runtime_benchmark: {
                source: (if $runtime_engine == "docker" then "CIS Docker Benchmark v1.8.0 via Docker Bench for Security" else "podman-system-applicability" end),
                checks: [ .[] | select(.category != "host-os") ],
                summary: ([ .[] | select(.category != "host-os") ] | group_by(.status) | map({(.[0].status): length}) | add // {})
            },
            checks: .
        }' "$CHECKS_JSONL" > "$RESULT_JSON"
}

write_results_markdown() {
    {
        printf '# CIS System Benchmark Results\n\n'
        printf '%s\n' "- State: \`$STATE\`"
        printf '%s\n' "- Runtime: \`$RUNTIME\`"
        printf '%s\n' "- Host profile: \`$HOST_PROFILE\`"
        printf '%s\n' "- Runtime profile: \`$RUNTIME_PROFILE\`"
        printf '%s\n\n' "- Scope: system-only; tested container artifacts are excluded."
        printf '## Sources\n\n'
        printf '%s\n' "- CIS AlmaLinux OS 10 Benchmark v1.0.0"
        printf '%s\n' "- OpenSCAP AlmaLinux 10 CIS evaluation when openscap-scanner and scap-security-guide are available"
        printf '%s\n' "- CIS Docker Benchmark v1.8.0 for Docker daemon/program checks where applicable"
        printf '%s\n\n' "- Podman system applicability checks for daemonless Podman configuration"
        printf '## Checks\n\n'
        jq -r '.checks[] | "- `\(.id)` [\(.status)] \(.title) - \(.benchmark)"' "$RESULT_JSON"
    } > "$RESULT_MD"
}

collect_host_checks
collect_openscap_checks
collect_docker_checks
collect_podman_checks
write_results_json
write_results_markdown

printf 'CIS system benchmark results written to %s\n' "$OUTPUT_DIR"
