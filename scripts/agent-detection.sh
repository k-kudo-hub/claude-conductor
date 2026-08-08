#!/bin/bash
# Claude Conductor - Agent Detection Method
# CLI entry point for task-lib's agent_detection, so callers can ask how an
# agent's state is tracked without sourcing the library.
#
# Usage: agent-detection.sh <agent>
# Prints "hooks" or "screen".

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"

# shellcheck source=scripts/task-lib.sh
. "$CONDUCTOR_HOME/scripts/task-lib.sh"

agent_detection "$1"
