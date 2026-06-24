#!/usr/bin/env bash
# =============================================================================
# deploy.sh  —  OpenClaw + n8n Stack Deployment (WSL2 / Ubuntu)
# =============================================================================
# Design principles:
#   - Idempotent: every phase inspects real system state; safe to re-run.
#   - Phased: run all, run one (--only X), or resume (--from X).
#   - Config as data: all inputs come from config.env, nothing hard-coded.
#   - Fail-fast: each phase validates its preconditions and reports clearly.
#   - Non-destructive: never overwrites a working OpenClaw gateway unit.
#
# Usage:
#   cp config.env.example config.env && nano config.env
#   chmod +x deploy.sh healthcheck.sh
#   ./deploy.sh                 # run all phases
#   ./deploy.sh --only docker   # run a single phase
#   ./deploy.sh --from openclaw  # run from a phase to the end
#   ./deploy.sh --list          # list phases
#   ./deploy.sh --dry-run       # show what would run, change nothing
#
# Phases (in order):
#   preflight packages wsl_config docker node openclaw gateway \
#   browser repo env_file stack autostart validate
# =============================================================================

set -Eeuo pipefail

# ─── Locate self & load config ───────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

# ─── Output helpers ──────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'
  BLU=$'\033[0;34m'; CYN=$'\033[0;36m'; BOLD=$'\033[1m'; RST=$'\033[0m'
else
  RED=""; GRN=""; YLW=""; BLU=""; CYN=""; BOLD=""; RST=""
fi
log()     { echo "${BLU}[INFO]${RST}  $*"; }
ok()      { echo "${GRN}[ OK ]${RST}  $*"; }
warn()    { echo "${YLW}[WARN]${RST}  $*"; }
err()     { echo "${RED}[FAIL]${RST} $*" >&2; }
phase()   { echo; echo "${BOLD}${CYN}▶ PHASE: $*${RST}"; }
die()     { err "$*"; exit 1; }

trap 'err "Aborted at line $LINENO (exit $?). Re-run: ./deploy.sh --from ${CURRENT_PHASE:-preflight}"' ERR

# ─── Defaults (overridden by config.env) ─────────────────────────────────────
LINUX_USER=""; WSL_DISTRO="Ubuntu"
REPO_URL="https://github.com/nbadadali/diplomatic-expression-docker.git"
REPO_DIR="$HOME/diplomatic-expression-docker"
# Loaded from config.env and consumed by windows-setup.ps1 (informational here).
# shellcheck disable=SC2034
WSL_MEMORY_GB="6"
# shellcheck disable=SC2034
WSL_SWAP_GB="4"
OPENCLAW_INSTALL_METHOD="npm"; OPENCLAW_GATEWAY_PORT="18789"
OPENCLAW_VERSION=""       # pin version, e.g. "1.4.2"; blank = install latest
REPO_REVISION=""          # pin repo tag/commit, e.g. "v1.0.0"; blank = pull latest main
ENABLE_BROWSER_AUTOMATION="false"
N8N_ENCRYPTION_KEY=""; N8N_JWT_SECRET=""; DB_POSTGRESDB_PASSWORD=""
PGVECTOR_PASSWORD=""; MCP_AUTH_TOKEN=""; N8N_API_KEY=""
WEBHOOK_URL="http://localhost:5678"; N8N_EDITOR_BASE_URL="http://localhost:5678"
GENERIC_TIMEZONE="Asia/Dubai"; REDIS_PASSWORD=""

DRY_RUN=false

# ─── Arg parsing ─────────────────────────────────────────────────────────────
ALL_PHASES=(preflight packages wsl_config docker node openclaw gateway browser repo env_file stack autostart validate)
RUN_ONLY=""; RUN_FROM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)    RUN_ONLY="$2"; shift 2 ;;
    --from)    RUN_FROM="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --list)    printf '%s\n' "${ALL_PHASES[@]}"; exit 0 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

# ─── Load config ─────────────────────────────────────────────────────────────
[[ -f "$CONFIG_FILE" ]] || die "config.env not found. Run: cp config.env.example config.env && nano config.env"
set -a
# shellcheck source=/dev/null disable=SC1090
source "$CONFIG_FILE"
set +a

