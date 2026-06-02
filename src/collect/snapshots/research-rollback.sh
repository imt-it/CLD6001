#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/snapshot-lib.sh"

print_usage() {
    echo "Usage: $0 {list|rollback [snapshot-name]}"
    echo ""
    echo "Commands:"
    echo "list          List available snapshots"
    echo "rollback <name> Rollback to specified snapshot"
    echo "rollback      Rollback to latest snapshot"
}

list_snapshots() {
    snapshot_info "Available snapshots"

    local listed=false
    local snapshot_name
    while IFS= read -r snapshot_name; do
        listed=true
        echo "$snapshot_name"
    done < <(list_snapshot_directories)

    if [ "$listed" = false ]; then
        snapshot_warn "No snapshots found"
    fi
}

rollback() {
    local requested_name="${1:-}"
    local snapshot_path

    snapshot_path="$(resolve_snapshot_path "$requested_name")" || {
        snapshot_error "No restorable snapshots found"
        exit 1
    }

    local snapshot_name
    snapshot_name="$(basename -- "$snapshot_path")"

    snapshot_info "Rolling back to: $snapshot_name..."
    restore_snapshot_path "$snapshot_path"
    snapshot_success "Rollback completed: $snapshot_name successfully"
}

case "${1:-}" in
    list)
        list_snapshots
        ;;
    rollback)
        rollback "${2:-}"
        ;;
    *)
        print_usage
        ;;
esac
