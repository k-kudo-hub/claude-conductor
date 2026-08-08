#!/bin/bash
# Claude Conductor - Task Deletion
# Records the task's output, uploads the work log, then removes every trace of
# the task and closes its tab.
#
# Usage: task-delete.sh <tab>
# Exit:
#   0  deleted (stdout holds the upload result line, empty when nothing was
#      uploaded because uploads are disabled or there was no pending entry)
#   1  the upload failed; nothing was deleted and the tab is left open
#
# The upload runs before anything is removed on purpose: a failed upload must
# leave the task fully intact so it can be retried.

set -e

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"
SESSION_NAME="${ZELLIJ_SESSION_NAME:-unknown}"
PENDING_DIR="$HOME/.claude-pending/$SESSION_NAME"

TAB="$1"
if [ -z "$TAB" ]; then
    echo "task-delete: tab name required" >&2
    exit 2
fi

bash "$CONDUCTOR_HOME/scripts/record-output.sh" "$TAB"

if ! UPLOAD_OUT=$(bash "$CONDUCTOR_HOME/scripts/upload-log.sh" "$TAB"); then
    exit 1
fi

# Deletion is committed from here on.
for f in "$PENDING_DIR"/*.json; do
    [ -f "$f" ] || continue
    if [ "$(jq -r '.tab' "$f" 2>/dev/null)" = "$TAB" ]; then
        rm -f "$f"
    fi
done

# Drop the task's registry entries so a later session restore does not
# resurrect it (issue #36), and its screen-detection state so a same-named
# future tab starts fresh.
# shellcheck source=scripts/registry-lib.sh
. "$CONDUCTOR_HOME/scripts/registry-lib.sh"
# shellcheck source=scripts/task-lib.sh
. "$CONDUCTOR_HOME/scripts/task-lib.sh"
registry_remove_by_tab "$SESSION_NAME" "$TAB"
rm -f "$PENDING_DIR/.screen-state/$(_screen_tab_slug "$TAB")"

# Close the tab by id rather than closing the active one: the synchronous
# upload can take seconds, during which the active tab may have switched.
# The tab name may contain spaces, so match everything past the id/position
# columns rather than just the third field.
TAB_ID=$(zellij action list-tabs 2>/dev/null | awk -v name="$TAB" \
    'NR>1 { line=$0; sub(/^[^ ]+ +[^ ]+ +/, "", line); if (line == name) print $1 }')
if [ -n "$TAB_ID" ]; then
    zellij action close-tab-by-id "$TAB_ID" 2>/dev/null || true
fi

# Report the upload result without the script's own prefix so callers can show
# it as-is.
echo "${UPLOAD_OUT#upload-log: }"
