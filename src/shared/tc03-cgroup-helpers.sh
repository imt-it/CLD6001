#!/bin/bash

if [ -n "${TC03_CGROUP_HELPERS_LOADED:-}" ]; then
    return 0
fi
readonly TC03_CGROUP_HELPERS_LOADED=1

tc03_runtime_freezer_paths() {
    local runtime_id="$1"

    case "$runtime_id" in
        docker-rootful)
            cat <<'EOF'
/sys/fs/cgroup/system.slice/docker-*.scope/cgroup.freeze
EOF
            ;;
        docker-rootless)
            cat <<'EOF'
/sys/fs/cgroup/user.slice/user-*.slice/user@*.service/user.slice/docker-*.scope/cgroup.freeze
EOF
            ;;
        podman-rootless)
            cat <<'EOF'
/sys/fs/cgroup/user.slice/*/*/cgroup.freeze
/sys/fs/cgroup/user.slice/*/*/*/cgroup.freeze
/sys/fs/cgroup/user.slice/*/*/*/*/cgroup.freeze
EOF
            ;;
        *)
            printf 'Unsupported TC03 runtime: %s\n' "$runtime_id" >&2
            return 1
            ;;
    esac
}

tc03_cgroup_tree_fallback_message() {
    local runtime_id="$1"

    case "$runtime_id" in
        docker-rootful|docker-rootless)
            printf 'Cgroup access blocked\n'
            ;;
        podman-rootless)
            printf 'cgroup v2 root\n'
            ;;
        *)
            printf 'Unsupported TC03 runtime: %s\n' "$runtime_id" >&2
            return 1
            ;;
    esac
}

tc03_cgroup_hierarchy_probe_script() {
    cat <<'PROBE'
echo "=== TC03: Cgroup Hierarchy Escape Probe (inside container) ==="
echo "Own cgroupv2 path (from /proc/self/cgroup):"
OWN_CGROUP="$(grep '^0::' /proc/self/cgroup 2>/dev/null | cut -d: -f3)"
if [ -z "$OWN_CGROUP" ]; then
    echo "  BLOCKED: cgroupv2 unified path not found in /proc/self/cgroup"
else
    echo "  $OWN_CGROUP"
    echo "---"
    echo "Cgroup namespace isolation check:"
    OWN_CGROUPNS="$(readlink /proc/self/ns/cgroup 2>/dev/null)" || OWN_CGROUPNS="BLOCKED"
    HOST_CGROUPNS="$(readlink /proc/1/ns/cgroup 2>/dev/null)" || HOST_CGROUPNS="BLOCKED"
    echo "  own cgroup ns : $OWN_CGROUPNS"
    echo "  pid1 cgroup ns: $HOST_CGROUPNS"
    if [ "$HOST_CGROUPNS" = "BLOCKED" ] || [ "$OWN_CGROUPNS" = "BLOCKED" ]; then
        echo "  INFO: namespace comparison blocked"
    elif [ "$OWN_CGROUPNS" = "$HOST_CGROUPNS" ]; then
        echo "  BREACH-SIGNAL: container shares host cgroup namespace (no cgroupns isolation)"
    else
        echo "  BOUNDARY HELD: container has isolated cgroup namespace"
    fi
    echo "---"
    echo "Attempting parent cgroup directory traversal:"
    PARENT_CGROUP="$(dirname "$OWN_CGROUP")"
    PARENT_DIR="/sys/fs/cgroup${PARENT_CGROUP}"
    if [ -d "$PARENT_DIR" ] && [ "$PARENT_CGROUP" != "$OWN_CGROUP" ] && [ "$PARENT_CGROUP" != "/" ]; then
        echo "  BREACH-SIGNAL: parent cgroup dir visible: $PARENT_DIR"
        ls "$PARENT_DIR" 2>/dev/null | head -5 && echo "  BREACH: parent cgroup listing succeeded" || echo "  BOUNDARY HELD: parent cgroup listing blocked"
        if [ -f "$PARENT_DIR/memory.max" ]; then
            echo "  BREACH: parent memory.max readable: $(cat "$PARENT_DIR/memory.max" 2>/dev/null)"
        fi
        echo "  Attempting parent memory.max write (direct boundary-breach attempt):"
        echo max > "$PARENT_DIR/memory.max" 2>&1 \
            && echo "  BREACH: parent memory.max write succeeded - cgroup boundary escaped" \
            || echo "  BOUNDARY HELD: parent memory.max write blocked"
        echo "  Attempting parent pids.max write (direct boundary-breach attempt):"
        echo max > "$PARENT_DIR/pids.max" 2>&1 \
            && echo "  BREACH: parent pids.max write succeeded - cgroup boundary escaped" \
            || echo "  BOUNDARY HELD: parent pids.max write blocked"
    else
        echo "  BOUNDARY HELD: parent cgroup dir not visible from container ($PARENT_DIR)"
    fi
    echo "---"
    echo "Attempting grandparent cgroup directory traversal:"
    GRANDPARENT_CGROUP="$(dirname "$PARENT_CGROUP")"
    GRANDPARENT_DIR="/sys/fs/cgroup${GRANDPARENT_CGROUP}"
    if [ -d "$GRANDPARENT_DIR" ] && [ "$GRANDPARENT_CGROUP" != "$PARENT_CGROUP" ] && [ "$GRANDPARENT_CGROUP" != "/" ]; then
        echo "  BREACH-SIGNAL: grandparent cgroup dir visible: $GRANDPARENT_DIR"
        echo max > "$GRANDPARENT_DIR/memory.max" 2>&1 \
            && echo "  BREACH: grandparent memory.max write succeeded - escaped to ancestor cgroup" \
            || echo "  BOUNDARY HELD: grandparent memory.max write blocked"
    else
        echo "  BOUNDARY HELD: grandparent cgroup dir not visible ($GRANDPARENT_DIR)"
    fi
fi
echo "=== end hierarchy probe ==="
PROBE
}

tc03_freezer_probe_script() {
    local runtime_id="$1"
    local cgroup_fallback=""
    local freezer_paths=""
    local freezer_path=""
    local freezer_path_words=""

    cgroup_fallback="$(tc03_cgroup_tree_fallback_message "$runtime_id")" || return 1
    freezer_paths="$(tc03_runtime_freezer_paths "$runtime_id")" || return 1
    while IFS= read -r freezer_path; do
        [ -n "$freezer_path" ] || continue
        freezer_path_words="${freezer_path_words}${freezer_path_words:+ }${freezer_path}"
    done <<< "$freezer_paths"

    case "$runtime_id" in
        docker-rootful|docker-rootless)
            cat <<EOF
echo "=== TC03-3a: Cgroup Boundary Breach Probe (inside container) ==="
echo "Own cgroup identity (/proc/self/cgroup):"
cat /proc/self/cgroup 2>/dev/null || echo "BLOCKED: /proc/self/cgroup unreadable"
echo "---"
echo "Cgroup FS visibility:"
ls /sys/fs/cgroup/ 2>/dev/null | head -20 || echo "BLOCKED: /sys/fs/cgroup inaccessible"
echo "---"
echo "Attempting parent cgroup hierarchy traversal:"
ls /sys/fs/cgroup/../ 2>/dev/null && echo "BREACH: parent traversal succeeded" || echo "BOUNDARY HELD: parent traversal blocked"
echo "---"
echo "Attempting to exceed limits via cgroup FS writes (cgroupv2):"
echo max > /sys/fs/cgroup/memory.max 2>&1 && echo "BREACH: memory.max write succeeded" || echo "BOUNDARY HELD: memory.max write blocked"
echo "max 100000" > /sys/fs/cgroup/cpu.max 2>&1 && echo "BREACH: cpu.max write succeeded" || echo "BOUNDARY HELD: cpu.max write blocked"
echo max > /sys/fs/cgroup/pids.max 2>&1 && echo "BREACH: pids.max write succeeded" || echo "BOUNDARY HELD: pids.max write blocked"
echo "---"
echo "Attempting cgroup.freeze self-manipulation (cgroupv2):"
echo "0" > /sys/fs/cgroup/cgroup.freeze 2>&1 && echo "BREACH: cgroup.freeze write succeeded" || echo "BOUNDARY HELD: cgroup.freeze write blocked"
echo "---"
echo "Container cgroups:"
cat /proc/self/cgroup 2>/dev/null || echo "${cgroup_fallback}"
echo "---"
echo "Attempting cgroup escape..."
for f in ${freezer_path_words}; do
    if [ -f "\$f" ]; then
        echo "Freezer found, attempting manipulation"
        echo "0" > "\$f" 2>&1
    fi
done
EOF
            ;;
        podman-rootless)
            cat <<EOF
echo "=== TC03-3a: Cgroup Boundary Breach Probe (inside container) ==="
echo "Own cgroup identity (/proc/self/cgroup):"
cat /proc/self/cgroup 2>/dev/null || echo "BLOCKED: /proc/self/cgroup unreadable"
echo "---"
echo "Cgroup FS visibility:"
ls /sys/fs/cgroup/ 2>/dev/null | head -20 || echo "BLOCKED: /sys/fs/cgroup inaccessible"
echo "---"
echo "Attempting parent cgroup hierarchy traversal:"
ls /sys/fs/cgroup/../ 2>/dev/null && echo "BREACH: parent traversal succeeded" || echo "BOUNDARY HELD: parent traversal blocked"
echo "---"
echo "Attempting to exceed limits via cgroup FS writes (cgroupv2 user delegation):"
echo max > /sys/fs/cgroup/memory.max 2>&1 && echo "BREACH: memory.max write succeeded" || echo "BOUNDARY HELD: memory.max write blocked"
echo "max 100000" > /sys/fs/cgroup/cpu.max 2>&1 && echo "BREACH: cpu.max write succeeded" || echo "BOUNDARY HELD: cpu.max write blocked"
echo max > /sys/fs/cgroup/pids.max 2>&1 && echo "BREACH: pids.max write succeeded" || echo "BOUNDARY HELD: pids.max write blocked"
echo "---"
echo "Attempting cgroup.freeze self-manipulation (cgroupv2):"
echo "0" > /sys/fs/cgroup/cgroup.freeze 2>&1 && echo "BREACH: cgroup.freeze write succeeded" || echo "BOUNDARY HELD: cgroup.freeze write blocked"
echo "---"
echo "Container cgroups:"
cat /proc/self/cgroup 2>/dev/null || echo "${cgroup_fallback}"
echo "---"
echo "Attempting cgroup escape..."
for f in ${freezer_path_words}; do
    if [ -f "\$f" ]; then
        echo "Freezer found dynamically: \$f"
        echo "0" > "\$f" 2>&1 || echo "Dynamic freezer bypass blocked"
    fi
done
EOF
            ;;
        *)
            printf 'Unsupported TC03 runtime: %s\n' "$runtime_id" >&2
            return 1
            ;;
    esac
}
