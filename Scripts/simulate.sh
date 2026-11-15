#!/bin/bash
# Fires fake multi-subagent events at the island for testing.
SOCK="$HOME/.notch-agents/sock"
send() { printf '%s' "$1" | /usr/bin/nc -U -w 1 "$SOCK"; }

send '{"hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"Explore"}'
send '{"hook_event_name":"SubagentStart","agent_id":"a2","agent_type":"general-purpose"}'
sleep 1
send '{"hook_event_name":"PreToolUse","agent_id":"a1","tool_name":"Grep","tool_input":{"pattern":"AgentStore"}}'
# Task list + step trace for the main agent (hover the notch to see it).
send '{"hook_event_name":"PreToolUse","tool_name":"TodoWrite","tool_input":{"todos":[{"content":"Read the store","activeForm":"Reading the store","status":"completed"},{"content":"Add the trace","activeForm":"Adding the trace","status":"in_progress"},{"content":"Verify in the notch","activeForm":"Verifying in the notch","status":"pending"}]}}'
send '{"hook_event_name":"PreToolUse","tool_use_id":"r1","tool_name":"Read","tool_input":{"file_path":"/tmp/Sources/AgentStore.swift"}}'
send '{"hook_event_name":"PostToolUse","tool_use_id":"r1","tool_name":"Read"}'
send '{"hook_event_name":"PreToolUse","tool_use_id":"b1","tool_name":"Bash","tool_input":{"command":"swift build"}}'
send '{"hook_event_name":"PreToolUse","agent_id":"a2","tool_name":"Edit","tool_input":{"file_path":"/tmp/Sources/App.swift"}}'
sleep 3
send '{"hook_event_name":"PostToolUse","agent_id":"a1","tool_name":"Grep"}'
send '{"hook_event_name":"SubagentStop","agent_id":"a1"}'
sleep 3
send '{"hook_event_name":"SubagentStop","agent_id":"a2"}'
send '{"hook_event_name":"PostToolUse","tool_use_id":"b1","tool_name":"Bash"}'
sleep 4
send '{"hook_event_name":"Stop"}'
echo "simulation done"
