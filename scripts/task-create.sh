#!/bin/bash
# Claude Conductor - Task Creation
# CLI entry point for task-lib's create_task, so the New Task pane can create
# a task without sourcing the library.
#
# Usage: task-create.sh <dir> <task-type> <name> [claude-session-id] [agent]

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"

# shellcheck source=scripts/task-lib.sh
. "$CONDUCTOR_HOME/scripts/task-lib.sh"

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "task-create: dir, task type and name are required" >&2
    exit 2
fi

create_task "$1" "$2" "$3" "$4" "$5"
