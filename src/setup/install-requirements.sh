#!/bin/bash
set -Eeuo pipefail

INSTALL_REQ_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${INSTALL_REQ_SCRIPT_DIR}/../../src/shared/terminal-colors.sh"
source "${INSTALL_REQ_SCRIPT_DIR}/../../src/shared/log-pipe.sh"
source "${INSTALL_REQ_SCRIPT_DIR}/../../src/shared/trivy-helpers.sh"

INSTALL_DOCKER=false
INSTALL_PODMAN=false
INSTALL_TOOLS=false
INSTALL_EVIDENCE=false
JUST_CHECK=false

INSTALLED=0
FAILED=0
SKIPPED=0
TRIVY_WRAPPER_PATH="${TRIVY_WRAPPER_PATH:-/usr/local/bin/trivy}"
readonly DOCKER_SCOUT_INSTALL_URL="https://raw.githubusercontent.com/docker/scout-cli/main/install.sh"
readonly DOCKER_SCOUT_INSTALL_SHA256="3d350aa78a4bf01b5ba27211a0bbb69441fe05d46202ab1694c8921877176d19"
readonly GRYPE_INSTALL_URL="https://raw.githubusercontent.com/anchore/grype/main/install.sh"
readonly GRYPE_INSTALL_SHA256="8646f06a90b10ca64992c1809b4aa00c44e30b4f551f63c309b0b0ab66873556"
readonly VERIFIED_INSTALLER_CACHE_DIR="${VERIFIED_INSTALLER_CACHE_DIR:-${INSTALL_REQ_SCRIPT_DIR}/.installer-cache}"

log_info() {
    log_pipe "INFO" "setup" "requirements" "$*"
}

log_ok() {
    log_pipe "OK" "setup" "requirements" "$*"
}

log_warn() {
    log_pipe "WARN" "setup" "requirements" "$*"
}

log_error() {
    log_pipe "ERROR" "setup" "requirements" "$*"
}

check_command() {
    if command -v "$1" &> /dev/null; then
        return 0
    fi
    if [ -x "/usr/local/bin/$1" ] || [ -x "/usr/bin/$1" ]; then
        return 0
    fi
    return 1
}

verified_curl_exec() {
    local url="$1"
    local expected_hash="$2"
    local installer_name="$3"
    shift 3

    local tmp_installer=""
    local actual_hash=""

    mkdir -p "$VERIFIED_INSTALLER_CACHE_DIR"
    tmp_installer="${VERIFIED_INSTALLER_CACHE_DIR}/${installer_name}-$$-${RANDOM}.sh"

    if ! curl -fsSL "$url" -o "$tmp_installer"; then
        log_error "Failed to download installer from $url"
        rm -f "$tmp_installer"
        return 1
    fi

    actual_hash="$(sha256sum "$tmp_installer" | cut -d' ' -f1)"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        log_error "Hash mismatch for $url: expected $expected_hash, got $actual_hash"
        rm -f "$tmp_installer"
        return 1
    fi

    if ! bash "$tmp_installer" "$@"; then
        log_error "Installer execution failed for $url"
        rm -f "$tmp_installer"
        return 1
    fi

    rm -f "$tmp_installer"
}

is_managed_trivy_wrapper() {
    [ -f "$TRIVY_WRAPPER_PATH" ] && grep -Fq "CLD6001 managed Trivy wrapper" "$TRIVY_WRAPPER_PATH"
}

is_legacy_trivy_wrapper() {
    [ -f "$TRIVY_WRAPPER_PATH" ] && grep -Fq 'docker run --rm --privileged aquasec/trivy:latest "$@"' "$TRIVY_WRAPPER_PATH"
}

