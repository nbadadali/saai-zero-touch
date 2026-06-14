<#
.SYNOPSIS
  Windows host configuration for the OpenClaw + n8n stack (WSL2).

.DESCRIPTION
  Idempotent. Safe to re-run. Configures:
    - .wslconfig memory/swap tuning
    - Windows login autostart launcher (Startup folder)
    - (optional) Edge CDP: portproxy + firewall + scheduled task

.EXAMPLE
  Set-ExecutionPolicy Bypass -Scope Process -Force
  .\windows-setup.ps1 -WslDistro 'Ubuntu' -WslUser 'nishant'

.EXAMPLE
  .\windows-setup.ps1 -WslUser 'nishant' -MemoryGB 8 -SwapGB 4 -EnableBrowser
#>

[CmdletBinding()]
param(
  [string]$WslDistro = "Ubuntu",
  [string]$WslUser   = "nishant",
  [int]$MemoryGB     = 6,
  [int]$SwapGB       = 4,
  [switch]$EnableBrowser
)

$ErrorActionPreference = "Stop"

function Write-Section($t) { Write-Host "`n══════════════════════════════════════════" -ForegroundColor Cyan; Write-Host "  $t" -ForegroundColor Cyan; Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Info($m) { Write-Host "[INFO] $m" -ForegroundColor Blue }
function Write-Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red }

# ─── Admin check ─────────────────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Fail "Must run as Administrator. Right-click PowerShell -> Run as Administrator."
  exit 1
}
Write-Ok "Running as Administrator"

# ─── Step 1: confirm distro ──────────────────────────────────────────────────
Write-Section "STEP 1 - WSL DISTRO"
$distroList = (wsl -l -q) -join "`n"
Write-Info "Installed distros:`n$distroList"
if ($distroList -notmatch [regex]::Escape($WslDistro)) {
  Write-Warn "Distro '$WslDistro' not found above. Update -WslDistro if the name differs."
} else {
  Write-Ok "Distro '$WslDistro' confirmed"
}

# ─── Step 2: .wslconfig ──────────────────────────────────────────────────────
Write-Section "STEP 2 - WSL MEMORY (.wslconfig)"
$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
$wslConfig = @"
[wsl2]
memory=${MemoryGB}GB
swap=${SwapGB}GB
localhostForwarding=true
pageReporting=true
autoMemoryReclaim=gradual
"@
if (Test-Path $wslConfigPath) {
  Copy-Item $wslConfigPath "$wslConfigPath.backup" -Force
  Write-Info "Existing .wslconfig backed up to .wslconfig.backup"
}
Set-Content -Path $wslConfigPath -Value $wslConfig -Encoding UTF8
Write-Ok ".wslconfig written ($MemoryGB GB mem / $SwapGB GB swap)"
Write-Warn "Run 'wsl --shutdown' for memory settings to take effect"

# ─── Step 3: login autostart ─────────────────────────────────────────────────
Write-Section "STEP 3 - LOGIN AUTOSTART"
$launcherDir = Join-Path $env:LOCALAPPDATA "OpenClaw"
New-Item -ItemType Directory -Force -Path $launcherDir | Out-Null

$wslLauncher = Join-Path $launcherDir "wsl-autostart.cmd"
$wslLauncherBody = "@echo off`r`nwsl.exe -d $WslDistro -- bash -lc `"/home/$WslUser/diplomatic-expression-docker/scripts/wsl-autostart.sh`""
Set-Content -Path $wslLauncher -Value $wslLauncherBody -Encoding ASCII
Write-Ok "WSL launcher: $wslLauncher"

$startupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$startupEntry = Join-Path $startupDir "OpenClaw-n8n-autostart.cmd"
$startupBody = "@echo off`r`ncall `"$wslLauncher`""
Set-Content -Path $startupEntry -Value $startupBody -Encoding ASCII
Write-Ok "Startup entry: $startupEntry"

