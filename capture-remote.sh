#!/bin/bash
# SessionEnd hook: turn a finished session into ONE new capture under `inbox/` in the
# Obsidian vault `homelab`.
#
# Memory v2 (2026-08-27): the vault is served by the `obsidian` MCP (Cloudflare Worker
# over YAOS). The git rail — `hiboute/memory`, `gh api` PUTs, mcp-memory.robiche.fr — is
# retired and nothing here talks to it. The `homelab-memory` skill and `rules.md`
# are the governing policy; the capture this hook writes follows the same format a model
# would write by hand (`references/capture-format.md` in that skill).
#
# #gotcha A hook is headless and CANNOT call an MCP tool: it cannot see claude.ai
# connectors, and a locally-registered MCP server would need an interactive OAuth login.
# So the write goes over whatever a shell can reach, in order:
#
#   1. a local copy of the vault ($AGENT_MEMORY_VAULT) — write the file, let Obsidian sync
#   2. the obsidian MCP's JSON-RPC over plain HTTPS, when a bearer is available
#   3. neither: stage the composed note under ~/.cache/agent-memory/pending/, where the
#      next session's SessionStart hook surfaces it — the model has the MCP and files it.
#      #gotcha This only defers the write on a machine that persists: a cloud sandbox is
#      reclaimed at session end, so there the staged file dies with the container and the
#      capture IS lost. In a sandbox, rail 2 (the bearer) is what makes capture durable.
#
# The summariser tries two paths, in order:
#   1. `claude -p --model haiku`   — free on the machine's subscription
#   2. Direct Haiku API call       — fires only if path 1 produced nothing at all AND
#      a key is available ($ANTHROPIC_API_KEY, else ~/.config/agent-memory/llm-key).
#      A valid "NONE" from path 1 never triggers path 2.
# Endpoint/model overridable via $AGENT_MEMORY_LLM_URL / $AGENT_MEMORY_LLM_MODEL.
# Neither path available → no capture, silently.
#
# One file per capture, so two machines (or two sessions) can never collide. The nightly
# distiller sweeps up whatever it finds in `inbox/` and is the only writer of core.md,
# INDEX.md and the hubs — this hook never touches those.
#
# Optional: $AGENT_MEMORY_SOURCE names the writing client (`ccr`, `cowork`, a hostname);
# useful in cloud sandboxes, where the hostname is a random container ID.
#
# Exits 0 in every path: a failed capture must never error out a finished session.
set -uo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

CFG="$HOME/.config/agent-memory"
PENDING_DIR="$HOME/.cache/agent-memory/pending"

cfg() {  # cfg <filename> <fallback>
  if [ -f "$CFG/$1" ]; then tr -d '\n' < "$CFG/$1"; else printf '%s' "$2"; fi
}

VAULT_ID="${AGENT_MEMORY_VAULT_ID:-$(cfg vault homelab)}"
MCP_URL="${AGENT_MEMORY_MCP_URL:-$(cfg mcp-url https://mcp-obsidian.chrobiche.workers.dev/mcp)}"
MCP_TOKEN="${OBSIDIAN_MCP_TOKEN:-$(cfg obsidian-token '')}"
VAULT="${AGENT_MEMORY_VAULT:-$(cfg vault-path '')}"

# The distiller sorts captures on <source>, and the capture format names the values it
# expects: app | cowork | ccr | hostname. Cloud environments still export the pre-v2
# `AGENT_MEMORY_SOURCE=cloud`, and earlier captures went in as `claude-code-remote`, so
# fold the known aliases onto `ccr` rather than splitting one client three ways.
# Anything else (a hostname, `app`, `cowork`) passes through untouched.
normalize_source() {
  case "$1" in
    cloud|claude-code-remote|claude-code-web|remote|ccr) printf 'ccr' ;;
    *) printf '%s' "$1" ;;
  esac
}

SOURCE="${AGENT_MEMORY_SOURCE:-$(cfg source '')}"
[ -z "$SOURCE" ] && SOURCE="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
[ -z "$SOURCE" ] && SOURCE="unknown"
SOURCE="$(normalize_source "$SOURCE")"

# The claude -p summariser below is itself a Claude session, which fires SessionEnd again.
[ "${CLAUDE_MEMORY_CAPTURE:-}" = "1" ] && exit 0