# Resolve identity
[[ -z "${LINUX_USER}" ]] && LINUX_USER="$(id -un)"
HOME_DIR="$(eval echo "~${LINUX_USER}")"
REPO_DIR="$(eval echo "${REPO_DIR}")"
LOG_FILE="${HOME_DIR}/saai-deploy.log"
GATEWAY_SERVICE="openclaw-gateway"
SYSTEMD_USER_DIR="${HOME_DIR}/.config/systemd/user"
GATEWAY_UNIT="${SYSTEMD_USER_DIR}/${GATEWAY_SERVICE}.service"
NPM_GLOBAL="${HOME_DIR}/.npm-global"
ENV_DEST="${REPO_DIR}/.env"

# Ensure npm global bin is in PATH for ALL phases.
# Each phase runs in a subshell (left side of the | tee pipe), so PATH exports
# inside phase functions don't carry over to sibling phases.  Exporting here in
# the parent shell lets every phase subshell inherit the correct PATH.
export PATH="${NPM_GLOBAL}/bin:${PATH}"

CURRENT_PHASE=""

run_step() { # echo + run, respecting dry-run.
  # eval is intentional: several callers pass pipes/redirects/heredocs as one
  # string, which must be re-parsed by the shell to execute correctly.
  # shellcheck disable=SC2294
  if $DRY_RUN; then echo "   ${YLW}[dry-run]${RST} $*"; else eval "$@"; fi
}

# =============================================================================
# Helper: robust literal .env writer (no sed delimiter / & corruption)
# =============================================================================
set_env_var() { # key value file
  local key="$1" val="$2" file="$3"
  python3 - "$key" "$val" "$file" <<'PYEOF'
import sys
key, val, file = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    lines = open(file, encoding="utf-8").read().splitlines()
except FileNotFoundError:
    lines = []
out, found = [], False
for line in lines:
    if line.startswith(key + "="):
        out.append(f"{key}={val}"); found = True
    else:
        out.append(line)
if not found:
    out.append(f"{key}={val}")
open(file, "w", encoding="utf-8").write("\n".join(out) + "\n")
PYEOF
}

gen_secret() { openssl rand -hex 24 2>/dev/null || head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 48; }

# =============================================================================
# PHASES
# =============================================================================

phase_preflight() {
  phase "preflight"
  [[ "$(id -u)" -eq 0 ]] && die "Do not run as root. Run as your normal Linux user (sudo is used only where needed)."

  if grep -qi microsoft /proc/version 2>/dev/null; then
    ok "WSL2 environment detected"
  else
    warn "Not a WSL2 environment — Windows-specific phases will be skipped where relevant"
  fi

  if systemctl --user show-environment >/dev/null 2>&1; then
    ok "systemd user session available"
  else
    die "systemd user session unavailable. Enable systemd in /etc/wsl.conf ([boot] systemd=true), then 'wsl --shutdown' and reopen."
  fi

  command -v curl >/dev/null || die "curl is required for preflight network check"
  if curl -fsSL --connect-timeout 6 https://github.com >/dev/null 2>&1; then
    ok "Internet connectivity confirmed"
  else
    die "No outbound internet. Fix WSL networking before continuing."
  fi

  ok "Config loaded for user '${LINUX_USER}' (home: ${HOME_DIR})"
}

phase_packages() {
  phase "packages"
  run_step "sudo apt-get update -qq"
  local pkgs=(curl git jq unzip ca-certificates gnupg lsb-release apt-transport-https python3 python3-pip openssl)
  for p in "${pkgs[@]}"; do
    if dpkg -s "$p" &>/dev/null; then ok "$p present"
    else log "installing $p"; run_step "sudo apt-get install -y -qq $p"; fi
  done
}

