#!/bin/bash
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/shared/output-layout.sh"

cld6001_ensure_temp_work_link() {
    local target_root=""
    local link_path=""

    [ "$(uname -s)" = "Linux" ] || return 0

    target_root="$(cld6001_linux_temp_root)"
    link_path="$(cld6001_repo_temp_link)"

    mkdir -p "$target_root"

    if [ -L "$link_path" ] && [ "$(readlink "$link_path")" = "$target_root" ]; then
        return 0
    fi

    if [ -e "$link_path" ] && [ ! -L "$link_path" ]; then
        printf 'ERROR: repo temp-work path exists and is not a symlink: %s\n' "$link_path" >&2
        return 1
    fi

    ln -sfn "$target_root" "$link_path"
}
