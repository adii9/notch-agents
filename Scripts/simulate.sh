#!/bin/bash
# Fires fake multi-subagent events at the island for testing.
SOCK="$HOME/.notch-agents/sock"
send() { printf '%s' "$1" | /usr/bin/nc -U -w 1 "$SOCK"; }

send '{"hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"Explore"}'
send '{"hook_event_name":"SubagentStart","agent_id":"a2","agent_type":"general-purpose"}'
sleep 1
send '{"hook_event_name":"PreToolUse","agent_id":"a1","tool_name":"Grep","tool_input":{"pattern":"AgentStore"}}'
send '{"hook_event_name":"PreToolUse","agent_id":"a2","tool_name":"Edit","tool_input":{"file_path":"/tmp/Sources/App.swift"}}'
sleep 3
send '{"hook_event_name":"PostToolUse","agent_id":"a1","tool_name":"Grep"}'
send '{"hook_event_name":"SubagentStop","agent_id":"a1"}'
sleep 3
send '{"hook_event_name":"SubagentStop","agent_id":"a2"}'
echo "simulation done"
