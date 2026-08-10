#!/bin/bash
# Claude Conductor - Codex Rollout Library
# The one place that knows how a codex rollout jsonl is shaped. Sourced by
# record-output.sh (statistics) and upload-log.sh (conversation summary) so a
# future format change is a single-file edit. Defines $CODEX_ROLLOUT_JQ, a set
# of jq definitions to prepend to a jq program run in slurp mode (`jq -s`), and
# nothing else.
#
# Two layouts exist in the wild and the codex version does NOT tell them apart
# (the same cli_version 0.147.0 writes both, and 0.147.0-alpha.6.5 writes only
# the older one), so every definition below reads whichever shape the rollout
# actually uses:
#   v1: conversation in event_msg payloads user_message / agent_message;
#       tool calls in response_items whose payload.type ends in "_call".
#   v2: conversation and tool activity in event_msg payloads of type
#       "item_completed", carrying an .item whose .type names the kind
#       (UserMessage / AgentMessage / Reasoning / CommandExecution /
#       McpToolCall / FileChange / Extension / Entered|ExitedReviewMode).
#
# Why tool calls pick one view instead of summing both (measured over every
# rollout under ~/.codex/sessions):
#   - The two views are the same activity seen from two sides. In the 08/10
#     rollout the nine `custom_tool_call` (name "exec") inputs are, in order,
#     four tools.web__run calls (rendered as Extension web.search items), one
#     tools.exec_command (CommandExecution), one pure introspection call (no
#     item at all), one tools.mcp__node call (McpToolCall) and two more
#     tools.exec_command (CommandExecution). Adding the item view to the
#     response_item view would count those five activities twice.
#   - There is no shared key to join them on: v1 carries call_id "call_..."
#     and id "ctc_...", v2 carries id "exec-<uuid>". No id-based union is
#     possible.
#   - Per-file counts confirm the response_item view is never the smaller one
#     when it exists at all (e.g. exec 7 + wait 1 vs CommandExecution 5 +
#     Extension 2). The one real gap is a rollout that logs no response_items
#     whatsoever (2026-08-07T22:17, 0 vs 8 CommandExecution items), which is
#     exactly what the fallback covers.

# jq definitions shared by the codex parsers. Input: the slurped array of
# rollout records (use `jq -s` / `jq -sc` / `jq -rs`).
CODEX_ROLLOUT_JQ='
# Conversation text, in file order, for both layouts. Reasoning items are
# internal deliberation and response_items include the developer system prompt,
# so neither is part of the conversation.
# Content elements are read leniently: real rollouts type them "text" for
# UserMessage but "Text" for AgentMessage, so they are taken by their .text
# field, and a bare string element is accepted too. A shape we cannot read
# degrades the summary instead of aborting the upload (and with it the tab
# deletion).
def codex_texts:
  [ .[]
    | select(.type == "event_msg")
    | .payload
    | if (.type == "user_message" or .type == "agent_message") then
        (.message | select(type == "string" and . != ""))
      elif (.type == "item_completed"
            and (.item.type == "UserMessage" or .item.type == "AgentMessage")) then
        ([ .item.content[]?
           | (if type == "string" then . else .text? end)
           | select(type == "string" and . != "")
         ] | join("\n") | select(. != ""))
      else empty end
  ];

# User turns. The layouts are picked, never summed: they are two ways of
# logging the same turn, so summing would double count a rollout that ever
# carried both.
def codex_turns:
  ([ .[] | select(.type == "event_msg" and .payload.type == "item_completed"
                  and .payload.item.type == "UserMessage") ] | length) as $v2
  | if $v2 > 0 then $v2
    else ([ .[] | select(.type == "event_msg" and .payload.type == "user_message") ] | length)
    end;

def codex_tools_v1:
  [ .[] | select(.type == "response_item") | .payload
        | select(.type != null) | select(.type | test("_call$")) ];

def codex_tools_v2:
  [ .[] | select(.type == "event_msg" and .payload.type == "item_completed")
        | .payload.item
        | select(.type == "CommandExecution" or .type == "McpToolCall"
                 or .type == "FileChange" or .type == "Extension") ];

# The response_item view when the rollout has one, else the item view.
def codex_tools:
  codex_tools_v1 as $v1
  | if ($v1 | length) > 0 then $v1 else codex_tools_v2 end;

# Display name of one tool entry: v1 calls carry .name, McpToolCall items carry
# .tool, Extension items carry .kind ("web.search"); anything else falls back to
# the item type.
def codex_tool_name: .name // .tool // .kind // .type;

# The command a CommandExecution item ran, as one string. Guarded on type: a
# rollout that ever writes .command as a string (or puts objects in the array)
# must not abort jq, which would drop the whole daily record to summary: null.
def codex_command_text:
  if (.command | type) == "array" then (.command | map(tostring) | join(" "))
  else ((.command // "") | tostring)
  end;

# Was a pull request merged? Scanned in both views (a boolean cannot double
# count). Only the invocation is scanned, never command output: a real rollout
# `cat`s a file mentioning gh pr merge, and CommandExecution items carry
# .stdout / .aggregated_output. MCP merges are matched by tool name rather than
# by argument text, which would fire on a Slack message quoting the tool name.
def codex_merged:
  ( codex_tools_v1
    | [ .[] | select( (((.input // .arguments // "") | tostring) | test("gh\\s+pr\\s+merge"))
                      or (((.name // "") | tostring) | test("merge_pull_request")) ) ]
    | length > 0 )
  or
  ( codex_tools_v2
    | [ .[] | select( (.type == "CommandExecution" and (codex_command_text | test("gh\\s+pr\\s+merge")))
                      or (.type == "McpToolCall" and (((.tool // "") | tostring) | test("merge_pull_request"))) ) ]
    | length > 0 );
'