write_trivy_wrapper() {
    {
        cat <<'EOF'
#!/bin/bash
# CLD6001 managed Trivy wrapper

set -Eeuo pipefail

EOF
        declare -f cld6001_trivy_log_error
        declare -f cld6001_trivy_container_image
        declare -f cld6001_trivy_runtime_root
        declare -f cld6001_trivy_cache_dir
        declare -f cld6001_trivy_resolve_runtime
        declare -f cld6001_trivy_prepare_cache_dir
        declare -f cld6001_trivy_create_scan_archive
        declare -f cld6001_trivy_bind_mount_arg
        declare -f cld6001_trivy_run_saved_image
        cat <<'EOF'

flag_takes_value() {
    case "$1" in
        --json|--quiet|--debug|--insecure|--ignore-unfixed|--download-db-only|--skip-db-update|--skip-java-db-update|--list-all-pkgs)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

run_image_scan() {
    local runtime="$1"
    local image_ref=""
    local tmp_root=""
    local scan_input=""
    local trivy_cache_dir=""
    local trivy_runtime_root=""
    local -a forwarded_args=()
    local -a mount_args=(
        -v "$(cld6001_trivy_bind_mount_arg "$runtime" "$PWD" "/work")"
        -w /work
    )

    shift

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --output|-o)
                [ "$#" -ge 2 ] || {
                    cld6001_trivy_log_error "$1 requires a value"
                    return 1
                }
                mkdir -p -- "$(dirname -- "$2")"
                if [ "${2#/}" != "$2" ]; then
                    mount_args+=(-v "$(cld6001_trivy_bind_mount_arg "$runtime" "$(dirname -- "$2")" "$(dirname -- "$2")")")
                    forwarded_args+=("$1" "$2")
                else
                    forwarded_args+=("$1" "/work/${2#./}")
                fi
                shift 2
                ;;
            --cache-dir)
                [ "$#" -ge 2 ] || {
                    cld6001_trivy_log_error "--cache-dir requires a value"
                    return 1
                }
                shift 2
                ;;
            --*)
                forwarded_args+=("$1")
                if [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] && flag_takes_value "$1"; then
                    forwarded_args+=("$2")
                    shift 2
                else
                    shift
                fi
                ;;
            *)
                image_ref="$1"
                shift
                ;;
        esac
    done

    [ -n "$image_ref" ] || {
        cld6001_trivy_log_error "trivy image requires an image reference"
        return 1
    }

    trivy_cache_dir="$(cld6001_trivy_prepare_cache_dir)" || return 1
    trivy_runtime_root="$(cld6001_trivy_runtime_root)" || return 1
    mkdir -p -- "$trivy_runtime_root"
    tmp_root="$(mktemp -d "${trivy_runtime_root%/}/cld6001-trivy-XXXXXX")" || return 1
    trap 'rm -rf -- "$tmp_root"' RETURN
    scan_input="$(cld6001_trivy_create_scan_archive "$runtime" "$image_ref" "$tmp_root")" || return 1

    cld6001_trivy_run_saved_image \
        "$runtime" \
        "$scan_input" \
        "$trivy_cache_dir" \
        "${mount_args[@]}" \
        -- \
        "${forwarded_args[@]}"
}

main() {
    local runtime=""
    local trivy_cache_dir=""
    local trivy_image=""

    runtime="$(cld6001_trivy_resolve_runtime)" || exit 1

    if [ "${1:-}" = "image" ]; then
        shift
        run_image_scan "$runtime" "$@"
        exit $?
    fi

    trivy_cache_dir="$(cld6001_trivy_prepare_cache_dir)" || exit 1
    trivy_image="$(cld6001_trivy_container_image)" || exit 1

    exec "$runtime" run --rm \
        -v "$(cld6001_trivy_bind_mount_arg "$runtime" "$PWD" "/work")" \
        -w /work \
        -v "$(cld6001_trivy_bind_mount_arg "$runtime" "$trivy_cache_dir" "/trivy-cache")" \
        -e TRIVY_CACHE_DIR=/trivy-cache \
        "$trivy_image" "$@"
}

main "$@"
EOF
    } > "$TRIVY_WRAPPER_PATH"
    chmod +x "$TRIVY_WRAPPER_PATH"
}