phase_wsl_config() {
  phase "wsl_config"
  grep -qi microsoft /proc/version 2>/dev/null || { warn "not WSL — skipping wsl.conf"; return 0; }
  if grep -q "systemd=true" /etc/wsl.conf 2>/dev/null; then
    ok "systemd already enabled in /etc/wsl.conf"
  else
    log "enabling systemd in /etc/wsl.conf (merging, preserving existing sections)"
    # Merge: update [boot] systemd=true without destroying other sections.
    run_step "python3 - <<'PYEOF'
import re, subprocess, sys

path = '/etc/wsl.conf'
try:
    content = open(path).read()
except FileNotFoundError:
    content = ''

# If [boot] section exists, set/add systemd=true inside it.
# If not, append a [boot] section.
boot_section = re.compile(r'(\[boot\][^\[]*)', re.DOTALL)
systemd_line = re.compile(r'^(systemd\s*=\s*.*)$', re.MULTILINE)

if boot_section.search(content):
    def patch_boot(m):
        block = m.group(1)
        if systemd_line.search(block):
            return systemd_line.sub('systemd=true', block)
        return block.rstrip() + '\nsystemd=true\n'
    new_content = boot_section.sub(patch_boot, content)
else:
    new_content = content.rstrip() + ('\n' if content else '') + '[boot]\nsystemd=true\n'

tmp = path + '.tmp'
open(tmp, 'w').write(new_content)
subprocess.run(['sudo', 'mv', tmp, path], check=True)
PYEOF"
    warn "wsl.conf changed — a 'wsl --shutdown' is required for it to take effect"
  fi
}

phase_docker() {
  phase "docker"
  if command -v docker &>/dev/null; then
    ok "docker present: $(docker --version 2>/dev/null || echo unknown)"
  else
    log "installing Docker Engine from official repo"
    run_step "sudo install -m 0755 -d /etc/apt/keyrings"
    run_step "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
    run_step "sudo chmod a+r /etc/apt/keyrings/docker.gpg"
    run_step "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable\" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null"
    run_step "sudo apt-get update -qq"
    run_step "sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    ok "docker installed"
  fi

  if id -nG "${LINUX_USER}" | grep -qw docker; then
    ok "${LINUX_USER} already in docker group"
  else
    log "adding ${LINUX_USER} to docker group"
    run_step "sudo usermod -aG docker ${LINUX_USER}"
    warn "group change needs a fresh shell. This script uses 'sg docker' to proceed now."
  fi

  run_step "sudo systemctl enable --now docker docker.socket" || warn "docker service enable returned non-zero (may already be active)"

  if docker info &>/dev/null; then ok "docker daemon reachable"
  elif sg docker -c "docker info" &>/dev/null; then ok "docker daemon reachable (via sg docker)"
  else warn "docker daemon not reachable yet — a fresh shell may be needed"; fi
}

# docker wrapper that works even before the group membership is active in this shell
dc() { if docker info &>/dev/null; then docker "$@"; else sg docker -c "docker $*"; fi; }

phase_node() {
  phase "node"
  # OpenClaw requires Node.js v22.19+. Check the *system* node (used by systemd
  # services) not just the shell's node (which may come from nvm).
  local node_ok=false
  if command -v node &>/dev/null; then
    local node_ver; node_ver="$(node --version 2>/dev/null | tr -d 'v')"
    local node_major; node_major="${node_ver%%.*}"
    if [[ "${node_major:-0}" -ge 22 ]]; then
      ok "node present and meets v22+ requirement: v${node_ver}"
      node_ok=true
    else
      warn "node v${node_ver} installed but openclaw requires v22+. Upgrading system Node.js via NodeSource 22.x..."
    fi
  else
    log "node not found — installing Node.js 22 via NodeSource"
  fi

  if ! $node_ok; then
    run_step "curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -"
    run_step "sudo apt-get install -y -qq nodejs"
    ok "node installed: $(/usr/bin/node --version 2>/dev/null || echo unknown)"
  fi
  run_step "mkdir -p ${NPM_GLOBAL}"
  run_step "npm config set prefix ${NPM_GLOBAL}"
  if ! grep -q ".npm-global/bin" "${HOME_DIR}/.bashrc" 2>/dev/null; then
    log "adding npm global bin to PATH in .bashrc"
    $DRY_RUN || echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "${HOME_DIR}/.bashrc"
  fi
  export PATH="${NPM_GLOBAL}/bin:$PATH"
  ok "npm global prefix set: ${NPM_GLOBAL}"
}

