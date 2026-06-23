#!/usr/bin/env bash
# WSL login autostart — invoked by both the Windows Startup launcher (immediately)
# and the delayed scheduled task (2 min later). The flock mutex ensures only the
# first invocation does real work; the second exits cleanly without duplicate logs.
set -uo pipefail
LOG="$HOME/wsl-autostart.log"
LOCK="/tmp/wsl-autostart.lock"

# Acquire an exclusive lock (non-blocking). If another instance holds it, exit quietly.
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

STACK_DIR="$(dirname "$(readlink -f "$0")")/.."
cd "$STACK_DIR"

# Bring the stack up; retry once if the first attempt fails (e.g. image pull race).
if ! docker compose up -d >> "$LOG" 2>&1; then
  echo "[$(date)] first compose up failed — retrying in 15s" >> "$LOG"
  sleep 15
  docker compose up -d >> "$LOG" 2>&1 || echo "[$(date)] ERROR: compose up failed on retry" >> "$LOG"
fi

echo "[$(date)] stack started" >> "$LOG"
