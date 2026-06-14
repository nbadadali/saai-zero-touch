# SAAI Stack — Deployment Runbook
**OpenClaw + n8n on WSL2 (Ubuntu / Windows)**

This package deploys the stack on a client machine with the **minimum possible
human interaction**. It is not 100% zero-touch — and this document is honest
about exactly why, and which steps remain manual.

---

## Why it can't be a single command (the honest version)

Three things are imposed by Windows + WSL2 and cannot be scripted away:

1. **WSL must exist before any Linux script can run.** If the client has no WSL2
   yet, installing it (`wsl --install`) requires a **Windows reboot**.
2. **`.wslconfig` and `/etc/wsl.conf` only apply after `wsl --shutdown`.** Memory
   tuning and systemd activation need a WSL restart to take effect.
3. **Edge remote-debugging and the WSL→Windows portproxy do not survive reboot.**
   They are re-applied automatically at each login by a Scheduled Task, but that
   task must be registered once (done by `windows-setup.ps1`).

Everything else **is** automated and idempotent. Realistic human touchpoints: **3**.

---

## The 3 touchpoints

| # | Where | Action | One-time? |
|---|-------|--------|-----------|
| 1 | Windows PowerShell (Admin) | `wsl --install` **only if WSL2 isn't present**, then reboot | yes |
| 2 | Windows PowerShell (Admin) | run `windows-setup.ps1`, then `wsl --shutdown` | yes |
| 3 | WSL2 Ubuntu | fill `config.env`, run `./deploy.sh` | yes |

After this, every reboot brings the whole stack back up on its own.

---

## Files in this package

| File | Runs on | Purpose |
|------|---------|---------|
| `config.env.example` | WSL2 | Template — copy to `config.env`, fill once. **Single source of truth.** |
| `deploy.sh` | WSL2 | Phased, idempotent, resumable Linux deployment |
| `healthcheck.sh` | WSL2 | Version-proof validation (run anytime) |
| `windows-setup.ps1` | Windows | Host config: `.wslconfig`, autostart, optional Edge CDP |
| `README.md` | — | This runbook |

---

## Procedure

### Touchpoint 1 — Ensure WSL2 exists (skip if already installed)

In **PowerShell as Administrator**:

```powershell
wsl --list --verbose      # if Ubuntu shows VERSION 2, skip to Touchpoint 2
wsl --install -d Ubuntu   # otherwise install, then REBOOT Windows
```

After reboot, open Ubuntu once to create your Linux user.

### Touchpoint 2 — Configure the Windows host

Copy this folder somewhere on Windows (or access it via `\\wsl$`). In
**PowerShell as Administrator**:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\windows-setup.ps1 -WslDistro 'Ubuntu' -WslUser '<your-linux-user>'
```

Add `-EnableBrowser` only if this client needs OpenClaw browser automation:

```powershell
.\windows-setup.ps1 -WslUser '<your-linux-user>' -MemoryGB 8 -EnableBrowser
```

Then apply WSL settings:

```powershell
wsl --shutdown
```

### Touchpoint 3 — Deploy the stack (inside WSL2)

Open Ubuntu. Get this folder into WSL (it may already be reachable under
`/mnt/c/...`; copy it to your home for cleanliness):

```bash
cp -r /mnt/c/path/to/saai-deploy ~/saai-deploy && cd ~/saai-deploy
cp config.env.example config.env
nano config.env          # set LINUX_USER, leave secrets blank to auto-generate
chmod +x deploy.sh healthcheck.sh
./deploy.sh
```

That single command runs all phases: packages → wsl_config → docker → node →
openclaw → gateway → (browser) → repo → env_file → stack → autostart → validate.

When it finishes, it runs the health check automatically and prints the n8n URL.

---

## Operating the deployment

### Re-run safely (idempotent)
```bash
./deploy.sh                  # re-runs everything; skips what's already done
```

### Run or repair a single phase
```bash
./deploy.sh --only docker
./deploy.sh --only gateway
./deploy.sh --only env_file  # after editing config.env / adding N8N_API_KEY
```

### Resume after a failure
The script prints the exact resume command on any error, e.g.:
```bash
./deploy.sh --from openclaw
```

### Preview without changing anything
```bash
./deploy.sh --dry-run
```

### Validate health anytime
```bash
bash ~/saai-deploy/healthcheck.sh
```

---

## What survives a reboot

| Item | Persists? | Restored by |
|------|-----------|-------------|
| Docker containers | ✅ | `restart: unless-stopped` |
| Docker service | ✅ | systemd (enabled) |
| OpenClaw gateway | ✅ | systemd user service + linger |
| `.wslconfig` / systemd | ✅ | written once by `windows-setup.ps1` |
| Windows Startup launcher | ✅ | `windows-setup.ps1` |
| Stack auto-up on login | ✅ | `wsl-autostart.sh` via Startup launcher |
| portproxy (9222) | ❌ → re-applied | Scheduled Task at logon |
| Edge with `--remote-debugging` | ❌ → relaunched | Scheduled Task at logon |

---

## Troubleshooting

**`docker` permission denied right after install** — group membership needs a
fresh shell. The scripts use `sg docker` to work around it during the run; for
your own shell, run `newgrp docker` or just reopen the terminal.

**Gateway not active** —
```bash
systemctl --user status openclaw-gateway
systemctl --user start openclaw-gateway
loginctl enable-linger "$(id -un)"
```

**`.wslconfig` changes ignored** — you must `wsl --shutdown` (from PowerShell),
then reopen WSL.

**n8n loads but workflows fail** —
```bash
cd ~/diplomatic-expression-docker
docker compose logs --tail 80 n8n
docker compose logs --tail 80 postgres redis
```
Usual causes: a `CHANGE_ME` left in `.env`, or Postgres/Redis not healthy yet.

**Edge CDP not reachable from WSL** —
```bash
curl http://172.17.0.1:9222/json/version
```
If empty/refused, in PowerShell (Admin): `& "C:\Scripts\Start-OpenClaw-CDP.ps1"`.

---

## OpenClaw install method note

`config.env` has `OPENCLAW_INSTALL_METHOD` (`npm` | `script` | `skip`). The
default is `npm`. If OpenClaw is already installed on the client, set it to
`skip` — `deploy.sh` will detect and preserve the existing install and will
**never overwrite a working `openclaw-gateway.service`**.

---

## Scaling beyond one machine

For a fleet of client machines, the natural next step is to wrap `deploy.sh` and
`windows-setup.ps1` in a configuration-management layer (Ansible for the Linux
side; a signed MSI / Intune package or DSC for the Windows side). The phase
structure here maps cleanly onto Ansible roles when that time comes. For one
machine, this toolkit is the right level of tooling.
