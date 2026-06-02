#!/bin/bash

set -Eeuo pipefail

if ! declare -F info >/dev/null 2>&1; then
    info() { :; }
fi

if ! declare -F warn >/dev/null 2>&1; then
    warn() { :; }
fi

if ! declare -F error >/dev/null 2>&1; then
    error() { :; }
fi

ALPINE_IMAGES=(
    "alpine:3.23.0"       # Latest stable (Priority 1) - Updated 2026-05
    "alpine:3.22"         # Floating stable (Priority 2)
    "alpine:3.21.7"       # Previous stable (Priority 3)
    "alpine:3.20.10"      # Older stable, known vulnerable (Priority 4)
    "alpine:3.19"         # Historical comparison (Priority 5)
    "alpine:3.18"         # Older historical (Priority 6)
)

UBUNTU_IMAGES=(
    "ubuntu:24.04"        # Noble LTS - Latest (Priority 1)
    "ubuntu:22.04"        # Jammy LTS - Previous (Priority 2)
    "ubuntu:20.04"        # Focal LTS - Known vulnerable (Priority 3)
    "ubuntu:18.04"        # Bionic EOL - Historical (Priority 4)
    "ubuntu:16.04"        # Xenial EOL - Known vulnerable for runtime CVEs (Priority 5)
)

DEBIAN_IMAGES=(
    "debian:testing-slim"       # Trixie (Testing) - Latest (Priority 1)
    "debian:stable-slim"        # Bookworm (Stable) - Current stable (Priority 2)
    "debian:bullseye-slim"      # Oldstable - Known vulnerable (Priority 3)
    "debian:buster-slim"        # EOL - Historical (Priority 4)
    "debian:jessie-slim"        # Very old EOL - Historical (Priority 5)
)

CENTOS_IMAGES=(
    "quay.io/centos/centos:stream10"   # Stream 10 - Latest (Priority 1)
    "quay.io/centos/centos:stream9"    # Stream 9 - Previous (Priority 2)
    "quay.io/centos/centos:stream8"    # Stream 8 - Known vulnerable (Priority 3)
)

NGINX_IMAGES=(
    "nginx:1.31.0-alpine3.23"   # Latest (Priority 1)
    "nginx:1.27.3-alpine3.21"   # Previous (Priority 2)
    "nginx:1.25-alpine3.19"     # Known vulnerable for HTTP/2 exploits (Priority 3)
    "nginx:1.23.4-alpine"       # Older vulnerable (Priority 4)
    "nginx:1.21.6-alpine"       # Historical (Priority 5)
)

NODE_IMAGES=(
    "node:24.16.0-alpine3.23"   # Jod (Current) - Latest (Priority 1)
    "node:20-alpine3.21"        # Iron (LTS) - Previous (Priority 2)
    "node:18-alpine3.19"        # Hydrogen (LTS) - Known vulnerable (Priority 3)
    "node:16-alpine"            # Argon (EOL) - Historical (Priority 4)
    "node:14-alpine"            # Erbium (EOL) - Historical (Priority 5)
)

POSTGRES_IMAGES=(
    "postgres:18.4-alpine3.23"  # Latest major (Priority 1)
    "postgres:15.18-alpine3.23"   # LTS (Priority 2)
    "postgres:14-alpine3.21"      # Known vulnerable (Priority 3)
    "postgres:12-alpine3.21"      # Historical (Priority 4)
    "postgres:11-alpine"          # Very old (Priority 5)
)

image_priority_runtime_command() {
    printf '%s\n' "${RUNNER_RUNTIME_ENGINE:-${CONTAINER_RUNTIME:-docker}}"
}

image_priority_inspect() {
    local runtime_command=""
    runtime_command="$(image_priority_runtime_command)"

    if "$runtime_command" image inspect "$1" > /dev/null 2>&1; then
        printf '0\n'
    else
        printf '1\n'
    fi
}

get_image() {
    local list_name="$1"
    local -n image_list_ref="$list_name"
    local image_list=("${image_list_ref[@]}")
    local inspect_status=""

    for image in "${image_list[@]}"; do
        inspect_status="$(image_priority_inspect "$image")"

        if [ "$inspect_status" = "0" ]; then
            echo "$image"
            return 0
        fi
    done

    echo "${image_list[0]}"
}

run_with_priority_images() {
    local list_name="$1"
    local command="$2"
    local -n image_list_ref="$list_name"
    local image_list=("${image_list_ref[@]}")
    local inspect_status=""

    for image in "${image_list[@]}"; do
        inspect_status="$(image_priority_inspect "$image")"

        if [ "$inspect_status" = "0" ]; then
            info "Testing with: $image..."
            IMAGE="$image"
            if eval "$command"; then
                return 0  # Success
            fi
            warn "Command failed with $image, trying next version"
        else
            warn "Image not available: $image, skipping"
        fi
    done

    error "All images failed or unavailable"
    return 1
}

has_cve() {
    local image="$1"
    local cve_id="$2"

    local vuln_output
    vuln_output=$(trivy image --format json "$image" 2>/dev/null)

    if echo "$vuln_output" | grep -q "$cve_id" > /dev/null 2>&1; then
        return 0  # CVE found
    fi

    return 1  # CVE not found
}

get_image_with_cve() {
    local list_name="$1"
    local cve_id="$2"
    local -n image_list_ref="$list_name"
    local image_list=("${image_list_ref[@]}")
    local inspect_status=""

    for image in "${image_list[@]}"; do
        inspect_status="$(image_priority_inspect "$image")"

        if [ "$inspect_status" = "0" ]; then
            if has_cve "$image" "$cve_id"; then
                echo "$image"
                return 0
            fi
        fi
    done

    error "No available image contains CVE $cve_id"
    return 1
}

get_image_by_kernel() {
    local list_name="$1"
    local min_version="$2"
    local max_version="$3"
    local -n image_list_ref="$list_name"
    local image_list=("${image_list_ref[@]}")
    local runtime_command=""
    local inspect_status=""

    runtime_command="$(image_priority_runtime_command)"

    for image in "${image_list[@]}"; do
        inspect_status="$(image_priority_inspect "$image")"

        if [ "$inspect_status" = "0" ]; then
            local kernel_version
            kernel_version=$("$runtime_command" run --rm "$image" uname -r 2>/dev/null | cut -d'.' -f1-3)

            if version_between "$kernel_version" "$min_version" "$max_version"; then
                echo "$image"
                return 0
            fi
        fi
    done

    error "No image found with kernel version $min_version-$max_version"
    return 1
}

version_between() {
    local version="$1"
    local min="$2"
    local max="$3"

    local ver_major=$(echo "$version" | cut -d'.' -f1)
    local ver_minor=$(echo "$version" | cut -d'.' -f2)
    local min_major=$(echo "$min" | cut -d'.' -f1)
    local min_minor=$(echo "$min" | cut -d'.' -f2)
    local max_major=$(echo "$max" | cut -d'.' -f1)
    local max_minor=$(echo "$max" | cut -d'.' -f2)

    if (( ver_major > min_major )) || (( ver_major == min_major && ver_minor >= min_minor )); then
        if (( ver_major < max_major )) || (( ver_major == max_major && ver_minor <= max_minor )); then
            return 0
        fi
    fi

    return 1
}

echo "Image priorities loaded successfully"
