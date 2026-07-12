#!/bin/bash
# SessionStart hook: inject core memory into the session's context.
#
# Reading memory used to be a request in CLAUDE.md ("call memory_get_core at session
# start"), which the model was free to skip — and did. Writing, meanwhile, was hooked
# and deterministic. This closes that asymmetry: whatever this script prints to stdout
# is injected into context, so core memory is loaded whether or not anyone remembers to
# ask for it.
#
# A hook cannot call an MCP tool (hooks run shell commands; tools are called by the
# model), so this fetches core.md directly. Three sources, in order of cost:
#
#   1. the local vault, if this machine is the host        — free, instant
#   2. the GitHub API via `gh`, if authenticated           — no extra credential
#   3. nothing                                             — stay silent
#
# It never fails loudly: a session that starts without memory is a degraded session,
# not a broken one.
set -uo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

VAULT="${AGENT_MEMORY_VAULT:-$HOME/GIT/Perso/memory}"
CACHE="$HOME/.cache/agent-memory/core.md"
CACHE_TTL=900   # seconds; clients re-fetch at most every 15 min

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

# 1. Host: read the vault directly.
if [ -f "$VAULT/core.md" ]; then
  core=$(cat "$VAULT/core.md")

# 2. Client: pull core.md from the private repo through gh, which is already
#    authenticated on these machines. No new token to mint or rotate.
else
  if [ -f "$CACHE" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
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

cat <<EOF
<long-term-memory>
This is your long-term memory about this user, carried across every session and
machine. Treat it as established fact; do not re-ask what it already tells you.

$core

Search the rest with memory_search; record durable new facts with memory_append.
</long-term-memory>
EOF

exit 0
