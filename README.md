# claude-code-web

Bootstrap script for [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web) sandboxes.

Installs:
- [GitHub CLI](https://cli.github.com/) (`gh`)
- [1Password CLI](https://developer.1password.com/docs/cli/) (`op`)
- [gstack skills](https://github.com/garrytan/gstack) — into `~/.claude/skills/gstack`
- [Hiboute skills](https://github.com/hiboute/skills) — into `~/.claude/skills/hiboute-skills`
- A skills reference block in `~/.claude/CLAUDE.md`
- **Agent-memory hooks** in `~/.claude/settings.json` — `SessionStart` injects `core.md`
  into context, `SessionEnd` captures the finished session into the vault's inbox. Both
  hooks fetch their scripts at run time from the private
  [hiboute/memory](https://github.com/hiboute/memory) repo via the GitHub contents API;
  that repo's README documents how the memory system works.

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
| `AGENT_MEMORY_GH_TOKEN` | fine-grained PAT, **Contents read + write** on `hiboute/memory` — capture PUTs new inbox files, it does not just read. Do **not** name it `GH_TOKEN`: the platform injects its own token under that name, scoped to the session's repo, and it 403s against the vault |
| `AGENT_MEMORY_SOURCE=cloud` | sandbox hostnames are random container IDs; this names the inbox files |
| `ANTHROPIC_API_KEY` | optional — summariser fallback for when a nested `claude -p` cannot authenticate (see "Which Haiku answers" in the memory README) |

Without a token (`AGENT_MEMORY_GH_TOKEN`, falling back to `GH_TOKEN`), both memory
hooks exit 0 before touching the network: a sandbox without memory is degraded, not
broken.

## Running locally

The installer targets Debian/Ubuntu (what claude.ai/code runs). Running it on macOS
will fail with a clear error.

```bash
curl -fsSL https://raw.githubusercontent.com/hiboute/claude-code-web/main/install.sh | bash
```
