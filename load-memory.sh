#!/usr/bin/env bash
# claude-code-web · load-memory.sh
# SessionStart hook: fetch core.md from the agent-memory MCP endpoint and print
# it to stdout — Claude Code adds SessionStart stdout to the session context,
# so every sandbox starts warm even before any MCP connector is wired.
#
# Never fails the session: every path exits 0 (same contract as capture-remote.sh).
#
# Token sources, in order:
#   1. $AGENT_MEMORY_TOKEN            — cloud sandbox env secret
#   2. ~/.config/agent-memory/token   — local machines
#
# Usage as a SessionStart hook (.claude/settings.json):
#   bash -lc 'curl -fsSL https://raw.githubusercontent.com/hiboute/claude-code-web/main/load-memory.sh | bash'

set -u

ENDPOINT="${AGENT_MEMORY_ENDPOINT:-https://mcp-memory.robiche.fr/mcp}"

note() { printf '[agent-memory] %s\n' "$*"; }

TOKEN="${AGENT_MEMORY_TOKEN:-}"
if [ -z "${TOKEN}" ] && [ -r "${HOME}/.config/agent-memory/token" ]; then
  TOKEN="$(cat "${HOME}/.config/agent-memory/token")"
fi
if [ -z "${TOKEN}" ]; then
  note "core.md not loaded: no token. Set the AGENT_MEMORY_TOKEN env secret (cloud) or ~/.config/agent-memory/token (local). The agent-memory MCP connector may still be available for tool calls."
  exit 0
fi

PAYLOAD='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"memory_get_core","arguments":{}}}'

RESP="$(curl -fsS -m 10 -X POST "${ENDPOINT}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d "${PAYLOAD}" 2>/dev/null)" || RESP=""

if [ -z "${RESP}" ]; then
  note "core.md not loaded: ${ENDPOINT} unreachable (a 502 usually means com.agent-memory is down on the Mac mini)."
  exit 0
fi

# The server may answer plain JSON or SSE-framed lines ("data: {...}") — handle both.
BODY="$(printf '%s\n' "${RESP}" | sed -n 's/^data: //p')"
[ -z "${BODY}" ] && BODY="${RESP}"

CORE="$(printf '%s\n' "${BODY}" | jq -r 'select(.result?) | .result.content[0].text // empty' 2>/dev/null || true)"

if [ -z "${CORE}" ] && command -v python3 >/dev/null 2>&1; then
  CORE="$(printf '%s\n' "${BODY}" | python3 -c '
import sys, json
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    r = o.get("result") or {}
    c = (r.get("content") or [{}])[0]
    if c.get("text"):
        print(c["text"])
        break
' 2>/dev/null || true)"
fi

if [ -z "${CORE}" ]; then
  note "core.md not loaded: unexpected response from ${ENDPOINT}."
  exit 0
fi

printf '<agent-memory-core>\n%s\n</agent-memory-core>\n' "${CORE}"
printf 'core.md above was loaded from the agent-memory vault at session start. Search the vault with memory_search (agent-memory MCP) before asking about anything possibly already known; record durable facts with memory_append. rules.md in the vault governs every write.\n'
exit 0
