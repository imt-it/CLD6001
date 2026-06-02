#!/bin/bash

set -Eeuo pipefail

DIGEST_VERIFICATION_ENABLED="${DIGEST_VERIFICATION_ENABLED:-true}"
IMAGE_PLATFORM="${IMAGE_PLATFORM:-linux/amd64}"

declare -A DOCKER_OFFICIAL_REGISTRY=(
    ["nginx:alpine"]="nginx:1.31.0-alpine3.23@sha256:30cfeaf0e07664347dea89f3c11911f817a0df1751d7f2b97fe55fa9cb03a2ee"
    ["nginx:debian"]="nginx:1.31.0-trixie@sha256:966242c15165ecae32475055025be129210d5a035e44d198419885fc3a863775"

    ["python:alpine"]="python:3.14.5-alpine3.23@sha256:1aba322febb2d47185eb4db4934a1d7ce942cf3a469be8908dbce95aa513419b"
    ["python:debian"]="python:3.14.5-trixie@sha256:ef1933f1bbef1a07683cea9dae6b7ba16ea45c12ab7234da63906f4df3f818b7"

    ["nodejs:alpine"]="node:24.16.0-alpine3.23@sha256:9a2c6269f83d74af45665c0b738b78c7b5f07bf2374c72a4c540065a975b9693"
    ["nodejs:debian"]="node:24.16.0-trixie@sha256:72fedf7501f23eab94f6871d67d8a471366e1128159582847d849cccb78f84df"

    ["postgres:alpine"]="postgres:18.4-alpine3.23@sha256:15b46a9c5a6b361eb4c0ce8d689365bf49fbf6802e615dce4e5e2326b3213e15"
    ["postgres:debian"]="postgres:18.4-trixie@sha256:41da01536bc3ae26308cefb0c57235e7488001360bdb15191eb0b7955b570299"
)

declare -A DOCKER_OFFICIAL_DIGESTS=(
)

declare -A DHI_REGISTRY=(
    ["nginx:alpine:production"]="dhi.io/nginx:1.31.0-alpine3.23@sha256:0d6d5f188a9873c0bec8d5b9d9ae3b6b50fc87c821dd4598b919bd539d39ab43"
    ["nginx:debian:production"]="dhi.io/nginx:1.31.0-debian13@sha256:8ea8fa750b27cd713516d75b41304e0060bd8ae2f7c3b7f08284b16968a0113d"
    ["nginx:alpine:development"]="dhi.io/nginx:1.31.0-alpine3.23-dev@sha256:978fec89166de657214869d01617dee5e5c6a5dfd71ee549ee0b662ad9e05b19"
    ["nginx:debian:development"]="dhi.io/nginx:1.31.0-debian13-dev@sha256:c8911952140fd10221604f749b775a454296d661df3742b7b389c217b060213b"

    ["python:alpine:production"]="dhi.io/python:3.14.5-alpine3.23@sha256:263eff340d66dc716725091a68c2b0c42dece20202444b46db12bc30ba6e4a70"
    ["python:debian:production"]="dhi.io/python:3.14.5-debian13@sha256:da6336280bd28ee98a2980a2f211b99acaf42cb08ec8aa04f70bbdb05e67bd35"
    ["python:alpine:development"]="dhi.io/python:3.14.5-alpine3.23-dev@sha256:99298a132edef75ffbac3943eabea7419a0d576bb70981f83e274a2374aad461"
    ["python:debian:development"]="dhi.io/python:3.14.5-debian13-dev@sha256:2dc7e52de6de02eb0a6c141a4f96fa0c4e7ea850a6bbe5998b5f202389b4441e"

    ["nodejs:alpine:production"]="dhi.io/node:24.16.0-alpine3.23@sha256:9028ab2d131fc007888d60a432dc5f4479b82529e19c266cc563edf7578c4a37"
    ["nodejs:debian:production"]="dhi.io/node:24.16.0-debian13@sha256:a09cefdc310d4df75a42fe8ac21f95c1a6ff2505f61b8ecf5caef00ce9a793c4"
    ["nodejs:alpine:development"]="dhi.io/node:24.16.0-alpine3.23-dev@sha256:264599c62f8e173d57d4b267deb88596f42f078dbc4a8f3570e82d266c14c593"
    ["nodejs:debian:development"]="dhi.io/node:24.16.0-debian13-dev@sha256:201a0aba57d1863f8b444b173e5294d3bd6dea81e97031dd32b9a54564d0d676"

    ["postgres:alpine:production"]="dhi.io/postgres:18.4-alpine3.23@sha256:e87dfbac589c8542f8a460dab1c77c131bdb2edc96060912a1244f4517b28c48"
    ["postgres:debian:production"]="dhi.io/postgres:18.4-debian13@sha256:5f2e795057375a9bbb83e9ebeffb92f147c8055c522bdd8674bd68dd0efe6511"
    ["postgres:alpine:development"]="dhi.io/postgres:18.4-alpine3.23-dev@sha256:f4d91025b8d7adb4fb86cccdef6ff249f9f743f2bfd01fa8e5b352f88c37a6ee"
    ["postgres:debian:development"]="dhi.io/postgres:18.4-debian13-dev@sha256:e57529ef883a6ad096308feeb6ef89c1ca2cb94e352a7a7340762a65bf9740a3"
)

