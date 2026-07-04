#!/bin/bash
# Claude Conductor - File Lock Library
# Serialises daily-log updates between record-output.sh (append) and
# restore-task.sh (read-modify-rewrite) so a completion is never lost to a
# concurrent rewrite. macOS ships no flock(1), so this uses an atomic `mkdir`
# lock with stale-owner detection. Sourced; defines functions only.

# acquire_lock <lockdir> [timeout_seconds]
#   Atomically claims <lockdir>. Reclaims a lock whose owner PID is gone.
#   Returns 0 if acquired, 1 on timeout.
acquire_lock() {
    local lockdir="$1"
    local timeout="${2:-5}"
    local deadline=$((timeout * 10))
    local waited=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        # Reclaim the lock if its owner process no longer exists.
        local owner
        owner=$(cat "$lockdir/pid" 2>/dev/null || true)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$lockdir" 2>/dev/null
            continue
        fi
        waited=$((waited + 1))
        if [ "$waited" -ge "$deadline" ]; then
            return 1
        fi
        sleep 0.1
    done
    echo "$$" > "$lockdir/pid" 2>/dev/null
    return 0
}

# release_lock <lockdir>
release_lock() {
    rm -rf "$1" 2>/dev/null
}
