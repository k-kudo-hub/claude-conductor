#!/bin/bash
# Claude Conductor - Agent Launcher
# Launches the configured agent CLI (config .agent.command, default: claude).
# Used by layouts/dev.kdl, whose static KDL cannot read config.json itself;
# task tabs go through create_task in task-lib.sh instead.

CONDUCTOR_HOME="${CONDUCTOR_HOME:-$HOME/.claude-conductor}"

source "$CONDUCTOR_HOME/scripts/task-lib.sh"

declare -a cmd
read -r -a cmd <<< "$(agent_command)"
exec "${cmd[@]}"
