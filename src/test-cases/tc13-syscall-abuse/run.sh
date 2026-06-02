#!/bin/bash
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$(cd -- "$SCRIPT_DIR/../../shared" && pwd -P)/tc-run-dispatcher.sh"