declare -A DHI_DIGESTS=(
)

IMAGE_NAMES=(
    "nodejs"
)
BASE_OS_VARIANTS=("alpine" "debian")
DHI_FLAVORS=("production" "development")

image_registry_repo_name() {
    case "$1" in
        nodejs)
            printf '%s\n' 'node'
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

get_image_platform() {
    printf '%s\n' "$IMAGE_PLATFORM"
}

image_registry_full_references() {
    local registry_name="$1"
    local -n registry_ref="$registry_name"
    local key=""

    for key in "${!registry_ref[@]}"; do
        [ -n "${registry_ref[$key]:-}" ] && printf '%s\n' "${registry_ref[$key]}"
    done
}

image_registry_reference_by_key() {
    local registry_name="$1"
    local key="$2"
    local -n registry_ref="$registry_name"

    [ -n "${registry_ref[$key]:-}" ] || return 1
    printf '%s\n' "${registry_ref[$key]}"
}

image_registry_tag_from_reference() {
    printf '%s\n' "${1%@*}"
}

image_registry_digest_from_reference() {
    local reference="$1"

    case "$reference" in
        *@*)
            ;;
        *)
            return 1
            ;;
    esac
    printf '%s\n' "${reference#*@}"
}

image_registry_matches_base_os() {
    local reference="$1"
    local base_os="$2"

    case "$base_os" in
        alpine)
            case "$reference" in
                *alpine*) return 0 ;;
            esac
            ;;
        debian)
            case "$reference" in
                *debian*|*bookworm*|*bullseye*|*buster*|*jessie*|*trixie*|*stable*) return 0 ;;
            esac
            ;;
        *)
            case "$reference" in
                *"$base_os"*) return 0 ;;
            esac
            ;;
    esac

    return 1
}

image_registry_matches_dhi_flavor() {
    local reference="$1"
    local flavor="${2:-production}"

    case "$flavor" in
        production)
            case "$reference" in
                *-dev|*-dev@*) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        development)
            case "$reference" in
                *-dev|*-dev@*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

find_docker_official_reference() {
    local image_name="$1"
    local base_os="$2"
    local key="${image_name}:${base_os}"

    if image_registry_reference_by_key DOCKER_OFFICIAL_REGISTRY "$key"; then
        return 0
    fi

    echo "ERROR: No Docker Official Image found for ${image_name}:${base_os}" >&2
    return 1
}

find_dhi_reference() {
    local image_name="$1"
    local base_os="$2"
    local flavor="${3:-production}"
    local key="${image_name}:${base_os}:${flavor}"

    if image_registry_reference_by_key DHI_REGISTRY "$key"; then
        return 0
    fi

    echo "ERROR: No DHI image found for ${image_name}:${base_os}:${flavor}" >&2
    return 1
}

get_registry_digest_by_image_tag() {
    local image_tag="$1"
    local reference=""

    while IFS= read -r reference; do
        [ "$(image_registry_tag_from_reference "$reference")" = "$image_tag" ] || continue
        image_registry_digest_from_reference "$reference"
        return 0
    done < <(
        image_registry_full_references DOCKER_OFFICIAL_REGISTRY
        image_registry_full_references DHI_REGISTRY
    )

    return 1
}

get_docker_official_image_tag() {
    local image_name="$1"
    local base_os="$2"
    local reference=""

    reference="$(find_docker_official_reference "$image_name" "$base_os")" || return 1
    image_registry_tag_from_reference "$reference"
}

get_dhi_image_tag() {
    local image_name="$1"
    local base_os="$2"
    local flavor="${3:-production}"
    local reference=""

    reference="$(find_dhi_reference "$image_name" "$base_os" "$flavor")" || return 1
    image_registry_tag_from_reference "$reference"
}