phase_openclaw() {
  phase "openclaw"
  export PATH="${NPM_GLOBAL}/bin:$PATH"
  case "${OPENCLAW_INSTALL_METHOD}" in
    skip) warn "OPENCLAW_INSTALL_METHOD=skip — leaving OpenClaw untouched" ;;
    npm)
      # Always use @latest by default — bare "openclaw" resolves to a squatted
      # placeholder (v0.0.1, no binary). A pinned OPENCLAW_VERSION overrides.
      local pkg="openclaw@latest"; [[ -n "${OPENCLAW_VERSION}" ]] && pkg="openclaw@${OPENCLAW_VERSION}"
      if command -v openclaw &>/dev/null; then ok "openclaw present: $(openclaw --version 2>/dev/null || echo unknown)"
      else log "installing ${pkg} via npm"; run_step "npm install -g ${pkg}"; ok "openclaw installed"; fi ;;
    script)
      if command -v openclaw &>/dev/null; then ok "openclaw present"
      else log "installing OpenClaw via official installer"; run_step "curl -fsSL https://openclaw.ai/install.sh | bash"; fi ;;
    *) die "Unknown OPENCLAW_INSTALL_METHOD: ${OPENCLAW_INSTALL_METHOD}" ;;
  esac
  $DRY_RUN && return 0
  [[ "${OPENCLAW_INSTALL_METHOD}" == "skip" ]] && return 0
  command -v openclaw >/dev/null || die "openclaw binary not found after install (check PATH: ${NPM_GLOBAL}/bin)"
  ok "openclaw resolves to: $(command -v openclaw)"
}

phase_gateway() {
  phase "gateway"
  $DRY_RUN && { echo "   ${YLW}[dry-run]${RST} would create/enable ${GATEWAY_UNIT}"; return 0; }

  run_step "sudo loginctl enable-linger ${LINUX_USER}"
  mkdir -p "${SYSTEMD_USER_DIR}"

  local bin; bin="$(command -v openclaw)"
  # Desired unit content — used both for creation and drift detection.
  local desired_unit
  desired_unit="$(cat <<EOF
[Unit]
Description=OpenClaw AI Gateway
After=network.target

[Service]
Type=simple
ExecStart=${bin} gateway --port ${OPENCLAW_GATEWAY_PORT} --allow-unconfigured
Restart=always
RestartSec=5
Environment=OPENCLAW_GATEWAY_PORT=${OPENCLAW_GATEWAY_PORT}
WorkingDirectory=${HOME_DIR}

[Install]
WantedBy=default.target
EOF
)"
  if [[ -f "${GATEWAY_UNIT}" ]]; then
    if [[ "$(cat "${GATEWAY_UNIT}")" == "${desired_unit}" ]]; then
      ok "gateway unit present and up to date"
    else
      log "gateway unit config drift detected — regenerating"
      printf '%s\n' "${desired_unit}" > "${GATEWAY_UNIT}"
      ok "gateway unit regenerated (port, binary, or env changed)"
    fi
  else
    log "creating ${GATEWAY_UNIT}"
    printf '%s\n' "${desired_unit}" > "${GATEWAY_UNIT}"
    ok "gateway unit created"
  fi

  systemctl --user daemon-reload
  systemctl --user enable "${GATEWAY_SERVICE}" >/dev/null 2>&1 || true
  systemctl --user restart "${GATEWAY_SERVICE}" 2>/dev/null || systemctl --user start "${GATEWAY_SERVICE}" 2>/dev/null || \
    warn "could not start via systemd — try: openclaw gateway --port ${OPENCLAW_GATEWAY_PORT}"

  sleep 3
  if systemctl --user is-active --quiet "${GATEWAY_SERVICE}"; then
    ok "gateway active on port ${OPENCLAW_GATEWAY_PORT}"
  else
    warn "gateway not active — check: systemctl --user status ${GATEWAY_SERVICE}"
  fi
}

