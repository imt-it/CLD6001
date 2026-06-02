#!/bin/bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$REPO_ROOT/src/execute/run-context.sh"
source "$REPO_ROOT/src/shared/terminal-colors.sh"
source "$REPO_ROOT/src/shared/env-loader.sh"
source "$REPO_ROOT/src/shared/log-pipe.sh"

INTERACTIVE=true
SETUP_ONLY=false
PULL_ONLY=false
TEST_ONLY=false
CLEAN=false
DRY_RUN=false

snapshot_relaxed_debug_opt_in() {
    local explicit_set="false"
    local explicit_value=""

    if [[ "${CLD6001_ORCHESTRATOR_RELAXED_DEBUG+x}" == "x" ]]; then
        explicit_set="true"
        explicit_value="${CLD6001_ORCHESTRATOR_RELAXED_DEBUG}"
    fi

    exec 9<<EOF
${explicit_set}
${explicit_value}
EOF
}

restore_relaxed_debug_opt_in_snapshot() {
    IFS= read -r ORCHESTRATOR_RELAXED_DEBUG_EXPLICIT_SET <&9 || ORCHESTRATOR_RELAXED_DEBUG_EXPLICIT_SET=false
    IFS= read -r ORCHESTRATOR_RELAXED_DEBUG_EXPLICIT_VALUE <&9 || ORCHESTRATOR_RELAXED_DEBUG_EXPLICIT_VALUE=""
    exec 9<&-

    readonly ORCHESTRATOR_RELAXED_DEBUG_EXPLICIT_SET
    readonly ORCHESTRATOR_RELAXED_DEBUG_EXPLICIT_VALUE
}

snapshot_relaxed_debug_opt_in

ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "$ENV_FILE" ]]; then
    safe_source_env "$ENV_FILE"
fi
restore_relaxed_debug_opt_in_snapshot

RUN_ID="${CLD6001_RUN_ID:-$(cld6001_generate_run_id)}"
LOG_DIR="${REPO_ROOT}/temp-work/${RUN_ID}"
mkdir -p "${LOG_DIR}"

LOCAL_MODE=true
TEMP_SUDOERS_PATH="/etc/sudoers.d/99-cld6001-thesis-runtime"
TEMP_SUDOERS_ACTIVE=false

LOG_FILE="${REPO_ROOT}/automation-${RUN_ID}.log"

log() {
    local level="$1"
    shift
    log_pipe "$level" "setup" "automate" "$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local normalized_level
    normalized_level="$(terminal_normalize_level "$level")"
    printf '[%s] [%s] %s\n' "$timestamp" "$normalized_level" "$*" >> "$LOG_FILE"
}

info() { log "INFO" "$@"; }
ok() { log "OK" "$@"; }
warn() { log "WARN" "$@"; }
block() { log "BLOCK" "$@"; }
error() { log "ERROR" "$@"; }
fail() { log "FAIL" "$@"; }

if [[ -f "$ENV_FILE" ]]; then
    info "Loading environment variables from $ENV_FILE"
fi

prompt_credential() {
    local name="$1"
    local prefix="$2"
    local user_var="${prefix}_USER"
    local pass_var="${prefix}_PASS"
    local username="${!user_var:-}"
    local password="${!pass_var:-}"

    if [[ -n "$username" && -n "$password" ]]; then
        return 0
    fi

    if [[ "$INTERACTIVE" != "true" ]]; then
        error "${user_var} and ${pass_var} must be set when --non-interactive mode is enabled"
        return 1
    fi

    if [[ -z "$username" ]]; then
        read -r -p "Enter ${name} username: " username
    fi
    if [[ -z "$password" ]]; then
        read -r -s -p "Enter ${name} password: " password
        echo
    fi

    if [[ -z "$username" ]] || [[ -z "$password" ]]; then
        error "$name credentials not provided"
        return 1
    fi

    printf -v "${prefix}_USER" '%s' "$username"
    printf -v "${prefix}_PASS" '%s' "$password"
    return 0
}

