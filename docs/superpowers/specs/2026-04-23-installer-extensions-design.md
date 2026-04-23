# Installer extensions: agent toolbox

Date: 2026-04-23
Status: Draft (awaiting user review)
Repo: hiboute/claude-code-web

## Goal

Extend `install.sh` so every Claude Code on the web sandbox boots with a richer
agent-facing toolbox: a small set of CLI tools, two language runtimes, one
additional skill source, and one MCP server.

Scope is opinionated for personal use (single owner). Startup time is not a
constraint.

## Non-goals

- Human-ergonomics tools the agent does not use (fzf, bat, delta, direnv, starship)
- A pluggable extras-hook escape hatch (rejected during brainstorming)
- Pinning binary versions for reproducibility (current script does not pin gh or
  op either; consistency wins; revisit later if drift becomes an issue)
- Supporting non-Debian/Ubuntu hosts (existing platform guard remains)

## Architecture

Four new step functions are added, plus a text-only update to the existing
`update_claude_md` block. All steps are routed through the existing `run_step`
wrapper so a single failure does not abort the rest of the installer. Each
function is idempotent — re-running the installer is safe.

Step order in `main()`:

```
install_gh_cli            (existing)
install_1password_cli     (existing)
install_extra_cli_tools   (NEW)
install_runtimes          (NEW)
install_superpowers       (existing)
install_gstack            (existing)
install_hiboute_skills    (existing)
install_anthropic_skills  (NEW)
install_context7_mcp      (NEW)
update_claude_md          (existing, with updated block text)
```

`install_context7_mcp` runs after `install_extra_cli_tools` because it depends
on `jq`. All other ordering is preserved.

## Components

### `install_extra_cli_tools`

Single batched apt install:

```
sudo apt-get install -y ripgrep fd-find jq shellcheck sqlite3 tree
```

Post-install: `sudo ln -sfn /usr/bin/fdfind /usr/local/bin/fd` so the agent can
invoke `fd` directly (Debian ships the binary as `fdfind`).

Step is skipped entirely if all six binaries (`rg`, `fd`, `jq`, `shellcheck`,
`sqlite3`, `tree`) are already on PATH; otherwise the full apt batch runs
(apt-get is a no-op for already-installed packages, so partial state is handled
cleanly). The `fd` symlink is created unconditionally with `ln -sfn` (idempotent).
If `apt-get install` fails, the step logs WARN and is recorded in `FAILED_STEPS`.

### `install_runtimes`

- **uv (Python):** if `command -v uv` already passes, skip. Otherwise download
  `https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz`
  to a temp dir (`mktemp -d`), extract with `tar -xzf`, then
  `sudo mv` the `uv` binary to `/usr/local/bin/uv` and `chmod +x`. Clean up the
  temp dir. `/usr/local/bin` is on the default PATH so no shell-rc fiddling is
  required.
- **pnpm (Node):** run `corepack enable pnpm`. Node and corepack are
  preinstalled on claude.ai/code sandboxes. Skip if `command -v pnpm` already
  passes. If `corepack` is missing, log WARN and record in `FAILED_STEPS`.

### `install_anthropic_skills`

Reuses `clone_or_update`:

- Clone `https://github.com/anthropics/skills.git` (branch `main`, depth 1)
  into `~/.claude/plugins/anthropic-skills`.
- Iterate `~/.claude/plugins/anthropic-skills/skills/*/`.
- For each subdirectory, `ln -sfn` it into
  `~/.claude/skills/anthropic:<name>` (mirrors the existing `superpowers:`
  prefix pattern; avoids collisions with other providers).
- If the upstream `skills/` folder is missing, log WARN and return without
  failing the rest of the installer.

### `install_context7_mcp`

Target file: `~/.claude.json` (Claude Code global config).

Operation: idempotent `jq` merge.

- If file does not exist: create with
  ```json
  { "mcpServers": { "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] } } }
  ```
- If file exists and lacks `.mcpServers`: add the key.
- If file exists and has `.mcpServers.context7`: leave as-is (no overwrite —
  user may have customized).
- All other keys preserved verbatim.

Implementation sketch:

