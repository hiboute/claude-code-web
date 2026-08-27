# claude-code-web

Bootstrap script for [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web) sandboxes.

Installs:
- [GitHub CLI](https://cli.github.com/) (`gh`)
- [1Password CLI](https://developer.1password.com/docs/cli/) (`op`)
- [gstack skills](https://github.com/garrytan/gstack) — into `~/.claude/skills/gstack`
- [Hiboute skills](https://github.com/hiboute/skills) — into `~/.claude/skills/hiboute-skills`
- A skills + memory reference block in `~/.claude/CLAUDE.md`
- **Agent-memory hooks** in `~/.claude/settings.json` — `SessionStart` injects `core.md`
  into context, `SessionEnd` captures the finished session into the vault's inbox. The
  two hook scripts (`inject-core.sh`, `capture-remote.sh`) live **in this repo**: they
  contain nothing sensitive, which is what keeps every fetch anonymous.

Memory is the Obsidian vault **`homelab`**, read and written through the **`obsidian`**
MCP (`https://mcp-obsidian.chrobiche.workers.dev/mcp`, a Cloudflare Worker over YAOS).
The **`homelab-memory` skill** — synced to `~/.claude/skills`, not installed from here
— is the governing contract: recall path, the vault's own `rules.md`, and the capture
format the hooks emit. (It cannot be called `memory`: that name collides with Claude
Code's built-in `/memory` command and the Skill tool refuses to load it.) The git rail is retired: no `hiboute/memory` clone, no `gh api`, no
`Memory` connector (`memory_get_core` / `memory_append`).

## Why

Claude Code on the web can't run `claude plugin install` — the command hangs. Anthropic's documented workaround is a [`SessionStart` hook](https://code.claude.com/docs/en/claude-code-on-the-web#dependency-management) that runs a dependency-install script from your repo. This is that script.

## Usage

Two ways to run it. The installer is idempotent, so either (or both) is safe.

**As the cloud environment's setup script** — recommended; runs at environment boot,
before any session, so hooks and skills are in place from the first prompt:

```bash
curl -fsSL https://raw.githubusercontent.com/hiboute/claude-code-web/main/install.sh | bash
```

**As a per-repo `SessionStart` hook** — for repos used outside a configured
environment. Add `.claude/settings.json` to the repo:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "bash -lc 'set -euo pipefail; tmp=$(mktemp); curl -fsSL https://raw.githubusercontent.com/hiboute/claude-code-web/main/install.sh -o \"$tmp\"; chmod +x \"$tmp\"; \"$tmp\"; rm -f \"$tmp\"'"
          }
        ]
      }
    ]
  }
}
```

## Environment configuration

The memory hooks read these from the cloud environment's secrets:

| Secret | Why |
|---|---|
| `OBSIDIAN_MCP_TOKEN` | bearer for the `obsidian` MCP endpoint. Optional but load-bearing: with it the hooks read `core.md` and write the capture themselves; without it they degrade (see below) |
| `AGENT_MEMORY_SOURCE=ccr` | sandbox hostnames are random container IDs; this names the capture files and the `source:` frontmatter key. Defaults to `ccr` |
| `ANTHROPIC_API_KEY` | optional — summariser fallback for when a nested `claude -p` cannot authenticate |

Optional overrides, all with working defaults: `AGENT_MEMORY_VAULT_ID` (`homelab`),
`AGENT_MEMORY_MCP_URL` (the Worker), `AGENT_MEMORY_VAULT` (path to a locally synced copy
of the vault — set on a Mac running Obsidian, never in a sandbox), `AGENT_MEMORY_LLM_URL`
and `AGENT_MEMORY_LLM_MODEL`.

**Hook processes never see environment secrets** — secrets load after hooks, which
is also why this repo is public. The setup script is the actor that has them, so it
persists what the hooks need to `~/.config/agent-memory/` and fetches the hook scripts
from this repo into `~/.local/bin` — anonymously, since nothing in them is sensitive.

### What the hooks do without a bearer

A hook is a shell command, not a model, so it **cannot call an MCP tool** — the single
most expensive gotcha of this system. Each hook therefore has rails, and the last one
needs no credential at all:

| | with `OBSIDIAN_MCP_TOKEN` (or a local vault) | without |
|---|---|---|
| `SessionStart` | reads `core.md` + the hub matching this repo (via `INDEX.md`) and injects them | injects the *contract* instead: the session loads `core.md` through the `obsidian` MCP with its own first tool call |
| `SessionEnd` | summarises the session and writes one new file under `inbox/` | stages the composed note in `~/.cache/agent-memory/pending/`, which the next `SessionStart` hands to the model to file |

A session without the bearer is degraded, not broken — but note what staging can and
cannot do: it defers the write on a machine that persists (a Mac), and a cloud sandbox
is reclaimed at session end, so there the staged file dies with the container. In a
sandbox, `OBSIDIAN_MCP_TOKEN` is what makes capture durable; without it the read path
still works (the session loads `core.md` itself) but the capture is best-effort.

## Running locally

The installer targets Debian/Ubuntu (what claude.ai/code runs). Running it on macOS
will fail with a clear error.

```bash
curl -fsSL https://raw.githubusercontent.com/hiboute/claude-code-web/main/install.sh | bash
```
