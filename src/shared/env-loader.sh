#!/bin/bash

safe_source_env() {
    local env_file="$1"
    local line=""
    local line_number=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))

        if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
            printf '[WARN] Ignoring unsafe %s line %d: invalid assignment format\n' "$env_file" "$line_number" >&2
            continue
        fi

        if [[ "$line" == *'$('* || "$line" == *'`'* || "$line" == *';'* || "$line" == *'|'* || "$line" == *'<'* || "$line" == *'>'* ]]; then
            printf '[WARN] Ignoring unsafe %s line %d: forbidden shell metacharacters\n' "$env_file" "$line_number" >&2
            continue
        fi

        export "$line"
    done < "$env_file"
}
