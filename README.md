# claude-code-web

Bootstrap script for [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web) sandboxes.

Installs:
- [GitHub CLI](https://cli.github.com/) (`gh`)
- [1Password CLI](https://developer.1password.com/docs/cli/) (`op`)
- Agent CLI tools: `ripgrep`, `fd-find` (+ `fd` alias), `jq`, `shellcheck`, `sqlite3`, `tree`
- Runtimes: [`uv`](https://github.com/astral-sh/uv) (Python), `pnpm` (via `corepack enable`)
- [Superpowers plugin](https://github.com/obra/superpowers) — into `~/.claude/plugins/superpowers`
- [gstack skills](https://github.com/garrytan/gstack) — into `~/.claude/skills/gstack`
- [Hiboute skills](https://github.com/hiboute/skills) — into `~/.claude/skills/hiboute-skills`
- [Anthropic skills](https://github.com/anthropics/skills) — into `~/.claude/plugins/anthropic-skills`, symlinked as `~/.claude/skills/anthropic:*`
- [Context7 MCP server](https://github.com/upstash/context7) — seeded in `~/.claude.json`
- Appends a skills reference block to `~/.claude/CLAUDE.md`

## Why

Claude Code on the web can't run `claude plugin install` — the command hangs (see [obra/superpowers#262](https://github.com/obra/superpowers/issues/262)). Anthropic's documented workaround is a [`SessionStart` hook](https://code.claude.com/docs/en/claude-code-on-the-web#dependency-management) that runs a dependency-install script from your repo. This is that script.

## Usage

In the repo you use on claude.ai/code, add `.claude/settings.json`:

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

Every web session will now run `install.sh` at startup.

## Running locally

The installer targets Debian/Ubuntu (what claude.ai/code runs). Running it on macOS will fail with a clear error.

```bash
curl -fsSL https://raw.githubusercontent.com/hiboute/claude-code-web/main/install.sh | bash
```

## Environment variables

- `SUPERPOWERS_REPO_URL` — override the Superpowers clone URL
- `SUPERPOWERS_REPO_REF` — branch or tag to check out (default `main`)

## Notes

- **Context7 MCP approval prompt** — the installer seeds `~/.claude.json` with the Context7 MCP server. The Claude Code harness may prompt you to approve the MCP server on first use in a session. One-time click, then cached.
- **Idempotent** — re-running `install.sh` is safe; each step guards against existing installs and falls back to a no-op.
- **Per-step failure isolation** — one failing step logs a `WARN` and is recorded in `FAILED_STEPS`; the rest of the installer still runs. Exit code is `1` if any step failed, `0` otherwise.

## Testing

`test.sh` runs the installer inside a fresh `ubuntu:noble` Docker container and asserts every binary is on PATH, `anthropic:*` skills are symlinked, and `~/.claude.json` has the Context7 MCP entry. Also runs the installer twice to smoke-test idempotence.

```bash
./test.sh
```

Requires Docker. The Hiboute step (private repo) is allowed to fail without failing the overall test.
