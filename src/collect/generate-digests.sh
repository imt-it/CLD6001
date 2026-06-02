#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/../../src/execute/image-registry.sh"

PLATFORM="${IMAGE_PLATFORM:-linux/amd64}"
RUNTIME="${CONTAINER_RUNTIME:-docker}"

resolve_manifest_digest() {
    local image_tag="$1"
    local manifest_payload=""
    local digest=""

    manifest_payload="$("$RUNTIME" manifest inspect --platform "$PLATFORM" "$image_tag")"
    digest="$(printf '%s\n' "$manifest_payload" | jq -r '.digest')"

    case "$digest" in
        sha256:*)
            printf '%s\n' "$digest"
            ;;
        *)
            printf 'missing digest for %s\n' "$image_tag" >&2
            return 1
            ;;
    esac
}

while [ $# -gt 0 ]; do
    case $1 in
        --platform)
            PLATFORM="$2"
            shift
            ;;
        --runtime)
            RUNTIME="$2"
            shift
            ;;
        *)
            echo "Usage: bash generate-digests.sh [--platform linux/amd64] [--runtime docker]"
            exit 1
            ;;
    esac
    shift
done

echo "---"
echo "Image Digest Generator"
echo "---"
echo "Platform: $PLATFORM"
echo "Runtime: $RUNTIME"
echo "---"
echo ""

echo "# Docker Official Images Digests"
echo "declare -A DOCKER_OFFICIAL_DIGESTS=("
tag=""
digest=""
for image in "${IMAGE_NAMES[@]}"; do
    for base_os in "${BASE_OS_VARIANTS[@]}"; do
        tag="$(get_docker_official_image_tag "$image" "$base_os")"
        digest="$(resolve_manifest_digest "$tag")"
        printf '    "%s:%s"="%s"\n' "$image" "$base_os" "$digest"
    done
done
echo ")"
echo ""

echo "# Docker Hardened Images Digests"
echo "declare -A DHI_DIGESTS=("
for image in "${IMAGE_NAMES[@]}"; do
    for base_os in "${BASE_OS_VARIANTS[@]}"; do
        for flavor in "${DHI_FLAVORS[@]}"; do
            tag="$(get_dhi_image_tag "$image" "$base_os" "$flavor")"
            digest="$(resolve_manifest_digest "$tag")"
            printf '    "%s:%s:%s"="%s"\n' "$image" "$base_os" "$flavor" "$digest"
        done
    done
done
echo ")"

echo ""
echo "---"
echo "Digest generation complete"
echo "---"
echo ""
echo "IMPORTANT: Verify all digests before use!"
echo "Copy the generated digests to src/execute/image-registry.sh"
