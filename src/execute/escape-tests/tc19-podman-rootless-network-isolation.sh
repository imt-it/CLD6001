#!/bin/bash
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
exec "$REPO_ROOT/src/test-cases/tc19-network-isolation/run.sh" podman-rootless "$@"
