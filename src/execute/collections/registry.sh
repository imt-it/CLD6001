#!/bin/bash
set -Eeuo pipefail

COLLECTION_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

cld6001_collection_count() {
    printf '8\n'
}

cld6001_collections() {
    printf '%s\n' \
        collection-a-boundary-foundation \
        collection-b-image-supply-chain \
        collection-c-capability-and-namespace-controls \
        collection-d-selinux-controls \
        collection-e-seccomp-and-syscall-controls \
        collection-f-combined-control-exploration \
        collection-g-page-cache-attack-family \
        collection-h-post-hardening-validations
}

cld6001_collection_name() {
    case "$1" in
        a|collection-a-boundary-foundation) printf 'collection-a-boundary-foundation\n' ;;
        b|collection-b-image-supply-chain) printf 'collection-b-image-supply-chain\n' ;;
        c|collection-c-capability-and-namespace-controls) printf 'collection-c-capability-and-namespace-controls\n' ;;
        d|collection-d-selinux-controls) printf 'collection-d-selinux-controls\n' ;;
        e|collection-e-seccomp-and-syscall-controls) printf 'collection-e-seccomp-and-syscall-controls\n' ;;
        f|collection-f-combined-control-exploration) printf 'collection-f-combined-control-exploration\n' ;;
        g|collection-g-page-cache-attack-family) printf 'collection-g-page-cache-attack-family\n' ;;
        h|collection-h-post-hardening-validations) printf 'collection-h-post-hardening-validations\n' ;;
        *)
            return 1
            ;;
    esac
}

cld6001_collection_manifest_path() {
    local collection_name
    collection_name="$(cld6001_collection_name "$1")" || return 1
    printf '%s/%s.sh\n' "$COLLECTION_DIR" "$collection_name"
}

cld6001_collection_manifest() {
    local collection="$1"
    local manifest_path
    manifest_path="$(cld6001_collection_manifest_path "$collection")"
    [ -f "$manifest_path" ] || return 1
    bash "$manifest_path"
}

cld6001_export_only_targeted_testcase_slug() {
    case "$1" in
        tc21|tc21-control-impact-matrix)
            printf 'tc21-control-impact-matrix\n'
            ;;
        *)
            return 1
            ;;
    esac
}

cld6001_export_only_targeted_testcase_collection() {
    case "$1" in
        tc21|tc21-control-impact-matrix)
            printf 'h\n'
            ;;
        *)
            return 1
            ;;
    esac
}

cld6001_testcase_exists() {
    local tc="$1"
    local collection

    cld6001_export_only_targeted_testcase_slug "$tc" >/dev/null 2>&1 && return 0

    for collection in a b c d e f g h; do
        if cld6001_collection_manifest "$collection" | grep -qF "$tc"; then
            return 0
        fi
    done
    return 1
}

cld6001_collection_for_testcase() {
    local tc="$1"
    local collection

    if collection="$(cld6001_export_only_targeted_testcase_collection "$tc" 2>/dev/null)"; then
        printf '%s\n' "$collection"
        return 0
    fi

    for collection in a b c d e f g h; do
        if cld6001_collection_manifest "$collection" | grep -qF "$tc"; then
            printf '%s\n' "$collection"
            return 0
        fi
    done
    return 1
}

cld6001_testcases_for_collection() {
    local collection="$1"
    local state="${2:-}"
    if [ -n "$state" ]; then
        cld6001_collection_manifest "$collection" | awk -F'|' -v s="$state" '$2==s {split($3,a," "); print a[2]}'
    else
        cld6001_collection_manifest "$collection" | awk -F'|' '{split($3,a," "); print a[2]}' | sort -u
    fi
}

cld6001_testcase_slug() {
    local tc="$1"

    if cld6001_export_only_targeted_testcase_slug "$tc" 2>/dev/null; then
        return 0
    fi

    case "$tc" in
        tc[0-9]*-*) printf '%s\n' "$tc"; return 0 ;;
        tc[0-9]*)
            local collection
            for collection in a b c d e f g h; do
                local slug
                slug="$(cld6001_collection_manifest "$collection" | grep -oP "(?<=cld6001_run_testcase )(${tc}-[^ ]+)" | head -1)"
                if [ -n "$slug" ]; then
                    printf '%s\n' "$slug"
                    return 0
                fi
            done
            ;;
    esac
    return 1
}
