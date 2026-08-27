#!/bin/bash
# SessionStart hook: put long-term memory in front of the model before the first turn.
#
# Memory v2 (2026-08-27): memory is the Obsidian vault `homelab`, read and written only
# through the `obsidian` MCP (a Cloudflare Worker over YAOS storage). The git rail is
# retired — no `hiboute/memory` clone, no `gh api`, no mcp-memory.robiche.fr. The
# `homelab-memory` skill carries the contract (recall path, the vault's own rules.md,
# capture format); this hook only makes sure a session never starts blind.
#
# Reading memory used to be a request in CLAUDE.md ("call memory_get_core at session
# start"), which the model was free to skip — and did. Writing, meanwhile, was hooked
# and deterministic. This closes that asymmetry: whatever this script prints to stdout
# is injected into context.
#
# #gotcha A hook is a shell command, not a model, so it CANNOT call an MCP tool. Three
# rails, in order of cost:
#
#   1. a local copy of the vault ($AGENT_MEMORY_VAULT)   — free, instant
#   2. the obsidian MCP's JSON-RPC over plain HTTPS, if a bearer is available
#   3. neither: inject the *contract* instead of the content — name the vault, the MCP
#      and the `homelab-memory` skill, and let the session's first tool call read it.
#      The model can reach the MCP even where this script cannot.
#
# Context priming: `context-map.tsv` is gone (it is not a note, so it cannot live in the
# vault any more). The catalog `INDEX.md` replaces it — the session's repo or directory
# name is matched against its `[[slug]]` entries and the matching hub is injected
# alongside core: the memory this session is most likely to need, loaded before anyone
# asks (cue-driven recall).
#
# It never fails loudly: a session that starts without memory is degraded, not broken.
set -uo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

CFG="$HOME/.config/agent-memory"
CACHE_DIR="$HOME/.cache/agent-memory"
PENDING_DIR="$CACHE_DIR/pending"
CACHE_TTL=900           # seconds; re-fetch at most every 15 min
PRIME_MAX_BYTES=16384   # cap the injected hub — context is billed every session

# Config the installer wrote (hook processes never see environment secrets: they load
# after hooks, which is why install.sh bridges them into files).
cfg() {  # cfg <filename> <fallback>
  if [ -f "$CFG/$1" ]; then tr -d '\n' < "$CFG/$1"; else printf '%s' "$2"; fi
}

VAULT_ID="${AGENT_MEMORY_VAULT_ID:-$(cfg vault homelab)}"
MCP_URL="${AGENT_MEMORY_MCP_URL:-$(cfg mcp-url https://mcp-obsidian.chrobiche.workers.dev/mcp)}"
MCP_TOKEN="${OBSIDIAN_MCP_TOKEN:-$(cfg obsidian-token '')}"
# A machine that syncs the vault locally (Obsidian on a Mac) skips the network entirely.
# No default path: unset means "no local vault here", not "guess one".
VAULT="${AGENT_MEMORY_VAULT:-$(cfg vault-path '')}"

# --- obsidian MCP over plain HTTPS -------------------------------------------
# JSON-RPC straight at the endpoint, which is a normal HTTPS POST — not an MCP tool
# call from a model, so it works headless. Streamable-HTTP servers may hand out a
# session id at initialize; stateless ones ignore it.
MCP_SESSION=""

mcp_headers() {
  MCP_HDRS=(-H "Authorization: Bearer $MCP_TOKEN"
            -H "Content-Type: application/json"
            -H "Accept: application/json, text/event-stream")
  [ -n "$MCP_SESSION" ] && MCP_HDRS+=(-H "Mcp-Session-Id: $MCP_SESSION")
}

mcp_init() {
  [ -n "$MCP_TOKEN" ] || return 1
  local hdr
  mcp_headers
  hdr=$(curl -sS -m 12 -D - -o /dev/null -X POST "$MCP_URL" "${MCP_HDRS[@]}" \
    -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"agent-memory-hook","version":"2"}}}' \
    2>/dev/null) || return 1
  MCP_SESSION=$(printf '%s' "$hdr" | tr -d '\r' | grep -i '^mcp-session-id:' | tail -1 | cut -d' ' -f2)
  if [ -n "$MCP_SESSION" ]; then
    mcp_headers
    curl -sS -m 12 -o /dev/null -X POST "$MCP_URL" "${MCP_HDRS[@]}" \
      -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' 2>/dev/null
  fi
  return 0
}

# Call one obsidian tool; prints result.content[0].text (the tools answer with a JSON
# document in there). Server may reply plain JSON or SSE ("data: {...}"). Returns
# non-zero on a JSON-RPC error or an isError result — a missing note comes back that
# way ("no such note: <path>"), and that text must never be mistaken for content.
mcp_call() {
  local name="$1" args="$2" resp body ok
  [ -n "$MCP_TOKEN" ] || return 1
  mcp_headers
  resp=$(curl -sS -m 15 -X POST "$MCP_URL" "${MCP_HDRS[@]}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args}}" \
    2>/dev/null) || return 1
  body=$(printf '%s\n' "$resp" | sed -n 's/^data: //p'); [ -z "$body" ] && body="$resp"
  ok=$(printf '%s' "$body" | jq -r 'if (.result? and (.result.isError != true)) then "1" else "0" end' 2>/dev/null)
  [ "$ok" = "1" ] || return 1
  printf '%s' "$body" | jq -r '.result.content[0].text // empty' 2>/dev/null
}

