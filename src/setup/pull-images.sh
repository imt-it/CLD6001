#!/bin/bash

set -Eeuo pipefail

PULL_IMAGES_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${PULL_IMAGES_SCRIPT_DIR}/../../src/shared/terminal-colors.sh"
source "${PULL_IMAGES_SCRIPT_DIR}/../../src/execute/image-registry.sh"

DRY_RUN=false
PULL_PRIMARY=false
PULL_DHI=false
PULL_MATRIX=false
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
PULL_IMAGES_STRICT="${CLD6001_PULL_IMAGES_STRICT:-false}"
TARGET_IMAGE=""
TARGET_BASE_OS=""
TARGET_FLAVOR=""

pull_images_strict_mode() {
    [ "$PULL_IMAGES_STRICT" = "true" ]
}

parse_pull_images_args() {
    local arg=""

    for arg in "$@"; do
        case $arg in
            --dry-run)
                DRY_RUN=true
                ;;
            --all)
                :
                ;;
            --primary)
                PULL_PRIMARY=true
                ;;
            --dhi)
                PULL_DHI=true
                ;;
            --matrix)
                PULL_MATRIX=true
                ;;
            --image=*)
                TARGET_IMAGE="${arg#*=}"
                ;;
            --base-os=*)
                TARGET_BASE_OS="${arg#*=}"
                ;;
            --flavor=*)
                TARGET_FLAVOR="${arg#*=}"
                ;;
            *)
                echo "Usage: bash pull-images.sh [--dry-run] [--all|--primary|--dhi|--matrix]"
                echo "[--image=image_name] [--base-os=alpine|debian] [--flavor=production|development]"
                echo ""
                echo "Options:"
                echo "--dry-run         Show what would be pulled without actually pulling"
                echo "--all             Pull all image categories"
                echo "--primary         Pull primary targets plus required helper images"
                echo "--dhi             Pull only Docker Hardened Images required by the suite"
                echo "--matrix          Pull the active tested DHI matrix"
                echo "--image=name      Pull only a specific image (nginx|postgres|nodejs)"
                echo "--base-os=os      Pull only a specific base OS (alpine|debian)"
                echo "--flavor=flavor   Pull only a specific DHI flavor (production|development)"
                echo ""
                echo "Default: Pulls the current active inventory"
                return 1
                ;;
        esac
    done
}

collect_primary_images() {
    local image_name=""
    local base_os=""

    for image_name in "${IMAGE_NAMES[@]}"; do
        for base_os in "${BASE_OS_VARIANTS[@]}"; do
            get_docker_official_image_tag "$image_name" "$base_os"
        done
    done
}

HELPER_IMAGES=(
    "python:3.14-slim"
    "alpine:3.23.0"
)

collect_dhi_images() {
    local image_name=""
    local base_os=""
    local flavor=""

    for image_name in "${IMAGE_NAMES[@]}"; do
        for base_os in "${BASE_OS_VARIANTS[@]}"; do
            for flavor in "${DHI_FLAVORS[@]}"; do
                get_dhi_image_tag "$image_name" "$base_os" "$flavor"
            done
        done
    done
}

runtime_exec() {
    "$CONTAINER_RUNTIME" "$@"
}