install_package() {
    local pkg="$1"

    if check_command "$pkg" || rpm -q "$pkg" &>/dev/null; then
        log_warn "$pkg already installed, skipping"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    log_info "Installing $pkg..."
    if dnf install -y "$pkg" &>/dev/null || dnf install -y --disableexcludes=main "$pkg" &>/dev/null; then
        log_ok "$pkg installed successfully"
        INSTALLED=$((INSTALLED + 1))
        return 0
    else
        log_error "Failed to install $pkg"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

verify_installation() {
    local command_name="$1"
    if check_command "$command_name"; then
        log_ok "$command_name is available successfully: $(which $command_name)"
        return 0
    else
        log_error "$command_name not found after installation"
        return 1
    fi
}

check_system_requirements() {
    log_info "--- Checking System Requirements ---"
    local all_passed=0  # 0 = all good

    if ! grep -qi "almalinux" /etc/os-release 2>/dev/null; then
        log_warn "System is not AlmaLinux (found: $(cat /etc/os-release 2>/dev/null | grep -i id))"
    else
        log_ok "AlmaLinux detected successfully"
    fi

    if grep -qi "almalinux" /etc/os-release 2>/dev/null; then
        local version=$(grep -oP 'VERSION_ID.*?\"(\d+\.\d+)' /etc/os-release | grep -oP '\d+\.\d+')
        case "$version" in
            10.*)
                log_ok "AlmaLinux version $version verified successfully"
                ;;
            *)
                log_warn "AlmaLinux version $version - recommended is 10.x"
                ;;
        esac
    fi

    if [ "$(id -u)" -eq 0 ]; then
        log_ok "Running as root verified successfully"
    else
        if check_command sudo; then
            log_ok "sudo available successfully"
        else
            log_error "Not running as root and sudo not found"
            all_passed=1
        fi
    fi

    if ping -c 1 -W 5 github.com &>/dev/null; then
        log_ok "Internet connectivity verified successfully"
    else
        log_error "No internet connectivity - downloads will fail"
        all_passed=1
    fi

    local available=$(df -BG / | tail -1 | awk '{print $4}' | cut -d'G' -f1)
    if [ "${available:-0}" -lt 20 ]; then
        log_warn "Low disk space: ${available}GB available, 20GB+ recommended"
    else
        log_ok "Disk space verified successfully: ${available}GB available"
    fi

    return ${all_passed}
}

install_docker() {
    log_info "--- Installing Docker ---"

    if check_command docker; then
        log_warn "Docker already installed: $(docker --version | head -1)"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    log_info "Installing EPEL repository..."
    dnf install -y epel-release &>/dev/null

    log_info "Adding Docker CE repository..."
    if command -v dnf-config-manager >/dev/null 2>&1; then
        dnf-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    else
        dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi

    log_info "Installing Docker CE packages..."
    if dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        log_ok "Docker CE packages installed successfully"
        INSTALLED=$((INSTALLED + 1))
    else
        log_error "Failed to install Docker CE packages"
        FAILED=$((FAILED + 1))
        return 1
    fi

    log_info "Starting Docker service..."
    systemctl enable --now docker

    groupadd -f docker
    usermod -aG docker "$SUDO_USER" 2>/dev/null || usermod -aG docker "$(whoami)"

    log_info "Installing rootless Docker tools..."
    dnf install -y docker-ce-rootless-extras slirp4netns

    verify_installation docker
}

install_podman() {
    log_info "--- Installing Podman ---"

    if check_command podman; then
        log_warn "Podman already installed: $(podman --version | head -1)"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    log_info "Installing Podman and dependencies..."
    local packages=(
        podman
        containers-common
        buildah
        crun
        slirp4netns
        fuse-overlayfs
        fuse3
        netavark
        runc
        catatonit
        container-selinux
    )

    dnf install -y podman-plugins &>/dev/null || true

    for pkg in "${packages[@]}"; do
        install_package "$pkg"
    done

    verify_installation podman
}

