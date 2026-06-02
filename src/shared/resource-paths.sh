#!/bin/bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

cld6001_resource_root() {
    printf '%s/resources\n' "$REPO_ROOT"
}

cld6001_images_resource_dir() {
    printf '%s/images\n' "$(cld6001_resource_root)"
}

cld6001_podman_policy_dir() {
    printf '%s/policies/podman\n' "$(cld6001_resource_root)"
}

cld6001_custom_hardened_dockerfile() {
    printf '%s/Dockerfile.custom-hardened\n' "$(cld6001_images_resource_dir)"
}

cld6001_podman_containers_template() {
    printf '%s/containers.conf\n' "$(cld6001_podman_policy_dir)"
}

cld6001_podman_registries_template() {
    printf '%s/registries.conf\n' "$(cld6001_podman_policy_dir)"
}

cld6001_podman_storage_template() {
    printf '%s/storage.conf\n' "$(cld6001_podman_policy_dir)"
}

cld6001_exploits_dir() {
    printf '%s/exploits\n' "$(cld6001_resource_root)"
}

cld6001_fixtures_dir() {
    printf '%s/fixtures\n' "$(cld6001_resource_root)"
}

cld6001_selinux_install_script() {
    printf '%s/templates/selinux-install.sh\n' "$(cld6001_resource_root)"
}