prompt_docker_token_credentials() {
    local name="$1"
    local username="${DOCKER_USERNAME:-}"
    local token="${DOCKER_TOKEN:-}"

    if [[ -n "$username" && -n "$token" ]]; then
        info "$name token credentials provided via environment"
        return 0
    fi

    if [[ "$INTERACTIVE" != "true" ]]; then
        error "DOCKER_USERNAME and DOCKER_TOKEN must be set when --non-interactive mode is enabled"
        return 1
    fi

    if [[ -z "$username" ]]; then
        read -r -p "Enter ${name} username: " username
    fi
    if [[ -z "$token" ]]; then
        read -r -s -p "Enter ${name} access token: " token
        echo
    fi

    if [[ -z "$username" ]] || [[ -z "$token" ]]; then
        error "$name token credentials not provided"
        return 1
    fi

    printf -v DOCKER_USERNAME '%s' "$username"
    printf -v DOCKER_TOKEN '%s' "$token"
    return 0
}

bootstrap_local_sudo() {
    if sudo -n true 2>/dev/null; then
        return 0
    fi

    if [[ "$INTERACTIVE" == "true" ]]; then
        info "NOPASSWD sudo is unavailable; prompting once to cache sudo credentials for this session"
        sudo -v
        return 0
    fi

    error "NOPASSWD sudo is required in non-interactive mode. Configure sudoers for the automation user or rerun interactively so sudo can prompt once up front."
    return 1
}

install_temporary_sudoers() {
    local target_user="${VM_USER:-$(id -un)}"

    info "Installing temporary CLD6001 passwordless sudo policy for ${target_user}..."

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would install ${TEMP_SUDOERS_PATH}..."
        return 0
    fi

    bootstrap_local_sudo || return 1
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$target_user" | sudo tee "$TEMP_SUDOERS_PATH" >/dev/null
    sudo chmod 0440 "$TEMP_SUDOERS_PATH"
    sudo visudo -cf "$TEMP_SUDOERS_PATH" >/dev/null
    sudo -n true

    TEMP_SUDOERS_ACTIVE=true
    ok "Temporary passwordless sudo policy activated successfully"
}

remove_temporary_sudoers() {
    local best_effort="${1:-false}"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would remove ${TEMP_SUDOERS_PATH}..."
        TEMP_SUDOERS_ACTIVE=false
        return 0
    fi

    if sudo -n true 2>/dev/null; then
        sudo rm -f "$TEMP_SUDOERS_PATH"
        sudo -k || true
    elif [[ "$best_effort" != "true" ]]; then
        error "Cannot remove temporary sudoers policy because sudo -n is unavailable"
        return 1
    fi

    TEMP_SUDOERS_ACTIVE=false
}

automation_exit_handler() {
    local status=$?

    if [[ "${TEMP_SUDOERS_ACTIVE:-false}" == "true" ]]; then
        remove_temporary_sudoers true || true
    fi

    exit "$status"
}

trap automation_exit_handler EXIT

workspace_root() {
    printf '%s\n' "$REPO_ROOT"
}

local_workspace_path() {
    local raw_path="${1:-}"
    local root=""

    root="$(workspace_root)"

    case "$raw_path" in
        "~"|"~/thesis-research"|"~/cld6001")
            printf '%s\n' "$root"
            ;;
        "~/thesis-research/"*)
            printf '%s/%s\n' "$root" "${raw_path#"~/thesis-research/"}"
            ;;
        "~/cld6001/"*)
            printf '%s/%s\n' "$root" "${raw_path#"~/cld6001/"}"
            ;;
        *)
            printf '%s\n' "$raw_path"
            ;;
    esac
}

localize_workspace_command() {
    local command_text="$1"
    local root=""

    root="$(workspace_root)"
    command_text="${command_text//\~\/thesis-research/$root}"
    command_text="${command_text//\~\/cld6001/$root}"
    printf '%s\n' "$command_text"
}

