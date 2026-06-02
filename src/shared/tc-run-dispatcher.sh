#!/bin/bash
set -Eeuo pipefail
runtime="${1:?runtime required}"
case "$runtime" in
    docker-rootful|docker-rootless|podman-rootless) ;;
    *)
        printf 'Unsupported runtime: %s\n' "$runtime" >&2
        return 1
        ;;
esac
exec "$SCRIPT_DIR/adapters/${runtime}.sh" "${@:2}"