install_security_tools() {
    log_info "--- Installing Security Analysis Tools ---"

    log_info "Installing Docker Scout..."
    if ! check_command docker-scout; then
        if verified_curl_exec "$DOCKER_SCOUT_INSTALL_URL" "$DOCKER_SCOUT_INSTALL_SHA256" "docker-scout" -b /usr/local/bin && check_command docker-scout; then
            log_ok "Docker Scout installed successfully"
            INSTALLED=$((INSTALLED + 1))
        else
            log_error "Failed to install Docker Scout"
            FAILED=$((FAILED + 1))
        fi
    else
        log_warn "Docker Scout already available"
        SKIPPED=$((SKIPPED + 1))
    fi

    log_info "Installing Trivy (runtime-aware container wrapper)..."
    if ! check_command trivy; then
        write_trivy_wrapper
        log_ok "Trivy wrapper installed successfully"
        INSTALLED=$((INSTALLED + 1))
    elif is_legacy_trivy_wrapper || is_managed_trivy_wrapper; then
        write_trivy_wrapper
        log_ok "Trivy wrapper updated successfully"
        INSTALLED=$((INSTALLED + 1))
    else
        log_warn "Trivy already available"
        SKIPPED=$((SKIPPED + 1))
    fi

    log_info "Installing Dockle..."
    if ! check_command dockle; then
        local version=$(curl -s "https://api.github.com/repos/goodwithtech/dockle/releases/latest" | jq -r .tag_name)
        local version_no_v=${version#v}
        log_info "Latest Dockle version: ${version}"
        if curl -L -o /tmp/dockle.tar.gz "https://github.com/goodwithtech/dockle/releases/download/${version}/dockle_${version_no_v}_Linux-64bit.tar.gz"; then
            tar -xzf /tmp/dockle.tar.gz -C /tmp
            mv -f /tmp/dockle /usr/local/bin/dockle
            chmod +x /usr/local/bin/dockle
            rm -f /tmp/dockle.tar.gz
            log_ok "Dockle installed successfully"
            INSTALLED=$((INSTALLED + 1))
        else
            log_error "Failed to download/install Dockle"
            FAILED=$((FAILED + 1))
        fi
    else
        log_warn "Dockle already available"
        SKIPPED=$((SKIPPED + 1))
    fi

    log_info "Installing Grype..."
    if ! check_command grype; then
        if verified_curl_exec "$GRYPE_INSTALL_URL" "$GRYPE_INSTALL_SHA256" "grype" -b /usr/local/bin; then
            log_ok "Grype installed successfully to /usr/local/bin/grype"
            INSTALLED=$((INSTALLED + 1))
        else
            log_error "Failed to install Grype"
            FAILED=$((FAILED + 1))
        fi
    else
        log_warn "Grype already available"
        SKIPPED=$((SKIPPED + 1))
    fi

    log_info "Installing Docker Bench Security..."
    if ! check_command docker-bench-security; then
        rm -rf /opt/docker-bench-security
        if git clone https://github.com/docker/docker-bench-security.git /opt/docker-bench-security; then
            ln -sf /opt/docker-bench-security/docker-bench-security.sh /usr/local/bin/docker-bench-security
            log_ok "Docker Bench Security installed successfully"
            INSTALLED=$((INSTALLED + 1))
        else
            log_error "Failed to clone Docker Bench Security"
            FAILED=$((FAILED + 1))
        fi
    else
        log_warn "Docker Bench Security already available"
        SKIPPED=$((SKIPPED + 1))
    fi

    install_package gcc
    install_package make
    install_package python3-scipy
    install_package libcap  # provides capsh
    install_package nmap-ncat  # provides nc
    install_package jq
}

install_evidence_tools() {
    log_info "--- Installing Evidence Capture Tools ---"

    install_package strace
    install_package tcpdump
    install_package wireshark

    if ! rpm -q ffmpeg &>/dev/null; then
        log_info "Installing ffmpeg..."
        if dnf install -y ffmpeg &>/dev/null; then
            log_ok "ffmpeg installed successfully"
            INSTALLED=$((INSTALLED + 1))
        else
            log_warn "ffmpeg package not found or failed to install. Continuing as it is optional (requires RPM Fusion)."
        fi
    else
        log_warn "ffmpeg already installed, skipping"
        SKIPPED=$((SKIPPED + 1))
    fi

    if ! check_command asciinema; then
        log_info "Installing asciinema..."
        if pip3 install --upgrade --break-system-packages asciinema &>/dev/null || pip3 install --upgrade asciinema &>/dev/null || pip3 install --upgrade --user asciinema &>/dev/null; then
            if [ -f "$HOME/.local/bin/asciinema" ]; then
                ln -sf "$HOME/.local/bin/asciinema" /usr/local/bin/asciinema
            elif [ -f "/root/.local/bin/asciinema" ]; then
                ln -sf "/root/.local/bin/asciinema" /usr/local/bin/asciinema
            fi
            log_ok "asciinema installed successfully"
            INSTALLED=$((INSTALLED + 1))
        else
            log_error "Failed to install asciinema"
            FAILED=$((FAILED + 1))
        fi
    else
        log_warn "asciinema already available"
        SKIPPED=$((SKIPPED + 1))
    fi
}

main() {
    echo "---"
    echo "CLD6001 Container Security Research"
    echo "Host Requirements Installation Script"
    echo "---"
    echo ""

    for arg in "$@"; do
        case "$arg" in
            --docker|--d)
                INSTALL_DOCKER=true
                ;;
            --podman|--p)
                INSTALL_PODMAN=true
                ;;
            --tools|--t)
                INSTALL_TOOLS=true
                ;;
            --evidence|--e)
                INSTALL_EVIDENCE=true
                ;;
            --check|--c)
                JUST_CHECK=true
                ;;
            --all|--*)
                INSTALL_DOCKER=true
                INSTALL_PODMAN=true
                INSTALL_TOOLS=true
                INSTALL_EVIDENCE=true
                ;;
            *)
                echo "Unknown option: $arg"
                echo "Usage: $0 [--docker] [--podman] [--tools] [--evidence] [--check] [--all]"
                exit 1
                ;;
        esac
    done

    if [ "$JUST_CHECK" = false ] && [ "$INSTALL_DOCKER" = false ] && [ "$INSTALL_PODMAN" = false ] && [ "$INSTALL_TOOLS" = false ] && [ "$INSTALL_EVIDENCE" = false ]; then
        INSTALL_DOCKER=true
        INSTALL_PODMAN=true
        INSTALL_TOOLS=true
        INSTALL_EVIDENCE=true
    fi

    check_system_requirements

    if [ "$JUST_CHECK" = false ]; then
        if [ "$(id -u)" -ne 0 ] && ! check_command sudo; then
            log_error "This script requires root access. Please run with sudo."
            exit 1
        fi

        if [ "$INSTALL_DOCKER" = true ]; then
            install_docker
            echo ""
        fi

        if [ "$INSTALL_PODMAN" = true ]; then
            install_podman
            echo ""
        fi

        if [ "$INSTALL_TOOLS" = true ]; then
            install_security_tools
            echo ""
        fi

        if [ "$INSTALL_EVIDENCE" = true ]; then
            install_evidence_tools
            echo ""
        fi
    fi

    echo "---"
    echo "Installation Summary"
    echo "---"
    echo -e "${GREEN}Installed: ${INSTALLED}${NC}"
    echo -e "${YELLOW}Skipped: ${SKIPPED}${NC}"
    echo -e "${RED}Failed: ${FAILED}${NC}"
    echo "---"

    if [ "$FAILED" -gt 0 ]; then
        log_error "Some installations failed. Please review the output above."
        exit 1
    else
        log_ok "All requirements installed successfully"
    fi
}

main "$@"
