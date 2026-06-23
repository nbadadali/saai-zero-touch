# SAAI Stack — Quickstart (Fresh Machine)

Deploy the OpenClaw + n8n AI orchestration stack on a new Windows laptop in
under 30 minutes. You will touch the keyboard exactly **3 times**.

---

## Prerequisites checklist

Before you start, confirm the following on the target machine:

- [ ] Windows 10 (21H2+) or Windows 11
- [ ] 8 GB RAM minimum (16 GB recommended)
- [ ] 20 GB free disk space
- [ ] Internet access (npm, Docker Hub, GitHub)
- [ ] You have a local Administrator account (or IT can run step 1 for you)

---

## Step 1 — Install WSL2 with Ubuntu 22.04

> Skip this step if `wsl -l -v` already shows `Ubuntu-22.04` at VERSION 2.

Open **PowerShell as Administrator** and run:

```powershell
wsl --install -d Ubuntu-22.04
```

When prompted, create a Linux username and password. Then **reboot Windows**.

After reboot, open Ubuntu 22.04 once from the Start menu to finish first-time
setup, then close it.

---

## Step 2 — Configure the Windows host

Open **PowerShell as Administrator** and navigate to this folder:

```powershell
cd C:\path\to\saai-zero-touch
Set-ExecutionPolicy Bypass -Scope Process -Force
```

Run the setup script with your WSL distro name:

```powershell
.\windows-setup.ps1 -WslDistro 'Ubuntu-22.04'
```

**Optional flags:**

| Flag | When to use |
|------|-------------|
| `-MemoryGB 12` | Client has 16+ GB RAM — give WSL more headroom |
| `-SwapGB 8` | Client has large RAM but slow disk — keep default 4 |
| `-EnableBrowser` | Client needs OpenClaw browser automation via Edge CDP |

Example with all options:

```powershell
.\windows-setup.ps1 -WslDistro 'Ubuntu-22.04' -MemoryGB 12 -EnableBrowser
```

When the script finishes, apply WSL memory settings:

```powershell
wsl --shutdown
```

---

## Step 3 — Deploy the stack (inside WSL2)

Open **Ubuntu 22.04** from the Start menu. Copy the deployment folder into WSL
and run:

```bash
cp -r /mnt/c/path/to/saai-zero-touch ~/saai-deploy
cd ~/saai-deploy

# Create your config file from the template
cp config.env.example config.env
nano config.env
```

### What to fill in config.env

Only two things need your attention on a fresh install:

| Field | What to set |
|-------|-------------|
| `LINUX_USER` | Your WSL username (same as Step 1) — or leave blank to auto-detect |
| `WSL_DISTRO` | `Ubuntu-22.04` (match what you used in Step 2) |

**Everything else can stay as-is for a standard install:**
- Secrets (`N8N_ENCRYPTION_KEY`, `DB_POSTGRESDB_PASSWORD`, etc.) — leave blank, deploy.sh generates strong random values automatically
- `WEBHOOK_URL` / `N8N_EDITOR_BASE_URL` — leave as `http://localhost:5678` for local installs
- `OPENCLAW_VERSION` — leave blank for latest

**If this client needs browser automation (Edge CDP):**
```bash
# Set before running deploy.sh — cannot be changed mid-run
ENABLE_BROWSER_AUTOMATION="true"
```
If you forgot to set this and deploy.sh already ran, fix it and resume:
```bash
nano ~/saai-deploy/config.env   # set ENABLE_BROWSER_AUTOMATION="true"
./deploy.sh --from browser
```

Save and close (`Ctrl+X`, then `Y`, then `Enter` in nano).

### Run the deployment

```bash
chmod +x deploy.sh healthcheck.sh
sed -i 's/\r//' deploy.sh
sed -i 's/\r//' config.env
./deploy.sh
```

The script runs all phases automatically:

```
packages → wsl_config → docker → node → openclaw → gateway
→ repo → env_file → stack → autostart → validate
```

Estimated time: **10–20 minutes** on a typical broadband connection.

When it completes, the health check runs automatically and prints:

```
══════════════════════════════════════════
  Platform Health Check
══════════════════════════════════════════
[PASS] OpenClaw gateway: active
[PASS] Gateway port 18789: listening
[PASS] User lingering: enabled
[PASS] Docker daemon: reachable
[PASS] Compose file: found
[PASS] postgres: running (healthy)
[PASS] redis: running (healthy)
[PASS] n8n: running
[PASS] n8n-worker: running (x2)
[PASS] mcp-server: running
[PASS] MCP server (:3000/health): responding
[PASS] n8n UI (:5678): responding
══════════════════════════════════════════
  12 pass / 0 fail / 0 warn
  Platform health looks good.
══════════════════════════════════════════
```