```bash
local cfg="${HOME}/.claude.json"
[ -f "${cfg}" ] || echo '{}' > "${cfg}"
jq '
  .mcpServers //= {} |
  if .mcpServers.context7 then .
  else .mcpServers.context7 = { command: "npx", args: ["-y", "@upstash/context7-mcp"] }
  end
' "${cfg}" > "${cfg}.tmp" && mv "${cfg}.tmp" "${cfg}"
```

Caveat: the Claude Code web harness may prompt the user to approve the MCP
server on first use of a session. This is a one-time click per session-start;
acceptable. Documented in README.

### `update_claude_md`

The existing function is unchanged in mechanics. The block text returned by
`render_skills_block` gains two new sections appended after the existing three:

```
## Anthropic skills

Available skills: /anthropic:skill-creator /anthropic:mcp-builder
/anthropic:frontend-design /anthropic:webapp-testing /anthropic:claude-api
/anthropic:doc-coauthoring /anthropic:docx /anthropic:pdf /anthropic:pptx
/anthropic:xlsx /anthropic:brand-guidelines /anthropic:canvas-design
/anthropic:algorithmic-art /anthropic:theme-factory /anthropic:internal-comms
/anthropic:slack-gif-creator /anthropic:web-artifacts-builder

Cloned to ~/.claude/plugins/anthropic-skills, symlinked into ~/.claude/skills/
with the `anthropic:` prefix.

## Context7 MCP

Up-to-date library docs via `npx -y @upstash/context7-mcp`. Seeded in
~/.claude.json by the installer. First use in a session may show a one-time
approval prompt.
```

The existing sentinel-based replace-block logic handles the new content; no
changes to the `awk`/`sed` repair path.

## Data flow

1. SessionStart hook fires `install.sh`.
2. Each `run_step` invocation runs its function in a subshell.
3. Idempotent guards (`command -v`, file-exists checks, `jq` merges,
   `git remote set-url` + `reset --hard`, `ln -sfn`) make every step safe to
   re-run on every session.
4. Failures are collected in `FAILED_STEPS` and reported at the end with
   exit code 1; successful steps still take effect.

## Error handling

- Apt batch: any package failing to install fails the whole step (apt's normal
  behavior). Logged to `FAILED_STEPS`. Other steps continue.
- uv tarball download: if `curl` or `tar` fails, log WARN; step recorded as
  failed; installer continues.
- corepack pnpm: if `corepack` missing or `enable pnpm` fails, log WARN; step
  recorded as failed; installer continues.
- Anthropic skills clone: existing `clone_or_update` semantics (network failure
  → step fails, others continue).
- Context7 MCP merge: if `jq` is unavailable (because `install_extra_cli_tools`
  failed), the step logs WARN and is skipped; installer continues.
- All filesystem writes use `mv` from a `.tmp` file to avoid leaving
  half-written config on crash.

## Testing

Add `test.sh` at repo root. It runs the installer in a fresh `ubuntu:noble`
Docker container and asserts:

- Each binary is on PATH inside the container: `gh op rg fd jq shellcheck
  sqlite3 tree uv pnpm`.
- `~/.claude/skills/anthropic:skill-creator` is a valid symlink resolving to a
  real `SKILL.md`.
- `jq -e '.mcpServers.context7' ~/.claude.json` succeeds.
- Running `install.sh` a second time inside the same container exits 0 with no
  errors (idempotence smoke test).

The test is invoked manually (`./test.sh`); no CI integration in this spec.
The test depends on `docker` being available locally; if not, it prints a
clear error and exits non-zero.

## README updates

Append a "What gets installed" section listing:

- Existing: gh, op, Superpowers, gstack, Hiboute skills, CLAUDE.md block
- New: ripgrep, fd-find (`fd`), jq, shellcheck, sqlite3, tree, uv, pnpm,
  Anthropic skills, Context7 MCP server

Document the one-time MCP approval prompt caveat under a new "Notes" subsection.

## Out of scope (future work)

- Pinning binary versions (uv, gh, op) for reproducibility
- CI integration for `test.sh`
- Additional MCP servers (Playwright, memory, fetch — explicitly deferred during
  brainstorming)
- Generic `EXTRA_SKILL_REPOS` env-var pluggability
