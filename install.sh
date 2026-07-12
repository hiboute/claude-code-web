#!/usr/bin/env bash
# claude-code-web installer
# Bootstraps dependencies for Claude Code on the web (claude.ai/code) sandboxes:
#   - 1Password CLI
#   - gstack skills       (garrytan/gstack)
#   - Hiboute skills      (hiboute/skills)
#   - Appends a skills reference block to ~/.claude/CLAUDE.md
#   - Memory hooks (inject-core.sh / capture-remote.sh) into ~/.claude/settings.json
#
# Usage as a SessionStart hook (.claude/settings.json):
#   bash -lc 'curl -fsSL https://raw.githubusercontent.com/hiboute/claude-code-web/main/install.sh | bash'

set -euo pipefail

log() { printf '[claude-code-web] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# --- Platform guard ----------------------------------------------------------
if ! command -v apt-get >/dev/null 2>&1; then
  die "apt-get not found. This installer targets Debian/Ubuntu sandboxes (e.g. claude.ai/code)."
fi
command -v git >/dev/null 2>&1 || die "git is required."

CLAUDE_HOME="${HOME}/.claude"
mkdir -p "${CLAUDE_HOME}/plugins" "${CLAUDE_HOME}/skills"

# --- GitHub CLI --------------------------------------------------------------
# Installed first because install_hiboute_skills falls back to `gh auth token`
# when GITHUB_TOKEN isn't set. Also a convenience for interactive work.
install_gh_cli() {
  if command -v gh >/dev/null 2>&1; then
    log "GitHub CLI already installed ($(gh --version | head -1)); skipping."
    return 0
  fi

  log "Installing GitHub CLI..."
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none
  sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null

  sudo apt-get update \
    -o Acquire::AllowInsecureRepositories=true \
    -o Acquire::AllowDowngradeToInsecureRepositories=true \
    2>/dev/null || true

  sudo apt-get install -y --allow-unauthenticated gh
  log "GitHub CLI installed: $(gh --version | head -1)"
}

# --- 1Password CLI -----------------------------------------------------------
install_1password_cli() {
  if command -v op >/dev/null 2>&1; then
    log "1Password CLI already installed ($(op --version)); skipping."
    return 0
  fi

  log "Installing 1Password CLI..."
  curl -fsSL https://downloads.1password.com/linux/keys/1password.asc \
    | sudo gpg --dearmor --yes --output /usr/share/keyrings/1password-archive-keyring.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" \
    | sudo tee /etc/apt/sources.list.d/1password.list >/dev/null

  sudo apt-get update \
    -o Acquire::AllowInsecureRepositories=true \
    -o Acquire::AllowDowngradeToInsecureRepositories=true \
    2>/dev/null || true

  sudo apt-get install -y --allow-unauthenticated 1password-cli
  log "1Password CLI installed: $(op --version)"
}

# --- Clone-or-update helper --------------------------------------------------
# Idempotent: clones shallow on first run, fetches + resets on subsequent runs.
clone_or_update() {
  local name="$1" url="$2" ref="$3" dest="$4"
  if [ -d "${dest}/.git" ]; then
    log "Updating ${name} in ${dest}"
    git -C "${dest}" remote set-url origin "${url}"
    git -C "${dest}" fetch --depth 1 origin "${ref}"
    git -C "${dest}" reset --hard FETCH_HEAD >/dev/null
  else
    log "Cloning ${name} into ${dest}"
    rm -rf "${dest}"
    git clone --single-branch --depth 1 --branch "${ref}" "${url}" "${dest}"
  fi
}

# --- gstack skills -----------------------------------------------------------
install_gstack() {
  local dest="${CLAUDE_HOME}/skills/gstack"
  clone_or_update "gstack" "https://github.com/garrytan/gstack.git" "main" "${dest}"
  if [ -x "${dest}/setup" ]; then
    log "Running gstack ./setup"
    (cd "${dest}" && ./setup) || log "WARN: gstack setup exited non-zero (continuing)"
  fi
}

# --- Hiboute skills ----------------------------------------------------------
# hiboute/skills is public. We still honor a token if one is available so the
# installer keeps working if the repo ever flips back to private. Credential
# sources (in order):
#   1. $GH_TOKEN env var       (claude.ai/code cloud runs expose this name)
#   2. $GITHUB_TOKEN env var   (GitHub Actions convention)
#   3. `gh auth token`         (if gh is installed and authenticated)
#   4. Anonymous clone         (works while the repo is public)
install_hiboute_skills() {
  local dest="${CLAUDE_HOME}/skills/hiboute-skills"
  local token=""

  if [ -n "${GH_TOKEN:-}" ]; then
    token="${GH_TOKEN}"
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    token="${GITHUB_TOKEN}"
  elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    token="$(gh auth token 2>/dev/null || true)"
  fi

  local url
  if [ -n "${token}" ]; then
    url="https://x-access-token:${token}@github.com/hiboute/skills.git"
  else
    url="https://github.com/hiboute/skills.git"
  fi

  clone_or_update "hiboute-skills" "${url}" "main" "${dest}"
  if [ -x "${dest}/setup" ]; then
    log "Running hiboute-skills ./setup"
    (cd "${dest}" && ./setup) || log "WARN: hiboute-skills setup exited non-zero (continuing)"
  fi
}

# --- CLAUDE.md reference block ----------------------------------------------
# Appends a skills reference block to ~/.claude/CLAUDE.md, guarded by a
#   - Memory hooks (inject-core.sh / capture-remote.sh) into ~/.claude/settings.json
# sentinel marker so re-runs don't duplicate the section.
SENTINEL_BEGIN="<!-- claude-code-web:skills-ref BEGIN -->"
SENTINEL_END="<!-- claude-code-web:skills-ref END -->"

update_claude_md() {
  local claude_md="${CLAUDE_HOME}/CLAUDE.md"
  touch "${claude_md}"

  local block
  block="$(printf '%s\n%s\n%s\n' "${SENTINEL_BEGIN}" "$(render_skills_block)" "${SENTINEL_END}")"

  if grep -qF "${SENTINEL_BEGIN}" "${claude_md}"; then
    # Replace existing block. If the END sentinel is missing (interrupted
    # prior run), truncate from BEGIN to EOF and treat it as a repair.
    if ! grep -qF "${SENTINEL_END}" "${claude_md}"; then
      log "Repairing broken sentinels in ${claude_md}"
      sed -i "/${SENTINEL_BEGIN}/,\$d" "${claude_md}"
      printf '\n%s\n' "${block}" >> "${claude_md}"
    else
      log "Refreshing skills block in ${claude_md}"
      awk -v begin="${SENTINEL_BEGIN}" -v end="${SENTINEL_END}" -v repl="${block}" '
        $0 ~ begin { print repl; skip=1; next }
        skip && $0 ~ end { skip=0; next }
        !skip { print }
      ' "${claude_md}" > "${claude_md}.tmp" && mv "${claude_md}.tmp" "${claude_md}"
    fi
  else
    log "Appending skills block to ${claude_md}"
    printf '\n%s\n' "${block}" >> "${claude_md}"
  fi
}

render_skills_block() {
  cat <<'EOF'
## gstack skills

Use the `/browse` skill from gstack for all web browsing. Never use `mcp__claude-in-chrome__*` tools.

Available gstack skills:

/office-hours /plan-ceo-review /plan-eng-review /plan-design-review
/design-consultation /design-shotgun /design-html /review /ship
/land-and-deploy /canary /benchmark /browse /connect-chrome /qa
/qa-only /design-review /setup-browser-cookies /setup-deploy /retro
/investigate /document-release /codex /cso /autoplan /plan-devex-review
/devex-review /careful /freeze /guard /unfreeze /gstack-upgrade /learn

Install with: `git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack && cd ~/.claude/skills/gstack && ./setup`

## Hiboute skills

Available skills: `/ideation` `/roadmap` `/autopilot`

Install with: `gh repo clone hiboute/skills ~/.claude/skills/hiboute-skills && ~/.claude/skills/hiboute-skills/setup`
Update with: `~/.claude/skills/hiboute-skills/bin/hiboute-skills-upgrade`
EOF
}

# --- Memory hooks -------------------------------------------------------------
# The environment setup script is the ONLY actor that runs with the environment
# secrets in hand — hook processes never see them (secrets load after hooks),
# which is also why this repo is public. So this step bridges through files:
#   1. persist AGENT_MEMORY_GH_TOKEN, ANTHROPIC_API_KEY, AGENT_MEMORY_SOURCE
#      into ~/.config/agent-memory/ (0600)
#   2. pre-fetch inject-core.sh + capture-remote.sh from the private
#      hiboute/memory repo into ~/.local/bin, authenticated, at setup time
#   3. write SessionStart/SessionEnd hooks that run those local copies —
#      no fetch, no env secret needed at hook time
# Without a token this logs and skips: a sandbox without memory is degraded,
# not broken.
install_memory_hooks() {
  local settings="${CLAUDE_HOME}/settings.json"
  local bin="${HOME}/.local/bin"
  local cfg="${HOME}/.config/agent-memory"
  local token="${AGENT_MEMORY_GH_TOKEN:-${GH_TOKEN:-}}"

  mkdir -p "${bin}" "${cfg}"
  chmod 700 "${cfg}"

  # 1. Persist secrets for the hooks.
  if [ -n "${AGENT_MEMORY_GH_TOKEN:-}" ]; then
    printf '%s' "${AGENT_MEMORY_GH_TOKEN}" > "${cfg}/gh-token" && chmod 600 "${cfg}/gh-token"
    log "Persisted AGENT_MEMORY_GH_TOKEN to ${cfg}/gh-token"
  else
    log "AGENT_MEMORY_GH_TOKEN not visible at setup time — memory hooks will be inert."
  fi
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    printf '%s' "${ANTHROPIC_API_KEY}" > "${cfg}/llm-key" && chmod 600 "${cfg}/llm-key"
    log "Persisted ANTHROPIC_API_KEY to ${cfg}/llm-key"
  fi
  printf '%s' "${AGENT_MEMORY_SOURCE:-cloud}" > "${cfg}/source"

  # 2. Pre-fetch the hook scripts, authenticated.
  if [ -n "${token}" ]; then
    local s rc=0
    for s in inject-core.sh capture-remote.sh; do
      if curl -fsSL -m 15 \
          -H "Authorization: Bearer ${token}" \
          -H "Accept: application/vnd.github.raw" \
          "https://api.github.com/repos/hiboute/memory/contents/${s}?ref=main" \
          -o "${bin}/${s}"; then
        chmod +x "${bin}/${s}"
        log "Fetched ${s} -> ${bin}/${s}"
      else
        log "WARN: could not fetch ${s} (403 = token cannot see hiboute/memory)"
        rc=1
      fi
    done
    [ "${rc}" -ne 0 ] && return 1
  fi

  # 3. Write the hooks. They run local files only.
  if [ -s "${settings}" ] && grep -q "capture-remote.sh" "${settings}"; then
    log "Memory hooks already present in ${settings}; skipping."
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}" <<'HOOKS_EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear",
        "hooks": [
          {
            "type": "command",
            "command": "bash -lc '[ -x \"$HOME/.local/bin/inject-core.sh\" ] || exit 0; exec \"$HOME/.local/bin/inject-core.sh\"'",
            "timeout": 20
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash -lc '[ -x \"$HOME/.local/bin/capture-remote.sh\" ] || exit 0; exec \"$HOME/.local/bin/capture-remote.sh\"'",
            "timeout": 120
          }
        ]
      }
    ]
  }
}
HOOKS_EOF

  if [ -s "${settings}" ]; then
    # Merge into existing settings; our hook groups win on key collision.
    if command -v jq >/dev/null 2>&1; then
      log "Merging memory hooks into existing ${settings}"
      jq -s '.[0] * .[1]' "${settings}" "${tmp}" > "${settings}.new" \
        && mv "${settings}.new" "${settings}"
    else
      log "WARN: jq missing and ${settings} non-empty; leaving it untouched."
      rm -f "${tmp}"
      return 1
    fi
    rm -f "${tmp}"
  else
    log "Writing memory hooks to ${settings}"
    mv "${tmp}" "${settings}"
  fi
}
HOOKS_EOF

  if [ -s "${settings}" ]; then
    # Merge into existing settings; our hook groups win on key collision.
    if command -v jq >/dev/null 2>&1; then
      log "Merging memory hooks into existing ${settings}"
      jq -s '.[0] * .[1]' "${settings}" "${tmp}" > "${settings}.new" \
        && mv "${settings}.new" "${settings}"
    else
      log "WARN: jq missing and ${settings} non-empty; leaving it untouched."
      rm -f "${tmp}"
      return 1
    fi
    rm -f "${tmp}"
  else
    log "Writing memory hooks to ${settings}"
    mv "${tmp}" "${settings}"
  fi
}

# --- Main --------------------------------------------------------------------
# Each step runs in a subshell so a single failure doesn't abort the rest.
# Subshell exit codes are captured; we track whether any step failed.
run_step() {
  local name="$1"; shift
  if ( "$@" ); then
    return 0
  else
    log "WARN: step '${name}' failed (continuing)"
    FAILED_STEPS+=("${name}")
    return 0
  fi
}

main() {
  FAILED_STEPS=()
  run_step "gh-cli"         install_gh_cli
  run_step "1password"      install_1password_cli
  run_step "gstack"         install_gstack
  run_step "hiboute-skills" install_hiboute_skills
  run_step "claude-md"      update_claude_md
  run_step "memory-hooks"   install_memory_hooks

  if [ ${#FAILED_STEPS[@]} -eq 0 ]; then
    log "All done."
  else
    log "Done with failures: ${FAILED_STEPS[*]}"
    exit 1
  fi
}

main "$@"
