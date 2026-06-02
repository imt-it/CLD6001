#!/bin/bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
exec "$REPO_ROOT/src/test-cases/tc05-standard-image-assessment/run.sh" docker-rootful "$@"