resolve_runtime_pull_image() {
    local image="$1"

    if [ "$CONTAINER_RUNTIME" = "podman" ]; then
        case "$image" in
            */*)
                printf '%s\n' "$image"
                return 0
                ;;
            *)
                printf 'docker.io/library/%s\n' "$image"
                return 0
                ;;
        esac
    fi

    printf '%s\n' "$image"
}

lookup_expected_digest() {
    local image="$1"

    get_registry_digest_by_image_tag "$image" 2>/dev/null
}

get_helper_image_tag() {
    local helper_name="$1"

    case "$helper_name" in
        python-probe)
            printf '%s\n' 'python:3.14-slim'
            ;;
        alpine-shell)
            printf '%s\n' 'alpine:3.23.0'
            ;;
        *)
            printf 'Unknown helper image: %s\n' "$helper_name" >&2
            return 1
            ;;
    esac
}

pull_image() {
    local image=$1
    local expected_digest="${2:-}"
    local image_platform=""
    local runtime_image=""
    local source_reference=""

    if $DRY_RUN; then
        info "DRY RUN: Would pull $image..."
        return 0
    fi

    info "Pulling: $image..."
    runtime_image="$(resolve_runtime_pull_image "$image")"

    local pull_args=()
    if [ -n "$expected_digest" ]; then
        source_reference="${runtime_image}@${expected_digest}"
    else
        source_reference="$runtime_image"
    fi
    pull_args+=("$source_reference")

    image_platform="$(get_image_platform)"
    if [ -n "$image_platform" ]; then
        pull_args=(--platform "$image_platform" "${pull_args[@]}")
    fi

    if [ "$CONTAINER_RUNTIME" = "podman" ]; then
        pull_args=(--policy=always "${pull_args[@]}")
    fi

    if runtime_exec pull "${pull_args[@]}" > /dev/null 2>&1; then
        ok "$image pulled successfully"

        if [ "$source_reference" != "$image" ]; then
            runtime_exec tag "$source_reference" "$image" > /dev/null 2>&1 || true
        fi

        if [ -n "$expected_digest" ] && is_digest_verification_enabled; then
            info "Verifying digest for: $image..."
            if verify_image_digest "$image" "$expected_digest" "$CONTAINER_RUNTIME"; then
                ok "Digest verification passed successfully"
            else
                error "Digest verification failed for: $image"
                return 1
            fi
        fi

        return 0
    else
        warn "Failed to pull: $image"
        return 1
    fi
}

pull_group() {
    local group_name=$1
    shift
    local images=( "$@" )
    local expected_digest=""

    echo "---"
    echo "$group_name"
    echo "---"
    echo "Images: ${#images[@]}"
    echo "Digest verification: $([ "$DIGEST_VERIFICATION_ENABLED" = "true" ] && echo "enabled" || echo "disabled")"
    echo "---"

    local failed=0
    local verified=0
    for image in "${images[@]}"; do
        if expected_digest="$(lookup_expected_digest "$image" 2>/dev/null)"; then
            :
        else
            expected_digest=""
        fi

        if pull_image "$image" "$expected_digest"; then
            verified=$((verified + 1))
        else
            failed=$((failed + 1))
        fi
    done

    echo ""
    echo "Result: $(( ${#images[@]} - failed ))/${#images[@]} pulled"
    echo "Verified: $verified images"

    if [ $failed -gt 0 ]; then
        warn "$failed images failed to pull"
    else
        ok "All images pulled successfully"
    fi

    return 0
}

pull_image_matrix() {
    local target_image="${1:-}"
    local target_base_os="${2:-}"
    local target_flavor="${3:-}"
    local images_to_pull=()
    local digests_to_verify=()

    echo "---"
    echo "Pulling Image Matrix (${#IMAGE_NAMES[@]}x${#BASE_OS_VARIANTS[@]}x${#DHI_FLAVORS[@]})"
    echo "---"
    echo "Digest verification: $([ "$DIGEST_VERIFICATION_ENABLED" = "true" ] && echo "enabled" || echo "disabled")"

    if [ -n "$target_image" ]; then
        for base_os in "${BASE_OS_VARIANTS[@]}"; do
            if [ -z "$target_base_os" ] || [ "$base_os" = "$target_base_os" ]; then
                for flavor in "${DHI_FLAVORS[@]}"; do
                    if [ -z "$target_flavor" ] || [ "$flavor" = "$target_flavor" ]; then
                        local tag
                        tag="$(get_dhi_image_tag "$target_image" "$base_os" "$flavor")"
                        images_to_pull+=("$tag")

                        local digest
                        if digest=$(get_dhi_digest "$target_image" "$base_os" "$flavor"); then
                            digests_to_verify+=("$digest")
                        else
                            digests_to_verify+=("")
                        fi
                    fi
                done
            fi
        done
    elif [ -n "$target_base_os" ]; then
        for image in "${IMAGE_NAMES[@]}"; do
            for flavor in "${DHI_FLAVORS[@]}"; do
                if [ -z "$target_flavor" ] || [ "$flavor" = "$target_flavor" ]; then
                    local tag
                    tag="$(get_dhi_image_tag "$image" "$target_base_os" "$flavor")"
                    images_to_pull+=("$tag")

                    local digest
                    if digest=$(get_dhi_digest "$image" "$target_base_os" "$flavor"); then
                        digests_to_verify+=("$digest")
                    else
                        digests_to_verify+=("")
                    fi
                fi
            done
        done
    else
        for image in "${IMAGE_NAMES[@]}"; do
            for base_os in "${BASE_OS_VARIANTS[@]}"; do
                for flavor in "${DHI_FLAVORS[@]}"; do
                    local tag
                    tag="$(get_dhi_image_tag "$image" "$base_os" "$flavor")"
                    images_to_pull+=("$tag")

                    local digest
                    if digest=$(get_dhi_digest "$image" "$base_os" "$flavor"); then
                        digests_to_verify+=("$digest")
                    else
                        digests_to_verify+=("")
                    fi
                done
            done
        done
    fi

    local failed=0
    local verified=0
    for i in "${!images_to_pull[@]}"; do
        local image="${images_to_pull[$i]}"
        local digest="${digests_to_verify[$i]}"

        if pull_image "$image" "$digest"; then
            verified=$((verified + 1))
        else
            failed=$((failed + 1))
        fi
    done

    echo ""
    echo "Result: $(( ${#images_to_pull[@]} - failed ))/${#images_to_pull[@]} pulled"
    echo "Verified: $verified images"

    if [ $failed -gt 0 ]; then
        warn "$failed images failed to pull"
        pull_images_strict_mode && return 1
    else
        ok "All images pulled successfully"
    fi

    return 0
}

list_all_images() {
    echo ""
    echo "---"
    echo "Image Inventory"
    echo "---"
    echo ""
    echo "Primary (latest):     ${#PRIMARY_IMAGES[@]}"
    echo "Helper/disposable:    ${#HELPER_IMAGES[@]}"
    echo "DHI:                  ${#DHI_IMAGES[@]}"
    echo "Total:                $(( ${#PRIMARY_IMAGES[@]} + ${#HELPER_IMAGES[@]} + ${#DHI_IMAGES[@]} ))"
    echo ""

    echo "Primary Images (Latest):"
    echo "-------------------------"
    for image in "${PRIMARY_IMAGES[@]}"; do
        echo "* $image"
    done

    echo ""
    echo "Helper/Disposable Images:"
    echo "-------------------------"
    for image in "${HELPER_IMAGES[@]}"; do
        echo "* $image"
    done

    echo ""
    echo "Docker Hardened Images:"
    echo "------------------------"
    for image in "${DHI_IMAGES[@]}"; do
        echo "* $image"
    done
}

verify_images() {
    local all_images=( "$@" )

    echo ""
    echo "---"
    echo "Verifying Pulled Images"
    echo "---"
    local present=0
    local missing=0

    for image in "${all_images[@]}"; do
        if runtime_exec image inspect "$image" > /dev/null 2>&1; then
            present=$((present + 1))
        else
            warn "Missing: $image"
            missing=$((missing + 1))
        fi
    done

    echo ""
    echo "Verification: $present present, $missing missing"

    if [ $missing -eq 0 ]; then
        ok "All images present successfully"
        return 0
    else
        warn "$missing images missing (may require registry login)"
        pull_images_strict_mode && return 1
        return 0
    fi
}

mapfile -t PRIMARY_IMAGES < <(collect_primary_images)
mapfile -t DHI_IMAGES < <(collect_dhi_images)

pull_images_main() {
    local verify_targets=()
    local pull_status=0

    parse_pull_images_args "$@" || return 1

    echo "---"
    echo "CLD6001 Container Image Pull Script"
    echo "---"
    echo ""
    echo "Strategy: Active thesis inventory only"
    echo "Date:     $(date +%Y-%m-%d)"
    echo ""

    if $DRY_RUN; then
        echo "DRY RUN MODE - No images will be pulled"
        list_all_images
        return 0
    fi

    if ! command -v "$CONTAINER_RUNTIME" &> /dev/null; then
        error "Runtime not found: $CONTAINER_RUNTIME"
        return 1
    fi

    if ! runtime_exec info > /dev/null 2>&1; then
        error "Runtime not available: $CONTAINER_RUNTIME"
        return 1
    fi

    ok "$CONTAINER_RUNTIME is available and running successfully"
    echo ""

    if $PULL_MATRIX; then
        if ! pull_image_matrix "$TARGET_IMAGE" "$TARGET_BASE_OS" "$TARGET_FLAVOR"; then
            pull_status=1
        fi
        if [ -n "$TARGET_IMAGE" ]; then
            verify_targets=($(get_dhi_variants "$TARGET_IMAGE"))
        elif [ -n "$TARGET_BASE_OS" ]; then
            verify_targets=($(get_dhi_images_for_os "$TARGET_BASE_OS" "$TARGET_FLAVOR"))
        else
            for image in "${IMAGE_NAMES[@]}"; do
                for base_os in "${BASE_OS_VARIANTS[@]}"; do
                    for flavor in "${DHI_FLAVORS[@]}"; do
                        verify_targets+=($(get_dhi_image_tag "$image" "$base_os" "$flavor"))
                    done
                done
            done
        fi
    elif $PULL_PRIMARY && $PULL_DHI; then
        if ! pull_group "Pulling Primary (Latest) Targets" "${PRIMARY_IMAGES[@]}"; then
            pull_status=1
        fi
        echo ""
        if ! pull_group "Pulling Helper/Disposable Images" "${HELPER_IMAGES[@]}"; then
            pull_status=1
        fi
        echo ""
        if ! pull_group "Pulling Docker Hardened Images" "${DHI_IMAGES[@]}"; then
            pull_status=1
        fi
        verify_targets=("${PRIMARY_IMAGES[@]}" "${HELPER_IMAGES[@]}" "${DHI_IMAGES[@]}")
    elif $PULL_PRIMARY; then
        if ! pull_group "Pulling Primary (Latest) Targets" "${PRIMARY_IMAGES[@]}"; then
            pull_status=1
        fi
        echo ""
        if ! pull_group "Pulling Helper/Disposable Images" "${HELPER_IMAGES[@]}"; then
            pull_status=1
        fi
        verify_targets=("${PRIMARY_IMAGES[@]}" "${HELPER_IMAGES[@]}")
    elif $PULL_DHI; then
        if ! pull_group "Pulling Docker Hardened Images" "${DHI_IMAGES[@]}"; then
            pull_status=1
        fi
        verify_targets=("${DHI_IMAGES[@]}")
    else
        if ! pull_group "1. Primary Targets (Latest)" "${PRIMARY_IMAGES[@]}"; then
            pull_status=1
        fi
        echo ""
        if ! pull_group "1b. Helper/Disposable Images" "${HELPER_IMAGES[@]}"; then
            pull_status=1
        fi
        echo ""
        if ! pull_group "2. Docker Hardened Images" "${DHI_IMAGES[@]}"; then
            pull_status=1
        fi
        verify_targets=("${PRIMARY_IMAGES[@]}" "${HELPER_IMAGES[@]}" "${DHI_IMAGES[@]}")
    fi

    list_all_images
    if ! verify_images "${verify_targets[@]}"; then
        pull_status=1
    fi

    echo ""
    echo "---"
    echo "Image pull complete"
    echo "---"

    [ "$pull_status" -eq 0 ] || return 1
}

if [ "${BASH_SOURCE[0]}" == "$0" ]; then
    pull_images_main "$@"
fi
