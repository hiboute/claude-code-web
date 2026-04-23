# claude-code-web

Bootstrap script for [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web) sandboxes.

Installs:
- [1Password CLI](https://developer.1password.com/docs/cli/) (`op`)
- [Superpowers plugin](https://github.com/obra/superpowers) — into `~/.claude/plugins/superpowers`
- [gstack skills](https://github.com/garrytan/gstack) — into `~/.claude/skills/gstack`
- [Hiboute skills](https://github.com/hiboute/skills) — into `~/.claude/skills/hiboute-skills`
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
