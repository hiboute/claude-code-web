#!/usr/bin/env bash
# claude-code-web installer
# Bootstraps dependencies for Claude Code on the web (claude.ai/code) sandboxes:
#   - GitHub CLI
#   - 1Password CLI
#   - Extra CLI tools   (ripgrep, fd, jq, shellcheck, sqlite3, tree)
#   - Runtimes          (uv, pnpm)
#   - Superpowers plugin  (obra/superpowers)
#   - gstack skills       (garrytan/gstack)
#   - Hiboute skills      (hiboute/skills)
#   - Anthropic skills    (anthropics/skills)
#   - Context7 MCP server (seeded in ~/.claude.json)
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

# --- Extra CLI tools ---------------------------------------------------------
# Single batched apt install for agent-useful tools. Skipped entirely if all
# six binaries are already on PATH; otherwise apt-get runs for the whole set
# (apt-get is a no-op for already-installed packages, so partial state is fine).
install_extra_cli_tools() {
  local pkgs=(ripgrep fd-find jq shellcheck sqlite3 tree)
  local bins=(rg fd jq shellcheck sqlite3 tree)
  local missing=0
  for bin in "${bins[@]}"; do
    command -v "${bin}" >/dev/null 2>&1 || missing=1
  done

  if [ "${missing}" -eq 0 ]; then
    log "Extra CLI tools already installed; skipping."
    return 0
  fi

  log "Installing extra CLI tools: ${pkgs[*]}"
  sudo apt-get install -y "${pkgs[@]}"

  # Debian ships fd-find as `fdfind`; add the conventional `fd` alias so the
  # agent (and users) can invoke it by its canonical name.
  if [ -x /usr/bin/fdfind ] && [ ! -e /usr/local/bin/fd ]; then
    sudo ln -sfn /usr/bin/fdfind /usr/local/bin/fd
  fi

  log "Extra CLI tools installed."
}