LLM_KEY="${ANTHROPIC_API_KEY:-}"
LLM_KEY_FILE="${AGENT_MEMORY_LLM_KEY_FILE:-$CFG/llm-key}"
if [ -z "$LLM_KEY" ] && [ -f "$LLM_KEY_FILE" ]; then
  LLM_KEY=$(tr -d '\n' < "$LLM_KEY_FILE")
fi
# At least one summariser path must exist. (A write rail is not required: without one
# the capture is staged for the next session instead of being thrown away.)
command -v claude >/dev/null 2>&1 || [ -n "$LLM_KEY" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# --- obsidian MCP over plain HTTPS -------------------------------------------
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

# Prints result.content[0].text; returns non-zero on transport error, JSON-RPC error,
# or an isError result (a missing note answers "no such note: <path>" that way).
mcp_call() {
  local name="$1" args="$2" resp body ok
  [ -n "$MCP_TOKEN" ] || return 1
  mcp_headers
  resp=$(curl -sS -m 30 -X POST "$MCP_URL" "${MCP_HDRS[@]}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args}}" \
    2>/dev/null) || return 1
  body=$(printf '%s\n' "$resp" | sed -n 's/^data: //p'); [ -z "$body" ] && body="$resp"
  ok=$(printf '%s' "$body" | jq -r 'if (.result? and (.result.isError != true)) then "1" else "0" end' 2>/dev/null)
  [ "$ok" = "1" ] || return 1
  printf '%s' "$body" | jq -r '.result.content[0].text // empty' 2>/dev/null
}

# vault_write_note overwrites silently, so a path must be proved free first: an
# unmatched prefix lists as []. Unknown (call failed) counts as "not free".
path_free() {
  local prefix="$1" out
  out=$(mcp_call vault_list_notes "$(jq -nc --arg v "$VAULT_ID" --arg p "$prefix" '{vaultId:$v,pathPrefix:$p}')") || return 1
  [ "$(printf '%s' "$out" | jq -r 'if type=="array" then length else 1 end' 2>/dev/null)" = "0" ]
}

slugify() {
  local s="$1" a
  a=$(printf '%s' "$s" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null)
  [ -n "$a" ] && s="$a"
  printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' \
    | cut -c1-40 | sed -e 's/^-*//' -e 's/-*$//'
}

# --- Transcript ---------------------------------------------------------------
payload=$(cat)
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty')
[ -z "$transcript" ] || [ ! -f "$transcript" ] && exit 0

# Skip trivial sessions — summarising a two-message exchange costs more than it is worth.
lines=$(wc -l < "$transcript" | tr -d ' ')
[ "${lines:-0}" -lt 15 ] && exit 0

read -r -d '' PROMPT <<'EOF'
You are maintaining a long-term memory for a user across many Claude sessions. It is an
Obsidian vault; your output becomes one new capture file under its inbox/, which a
nightly distiller merges into the curated notes.

Read the transcript below. Extract ONLY what will still matter in a month:
  - decisions the user made, and the reasoning behind them
  - how this user's systems are actually configured (paths, hosts, services)
  - preferences and corrections the user gave
  - non-obvious gotchas discovered the hard way

Ignore: routine tool calls, code already committed, anything reconstructible from the
repo, anything that only mattered inside this one session, and your own suggestions the
user did not adopt. Never record credentials, tokens or keys — name where they live
(the 1Password item) instead. No L'Oreal internals beyond role, tooling and
architecture. No family detail finer than "Tours region".

If nothing is worth remembering — the common case — output exactly: NONE

Otherwise output exactly this shape, no preamble, no code fences:

TITLE: <one line, no leading #>
TYPE: <fact | decision | runbook | gotcha | incident>
PROJECTS: <comma-separated entity slugs this is about (e.g. vps, agent-memory), or empty>
TAGS: <comma-separated, only from: decision runbook gotcha incident work perso>
BODY:
# <the title again, as an H1>

<2-5 sentences, self-contained: dates, hostnames, paths. A decision uses:
**Why:** <the deciding reason, alternatives rejected if any>
**Scope:** <what it applies to; effective date>
and must be the user's own decision, stated by them — never one you inferred.>
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

# --- Compose the capture ------------------------------------------------------
title=$(printf '%s\n' "$learnings" | grep -m1 '^TITLE:' | sed 's/^TITLE:[[:space:]]*//')
kind=$(printf '%s\n' "$learnings" | grep -m1 '^TYPE:' | sed 's/^TYPE:[[:space:]]*//' \
         | tr '[:upper:]' '[:lower:]' | tr -d ' ')
projects=$(printf '%s\n' "$learnings" | grep -m1 '^PROJECTS:' | sed 's/^PROJECTS:[[:space:]]*//')
tags=$(printf '%s\n' "$learnings" | grep -m1 '^TAGS:' | sed 's/^TAGS:[[:space:]]*//' \
         | tr '[:upper:]' '[:lower:]')
body=$(printf '%s\n' "$learnings" | sed -n '/^BODY:[[:space:]]*$/,$p' | sed '1d')

# Malformed answer (an older model, a truncated reply) — nothing safe to file.
[ -z "$title" ] && exit 0
[ -z "$body" ] && exit 0
printf '%s' "$body" | grep -q '^# ' || body=$(printf '# %s\n\n%s' "$title" "$body")

case "$kind" in
  fact|decision|runbook|gotcha|incident) ;;
  *) kind="fact" ;;