phase_browser() {
  phase "browser"
  if [[ "${ENABLE_BROWSER_AUTOMATION}" != "true" ]]; then
    ok "browser automation disabled in config — skipping (set ENABLE_BROWSER_AUTOMATION=true to enable)"
    return 0
  fi
  $DRY_RUN && { echo "   ${YLW}[dry-run]${RST} would set up Playwright + discover OpenClaw browser command"; return 0; }

  log "installing Playwright Edge runtime (best-effort)"
  pip3 install playwright --break-system-packages -q 2>/dev/null || pip3 install playwright -q 2>/dev/null || \
    run_step "npm install -g playwright" || warn "playwright install failed — continuing"
  python3 -m playwright install msedge 2>/dev/null || warn "Edge runtime install via Playwright failed"

  # Do NOT guess the CLI subcommand. Discover it.
  log "discovering OpenClaw browser-enable command"
  local helptext; helptext="$(openclaw --help 2>&1; openclaw plugins --help 2>&1; openclaw skills --help 2>&1)"
  if echo "$helptext" | grep -q "plugins"; then
    run_step "openclaw plugins enable browser" || warn "'openclaw plugins enable browser' failed — verify manually"
  elif echo "$helptext" | grep -q "skills"; then
    warn "Use 'openclaw skills' to enable the browser skill — see post-restart validation doc"
  else
    warn "Could not auto-discover the browser command. Enable manually and run: openclaw skills check"
  fi
  warn "Browser automation also requires the Windows side (Edge CDP). Run windows-setup.ps1 with -EnableBrowser."
}

phase_repo() {
  phase "repo"
  if [[ -d "${REPO_DIR}/.git" ]]; then
    log "repo exists — fetching"
    run_step "git -C '${REPO_DIR}' fetch --tags origin" || warn "git fetch failed — keeping existing checkout"
  else
    log "cloning ${REPO_URL}"
    run_step "git clone '${REPO_URL}' '${REPO_DIR}'"
  fi
  if [[ -n "${REPO_REVISION}" ]]; then
    log "pinning repo to ${REPO_REVISION}"
    run_step "git -C '${REPO_DIR}' checkout '${REPO_REVISION}'"
    ok "repo at ${REPO_REVISION} (${REPO_DIR})"
  else
    run_step "git -C '${REPO_DIR}' pull --ff-only" || warn "git pull failed — keeping existing checkout"
    ok "repo at latest main (${REPO_DIR})"
  fi
}

