#!/bin/bash
# Claude Conductor - Shared helpers
# Sourced by scripts that need config resolution or pending-file lookup.

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"

# load_config: echo the effective config file path (config.json > config.default.json).
load_config() {
    local config_file="$CONDUCTOR_HOME/config.json"
    if [ ! -f "$config_file" ]; then
        config_file="$CONDUCTOR_HOME/config.default.json"
    fi
    echo "$config_file"
}

# find_pending_file <pending_dir> <tab>: echo the path of the first pending
# JSON whose .tab matches; return non-zero when none is found.
find_pending_file() {
    local dir="$1" tab="$2" f
    for f in "$dir"/*.json; do
        [ -f "$f" ] || continue
        [ "$(jq -r '.tab' "$f" 2>/dev/null)" = "$tab" ] || continue
        printf '%s' "$f"
        return 0
    done
    return 1
}