list_all_images() {
    echo "Image Registry:"
    echo "---"
    echo ""
    echo "Docker Official Images:"
    echo "------------------------"
    for image in "${IMAGE_NAMES[@]}"; do
        echo ""
        echo "${image}:"
        for base_os in "${BASE_OS_VARIANTS[@]}"; do
            local tag
            tag="$(get_docker_official_image_tag "$image" "$base_os")"
            echo "${base_os}: ${tag}"
        done
    done

    echo ""
    echo "Docker Hardened Images (DHI):"
    echo "------------------------------"
    for image in "${IMAGE_NAMES[@]}"; do
        echo ""
        echo "${image}:"
        for base_os in "${BASE_OS_VARIANTS[@]}"; do
            for flavor in "${DHI_FLAVORS[@]}"; do
                local tag
                tag="$(get_dhi_image_tag "$image" "$base_os" "$flavor")"
                echo "${base_os}:${flavor}: ${tag}"
            done
        done
    done
}

get_docker_official_variants() {
    local image_name="$1"
    local tags=()

    for base_os in "${BASE_OS_VARIANTS[@]}"; do
        local tag
        tag="$(get_docker_official_image_tag "$image_name" "$base_os")"
        tags+=("$tag")
    done

    echo "${tags[@]}"
}

get_dhi_variants() {
    local image_name="$1"
    local tags=()

    for base_os in "${BASE_OS_VARIANTS[@]}"; do
        for flavor in "${DHI_FLAVORS[@]}"; do
            local tag
            tag="$(get_dhi_image_tag "$image_name" "$base_os" "$flavor")"
            tags+=("$tag")
        done
    done

    echo "${tags[@]}"
}

get_docker_official_images_for_os() {
    local base_os="$1"
    local tags=()

    for image in "${IMAGE_NAMES[@]}"; do
        local tag
        tag="$(get_docker_official_image_tag "$image" "$base_os")"
        tags+=("$tag")
    done

    echo "${tags[@]}"
}

get_dhi_images_for_os() {
    local base_os="$1"
    local flavor="${2:-production}"
    local tags=()

    for image in "${IMAGE_NAMES[@]}"; do
        local tag
        tag="$(get_dhi_image_tag "$image" "$base_os" "$flavor")"
        tags+=("$tag")
    done

    echo "${tags[@]}"
}

get_total_image_count() {
    echo $(( ${#IMAGE_NAMES[@]} * ${#BASE_OS_VARIANTS[@]} ))
}

get_total_dhi_image_count() {
    echo $(( ${#IMAGE_NAMES[@]} * ${#BASE_OS_VARIANTS[@]} * ${#DHI_FLAVORS[@]} ))
}

get_docker_official_digest() {
    local image_name="$1"
    local base_os="$2"
    local key="${image_name}:${base_os}"

    if [ -n "${DOCKER_OFFICIAL_DIGESTS[$key]:-}" ]; then
        echo "${DOCKER_OFFICIAL_DIGESTS[$key]}"
        return 0
    fi

    image_registry_digest_from_reference "$(find_docker_official_reference "$image_name" "$base_os")" && return 0

    return 1
}

get_dhi_digest() {
    local image_name="$1"
    local base_os="$2"
    local flavor="${3:-production}"
    local key="${image_name}:${base_os}:${flavor}"

    if [ -n "${DHI_DIGESTS[$key]:-}" ]; then
        echo "${DHI_DIGESTS[$key]}"
        return 0
    fi

    image_registry_digest_from_reference "$(find_dhi_reference "$image_name" "$base_os" "$flavor")" && return 0

    return 1
}

build_image_reference() {
    local image_tag="$1"
    local digest="${2:-}"

    if [ -n "$digest" ]; then
        echo "${image_tag}@${digest}"
    else
        echo "$image_tag"
    fi
}

verify_image_digest() {
    local image_tag="$1"
    local expected_digest="$2"
    local runtime="${3:-docker}"

    local actual_digest
    actual_digest=$($runtime inspect --format='{{index .RepoDigests 0}}' "$image_tag" 2>/dev/null | cut -d'@' -f2)

    if [ "$actual_digest" = "$expected_digest" ]; then
        return 0
    fi

    echo "Digest mismatch for $image_tag" >&2
    echo "Expected: $expected_digest" >&2
    echo "Actual:   $actual_digest" >&2
    return 1
}

is_digest_verification_enabled() {
    [ "$DIGEST_VERIFICATION_ENABLED" = "true" ]
}
