#!/bin/bash

if [ -n "${RUNTIME_SMOKE_TEST_HELPERS_LOADED:-}" ]; then
    return 0
fi
readonly RUNTIME_SMOKE_TEST_HELPERS_LOADED=1

cld6001_runtime_smoke_test_image() {
    printf '%s\n' 'hello-world'
}

cld6001_run_runtime_smoke_test() {
    local runtime_bin="${1:-}"
    local smoke_image=""

    if [ -z "${runtime_bin}" ]; then
        printf 'Runtime smoke-test executable is required\n' >&2
        return 1
    fi

    smoke_image="$(cld6001_runtime_smoke_test_image)"
    "${runtime_bin}" run --rm "${smoke_image}"
}

cld6001_runtime_smoke_test_shell_command() {
    local runtime_bin="${1:-}"
    local smoke_image=""

    if [ -z "${runtime_bin}" ]; then
        printf 'Runtime smoke-test executable is required\n' >&2
        return 1
    fi

    smoke_image="$(cld6001_runtime_smoke_test_image)"
    printf '%q run --rm %q' "${runtime_bin}" "${smoke_image}"
}