esac

# Only vocab.md tags survive distillation; anything else is noise. Keep a sphere tag.
clean_list() {  # clean_list "<csv>" "<allowed…>" — echoes a YAML inline list
  local csv="$1"; shift
  local allowed=" $* " item out=""
  IFS=','; for item in $csv; do
    item=$(printf '%s' "$item" | tr -d '[:space:]')
    [ -z "$item" ] && continue
    if [ $# -eq 0 ] || case "$allowed" in *" $item "*) true;; *) false;; esac; then
      case ",$out," in *",$item,"*) ;; *) out="${out:+$out,}$item" ;; esac
    fi
  done
  unset IFS
  printf '%s' "$out"
}

tags=$(clean_list "$tags" decision runbook gotcha incident work perso)
case ",$tags," in *,work,*|*,perso,*) ;; *) tags="${tags:+$tags,}perso" ;; esac
projects=$(clean_list "$projects")

today=$(date +%F)
slug=$(slugify "$title")
[ -z "$slug" ] && slug="session-capture"

content=$(printf -- '---\ntype: %s\nprojects: [%s]\ntags: [%s]\nsource: %s\ncreated: %s\n---\n%s' \
  "$kind" "${projects//,/, }" "${tags//,/, }" "$SOURCE" "$today" "$body")
content+=$'\n'   # command substitution eats trailing newlines; notes end with one

base="inbox/${today}-${SOURCE}-${slug}"
path="${base}.md"

# --- Write --------------------------------------------------------------------
# 1. Local vault: this machine syncs the vault, so writing the file IS the write.
if [ -n "$VAULT" ] && [ -d "$VAULT/inbox" ]; then
  n=2
  while [ -e "$VAULT/$path" ] && [ "$n" -le 9 ]; do path="${base}-${n}.md"; n=$((n + 1)); done
  if [ ! -e "$VAULT/$path" ]; then
    printf '%s' "$content" > "$VAULT/$path" && exit 0
  fi
fi

# 2. obsidian MCP with a bearer. Only ever write to a path proved free: if the listing
#    itself fails we know nothing, so fall through to staging rather than risk
#    replacing a note.
if [ -n "$MCP_TOKEN" ] && mcp_init; then
  free_path="" candidate="$base" n=2
  while [ "$n" -le 10 ]; do
    if path_free "$candidate"; then free_path="$candidate"; break; fi
    candidate="inbox/${today}-${SOURCE}-${slug}-${n}"; n=$((n + 1))
  done
  if [ -n "$free_path" ]; then
    path="${free_path}.md"
    if mcp_call vault_write_note \
        "$(jq -nc --arg v "$VAULT_ID" --arg p "$path" --arg t "$content" \
             '{vaultId:$v,path:$p,text:$t,confirm:true}')" >/dev/null; then
      exit 0
    fi
  fi
fi

# 3. No write rail. Stage it for the next session's SessionStart hook, which asks the
#    model — which does have the MCP — to file it. First line names the vault path.
mkdir -p "$PENDING_DIR"
staged="$PENDING_DIR/$(printf '%s' "$path" | tr '/' '_')"
n=2
while [ -e "$staged" ] && [ "$n" -le 9 ]; do
  staged="$PENDING_DIR/$(printf '%s' "${base}-${n}.md" | tr '/' '_')"; n=$((n + 1))
done
printf '<!-- vault-path: %s -->\n%s' "$path" "$content" > "$staged" 2>/dev/null

exit 0
