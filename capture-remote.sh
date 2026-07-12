#!/bin/bash
# SessionEnd hook for CLIENT machines — any machine that is not the memory host.
#
# Same job as capture.sh, but the client has no vault on disk.
#
# It does NOT go through the MCP server, even though that is where memory_append lives.
# Hooks run headless, and headless sessions cannot see claude.ai connectors at all,
# while a locally-registered MCP server needs an interactive OAuth login before it
# works. Either way the hook would silently capture nothing — which is exactly what
# happened. So it writes to the vault through `gh` instead: already authenticated on
# these machines, no new credential, and it works headless.
#
# The summariser tries two paths, in order:
#   1. `claude -p --model haiku`   — free on the machine's subscription
#   2. Direct Haiku API call       — fires only if path 1 produced nothing at all AND
#      a key is available ($ANTHROPIC_API_KEY, else ~/.config/agent-memory/llm-key).
#      A valid "NONE" from path 1 never triggers path 2.
# Endpoint/model overridable via $AGENT_MEMORY_LLM_URL / $AGENT_MEMORY_LLM_MODEL.
# Neither path available → no capture, silently.
#
# Each capture creates its own file, so two machines (or two sessions) can never collide
# and there is no read-modify-write against the GitHub API. The distillation job sweeps
# up whatever it finds in inbox/.
#
# Optional: $AGENT_MEMORY_SOURCE overrides the source name (useful in cloud sandboxes,
# where the hostname is a random container ID).
#
# Exits 0 in every path: a failed capture must never error out a finished session.
set -uo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REPO="${AGENT_MEMORY_REPO:-hiboute/memory}"
SOURCE="${AGENT_MEMORY_SOURCE:-}"
[ -z "$SOURCE" ] && [ -f "$HOME/.config/agent-memory/source" ] \
  && SOURCE="$(tr -d '\n' < "$HOME/.config/agent-memory/source")"
[ -z "$SOURCE" ] && SOURCE="$(hostname -s | tr '[:upper:]' '[:lower:]')"

# This host may have several gh accounts; only GH_USER can push to the private memory
# repo. Shadow `gh` so every call carries GH_USER's token, pulled from the keyring
# with `--user` — without switching the active account (which would hijack the
# user's other terminals). If the token can't be read, fall back to the active
# account: a degraded capture, not a broken one. In cloud sandboxes the keyring
# lookup fails and $AGENT_MEMORY_GH_TOKEN (a dedicated fine-grained PAT) takes
# over, read from env or from ~/.config/agent-memory/gh-token — a file the
# environment setup script writes, because hook processes never see environment
# secrets (they load after hooks). The platform's ambient $GH_TOKEN is its own
# installation token, scoped to the session's repo, and cannot see this vault.
GH_USER="${AGENT_MEMORY_GH_USER:-hiboute}"
gh() {
  local t; t="$(command gh auth token --user "$GH_USER" 2>/dev/null)"
  [ -z "$t" ] && t="${AGENT_MEMORY_GH_TOKEN:-}"
  [ -z "$t" ] && [ -f "$HOME/.config/agent-memory/gh-token" ] \
    && t="$(tr -d '\n' < "$HOME/.config/agent-memory/gh-token")"
  if [ -n "$t" ]; then GH_TOKEN="$t" command gh "$@"; else command gh "$@"; fi
}

# The claude -p summariser below is itself a Claude session, which fires SessionEnd again.
[ "${CLAUDE_MEMORY_CAPTURE:-}" = "1" ] && exit 0

command -v gh >/dev/null 2>&1 || exit 0
gh auth status >/dev/null 2>&1 || exit 0

LLM_KEY="${ANTHROPIC_API_KEY:-}"
LLM_KEY_FILE="${AGENT_MEMORY_LLM_KEY_FILE:-$HOME/.config/agent-memory/llm-key}"
if [ -z "$LLM_KEY" ] && [ -f "$LLM_KEY_FILE" ]; then
  LLM_KEY=$(tr -d '\n' < "$LLM_KEY_FILE")
fi
# At least one summariser path must exist.
command -v claude >/dev/null 2>&1 || [ -n "$LLM_KEY" ] || exit 0

payload=$(cat)
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty')
[ -z "$transcript" ] || [ ! -f "$transcript" ] && exit 0

# Skip trivial sessions — summarising a two-message exchange costs more than it is worth.
lines=$(wc -l < "$transcript" | tr -d ' ')
[ "${lines:-0}" -lt 15 ] && exit 0

read -r -d '' PROMPT <<'EOF'
You are maintaining a long-term memory for a user across many Claude sessions.

Read the transcript below. Extract ONLY facts that will still matter in a month:
  - decisions made, and the reasoning behind them
  - how this user's systems are actually configured (paths, hosts, services)
  - preferences and corrections the user gave
  - non-obvious gotchas discovered the hard way

Ignore: routine tool calls, code already committed, anything reconstructible from the
repo, and anything that only mattered inside this one session.

Output format — markdown, no preamble:
  ## <short title>
  <2-5 sentences>

If nothing is worth remembering — the common case — output exactly: NONE
EOF

INPUT_FILE=$(mktemp)
trap 'rm -f "$INPUT_FILE"' EXIT
{
  printf '%s\n\n--- TRANSCRIPT ---\n' "$PROMPT"
  tail -c 200000 "$transcript"
} > "$INPUT_FILE"

learnings=""

# Path 1 — claude CLI on this machine's subscription.
if command -v claude >/dev/null 2>&1; then
  learnings=$(CLAUDE_MEMORY_CAPTURE=1 claude -p --model haiku < "$INPUT_FILE" 2>/dev/null) || learnings=""
fi

# Path 2 — direct Haiku API call, only when path 1 yielded nothing at all.
if [ -z "$learnings" ] && [ -n "$LLM_KEY" ]; then
  api_body=$(jq -n --rawfile input "$INPUT_FILE" \
    --arg model "${AGENT_MEMORY_LLM_MODEL:-claude-haiku-4-5}" \
    '{model:$model, max_tokens:1000, messages:[{role:"user", content:$input}]}')
  learnings=$(curl -sS -m 60 -X POST "${AGENT_MEMORY_LLM_URL:-https://api.anthropic.com}/v1/messages" \
    -H "x-api-key: ${LLM_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$api_body" 2>/dev/null | jq -r '.content[0].text // empty' 2>/dev/null) || learnings=""
fi

[ -z "$learnings" ] && exit 0
printf '%s' "$learnings" | grep -qx "NONE" && exit 0
printf '%s' "$learnings" | grep -q "^## " || exit 0

session=$(printf '%s' "$payload" | jq -r '.session_id // empty' | cut -c1-8)
[ -z "$session" ] && session=$(date +%H%M%S)
path="inbox/$(date +%F)-${SOURCE}-${session}.md"

content=$(printf '# Session capture — %s (%s)\n\n%s\n\n_captured %s_\n' \
  "$SOURCE" "$(date +%F)" "$learnings" "$(date -Iseconds)")

# tr -d: GNU base64 wraps at 76 cols (Linux sandboxes); macOS does not. Strip both.
gh api --method PUT "repos/$REPO/contents/$path" \
  -f message="memory: session capture from $SOURCE" \
  -f content="$(printf '%s' "$content" | base64 | tr -d '\n')" \
  >/dev/null 2>&1 || true

exit 0