# ─── Step 4-6: Edge CDP (optional) ───────────────────────────────────────────
if ($EnableBrowser) {
  Write-Section "STEP 4 - EDGE CDP (PORTPROXY + FIREWALL + TASK)"

  # Detect Windows host IP as seen from WSL (nameserver in resolv.conf)
  $winHostIp = "172.17.0.1"
  try {
    $ns = (wsl -d $WslDistro -- sh -c "grep nameserver /etc/resolv.conf | awk '{print `$2}'").Trim()
    if ($ns -match '^\d+\.\d+\.\d+\.\d+$') { $winHostIp = $ns; Write-Info "WSL nameserver (host IP): $winHostIp" }
  } catch { Write-Warn "Could not detect host IP; using $winHostIp" }

  # portproxy (idempotent: delete then add)
  netsh interface portproxy delete v4tov4 listenport=9222 listenaddress=$winHostIp 2>$null | Out-Null
  netsh interface portproxy add v4tov4 listenport=9222 listenaddress=$winHostIp connectport=9222 connectaddress=127.0.0.1 | Out-Null
  Write-Ok "portproxy: ${winHostIp}:9222 -> 127.0.0.1:9222"

  # firewall
  $fwName = "OpenClaw Edge CDP 9222"
  if (-not (Get-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $fwName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 9222 | Out-Null
    Write-Ok "Firewall rule created: $fwName"
  } else {
    Enable-NetFirewallRule -DisplayName $fwName
    Write-Ok "Firewall rule present: $fwName"
  }

  # Resolve Edge path
  $edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
  if (-not (Test-Path $edge)) { $edge = "C:\Program Files\Microsoft\Edge\Application\msedge.exe" }

  # Startup script (single-quoted here-string: no escaping pitfalls).
  # Placeholders __IP__ and __EDGE__ are substituted afterwards.
  $scriptDir = "C:\Scripts"
  New-Item -ItemType Directory -Force -Path $scriptDir | Out-Null
  $cdpScript = Join-Path $scriptDir "Start-OpenClaw-CDP.ps1"
  $cdpBody = @'
# Auto-generated by windows-setup.ps1
# Re-applies portproxy (does not survive reboot) and launches Edge with CDP.
netsh interface portproxy delete v4tov4 listenport=9222 listenaddress=__IP__ 2>$null | Out-Null
netsh interface portproxy add v4tov4 listenport=9222 listenaddress=__IP__ connectport=9222 connectaddress=127.0.0.1

Stop-Process -Name msedge -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-Process -FilePath "__EDGE__" -ArgumentList @(
  "--remote-debugging-port=9222",
  "--remote-debugging-address=0.0.0.0",
  "--remote-allow-origins=*"
)
'@
  $cdpBody = $cdpBody.Replace("__IP__", $winHostIp).Replace("__EDGE__", $edge)
  Set-Content -Path $cdpScript -Value $cdpBody -Encoding UTF8
  Write-Ok "Edge CDP startup script: $cdpScript"

  # Scheduled task at logon (idempotent)
  $taskName = "OpenClaw-CDP-Autostart"
  if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  }
  $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$cdpScript`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  $settings= New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Description "OpenClaw: restore portproxy + start Edge CDP at logon" | Out-Null
  Write-Ok "Scheduled task registered: $taskName (runs at logon)"
} else {
  Write-Section "STEP 4 - EDGE CDP"
  Write-Info "Skipped (run with -EnableBrowser to configure Edge CDP)"
}

# ─── Verification ────────────────────────────────────────────────────────────
Write-Section "VERIFICATION"
Write-Info "Startup folder:"
Get-ChildItem $startupDir -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $($_.Name)" }
if ($EnableBrowser) {
  Write-Info "`nportproxy:"; netsh interface portproxy show all
  Write-Info "`nScheduled tasks (OpenClaw):"; Get-ScheduledTask | Where-Object { $_.TaskName -like "*OpenClaw*" } | Select-Object TaskName, State | Format-Table -AutoSize
}

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host "  WINDOWS SETUP COMPLETE" -ForegroundColor Green
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host ""
Write-Host "  Next:"
Write-Host "    1. wsl --shutdown        (apply .wslconfig + systemd)"
Write-Host "    2. Reopen WSL, run:  ./deploy.sh"
Write-Host "    3. Validate:         bash ~/InitialSetup/healthcheck.sh (or healthcheck.sh in the deploy folder)"
Write-Host ""
