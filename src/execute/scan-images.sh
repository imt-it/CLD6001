#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${REPO_ROOT}/src/execute/run-context.sh"
source "${SCRIPT_DIR}/image-registry.sh"

COLLECTION="${1:?Usage: scan-images.sh <collection_letter> [--runtime docker|podman]}"
shift
RUNTIME="docker"

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime)
      RUNTIME="${2:?Usage: scan-images.sh <collection_letter> [--runtime docker|podman]}"
      shift 2
      ;;
    *)
      echo "Usage: bash scan-images.sh <collection_letter> [--runtime docker|podman]"
      exit 1
      ;;
  esac
done

STANDARD_IMAGES=()
for image_name in "${IMAGE_NAMES[@]}"; do
  read -r -a variants <<< "$(get_docker_official_variants "$image_name")"
  STANDARD_IMAGES+=("${variants[@]}")
done

DHI_IMAGES=()
for image_name in "${IMAGE_NAMES[@]}"; do
  read -r -a variants <<< "$(get_dhi_variants "$image_name")"
  DHI_IMAGES+=("${variants[@]}")
done

CUSTOM_IMAGES=()

mkdir -p results/collection-$COLLECTION/trivy-results
mkdir -p results/collection-$COLLECTION/dockle-results

echo "--- Image Scanning Automation ---"
echo "Phase: $COLLECTION"
echo "Runtime: $RUNTIME"
echo "Date: $(date -Iseconds)"
echo ""

runtime_exec() {
  "$RUNTIME" "$@"
}

scan_with_trivy() {
  local image="$1"
  local variant="$2"
  local timestamp=""
  local output_file=""
  local log_file=""

  timestamp="$(cld6001_generate_timestamped_id "%Y%m%d-%H%M%S" "-")"
  output_file="results/collection-$COLLECTION/trivy-results/${variant}-${image//[:\/]/-}-trivy-$timestamp.json"
  log_file="results/collection-$COLLECTION/trivy-results/${variant}-${image//[:\/]/-}-trivy-$timestamp.log"

  runtime_exec image inspect "$image" > /dev/null 2>&1 || {
    echo "--- Skipping unavailable image $image (Trivy) ---"
    return 0
  }

  echo "--- Scanning $image (Trivy) ---"
  trivy image \
    --format json \
    --output "$output_file" \
    --severity HIGH,CRITICAL \
    "$image" 2>&1 | tee "$log_file"

  echo ""
}

scan_with_dockle() {
  local image="$1"
  local variant="$2"
  local timestamp=""
  local output_file=""
  local log_file=""

  timestamp="$(cld6001_generate_timestamped_id "%Y%m%d-%H%M%S" "-")"
  output_file="results/collection-$COLLECTION/dockle-results/${variant}-${image//[:\/]/-}-dockle-$timestamp.json"
  log_file="results/collection-$COLLECTION/dockle-results/${variant}-${image//[:\/]/-}-dockle-$timestamp.log"

  runtime_exec image inspect "$image" > /dev/null 2>&1 || {
    echo "--- Skipping unavailable image $image (Dockle) ---"
    return 0
  }

  echo "--- Scanning $image (Dockle) ---"
  dockle --format json \
    -o "$output_file" \
    "$image" 2>&1 | tee "$log_file"

  echo ""
}

record_image_sizes() {
  local timestamp=""
  local output_file=""
  local image=""

  timestamp="$(cld6001_generate_timestamped_id "%Y%m%d-%H%M%S" "-")"
  output_file="results/collection-$COLLECTION/image-sizes-$timestamp.txt"

  record_sizes_for_group() {
    local title="$1"
    shift

    echo "--- ${title} ---"
    for image in "$@"; do
      if runtime_exec image inspect "$image" > /dev/null 2>&1; then
        runtime_exec image ls --format "{{.Repository}}:{{.Tag}}\t{{.Size}}" "$image"
      else
        printf '%s\tUNAVAILABLE\n' "$image"
      fi
    done
    echo ""
  }

  echo "--- Recording Image Sizes ---"
  {
    echo "--- Image Sizes ---"
    echo "Date: $(date -Iseconds)"
    echo ""
    record_sizes_for_group "Standard Images" "${STANDARD_IMAGES[@]}"
    record_sizes_for_group "Docker Hardened Images" "${DHI_IMAGES[@]}"
    record_sizes_for_group "Custom Hardened Images" "${CUSTOM_IMAGES[@]}"
  } > "$output_file"

  echo "Image sizes recorded to $output_file"
  echo ""
}

echo "---"
echo "Phase $COLLECTION - Standard Images"
echo "---"
for image in "${STANDARD_IMAGES[@]}"; do
  scan_with_trivy "$image" "standard"
  scan_with_dockle "$image" "standard"
done

echo "---"
echo "Phase $COLLECTION - Docker Hardened Images"
echo "---"
for image in "${DHI_IMAGES[@]}"; do
  scan_with_trivy "$image" "dhi"
  scan_with_dockle "$image" "dhi"
done

echo "---"
echo "Phase $COLLECTION - Custom Hardened Images"
echo "---"
for image in "${CUSTOM_IMAGES[@]}"; do
  scan_with_trivy "$image" "custom"
  scan_with_dockle "$image" "custom"
done

record_image_sizes

echo "---"
echo "Scan Summary"
echo "---"
{
  echo "--- Scan Summary ---"
  echo "Date: $(date -Iseconds)"
  echo "Phase: $COLLECTION"
  echo "Runtime: $RUNTIME"
  echo ""
  echo "Standard images: ${#STANDARD_IMAGES[@]}"
  echo "DHI images: ${#DHI_IMAGES[@]}"
  echo "Custom images: ${#CUSTOM_IMAGES[@]}"
  echo ""
  echo "Trivy reports: $(find "results/collection-$COLLECTION/trivy-results" -maxdepth 1 -name '*.json' | wc -l)"
  echo "Dockle reports: $(find "results/collection-$COLLECTION/dockle-results" -maxdepth 1 -name '*.json' | wc -l)"
} | tee results/collection-$COLLECTION/scan-summary.txt

echo ""
echo "Scan automation complete"