**Open n8n:** http://localhost:5678

---

## First login to n8n

1. Browse to http://localhost:5678
2. Create your admin account (email + password of your choice)
3. Go to **Settings → API** and generate an API key
4. Add it to config.env:
   ```bash
   nano ~/saai-deploy/config.env   # set N8N_API_KEY="n8n_api_..."
   ./deploy.sh --only env_file
   ```
5. Restart the stack to pick up the key:
   ```bash
   cd ~/diplomatic-expression-docker
   docker compose restart n8n n8n-worker
   ```

---

## Verify after a reboot

Reboot the machine. After Windows login, wait **3–4 minutes** for the scheduled
task to bring the stack up, then:

- Open http://localhost:5678 — n8n should load
- Optionally run the health check:
  ```bash
  wsl -d Ubuntu-22.04 -- bash ~/saai-deploy/healthcheck.sh
  ```

---

## Common issues

### `wsl: Unknown key 'wsl2.pageReporting'` on WSL open

Old `.wslconfig` on disk. Re-run `windows-setup.ps1` from Admin PowerShell — it
overwrites the file. Then `wsl --shutdown` and reopen.

### `nvm` prefix conflict warning on WSL login

```bash
nvm use --delete-prefix v22.23.0 --silent
```

### Stack not up after reboot

Allow **3–4 minutes** after login before checking. If still down, inspect the autostart log:

```bash
cat ~/wsl-autostart.log
```

Check systemd service status inside WSL:

```bash
systemctl --user status n8n-stack.service
systemctl --user status openclaw-gateway.service
```

Verify the Windows Scheduled Task ran:

```powershell
Get-ScheduledTask -TaskName "OpenClaw-Stack-DelayedStart"
```

Manually trigger if needed:

```powershell
Start-ScheduledTask -TaskName "OpenClaw-Stack-DelayedStart"
```

Or start the stack directly from WSL:

```bash
cd ~/diplomatic-expression-docker && docker compose up -d
```

### Gateway not active

```bash
systemctl --user status openclaw-gateway
systemctl --user start openclaw-gateway
loginctl enable-linger "$(id -un)"
```

### Docker permission denied

```bash
newgrp docker
```

Or close and reopen the WSL terminal.

### Edge CDP not reachable (if `-EnableBrowser` was used)

**Check current state (PowerShell):**

```powershell
# Verify portproxy rule exists
netsh interface portproxy show all

# Verify firewall rule is enabled
Get-NetFirewallRule -DisplayName "OpenClaw Edge CDP 9222" | Select-Object DisplayName, Enabled, Direction, Action

# Verify Edge is running with remote debugging
Get-Process msedge -ErrorAction SilentlyContinue | Select-Object Id, ProcessName

# Verify port 9222 is listening
netstat -an | Select-String "9222"
```

**Check from WSL:**

```bash
# Get Windows host IP and test CDP endpoint
WIN_IP=$(ip route show default | awk '{print $3; exit}')
curl -s http://${WIN_IP}:9222/json/version | python3 -m json.tool
```

A successful response returns Edge browser info JSON. If it times out or is refused, restart CDP:

```powershell
& "C:\Scripts\Start-OpenClaw-CDP.ps1"
```

---

## Re-running safely

All scripts are idempotent — safe to run multiple times on the same machine.

```bash
./deploy.sh                    # re-run everything; skips what's already correct
./deploy.sh --only docker      # repair a single phase
./deploy.sh --only gateway
./deploy.sh --from openclaw    # resume after a failure
./deploy.sh --dry-run          # preview without making changes
bash ~/saai-deploy/healthcheck.sh   # validate health anytime
```

---

## Deployment checklist (sign-off)

Use this at the end of every client deployment:

- [ ] `./deploy.sh` completed with no FAIL lines
- [ ] `healthcheck.sh` shows 0 fail / 0 warn
- [ ] http://localhost:5678 loads and login works
- [ ] n8n API key generated and added to config.env
- [ ] Machine rebooted and stack came back up automatically
- [ ] (If `-EnableBrowser`) `curl -s http://$(ip route show default | awk '{print $3; exit}'):9222/json/version` returns Edge browser info JSON