# --- Runtimes (uv, pnpm) -----------------------------------------------------
# uv: downloaded as a static binary from astral-sh/uv releases to /usr/local/bin
#     (avoids the curl|sh installer's PATH fiddling).
# pnpm: enabled via corepack, which ships with Node on claude.ai/code sandboxes.
install_runtimes() {
  if ! command -v uv >/dev/null 2>&1; then
    log "Installing uv (Python)..."
    local tmp
    tmp="$(mktemp -d)"
    local url="https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz"
    if curl -fsSL "${url}" -o "${tmp}/uv.tar.gz" \
      && tar -xzf "${tmp}/uv.tar.gz" -C "${tmp}"; then
      # Archive layout: uv-x86_64-unknown-linux-gnu/uv (and uvx)
      local extracted
      extracted="$(find "${tmp}" -maxdepth 2 -type f -name uv | head -1)"
      if [ -n "${extracted}" ]; then
        sudo mv "${extracted}" /usr/local/bin/uv
        sudo chmod +x /usr/local/bin/uv
        # uvx is a handy companion; install it if present in the archive.
        local extracted_uvx
        extracted_uvx="$(find "${tmp}" -maxdepth 2 -type f -name uvx | head -1)"
        if [ -n "${extracted_uvx}" ]; then
          sudo mv "${extracted_uvx}" /usr/local/bin/uvx
          sudo chmod +x /usr/local/bin/uvx
        fi
        log "uv installed: $(uv --version 2>/dev/null | head -1)"
      else
        log "WARN: uv binary not found in archive"
      fi
    else
      log "WARN: uv download/extract failed"
    fi
    rm -rf "${tmp}"
  else
    log "uv already installed ($(uv --version 2>/dev/null | head -1)); skipping."
  fi

  if ! command -v pnpm >/dev/null 2>&1; then
    if command -v corepack >/dev/null 2>&1; then
      log "Enabling pnpm via corepack..."
      sudo corepack enable pnpm
      log "pnpm enabled: $(pnpm --version 2>/dev/null | head -1)"
    else
      log "WARN: corepack not found; cannot enable pnpm"
      return 1
    fi
  else
    log "pnpm already installed ($(pnpm --version 2>/dev/null | head -1)); skipping."
  fi
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
# `claude plugin install` hangs on web, AND the harness only auto-discovers
# skills under ~/.claude/skills/*/SKILL.md — it does NOT scan plugin dirs
# without a registered marketplace. So we:
#   1. Clone the plugin into ~/.claude/plugins/superpowers (source of truth)
#   2. Symlink each skill into ~/.claude/skills/ so Claude finds them
#      (same pattern gstack and hiboute-skills use in their ./setup scripts)
install_superpowers() {
  local plugin_dir="${CLAUDE_HOME}/plugins/superpowers"
  clone_or_update "superpowers" \
    "${SUPERPOWERS_REPO_URL:-https://github.com/obra/superpowers.git}" \
    "${SUPERPOWERS_REPO_REF:-main}" \
    "${plugin_dir}"

  if [ ! -d "${plugin_dir}/skills" ]; then
    log "WARN: ${plugin_dir}/skills not found — superpowers layout changed?"
    return 0
  fi

  local linked=0
  for skill_dir in "${plugin_dir}"/skills/*/; do
    [ -d "${skill_dir}" ] || continue
    local name
    name="$(basename "${skill_dir}")"
    # Prefix with "superpowers:" to avoid collisions with other providers.
    ln -sfn "${skill_dir%/}" "${CLAUDE_HOME}/skills/superpowers:${name}"
    linked=$((linked + 1))
  done
  log "Linked ${linked} superpowers skills into ~/.claude/skills/"
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
# hiboute/skills is a PRIVATE repo. Credential sources (in order):
#   1. $GH_TOKEN env var       (claude.ai/code cloud runs expose this name)
#   2. $GITHUB_TOKEN env var   (GitHub Actions convention)
#   3. `gh auth token`         (if gh is installed and authenticated)
# If none available, print a very loud ACTION REQUIRED message.
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

  if [ -z "${token}" ]; then
    cat >&2 <<'EOF'

  ====================================================================
  ACTION REQUIRED: hiboute-skills (private repo) NOT installed
  --------------------------------------------------------------------
  The hiboute/skills repo is private. To install it, set one of:
    - GH_TOKEN     (claude.ai/code cloud run env var), or
    - GITHUB_TOKEN, or
    - Pre-authenticate the `gh` CLI
  Once set, re-run the installer.
  ====================================================================

EOF
    return 1
  fi

  local url="https://x-access-token:${token}@github.com/hiboute/skills.git"
  clone_or_update "hiboute-skills" "${url}" "main" "${dest}"
  if [ -x "${dest}/setup" ]; then
    log "Running hiboute-skills ./setup"
    (cd "${dest}" && ./setup) || log "WARN: hiboute-skills setup exited non-zero (continuing)"
  fi
}

# --- Anthropic skills (anthropics/skills) -----------------------------------
# Layout: skills/<name>/SKILL.md (same subfolder pattern Superpowers uses).
# We clone to ~/.claude/plugins/anthropic-skills and symlink each skill into
# ~/.claude/skills/anthropic:<name> so the Claude harness auto-discovers them.
install_anthropic_skills() {
  local plugin_dir="${CLAUDE_HOME}/plugins/anthropic-skills"
  clone_or_update "anthropic-skills" \
    "https://github.com/anthropics/skills.git" "main" "${plugin_dir}"

  if [ ! -d "${plugin_dir}/skills" ]; then
    log "WARN: ${plugin_dir}/skills not found — anthropics/skills layout changed?"
    return 0
  fi

  local linked=0
  for skill_dir in "${plugin_dir}"/skills/*/; do
    [ -d "${skill_dir}" ] || continue
    local name
    name="$(basename "${skill_dir}")"
    ln -sfn "${skill_dir%/}" "${CLAUDE_HOME}/skills/anthropic:${name}"
    linked=$((linked + 1))
  done
  log "Linked ${linked} anthropic skills into ~/.claude/skills/"
}

# --- Context7 MCP server -----------------------------------------------------
# Seeds ~/.claude.json with an mcpServers.context7 entry (Upstash's up-to-date
# library-docs MCP). Idempotent: preserves any existing mcpServers entries and
# does not overwrite a pre-existing context7 entry.
install_context7_mcp() {
  if ! command -v jq >/dev/null 2>&1; then
    log "WARN: jq not available; skipping Context7 MCP seed"
    return 1
  fi

  local cfg="${HOME}/.claude.json"
  [ -f "${cfg}" ] || echo '{}' > "${cfg}"

  # Validate existing file is parseable JSON; if not, bail rather than trash it.
  if ! jq -e . "${cfg}" >/dev/null 2>&1; then
    log "WARN: ${cfg} is not valid JSON; skipping Context7 MCP seed"
    return 1
  fi

  if jq -e '.mcpServers.context7' "${cfg}" >/dev/null 2>&1; then
    log "Context7 MCP already present in ${cfg}; skipping."
    return 0
  fi

  log "Seeding Context7 MCP in ${cfg}"
  jq '
    .mcpServers //= {} |
    .mcpServers.context7 = { command: "npx", args: ["-y", "@upstash/context7-mcp"] }
  ' "${cfg}" > "${cfg}.tmp" && mv "${cfg}.tmp" "${cfg}"
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

## Anthropic skills

Official Anthropic agent skills (anthropics/skills). Available under the `anthropic:` prefix, e.g. `/anthropic:skill-creator`, `/anthropic:mcp-builder`, `/anthropic:frontend-design`, `/anthropic:webapp-testing`, `/anthropic:claude-api`, `/anthropic:doc-coauthoring`, `/anthropic:docx`, `/anthropic:pdf`, `/anthropic:pptx`, `/anthropic:xlsx`.

Cloned to `~/.claude/plugins/anthropic-skills`; each `skills/*/` is symlinked into `~/.claude/skills/anthropic:<name>`.

## Context7 MCP

Up-to-date library docs via `npx -y @upstash/context7-mcp`. Seeded in `~/.claude.json` by the installer. First use in a session may trigger a one-time MCP approval prompt.
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
  run_step "gh-cli"            install_gh_cli
  run_step "1password"         install_1password_cli
  run_step "extra-cli-tools"   install_extra_cli_tools
  run_step "runtimes"          install_runtimes
  run_step "superpowers"       install_superpowers
  run_step "gstack"            install_gstack
  run_step "hiboute-skills"    install_hiboute_skills
  run_step "anthropic-skills"  install_anthropic_skills
  run_step "context7-mcp"      install_context7_mcp
  run_step "claude-md"         update_claude_md

  if [ ${#FAILED_STEPS[@]} -eq 0 ]; then
    log "All done."
  else
    log "Done with failures: ${FAILED_STEPS[*]}"
    exit 1
  fi
}

main "$@"
