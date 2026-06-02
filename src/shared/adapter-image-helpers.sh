#!/bin/bash

cld6001_ensure_image() {
    local engine="${1:?engine required}"
    local image="${2:?image required}"
    if ! "$engine" image inspect "$image" > /dev/null 2>&1; then
        info "Image not available locally. Attempting to pull: $image"
        if ! "$engine" pull "$image"; then
            error "Image not available: $image"
            return 1
        fi
    fi
}

cld6001_ensure_images() {
    local engine="${1:?engine required}"
    shift
    local image=""

    for image in "$@"; do
        cld6001_ensure_image "$engine" "$image" || return 1
    done
}
