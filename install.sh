#!/usr/bin/env bash
# claude-code-web installer
# Bootstraps dependencies for Claude Code on the web (claude.ai/code) sandboxes:
#   - 1Password CLI
#   - Superpowers plugin  (obra/superpowers)
#   - gstack skills       (garrytan/gstack)
#   - Hiboute skills      (hiboute/skills)
#   - Appends a skills reference block to ~/.claude/CLAUDE.md
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

# --- Superpowers (plugin) ----------------------------------------------------
# Workaround for https://github.com/obra/superpowers/issues/262:
# `claude plugin install` hangs on web — clone directly into ~/.claude/plugins
# so the hooks + skills are discovered from the filesystem.
install_superpowers() {
  clone_or_update "superpowers" \
    "${SUPERPOWERS_REPO_URL:-https://github.com/obra/superpowers.git}" \
    "${SUPERPOWERS_REPO_REF:-main}" \
    "${CLAUDE_HOME}/plugins/superpowers"
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
# hiboute/skills is a PRIVATE repo. Requires GITHUB_TOKEN in the environment
# (claude.ai/code sandboxes can inject one) or pre-authenticated git/gh.
install_hiboute_skills() {
  local dest="${CLAUDE_HOME}/skills/hiboute-skills"
  local url="https://github.com/hiboute/skills.git"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    url="https://x-access-token:${GITHUB_TOKEN}@github.com/hiboute/skills.git"
  fi
  clone_or_update "hiboute-skills" "${url}" "main" "${dest}"
  if [ -x "${dest}/setup" ]; then
    log "Running hiboute-skills ./setup"
    (cd "${dest}" && ./setup) || log "WARN: hiboute-skills setup exited non-zero (continuing)"
  fi
}

# --- CLAUDE.md reference block ----------------------------------------------
# Appends a skills reference block to ~/.claude/CLAUDE.md, guarded by a
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

## Superpowers plugin

Cloned to `~/.claude/plugins/superpowers`. Skills and hooks are picked up automatically.

Install with: `git clone --single-branch --depth 1 https://github.com/obra/superpowers.git ~/.claude/plugins/superpowers`
Update with: `git -C ~/.claude/plugins/superpowers pull --ff-only`
EOF
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
  run_step "1password"      install_1password_cli
  run_step "superpowers"    install_superpowers
  run_step "gstack"         install_gstack
  run_step "hiboute-skills" install_hiboute_skills
  run_step "claude-md"      update_claude_md

  if [ ${#FAILED_STEPS[@]} -eq 0 ]; then
    log "All done."
  else
    log "Done with failures: ${FAILED_STEPS[*]}"
    exit 1
  fi
}

main "$@"