phase_env_file() {
  phase "env_file"
  $DRY_RUN && { echo "   ${YLW}[dry-run]${RST} would write secrets into ${ENV_DEST}"; return 0; }

  # Seed from .env.example if present and .env missing
  if [[ ! -f "${ENV_DEST}" && -f "${REPO_DIR}/.env.example" ]]; then
    cp "${REPO_DIR}/.env.example" "${ENV_DEST}"
    log "seeded .env from .env.example"
  fi
  touch "${ENV_DEST}"

  # Precedence for each secret: config.env value > existing .env value > generate.
  # This keeps secrets STABLE across re-runs (rotating N8N_ENCRYPTION_KEY would
  # make n8n unable to decrypt existing credentials).
  read_existing() { grep "^$1=" "${ENV_DEST}" 2>/dev/null | head -1 | cut -d= -f2- ; }
  is_placeholder() {
    # Returns 0 (true) when the value is a .env.example placeholder that must be replaced.
    local v="$1"
    [[ -z "$v" ]] && return 0
    [[ "$v" == replace-with-* ]] && return 0
    [[ "$v" == change-me* ]] && return 0
    [[ "$v" == choose-a-* ]] && return 0
    return 1
  }
  resolve_secret() { # varname
    local name="$1" cfgval="${!1}" exist
    exist="$(read_existing "$name")"
    if   [[ -n "${cfgval}" ]] && ! is_placeholder "${cfgval}"; then printf '%s' "${cfgval}"
    elif [[ -n "${exist}"  ]] && ! is_placeholder "${exist}";  then printf '%s' "${exist}"
    else log "generated ${name}" >&2; gen_secret; fi
  }

  N8N_ENCRYPTION_KEY="$(resolve_secret N8N_ENCRYPTION_KEY)"
  N8N_JWT_SECRET="$(resolve_secret N8N_JWT_SECRET)"
  DB_POSTGRESDB_PASSWORD="$(resolve_secret DB_POSTGRESDB_PASSWORD)"
  PGVECTOR_PASSWORD="$(resolve_secret PGVECTOR_PASSWORD)"
  MCP_AUTH_TOKEN="$(resolve_secret MCP_AUTH_TOKEN)"

  set_env_var "N8N_ENCRYPTION_KEY"     "${N8N_ENCRYPTION_KEY}"     "${ENV_DEST}"
  set_env_var "N8N_JWT_SECRET"         "${N8N_JWT_SECRET}"         "${ENV_DEST}"
  set_env_var "DB_POSTGRESDB_PASSWORD" "${DB_POSTGRESDB_PASSWORD}" "${ENV_DEST}"
  set_env_var "PGVECTOR_PASSWORD"      "${PGVECTOR_PASSWORD}"      "${ENV_DEST}"
  set_env_var "MCP_AUTH_TOKEN"         "${MCP_AUTH_TOKEN}"         "${ENV_DEST}"
  set_env_var "WEBHOOK_URL"            "${WEBHOOK_URL}"            "${ENV_DEST}"
  set_env_var "N8N_EDITOR_BASE_URL"    "${N8N_EDITOR_BASE_URL}"    "${ENV_DEST}"
  set_env_var "GENERIC_TIMEZONE"       "${GENERIC_TIMEZONE}"       "${ENV_DEST}"
  set_env_var "REDIS_PASSWORD"         "${REDIS_PASSWORD}"         "${ENV_DEST}"
  [[ -n "${N8N_API_KEY}" ]] && set_env_var "N8N_API_KEY" "${N8N_API_KEY}" "${ENV_DEST}"

  # GUARD: a database container created with an EMPTY password initializes an
  # unusable volume ("Database is uninitialized ... POSTGRES_PASSWORD not set")
  # and crash-loops forever. Fail loudly here instead of much later in the stack.
  [[ -n "${DB_POSTGRESDB_PASSWORD}" ]] || die "DB_POSTGRESDB_PASSWORD resolved empty — secret generation failed (check openssl/urandom). Aborting before stack."
  [[ -n "${PGVECTOR_PASSWORD}"      ]] || die "PGVECTOR_PASSWORD resolved empty — secret generation failed (check openssl/urandom). Aborting before stack."

  chmod 600 "${ENV_DEST}"
  ok ".env written and locked to 0600 (${ENV_DEST})"
}

phase_stack() {
  phase "stack"
  [[ -f "${REPO_DIR}/docker-compose.yml" ]] || die "docker-compose.yml not found in ${REPO_DIR}"
  cd "${REPO_DIR}"
  if $DRY_RUN; then
    echo "   ${YLW}[dry-run]${RST} dc compose pull && dc compose up -d --build"
    return 0
  fi
  # GUARD 1: .env must exist. Protects against running '--from stack' (or --only
  # stack) before env_file has generated secrets — that creates Postgres with an
  # empty password and an unusable, uninitialized data volume.
  [[ -f "${ENV_DEST}" ]] || die ".env missing at ${ENV_DEST}. Run a full ./deploy.sh, or ./deploy.sh --only env_file first. Never run '--from stack' before env_file."

  # ROOT-CAUSE FIX: phases run in a subshell (see the '<phase> | tee' loop), and
  # config.env was sourced with 'set -a', which EXPORTS empty secret values into
  # the environment on a fresh deploy. env_file writes the real generated
  # passwords to .env, but its in-subshell variable assignments never reach this
  # environment. Docker Compose gives environment variables PRECEDENCE over the
  # .env file, so those empty exports would shadow the real passwords in .env and
  # Postgres/pgvector would start with an EMPTY password. Re-load .env here so the
  # environment matches the file before any container is created.
  set -a
  # shellcheck disable=SC1090
  source "${ENV_DEST}"
  set +a

  # GUARD 2: the Postgres password must actually resolve from .env. This is the
  # #1 fresh-deploy failure mode — verify it BEFORE any container is created.
  local pgpw
  pgpw="$(dc compose config 2>/dev/null | awk -F'POSTGRES_PASSWORD:' 'NF>1{gsub(/[[:space:]"]/,"",$2); print $2; exit}')"
  [[ -n "${pgpw}" ]] || die "POSTGRES_PASSWORD did not resolve from ${ENV_DEST}. Run: ./deploy.sh --only env_file, then retry."

  log "pulling images (may take a few minutes)"
  dc compose pull 2>/dev/null || warn "image pull had warnings — continuing"
  log "starting stack"
  # --force-recreate self-heals any container left from a prior aborted run that
  # was created before .env existed (the empty-password / uninitialized-volume
  # state). The generated password is stable across runs and named volumes
  # persist, so recreating is safe and idempotent.
  dc compose up -d --build --force-recreate --remove-orphans
  log "waiting 20s for containers to settle"; sleep 20
  dc compose ps
}