# vault_read_note answers with {"path":..., "text":"<markdown>"}; unwrap to the markdown.
mcp_read_note() {
  local rel="$1" raw note
  raw=$(mcp_call vault_read_note "$(jq -nc --arg v "$VAULT_ID" --arg p "$rel" '{vaultId:$v,path:$p}')")
  [ -z "$raw" ] && return 1
  note=$(printf '%s' "$raw" | jq -r '.text // empty' 2>/dev/null)
  if [ -n "$note" ]; then printf '%s' "$note"; else printf '%s' "$raw"; fi
}

file_age() {
  local f="$1" m
  m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
  echo $(( $(date +%s) - m ))
}

# Fetch one vault note over the rails above, with a per-file client cache.
# Paths come from our own config and from INDEX.md, never from untrusted input.
fetch_vault_file() {
  local rel="$1" cache fetched age
  cache="$CACHE_DIR/$(printf '%s' "$rel" | tr '/' '_')"

  if [ -n "$VAULT" ] && [ -f "$VAULT/$rel" ]; then cat "$VAULT/$rel"; return 0; fi

  age=$((CACHE_TTL + 1))
  [ -f "$cache" ] && age=$(file_age "$cache")
  if [ "$age" -le "$CACHE_TTL" ]; then cat "$cache"; return 0; fi

  if [ -n "$MCP_TOKEN" ]; then
    fetched=$(mcp_read_note "$rel")
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

[ -n "$MCP_TOKEN" ] && mcp_init

core=$(fetch_vault_file "core.md")

# --- Which hub does this working directory cue? ------------------------------
prime="" prime_path="" prime_cue=""
workdir="${CLAUDE_PROJECT_DIR:-$PWD}"
dir_cue=$(basename "$workdir" 2>/dev/null | tr '[:upper:]' '[:lower:]')
repo_cue=$(basename -s .git "$(git -C "$workdir" remote get-url origin 2>/dev/null)" 2>/dev/null \
             | tr '[:upper:]' '[:lower:]')

if [ -n "$core" ]; then
  index=$(fetch_vault_file "INDEX.md" || true)
  if [ -n "$index" ]; then
    # INDEX.md lists one hub per line: "- [[slug]] `systems/slug.md` #tag — hook"
    for cue in "$repo_cue" "$dir_cue"; do   # repo identity beats directory name
      [ -z "$cue" ] && continue
      prime_path=$(printf '%s\n' "$index" | grep -F "[[${cue}]]" \
        | sed -n 's/.*`\([^`]*\.md\)`.*/\1/p' | head -1)
      if [ -n "$prime_path" ]; then prime_cue="$cue"; break; fi
    done
    if [ -n "$prime_path" ]; then
      prime=$(fetch_vault_file "$prime_path" || true)
      [ -n "$prime" ] && prime=$(printf '%s' "$prime" | head -c "$PRIME_MAX_BYTES")
    fi
  fi
fi

# --- Captures the SessionEnd hook could not file ------------------------------
# No bearer at session end means capture-remote.sh had no write rail and staged the
# composed note here instead. The model does have the MCP, so hand it the backlog.
pending=""
if [ -d "$PENDING_DIR" ]; then
  pending=$(find "$PENDING_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort | head -5)
fi

# --- Inject -------------------------------------------------------------------
if [ -n "$core" ]; then
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

  cat <<EOF

The memory itself is the Obsidian vault \`$VAULT_ID\`, reached through the \`obsidian\`
MCP (\`vault_read_note\`, \`vault_search\`, \`vault_list_notes\`, \`vault_write_note\`;
in Claude Code usually \`mcp__obsidian__vault_*\`). Load the \`homelab-memory\` skill
before reading further or recording anything — it carries the recall contract, the
vault's own rules.md and the capture format. Read a hub with \`vault_read_note\`,
resolve an unknown entity through \`INDEX.md\`, search with one literal token and a
\`pathPrefix\`. Record durable new facts as ONE new file under \`inbox/\`; never write
to core.md, INDEX.md or a hub — the distiller owns those.
</long-term-memory>
EOF

else
  # No content rail. Inject the contract so the session loads memory with its own first
  # tool call — the model can reach the MCP, this hook cannot.
  cat <<EOF
<long-term-memory>
Your long-term memory about this user could not be loaded by the session-start hook:
reading it needs an MCP tool call, and hooks cannot make one. Load it yourself before
answering anything about his projects, homelab or VPS infrastructure, L'Oréal work
context, the people he works with, or past decisions:

1. Load the \`homelab-memory\` skill — it carries the recall contract, the vault's own
   rules.md and the capture format. It governs; this block is only the pointer.
2. \`vault_read_note {vaultId: "$VAULT_ID", path: "core.md"}\` through the \`obsidian\`
   MCP (in Claude Code usually \`mcp__obsidian__vault_*\`). Treat what it says as
   established fact; do not re-ask what it already tells you.
3. Resolve the entity in play through \`INDEX.md\`, then read its hub. This session's
   cue is "${repo_cue:-${dir_cue:-unknown}}".

Vault id is \`$VAULT_ID\`, exact lowercase. Record durable new facts as ONE new file
under \`inbox/\`; never write to core.md, INDEX.md or a hub. Ignore any leftover
\`Memory\` connector (memory_get_core / memory_append): it is the retired git-backed
server and serves a stale copy.
</long-term-memory>
EOF
fi

if [ -n "$pending" ]; then
  cat <<EOF

<pending-memory-captures>
The SessionEnd hook of an earlier session summarised it but had no write rail, so the
capture is staged on disk instead of in the vault. Each file below is a complete,
ready-to-write note whose first line names its vault path. When convenient in this
session: read it, write it with \`vault_write_note {vaultId: "$VAULT_ID", confirm: true,
path: <that path>, text: <body after the path line>}\` — after checking the path is free
with \`vault_list_notes\` — then delete the local file. Do not merge them into hubs.

$pending
</pending-memory-captures>
EOF
fi

exit 0