local_exec_display() {
    local display_command=$1
    local workspace_command=$2
    local display_label="${3:-}"
    local status=0
    local localized_display=""
    local localized_command=""

    if [[ -n "$display_label" ]]; then
        localized_display="$display_label"
    else
        localized_display="$(localize_workspace_command "$display_command")"
    fi
    localized_command="$(localize_workspace_command "$workspace_command")"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would execute locally: $localized_display"
        return 0
    fi

    info "Executing locally: $localized_display..."

    local -a cmd_array=(bash -c "$localized_command")

    set +e
    "${cmd_array[@]}" 2>&1 | tee -a "$LOG_FILE"
    status=${PIPESTATUS[0]}
    set -e

    return "$status"
}

local_exec() {
    local workspace_command="$1"
    local display_label="${2:-}"
    local_exec_display "$workspace_command" "$workspace_command" "$display_label"
}

local_copy() {
    local local_file=$1
    local workspace_path=$2
    local target_path=""
    local status=0

    target_path="$(local_workspace_path "$workspace_path")"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would copy $local_file to $target_path..."
        return 0
    fi

    info "Copying $local_file to $target_path..."

    if [[ "$(cd -- "$(dirname -- "$local_file")" && pwd -P)/$(basename -- "$local_file")" == "$(realpath -m -- "$target_path")" ]]; then
        info "Source and destination are the same, skipping copy"
        return 0
    fi

    mkdir -p -- "$(dirname -- "$target_path")"
    set +e
    cp "$local_file" "$target_path" 2>&1 | tee -a "$LOG_FILE"
    status=${PIPESTATUS[0]}
    set -e
    return "$status"
}

local_copy_dir() {
    local local_dir=$1
    local workspace_dir=$2
    local target_dir=""
    local status=0

    target_dir="$(local_workspace_path "$workspace_dir")"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would copy $local_dir to $target_dir..."
        return 0
    fi

    info "Copying directory $local_dir to $target_dir..."

    if [[ "$(realpath -m -- "$local_dir")" == "$(realpath -m -- "$target_dir/$(basename -- "$local_dir")")" ]]; then
        info "Source and destination are the same, skipping copy"
        return 0
    fi

    mkdir -p -- "$target_dir"
    set +e
    cp -r "$local_dir" "$target_dir" 2>&1 | tee -a "$LOG_FILE"
    status=${PIPESTATUS[0]}
    set -e
    return "$status"
}

sync_test_repository_subset() {
    local _host="$1"
    info "Using current local checkout at $(workspace_root)"
    mkdir -p -- "$REPO_ROOT/artifacts" "$REPO_ROOT/temp-work" "$REPO_ROOT/logs" "$REPO_ROOT/snapshots"
}

