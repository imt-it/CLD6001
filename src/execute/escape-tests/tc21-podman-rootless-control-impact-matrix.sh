#!/bin/bash
set -Eeuo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
exec "$REPO_ROOT/src/test-cases/tc21-control-impact-matrix/run.sh" podman-rootless "$@"
