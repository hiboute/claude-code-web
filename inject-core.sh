#!/bin/bash
# SessionStart hook: inject core memory — and the hub for the project being
# worked on — into the session's context.
#
# Reading memory used to be a request in CLAUDE.md ("call memory_get_core at session
# start"), which the model was free to skip — and did. Writing, meanwhile, was hooked
# and deterministic. This closes that asymmetry: whatever this script prints to stdout
# is injected into context, so core memory is loaded whether or not anyone remembers to
# ask for it.
#
# Context priming: the vault keeps a distiller-maintained `context-map.tsv`
# (pattern <TAB> hub-path). If the session's git remote or directory name matches a
# pattern, that entity hub is injected alongside core — the memory the session is
# most likely to need, loaded before anyone asks (cue-driven recall).
#
# A hook cannot call an MCP tool (hooks run shell commands; tools are called by the
# model), so this fetches files directly. Three sources, in order of cost:
#
#   1. the local vault, if this machine is the host        — free, instant
#   2. the MCP endpoint, if a bearer is present (sandbox)  — plain HTTPS POST
#   3. the GitHub API via `gh`, if authenticated (client)  — no extra credential
#
# It never fails loudly: a session that starts without memory is a degraded session,
# not a broken one.
set -uo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

VAULT="${AGENT_MEMORY_VAULT:-$HOME/GIT/Perso/memory}"
CACHE_DIR="$HOME/.cache/agent-memory"
CACHE="$CACHE_DIR/core.md"
CACHE_TTL=900   # seconds; clients re-fetch at most every 15 min
PRIME_MAX_BYTES=16384   # cap the injected hub — context is billed every session

# This host may have several gh accounts; only GH_USER can see the private memory
# repo. Shadow `gh` so every call carries GH_USER's token, pulled from the keyring
# with `--user` — without switching the active account (which would hijack the
# user's other terminals). If the token can't be read, fall back to the active
# account: a degraded read, not a broken one.
GH_USER="${AGENT_MEMORY_GH_USER:-hiboute}"
gh() {
  local t; t="$(command gh auth token --user "$GH_USER" 2>/dev/null)"
  [ -z "$t" ] && t="${AGENT_MEMORY_GH_TOKEN:-}"
  [ -z "$t" ] && [ -f "$HOME/.config/agent-memory/gh-token" ] \
    && t="$(tr -d '\n' < "$HOME/.config/agent-memory/gh-token")"
  if [ -n "$t" ]; then GH_TOKEN="$t" command gh "$@"; else command gh "$@"; fi
}

core=""

# MCP endpoint config (sandbox rail). A bearer here means "not a host, not a Mac —
# a cloud sandbox where gh is brokered but the MCP host is reachable." Read it from
# env or the setup-script-written file.
MCP_URL="${AGENT_MEMORY_MCP_URL:-https://mcp-memory.robiche.fr/mcp}"
MCP_TOKEN="${AGENT_MEMORY_TOKEN:-}"
[ -z "$MCP_TOKEN" ] && [ -f "$HOME/.config/agent-memory/mcp-token" ] \
  && MCP_TOKEN="$(tr -d '\n' < "$HOME/.config/agent-memory/mcp-token")"

# call one MCP tool via the endpoint's JSON-RPC — a plain HTTPS POST, not an MCP tool
# call from a model, so it works headless. Extracts result.content[0].text.
mcp_call() {
  local name="$1" args="$2" resp body
  resp=$(curl -sS -m 12 -X POST "$MCP_URL" \
    -H "Authorization: Bearer $MCP_TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args}}" 2>/dev/null) || return 1
  # server may answer plain JSON or SSE ("data: {...}"); strip the prefix if present.
  body=$(printf '%s\n' "$resp" | sed -n 's/^data: //p'); [ -z "$body" ] && body="$resp"
  printf '%s' "$body" | jq -r 'select(.result?) | .result.content[0].text // empty' 2>/dev/null
}

mcp_get_core() { mcp_call "memory_get_core" "{}"; }

file_age() {
  local f="$1" m
  m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
  echo $(( $(date +%s) - m ))
}

