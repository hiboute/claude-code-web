#!/usr/bin/env bash
# claude-code-web installer test harness.
# Runs install.sh in a fresh ubuntu:noble Docker container and asserts that
# every expected binary, skill symlink, and config entry is present.
# Also runs the installer a second time to smoke-test idempotence.

set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found; test.sh requires Docker to run install.sh in isolation." >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The GitHub token needed for hiboute/skills (private). Optional: the hiboute
# step is allowed to fail without failing the overall test, since not every
# contributor has access to that repo.
GH_TOKEN_ARG=()
if [ -n "${GH_TOKEN:-}" ]; then
  GH_TOKEN_ARG=(-e "GH_TOKEN=${GH_TOKEN}")
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  GH_TOKEN_ARG=(-e "GITHUB_TOKEN=${GITHUB_TOKEN}")
fi

echo "==> Running install.sh in ubuntu:noble (+ running it twice for idempotence)..."
docker run --rm \
  -v "${SCRIPT_DIR}:/work:ro" \
  "${GH_TOKEN_ARG[@]}" \
  ubuntu:noble \
  bash -c '
    set -e
    apt-get update >/dev/null 2>&1
    apt-get install -y --no-install-recommends \
      sudo ca-certificates curl git gnupg nodejs npm >/dev/null 2>&1
    cp /work/install.sh /root/install.sh
    chmod +x /root/install.sh

    echo "--- first run ---"
    /root/install.sh || echo "(first run exited non-zero; may be hiboute-skills without token)"

    echo "--- second run (idempotence) ---"
    /root/install.sh || echo "(second run exited non-zero; may be hiboute-skills without token)"

    echo "--- assertions ---"
    fail=0
    for bin in gh rg fd jq shellcheck sqlite3 tree uv pnpm; do
      if command -v "$bin" >/dev/null 2>&1; then
        echo "  ok: $bin on PATH ($(command -v "$bin"))"
      else
        echo "  FAIL: $bin not on PATH"
        fail=1
      fi
    done

    # op (1Password CLI) may not install on every sandbox; warn but do not fail.
    if command -v op >/dev/null 2>&1; then
      echo "  ok: op on PATH"
    else
      echo "  warn: op not on PATH (1Password CLI skipped?)"
    fi

    anthro_link="$HOME/.claude/skills/anthropic:skill-creator"
    if [ -L "$anthro_link" ] && [ -f "$anthro_link/SKILL.md" ]; then
      echo "  ok: $anthro_link resolves to a SKILL.md"
    else
      echo "  FAIL: $anthro_link missing or does not resolve to SKILL.md"
      fail=1
    fi

    if jq -e ".mcpServers.context7" "$HOME/.claude.json" >/dev/null 2>&1; then
      echo "  ok: ~/.claude.json has .mcpServers.context7"
    else
      echo "  FAIL: ~/.claude.json missing .mcpServers.context7"
      fail=1
    fi

    if [ "$fail" -eq 0 ]; then
      echo "--- PASS ---"
    else
      echo "--- FAIL ---"
    fi
    exit "$fail"
  '
