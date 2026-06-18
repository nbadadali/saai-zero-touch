#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh  —  Platform validation for the OpenClaw + n8n stack
# =============================================================================
# Version-proof: derives expected services from the compose file itself and
# inspects each container individually (no reliance on `compose ps --format json`
# output shape, which differs across Docker Compose versions).
#
# Usage:
#   bash healthcheck.sh
#   REPO_DIR=/path/to/repo GATEWAY_PORT=18789 bash healthcheck.sh
# =============================================================================

set -uo pipefail

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; RST=$'\033[0m'
else RED=""; GRN=""; YLW=""; RST=""; fi

# Resolve REPO_DIR and GATEWAY_PORT: env override > config.env next to this script > built-in default.
# Running "bash healthcheck.sh" after a non-default REPO_DIR deploy just works.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
if [[ -z "${REPO_DIR:-}" && -f "${CONFIG_FILE}" ]]; then
  _rd="$(bash -c "source '${CONFIG_FILE}' 2>/dev/null; eval echo \"\${REPO_DIR:-}\"" 2>/dev/null || true)"
  [[ -n "${_rd}" ]] && REPO_DIR="${_rd}"
fi
if [[ -z "${GATEWAY_PORT:-}" && -f "${CONFIG_FILE}" ]]; then
  _gp="$(bash -c "source '${CONFIG_FILE}' 2>/dev/null; echo \"\${OPENCLAW_GATEWAY_PORT:-}\"" 2>/dev/null || true)"
  [[ -n "${_gp}" ]] && GATEWAY_PORT="${_gp}"
fi
REPO_DIR="${REPO_DIR:-$HOME/diplomatic-expression-docker}"
COMPOSE="${REPO_DIR}/docker-compose.yml"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
PASS=0; FAIL=0; WARN=0

chk()  { echo "${GRN}[PASS]${RST} $*"; PASS=$((PASS+1)); }
fail() { echo "${RED}[FAIL]${RST} $*"; FAIL=$((FAIL+1)); }
warn() { echo "${YLW}[WARN]${RST} $*"; WARN=$((WARN+1)); }

# docker wrapper that survives a not-yet-active docker group in this shell
dc() { if docker info &>/dev/null; then docker "$@"; else sg docker -c "docker $*"; fi; }

echo "══════════════════════════════════════════"
echo "  Platform Health Check — $(date '+%Y-%m-%d %H:%M:%S')"
echo "══════════════════════════════════════════"

# ─── OpenClaw gateway ────────────────────────────────────────────────────────
if systemctl --user is-active --quiet openclaw-gateway 2>/dev/null; then
  chk "OpenClaw gateway: active"
else
  fail "OpenClaw gateway: not active  →  systemctl --user start openclaw-gateway"
fi

if ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT}\b"; then
  chk "Gateway port ${GATEWAY_PORT}: listening"
else
  fail "Gateway port ${GATEWAY_PORT}: not listening"
fi

# ─── User lingering ──────────────────────────────────────────────────────────
if [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" == "yes" ]]; then
  chk "User lingering: enabled"
else
  fail "User lingering: disabled  →  sudo loginctl enable-linger $(id -un)"
fi

# ─── Docker daemon ───────────────────────────────────────────────────────────
if docker info &>/dev/null || sg docker -c "docker info" &>/dev/null; then
  chk "Docker daemon: reachable"
else
  fail "Docker daemon: not reachable  →  sudo systemctl start docker (or open a fresh shell)"
fi

# ─── Compose file ────────────────────────────────────────────────────────────
if [[ -f "${COMPOSE}" ]]; then
  chk "Compose file: found"
else
  fail "Compose file: missing at ${COMPOSE}"
  echo; echo "  Results: ${PASS} pass / ${FAIL} fail / ${WARN} warn"; exit 1
fi

# ─── Per-service container checks (derived from the compose file) ────────────
echo
echo "── Containers ─────────────────────────────"
mapfile -t SERVICES < <(dc compose -f "${COMPOSE}" config --services 2>/dev/null | sort)
if [[ ${#SERVICES[@]} -eq 0 ]]; then
  warn "Could not enumerate services from compose file (is docker accessible?)"
else
  for svc in "${SERVICES[@]}"; do
    cid="$(dc compose -f "${COMPOSE}" ps -q "${svc}" 2>/dev/null | head -1)"
    if [[ -z "${cid}" ]]; then
      fail "${svc}: no container (not started)"
      continue
    fi
    status="$(dc inspect -f '{{.State.Status}}' "${cid}" 2>/dev/null)"
    health="$(dc inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}" 2>/dev/null)"
    if [[ "${status}" == "running" ]]; then
      if [[ "${health}" == "healthy" || "${health}" == "none" ]]; then
        chk "${svc}: running${health:+ (${health})}"
      else
        warn "${svc}: running but health=${health}"
      fi
    else
      fail "${svc}: ${status}"
    fi
  done
fi

# ─── Endpoint checks ─────────────────────────────────────────────────────────
echo
echo "── Endpoints ──────────────────────────────"
if curl -fsS --connect-timeout 5 http://127.0.0.1:3000/health >/dev/null 2>&1; then
  chk "MCP server (:3000/health): responding"
else
  fail "MCP server (:3000/health): no response  →  check: docker compose logs mcp-server"
fi
if curl -fsS --connect-timeout 5 http://127.0.0.1:5678 >/dev/null 2>&1; then
  chk "n8n UI (:5678): responding"
else
  fail "n8n UI (:5678): no response  →  check: docker compose logs n8n"
fi

# ─── Edge CDP (Windows host via WSL gateway) ─────────────────────────────────
# Detect Windows host IP from the WSL default route (same IP the portproxy listens on).
WIN_HOST_IP="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
if [[ -z "${WIN_HOST_IP}" ]]; then
  warn "Edge CDP: could not detect Windows host IP from WSL default route"
else
  CDP_URL="http://${WIN_HOST_IP}:9222/json/version"
  CDP_RESP="$(curl -fsS --connect-timeout 5 "${CDP_URL}" 2>/dev/null)"
  if [[ -z "${CDP_RESP}" ]]; then
    fail "Edge CDP (${WIN_HOST_IP}:9222): no response  →  run windows-setup.ps1 -EnableBrowser and ensure Edge is open with CDP"
  else
    # Extract Browser field from JSON response to confirm it's actually Edge
    BROWSER_VER="$(echo "${CDP_RESP}" | grep -o '"Browser": *"[^"]*"' | cut -d'"' -f4)"
    if [[ -n "${BROWSER_VER}" ]]; then
      chk "Edge CDP (${WIN_HOST_IP}:9222): reachable — ${BROWSER_VER}"
    else
      warn "Edge CDP (${WIN_HOST_IP}:9222): responded but could not parse Browser field"
    fi
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "══════════════════════════════════════════"
echo "  ${GRN}${PASS} pass${RST} / ${RED}${FAIL} fail${RST} / ${YLW}${WARN} warn${RST}"
if [[ ${FAIL} -eq 0 ]]; then
  echo "  ${GRN}Platform health looks good.${RST}"
  echo "══════════════════════════════════════════"
  exit 0
else
  echo "  ${RED}Action required — review FAIL items above.${RST}"
  echo "══════════════════════════════════════════"
  exit 1
fi