phase_autostart() {
  phase "autostart"

  # Record the repo path so the autostart script can find the compose stack
  # regardless of username or directory — supports any deployment layout.
  echo "${REPO_DIR}" > "${HOME_DIR}/.saai-repo-path"
  ok "repo path recorded: ${HOME_DIR}/.saai-repo-path -> ${REPO_DIR}"

  # Place the autostart script outside the repo in a stable system location.
  # The systemd unit references it via the %h specifier (expands to home dir
  # at runtime) so no username or path is hardcoded anywhere.
  local script="${HOME_DIR}/.local/bin/saai-autostart.sh"
  run_step "mkdir -p ${HOME_DIR}/.local/bin"
  $DRY_RUN && { echo "   ${YLW}[dry-run]${RST} would write ${script}"; return 0; }

  cat > "${script}" <<'AUTOEOF'
#!/usr/bin/env bash
# saai-autostart.sh — invoked by n8n-stack.service (systemd user service).
# Reads repo location from ~/.saai-repo-path — no hardcoded paths or usernames.
set -uo pipefail
LOG="$HOME/wsl-autostart.log"
LOCK="/tmp/saai-autostart.lock"

# Acquire an exclusive lock (non-blocking). Guards against duplicate triggers.
exec 9>"${LOCK}"
if ! flock -n 9; then
  echo "[$(date)] autostart already running — skipping duplicate trigger" >> "$LOG"
  exit 0
fi
trap 'rm -f "${LOCK}"' EXIT

echo "[$(date)] autostart triggered" >> "$LOG"

# Ensure the OpenClaw gateway is up.
systemctl --user start openclaw-gateway 2>/dev/null || true

# Wait up to 3 minutes for Docker daemon (slow cold-boot on some machines).
WAITED=0
until docker info &>/dev/null 2>&1; do
  if [[ $WAITED -ge 180 ]]; then
    echo "[$(date)] ERROR: Docker did not become ready after 3 minutes" >> "$LOG"
    exit 1
  fi
  sleep 5; WAITED=$((WAITED+5))
done
echo "[$(date)] Docker ready after ${WAITED}s" >> "$LOG"

# Dynamically resolve the stack directory — no hardcoded path.
REPO_PATH_FILE="$HOME/.saai-repo-path"
if [[ ! -f "${REPO_PATH_FILE}" ]]; then
  echo "[$(date)] ERROR: ${REPO_PATH_FILE} missing — re-run: ./deploy.sh --only autostart" >> "$LOG"
  exit 1
fi
STACK_DIR="$(cat "${REPO_PATH_FILE}")"
if [[ ! -d "${STACK_DIR}" ]]; then
  echo "[$(date)] ERROR: repo dir '${STACK_DIR}' does not exist — update ${REPO_PATH_FILE}" >> "$LOG"
  exit 1
fi
cd "${STACK_DIR}"

# Bring the stack up; retry once on failure (e.g. image pull race on cold boot).
if ! docker compose up -d >> "$LOG" 2>&1; then
  echo "[$(date)] first compose up failed — retrying in 15s" >> "$LOG"
  sleep 15
  docker compose up -d >> "$LOG" 2>&1 || echo "[$(date)] ERROR: compose up failed on retry" >> "$LOG"
fi

echo "[$(date)] stack started" >> "$LOG"
AUTOEOF
  chmod +x "${script}"
  ok "autostart script written: ${script}"

  # The %h systemd specifier expands to the user's home directory at runtime.
  # This means the unit file contains zero hardcoded paths or usernames and
  # works correctly for any Linux user on any machine.
  local svc_dir="${HOME_DIR}/.config/systemd/user"
  run_step "mkdir -p ${svc_dir}"
  cat > "${svc_dir}/n8n-stack.service" <<'SVCEOF'
[Unit]
Description=n8n Docker Stack (n8n + postgres + redis + mcp-server)
After=default.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash %h/.local/bin/saai-autostart.sh

[Install]
WantedBy=default.target
SVCEOF
  run_step "systemctl --user daemon-reload"
  run_step "systemctl --user enable n8n-stack.service"
  ok "systemd user service enabled: n8n-stack.service"
}

