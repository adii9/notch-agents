#!/bin/bash
# Smoke-tests the hook script exactly as HookInstaller writes it (no app needed).
# Checks: valid bash, and it never fails or blocks Claude when the app isn't running.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/na-hook.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/.notch-agents"
HOOK="$WORK/.notch-agents/hook.sh"

# Extract the Swift multi-line string literal `script` and undo Swift's indentation and escapes.
python3 - "$HOOK" <<'EOF'
import re, sys
src = open("Sources/NotchAgents/HookInstaller.swift").read()
m = re.search(r'static let script = """\n(.*?)\n    """', src, re.S)
if not m:
    sys.exit("could not find HookInstaller.script")
lines = [l[4:] if l.startswith("    ") else l for l in m.group(1).split("\n")]
open(sys.argv[1], "w").write("\n".join(lines).replace("\\\\", "\\") + "\n")
EOF
chmod +x "$HOOK"

bash -n "$HOOK" && echo "ok   hook script is valid bash"

run() {  # $1 = payload; prints "<exit code>|<stdout>"
  local out rc=0
  out="$(printf '%s' "$1" | HOME="$WORK" "$HOOK")" || rc=$?
  printf '%s|%s' "$rc" "$out"
}
expect() {  # $1 = name, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; exit 1; fi
}

NORMAL='{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
PERM='{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}'

# No socket at all (app never installed or never started).
expect "no socket: normal event exits 0 silently" "0|" "$(run "$NORMAL")"
expect "no socket: permission request exits 0 silently" "0|" "$(run "$PERM")"

# Stale socket file left behind by a quit app: must still return at once, without a decision.
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$WORK/.notch-agents/sock"
start=$(date +%s)
expect "stale socket: permission request exits 0 silently" "0|" "$(run "$PERM")"
[ $(( $(date +%s) - start )) -le 2 ] && echo "ok   stale socket: returned within 2s" || { echo "FAIL stale socket: hook blocked"; exit 1; }
