#!/bin/bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CLD6001_POLICY_ROOT="$REPO_ROOT/resources/policies"
export CLD6001_POLICY_ROOT