phase_validate() {
  phase "validate"
  if [[ -x "${SCRIPT_DIR}/healthcheck.sh" ]]; then
    REPO_DIR="${REPO_DIR}" GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT}" bash "${SCRIPT_DIR}/healthcheck.sh"
  else
    warn "healthcheck.sh not found next to deploy.sh — skipping automated validation"
  fi
}

# =============================================================================
# Orchestration
# =============================================================================
declare -A PHASE_FN=(
  [preflight]=phase_preflight [packages]=phase_packages [wsl_config]=phase_wsl_config
  [docker]=phase_docker [node]=phase_node [openclaw]=phase_openclaw [gateway]=phase_gateway
  [browser]=phase_browser [repo]=phase_repo [env_file]=phase_env_file [stack]=phase_stack
  [autostart]=phase_autostart [validate]=phase_validate
)

# Build the run list
declare -a TO_RUN=()
if [[ -n "${RUN_ONLY}" ]]; then
  [[ -n "${PHASE_FN[$RUN_ONLY]:-}" ]] || die "Unknown phase: ${RUN_ONLY} (try --list)"
  TO_RUN=("${RUN_ONLY}")
elif [[ -n "${RUN_FROM}" ]]; then
  [[ -n "${PHASE_FN[$RUN_FROM]:-}" ]] || die "Unknown phase: ${RUN_FROM} (try --list)"
  local_started=false
  for p in "${ALL_PHASES[@]}"; do
    [[ "$p" == "${RUN_FROM}" ]] && local_started=true
    $local_started && TO_RUN+=("$p")
  done
else
  TO_RUN=("${ALL_PHASES[@]}")
fi

# Header
echo "${BOLD}${CYN}═══════════════════════════════════════════════════════════${RST}"
echo "${BOLD}${CYN}  OpenClaw + n8n Deployment${RST}"
echo "${BOLD}${CYN}═══════════════════════════════════════════════════════════${RST}"
echo "  user      : ${LINUX_USER}"
echo "  repo dir  : ${REPO_DIR}"
echo "  phases    : ${TO_RUN[*]}"
$DRY_RUN && echo "  mode      : ${YLW}DRY RUN (no changes)${RST}"
echo "  log       : ${LOG_FILE}"
{ echo "=== deploy run $(date) ==="; } >> "${LOG_FILE}" 2>/dev/null || true

for p in "${TO_RUN[@]}"; do
  CURRENT_PHASE="$p"
  "${PHASE_FN[$p]}" 2>&1 | tee -a "${LOG_FILE}"
done

echo
echo "${BOLD}${GRN}═══════════════════════════════════════════════════════════${RST}"
echo "${BOLD}${GRN}  DEPLOYMENT FINISHED${RST}"
echo "${BOLD}${GRN}═══════════════════════════════════════════════════════════${RST}"
echo "  • n8n UI        : http://localhost:5678"
echo "  • health check  : bash ${SCRIPT_DIR}/healthcheck.sh"
echo "  • re-run a phase: ./deploy.sh --only <phase>"
echo "  • full log      : ${LOG_FILE}"
echo "  • run docker yourself: newgrp docker   # (this shell only; automatic after reboot/new WSL session)"
echo
echo "  Windows host steps (run once, in PowerShell as Administrator):"
echo "      .\\windows-setup.ps1 -WslDistro '${WSL_DISTRO}' -WslUser '${LINUX_USER}'"
echo