setup_vm() {
    info "--- Step 1: VM Setup ---"

    local current_user="${VM_USER:-$(id -un)}"

    info "Running in local Linux workspace mode"
    ok "Local execution mode enabled successfully"

    info "Updating system packages..."
    local_exec "sudo dnf update -y -q"
    ok "System updated successfully"

    info "Installing runner prerequisites..."
    local_exec "
        missing=()
        for pkg in gcc make jq curl; do
            if ! command -v \$pkg &> /dev/null; then
                missing+=(\$pkg)
            fi
        done

        if ! python3 -c 'import scipy' &> /dev/null; then
            missing+=(python3-scipy)
        fi

        if [[ \${#missing[@]} -gt 0 ]]; then
            sudo dnf install -y -q \${missing[@]}
        else
            echo 'Runner prerequisites already installed'
        fi
    " "install runner prerequisites"
    ok "Runner prerequisites installed successfully"

    info "Installing Docker..."
    local_exec "
        if ! rpm -q \
            docker-ce \
            docker-ce-cli \
            docker-ce-rootless-extras \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin \
            slirp4netns > /dev/null 2>&1; then
            sudo rm -f /etc/yum.repos.d/docker*.repo
            cat > /tmp/docker-ce.repo <<'EOF'
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=https://download.docker.com/linux/centos/\$releasever/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg

[docker-ce-stable-debuginfo]
name=Docker CE Stable - \$basearch - Debuginfo
baseurl=https://download.docker.com/linux/centos/\$releasever/\$basearch/stable-debuginfo
enabled=0
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg

[docker-ce-stable-source]
name=Docker CE Stable - \$basearch - Sources
baseurl=https://download.docker.com/linux/centos/\$releasever/\$basearch/stable-source
enabled=0
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg
EOF
            sudo mv /tmp/docker-ce.repo /etc/yum.repos.d/docker-ce.repo
            sudo dnf clean all
            sudo dnf install -y -q \
                docker-ce \
                docker-ce-cli \
                docker-ce-rootless-extras \
                containerd.io \
                docker-buildx-plugin \
                docker-compose-plugin \
                slirp4netns
        else
            echo 'Docker already installed'
        fi
    " "install docker packages"
    ok "Docker installed successfully"

    info "Configuring Docker..."
    local_exec "
        sudo systemctl enable docker
        sudo systemctl start docker

        sudo usermod -aG docker ${current_user}
    " "configure docker service"
    ok "Docker configured successfully"

    info "Configuring docker-rootless..."
    local_exec "
        ROOTLESS_USER='${current_user}'
        ROOTLESS_UID=\$(id -u \"\$ROOTLESS_USER\")
        ROOTLESS_HOME=\$(getent passwd \"\$ROOTLESS_USER\" | cut -d: -f6)
        ROOTLESS_RUNTIME_DIR=/run/user/\$ROOTLESS_UID
        ROOTLESS_DBUS=unix:path=\${ROOTLESS_RUNTIME_DIR}/bus

        if env \
            HOME=\"\$ROOTLESS_HOME\" \
            XDG_RUNTIME_DIR=\"\$ROOTLESS_RUNTIME_DIR\" \
            DBUS_SESSION_BUS_ADDRESS=\"\$ROOTLESS_DBUS\" \
            DOCKER_HOST=\"unix://\${ROOTLESS_RUNTIME_DIR}/docker.sock\" \
            docker version > /dev/null 2>&1; then
            echo 'docker-rootless already configured'
        else
            sudo loginctl enable-linger \"\$ROOTLESS_USER\"
            env HOME=\"\$ROOTLESS_HOME\" XDG_RUNTIME_DIR=\"\$ROOTLESS_RUNTIME_DIR\" DBUS_SESSION_BUS_ADDRESS=\"\$ROOTLESS_DBUS\" dockerd-rootless-setuptool.sh install
            env HOME=\"\$ROOTLESS_HOME\" XDG_RUNTIME_DIR=\"\$ROOTLESS_RUNTIME_DIR\" DBUS_SESSION_BUS_ADDRESS=\"\$ROOTLESS_DBUS\" systemctl --user daemon-reload
            env HOME=\"\$ROOTLESS_HOME\" XDG_RUNTIME_DIR=\"\$ROOTLESS_RUNTIME_DIR\" DBUS_SESSION_BUS_ADDRESS=\"\$ROOTLESS_DBUS\" systemctl --user enable --now docker
        fi
    " "configure docker-rootless"
    ok "docker-rootless configured successfully"

    info "Installing Podman..."
    local_exec "
        if ! rpm -q podman buildah skopeo > /dev/null 2>&1; then
            sudo dnf install -y -q podman buildah skopeo
        else
            echo 'Podman already installed'
        fi
    " "install podman packages"
    ok "Podman installed successfully"

    ok "--- Step 1 complete ---"
}

authenticate() {
    info "--- Step 2: Authentication ---"

    local auth_method="token"

    info "Logging into Docker Hub..."

    prompt_docker_token_credentials "Docker Hub" || return 1
    info "Using access token authentication"

    local_exec_display "
        printf '%s\n' '[REDACTED]' | docker login -u \"\${DOCKER_USERNAME:-}\" --password-stdin &&
        printf '%s\n' '[REDACTED]' | sudo docker login -u \"\${DOCKER_USERNAME:-}\" --password-stdin
    " "
        printf '%s\n' \"\${DOCKER_TOKEN:-}\" | docker login -u \"\${DOCKER_USERNAME:-}\" --password-stdin &&
        printf '%s\n' \"\${DOCKER_TOKEN:-}\" | sudo docker login -u \"\${DOCKER_USERNAME:-}\" --password-stdin
    " "docker login"

    ok "Docker Hub authenticated successfully using $auth_method"

    info "Logging into Docker Hardened Images registry..."

    local_exec_display "
        printf '%s\n' '[REDACTED]' | docker login -u \"\${DOCKER_USERNAME:-}\" --password-stdin dhi.io &&
        printf '%s\n' '[REDACTED]' | sudo docker login -u \"\${DOCKER_USERNAME:-}\" --password-stdin dhi.io &&
        printf '%s\n' '[REDACTED]' | podman login -u \"\${DOCKER_USERNAME:-}\" --password-stdin dhi.io
    " "
        printf '%s\n' \"\${DOCKER_TOKEN:-}\" | docker login -u \"\${DOCKER_USERNAME:-}\" --password-stdin dhi.io &&
        printf '%s\n' \"\${DOCKER_TOKEN:-}\" | sudo docker login -u \"\${DOCKER_USERNAME:-}\" --password-stdin dhi.io &&
        printf '%s\n' \"\${DOCKER_TOKEN:-}\" | podman login -u \"\${DOCKER_USERNAME:-}\" --password-stdin dhi.io
    " "docker login dhi.io"

    ok "Docker Hardened Images registry authenticated successfully"

    info "Testing Quay.io access..."
    local_exec "
        if ! docker pull hello-world:latest > /dev/null 2>&1; then
            printf '%s\n' 'Quay.io access may require authentication' >&2
        fi
    " "test quay access"

    ok "--- Step 2 complete ---"
}

pull_images() {
    info "--- Step 3: Image Pulling ---"

    local image_script="${REPO_ROOT}/src/setup/pull-images.sh"
    local image_registry_helper="${REPO_ROOT}/src/execute/image-registry.sh"
    local docker_rootful_primary=""
    local docker_rootful_dhi=""
    local docker_rootless_primary=""
    local docker_rootless_dhi=""
    local podman_rootless_primary=""
    local podman_rootless_dhi=""

    local_exec "mkdir -p ~/cld6001/src/execute ~/cld6001/src/profiles ~/cld6001/src/setup ~/cld6001/src/collect ~/cld6001/tests"

    local_copy "$image_script" "~/cld6001/src/setup/pull-images.sh"
    local_copy "$image_registry_helper" "~/cld6001/src/execute/image-registry.sh"

    docker_rootful_primary="
        cd ~/cld6001
        sudo env CONTAINER_RUNTIME=docker bash src/setup/pull-images.sh --primary
    "
    docker_rootful_dhi="
        cd ~/cld6001
        sudo env CONTAINER_RUNTIME=docker bash src/setup/pull-images.sh --dhi
    "
    docker_rootless_primary="
        cd ~/cld6001
        ROOTLESS_USER='$(id -un)'
        ROOTLESS_UID=\$(id -u \"\$ROOTLESS_USER\")
        ROOTLESS_HOME=\$(getent passwd \"\$ROOTLESS_USER\" | cut -d: -f6)
        ROOTLESS_RUNTIME_DIR=/run/user/\$ROOTLESS_UID
        ROOTLESS_DBUS=unix:path=\${ROOTLESS_RUNTIME_DIR}/bus
        env HOME=\"\$ROOTLESS_HOME\" XDG_RUNTIME_DIR=\"\$ROOTLESS_RUNTIME_DIR\" DBUS_SESSION_BUS_ADDRESS=\"\$ROOTLESS_DBUS\" DOCKER_HOST=\"unix://\${ROOTLESS_RUNTIME_DIR}/docker.sock\" CONTAINER_RUNTIME=docker bash src/setup/pull-images.sh --primary
    "
    docker_rootless_dhi="
        cd ~/cld6001
        ROOTLESS_USER='$(id -un)'
        ROOTLESS_UID=\$(id -u \"\$ROOTLESS_USER\")
        ROOTLESS_HOME=\$(getent passwd \"\$ROOTLESS_USER\" | cut -d: -f6)
        ROOTLESS_RUNTIME_DIR=/run/user/\$ROOTLESS_UID
        ROOTLESS_DBUS=unix:path=\${ROOTLESS_RUNTIME_DIR}/bus
        env HOME=\"\$ROOTLESS_HOME\" XDG_RUNTIME_DIR=\"\$ROOTLESS_RUNTIME_DIR\" DBUS_SESSION_BUS_ADDRESS=\"\$ROOTLESS_DBUS\" DOCKER_HOST=\"unix://\${ROOTLESS_RUNTIME_DIR}/docker.sock\" CONTAINER_RUNTIME=docker bash src/setup/pull-images.sh --dhi
    "
    podman_rootless_primary="
        cd ~/cld6001
        CONTAINER_RUNTIME=podman bash src/setup/pull-images.sh --primary
    "
    podman_rootless_dhi="
        cd ~/cld6001
        CONTAINER_RUNTIME=podman bash src/setup/pull-images.sh --dhi
    "

    info "Pulling primary images for docker-rootful..."
    local_exec "$docker_rootful_primary" "bash src/setup/pull-images.sh --primary (docker-rootful)"
    info "Pulling DHI images for docker-rootful..."
    local_exec "$docker_rootful_dhi" "bash src/setup/pull-images.sh --dhi (docker-rootful)"

    info "Pulling primary images for docker-rootless..."
    local_exec "$docker_rootless_primary" "bash src/setup/pull-images.sh --primary (docker-rootless)"
    info "Pulling DHI images for docker-rootless..."
    local_exec "$docker_rootless_dhi" "bash src/setup/pull-images.sh --dhi (docker-rootless)"

    info "Pulling primary images for podman-rootless..."
    local_exec "$podman_rootless_primary" "bash src/setup/pull-images.sh --primary (podman-rootless)"
    info "Pulling DHI images for podman-rootless..."
    local_exec "$podman_rootless_dhi" "bash src/setup/pull-images.sh --dhi (podman-rootless)"

    info "Verifying images..."
    local_exec "
        sudo docker images --format 'Table {{.Repository}}:{{.Tag}}\t{{.Size}}' | head -20
    " "docker images"

    ok "--- Step 3 complete ---"
}

download_exploits() {
    info "--- Step 4: Exploit Acquisition ---"

    local exploit_script="${REPO_ROOT}/resources/exploits/download-exploits.sh"

    [[ -f "$exploit_script" ]] || {
        error "Exploit download script not found: $exploit_script"
        return 1
    }

    local_copy "$exploit_script" "~/cld6001/resources/exploits/download-exploits.sh"

    info "Downloading exploits..."
    local_exec "
        cd ~/cld6001/resources/exploits
        chmod +x download-exploits.sh
        bash ~/cld6001/resources/exploits/download-exploits.sh
    " "bash ~/cld6001/resources/exploits/download-exploits.sh"

    ok "--- Step 4 complete ---"
}

establish_baseline() {
    info "--- Step 5: Security Baseline ---"

    info "Pulling security scanning tools..."
    local_exec "
        set -Eeuo pipefail

        pull_first_available() {
            local label=\"\$1\"
            shift
            local image=\"\"

            for image in \"\$@\"; do
                echo \"[INFO] Pulling \$label candidate: \$image\"
                if docker pull \"\$image\"; then
                    echo \"[OK] Pulled \$label: \$image\"
                    return 0
                fi
            done

            echo \"[WARN] No pull candidate succeeded for \$label\" >&2
            return 0
        }

        pull_first_available \"Trivy\" \
            \"aquasec/trivy:latest\"

        pull_first_available \"Snyk\" \
            \"snyk/snyk:node\"

        pull_first_available \"Docker Bench for Security\" \
            \"docker/docker-bench-security\"
    " "warm-pull security tools"

    ok "--- Step 5 complete ---"
}

run_tests() {
    info "--- Step 6: Test Execution ---"

    local run_id="${CLD6001_RUN_ID:-$(cld6001_generate_run_id)}"
    local remote_run_root="~/thesis-research/results/$run_id"
    local remote_orch_log_root="$remote_run_root/orchestrator/logs"
    local orchestrator_command_prefix=""

    info "Preparing current local checkout for a fresh test run..."
    sync_test_repository_subset "" || return 1
    ok "Repository synchronized successfully"

    if [[ "$ORCHESTRATOR_RELAXED_DEBUG_EXPLICIT_SET" == "true" ]]; then
        printf -v orchestrator_command_prefix 'CLD6001_ORCHESTRATOR_RELAXED_DEBUG=%q ' "$ORCHESTRATOR_RELAXED_DEBUG_EXPLICIT_VALUE"
    else
        orchestrator_command_prefix='env -u CLD6001_ORCHESTRATOR_RELAXED_DEBUG '
    fi

    info "Running container security tests..."
    local_exec_display "bash src/execute/server-orchestrator.sh --run-id \"$run_id\" 2>&1 | tee \"$remote_orch_log_root/full-suite/server-orchestrator.log\" (results: $remote_run_root)" "
        cd ~/thesis-research
        set -Eeuo pipefail

        chmod +x src/execute/*.sh src/execute/escape-tests/*.sh src/execute/*.sh src/profiles/*.sh src/setup/*.sh src/collect/*.sh
        RUN_ID='$run_id'
        REMOTE_RUN_ROOT='$remote_run_root'
        REMOTE_ORCH_LOG_ROOT='$remote_orch_log_root'
        mkdir -p \"\$REMOTE_RUN_ROOT/orchestrator/logs/full-suite\"
        mkdir -p \"\$REMOTE_RUN_ROOT/reports\"
        mkdir -p \"\$REMOTE_RUN_ROOT/snapshots\"
        suite_log=\"\$REMOTE_ORCH_LOG_ROOT/full-suite/server-orchestrator.log\"
        ${orchestrator_command_prefix}CLD6001_RUN_ID=\"\$RUN_ID\" CLD6001_RUN_ROOT=\"\$REMOTE_RUN_ROOT\" CLD6001_RESULTS_ROOT=\"\$REMOTE_RUN_ROOT\" bash src/execute/server-orchestrator.sh --run-id \"\$RUN_ID\" 2>&1 | tee \"\$suite_log\"
    " || return 1

    ok "--- Step 6 complete ---"
}

cleanup_runtime_containers() {
    local -a runtime_cmd=("$@")
    local -a container_ids=()
    local container_id=""

    while IFS= read -r container_id; do
        [[ -n "$container_id" ]] || continue
        container_ids+=("$container_id")
    done < <("${runtime_cmd[@]}" ps -aq 2>/dev/null || true)

    if ((${#container_ids[@]})); then
        "${runtime_cmd[@]}" rm -f "${container_ids[@]}" >/dev/null 2>&1 || true
    fi
}

prune_runtime_networks() {
    local -a runtime_cmd=("$@")

    "${runtime_cmd[@]}" network prune -f >/dev/null 2>&1 || true
}

cleanup_restore_host_state() {
    info "--- Step 7: Host Restoration & General Cleanup ---"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would execute locally: restore host state"
        TEMP_SUDOERS_ACTIVE=false
        ok "--- Step 7 complete ---"
        return 0
    fi

    info "Executing locally: restore host state..."

    local status=0
    set +e
    {
        cleanup_runtime_containers sudo docker
        cleanup_runtime_containers docker
        cleanup_runtime_containers podman

        prune_runtime_networks sudo docker
        prune_runtime_networks docker
        prune_runtime_networks podman

        sudo rm -f "$TEMP_SUDOERS_PATH"
        sudo -k || true
    } 2>&1 | tee -a "$LOG_FILE"
    status=${PIPESTATUS[0]}
    set -e

    TEMP_SUDOERS_ACTIVE=false
    ok "--- Step 7 complete ---"
    return "$status"
}

cleanup() {
    info "--- Cleanup ---"

    info "Cleaning up temporary files..."
    local_exec "
        rm -rf ~/cld6001/resources/exploits/*.c
        rm -rf ~/cld6001/resources/exploits/*.o

        docker system prune -f --volumes
    " "cleanup local artifacts"

    ok "--- Cleanup complete ---"
}

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --non-interactive)
                INTERACTIVE=false
                ;;
            --setup-only)
                SETUP_ONLY=true
                ;;
            --pull-only)
                PULL_ONLY=true
                ;;
            --test-only)
                TEST_ONLY=true
                ;;
            --clean)
                CLEAN=true
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --local)
                LOCAL_MODE=true
                ;;
            *)
                echo "Usage: bash run.sh [OPTIONS]"
                echo ""
                echo "Options:"
                echo "--non-interactive    Run without prompts (use env vars)"
                echo "--setup-only         Only setup environment"
                echo "--pull-only          Only pull images"
                echo "--test-only           Only run tests"
                echo "--clean              Clean environment first"
                echo "--dry-run            Show what would be done"
                echo ""
                echo "Environment Variables:"
                echo "VM_USER"
                echo "DOCKER_USERNAME, DOCKER_TOKEN"
                exit 1
                ;;
        esac
        shift
    done

    echo "---"
    echo "--- CLD6001 Container Security Research - Server Orchestrator ---"
    echo "---"
    echo ""
    echo "Log file: $LOG_FILE"
    echo "Date: $(date)"
    echo ""

    install_temporary_sudoers

    local main_status=0

    if [[ "$SETUP_ONLY" == "true" ]]; then
        setup_vm || main_status=$?
    elif [[ "$TEST_ONLY" == "true" ]]; then
        run_tests || main_status=$?
        cleanup_restore_host_state || {
            [[ "$main_status" -ne 0 ]] || main_status=$?
        }
    elif [[ "$PULL_ONLY" == "true" ]]; then
        authenticate || main_status=$?
        if [[ "$main_status" -eq 0 ]]; then
            pull_images || main_status=$?
        fi
    else
        setup_vm || main_status=$?
        if [[ "$main_status" -eq 0 ]]; then
            authenticate || main_status=$?
        fi
        if [[ "$main_status" -eq 0 ]]; then
            info "Skipping standalone image staging during full automation; server-orchestrator owns per-runtime staging"
        fi
        if [[ "$main_status" -eq 0 ]]; then
            download_exploits || main_status=$?
        fi
        if [[ "$main_status" -eq 0 ]]; then
            establish_baseline || main_status=$?
        fi
        if [[ "$main_status" -eq 0 ]]; then
            run_tests || main_status=$?
        fi
        cleanup_restore_host_state || {
            [[ "$main_status" -ne 0 ]] || main_status=$?
        }
    fi

    if [[ "$CLEAN" == "true" ]]; then
        cleanup || {
            [[ "$main_status" -ne 0 ]] || main_status=$?
        }
    fi

    echo ""
    echo "---"
    echo "--- Automation Complete ---"
    echo "---"
    echo ""
    echo "Logs saved to: $LOG_FILE"
    echo ""

    return "$main_status"
}

main "$@"
