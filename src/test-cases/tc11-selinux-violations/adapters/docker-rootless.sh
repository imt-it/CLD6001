#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"

echo "--- TC11: SELinux Policy Violations ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: docker-rootless"
echo ""

if ! command -v getenforce >/dev/null 2>&1; then
    cld6001_block "selinux_tooling_unavailable" "SELinux tooling (getenforce) is not available on the host"
fi

SELINUX_MODE="$(getenforce)"
echo "Host SELinux mode: ${SELINUX_MODE}"

if [ "$SELINUX_MODE" = "Disabled" ]; then
    cld6001_block "selinux_disabled" "SELinux is disabled on the host"
fi

echo "docker-rootless SELinux violation comparison: NON-COMPARABLE"
cld6001_block \
    "selinux_non_comparable_rootless" \
    "Rootless Docker cannot provide a methodology-equivalent TC11 SELinux permissive-versus-enforcing comparison on this host"