# Fetch any vault file over the same three rails, with a per-file client cache.
# Paths come from our own map/config, never from untrusted input.
fetch_vault_file() {
  local rel="$1" cache fetched
  cache="$CACHE_DIR/$(printf '%s' "$rel" | tr '/' '_')"

  if [ -f "$VAULT/$rel" ]; then cat "$VAULT/$rel"; return 0; fi
  if [ -n "$MCP_TOKEN" ]; then mcp_call "memory_read" "{\"path\":\"$rel\"}"; return 0; fi

  local age=$((CACHE_TTL + 1))
  [ -f "$cache" ] && age=$(file_age "$cache")
  if [ "$age" -le "$CACHE_TTL" ]; then cat "$cache"; return 0; fi

  if command -v gh >/dev/null 2>&1; then
    fetched=$(gh api "repos/hiboute/memory/contents/$rel" \
                --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
    if [ -n "$fetched" ]; then
      mkdir -p "$CACHE_DIR"
      printf '%s' "$fetched" > "$cache"
      printf '%s' "$fetched"
      return 0
    fi
  fi
  [ -f "$cache" ] && cat "$cache"   # stale beats nothing when offline
  return 0
}

# 1. Host: read the vault directly.
if [ -f "$VAULT/core.md" ]; then
  core=$(cat "$VAULT/core.md")

# 1b. Sandbox: MCP endpoint with a static bearer (gh is brokered in cloud).
elif [ -n "$MCP_TOKEN" ]; then
  core=$(mcp_get_core || true)

# 2. Client: pull core.md from the private repo through gh, which is already
#    authenticated on these machines. No new token to mint or rotate.
else
  if [ -f "$CACHE" ]; then
    age=$(file_age "$CACHE")
  else
    age=$((CACHE_TTL + 1))
  fi

  if [ "$age" -le "$CACHE_TTL" ]; then
    core=$(cat "$CACHE")
  elif command -v gh >/dev/null 2>&1; then
    fetched=$(gh api repos/hiboute/memory/contents/core.md \
                --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
    if [ -n "$fetched" ]; then
      core="$fetched"
      mkdir -p "$(dirname "$CACHE")"
      printf '%s' "$core" > "$CACHE"
    elif [ -f "$CACHE" ]; then
      core=$(cat "$CACHE")   # stale beats nothing when offline
    fi
  elif [ -f "$CACHE" ]; then
    core=$(cat "$CACHE")
  fi
fi

[ -z "$core" ] && exit 0

# --- Context priming: which hub does this working directory cue? -------------
prime="" prime_path="" prime_cue=""
workdir="${CLAUDE_PROJECT_DIR:-$PWD}"
dir_cue=$(basename "$workdir" 2>/dev/null | tr '[:upper:]' '[:lower:]')
repo_cue=$(basename -s .git "$(git -C "$workdir" remote get-url origin 2>/dev/null)" 2>/dev/null \
             | tr '[:upper:]' '[:lower:]')

map=$(fetch_vault_file "context-map.tsv" || true)
if [ -n "$map" ]; then
  for cue in "$repo_cue" "$dir_cue"; do   # repo identity beats directory name
    [ -z "$cue" ] && continue
    prime_path=$(printf '%s\n' "$map" \
      | awk -F'\t' -v c="$cue" '$0 !~ /^#/ && tolower($1) == c { print $2; exit }')
    if [ -n "$prime_path" ]; then prime_cue="$cue"; break; fi
  done
  if [ -n "$prime_path" ]; then
    prime=$(fetch_vault_file "$prime_path" || true)
    [ -n "$prime" ] && prime=$(printf '%s' "$prime" | head -c "$PRIME_MAX_BYTES")
  fi
fi

# --- Inject ------------------------------------------------------------------
cat <<EOF
<long-term-memory>
This is your long-term memory about this user, carried across every session and
machine. Treat it as established fact; do not re-ask what it already tells you.

$core
EOF

if [ -n "$prime" ]; then
  cat <<EOF

---

Current project context — primed because this session works in "$prime_cue"
($prime_path; more via its Related links):

$prime
EOF
fi

cat <<'EOF'

Search the rest with memory_search; recall an entity's full context with
memory_recall; record durable new facts with memory_append.
</long-term-memory>
EOF

exit 0
