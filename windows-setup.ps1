<#
.SYNOPSIS
  Windows host configuration for the OpenClaw + n8n stack (WSL2).

.DESCRIPTION
  Idempotent. Safe to re-run. Configures:
    - .wslconfig memory/swap tuning
    - Scheduled Task: wakes the WSL2 VM at logon so systemd can start services
    - (optional) Edge CDP: portproxy + firewall + scheduled task

  The Windows side requires only the WSL distro name.
  All Linux paths and usernames are managed entirely by deploy.sh inside WSL.

.EXAMPLE
  Set-ExecutionPolicy Bypass -Scope Process -Force
  .\windows-setup.ps1 -WslDistro 'Ubuntu-22.04'

.EXAMPLE
  .\windows-setup.ps1 -WslDistro 'Ubuntu-22.04' -MemoryGB 8 -EnableBrowser
#>

[CmdletBinding()]
param(
  [string]$WslDistro  = "Ubuntu",
  # Deprecated  -- no longer used. Accepted for backward compatibility only.
  [string]$WslUser    = "",
  # Deprecated  -- no longer used. Accepted for backward compatibility only.
  [string]$WslRepoDir = "",
  [int]$MemoryGB      = 6,
  [int]$SwapGB        = 4,
  [switch]$EnableBrowser
)

$ErrorActionPreference = "Stop"

function Write-Section($t) { Write-Host "`n==========================================" -ForegroundColor Cyan; Write-Host "  $t" -ForegroundColor Cyan; Write-Host "==========================================" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Info($m) { Write-Host "[INFO] $m" -ForegroundColor Blue }
function Write-Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red }

# --- Admin check -------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Fail "Must run as Administrator. Right-click PowerShell -> Run as Administrator."
  exit 1
}
Write-Ok "Running as Administrator"

# --- Step 1: confirm distro --------------------------------------------------
Write-Section "STEP 1 - WSL DISTRO"
# Use 'wsl --list' to check distro existence  -- avoids loading .wslconfig which
# may contain unsupported keys (e.g. wsl2.pageReporting) on older WSL builds
# that would cause a non-zero exit code and false "distro not found" error.
$distroList = (wsl --list --quiet 2>&1) -replace "`0", ""
$distroFound = $distroList | Where-Object { $_ -match [regex]::Escape($WslDistro) }
if (-not $distroFound) {
  Write-Fail "Distro '$WslDistro' not found."
  Write-Fail "Re-run with the correct -WslDistro name (e.g. -WslDistro 'Ubuntu-22.04')."
  exit 1
} else {
  Write-Ok "Distro '$WslDistro' confirmed"
}

# --- Step 2: .wslconfig ------------------------------------------------------
Write-Section "STEP 2 - WSL MEMORY (.wslconfig)"
$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
$wslConfig = @"
[wsl2]
memory=${MemoryGB}GB
swap=${SwapGB}GB
localhostForwarding=true
"@
if (Test-Path $wslConfigPath) {
  Copy-Item $wslConfigPath "$wslConfigPath.backup" -Force
  Write-Info "Existing .wslconfig backed up to .wslconfig.backup"
}
Set-Content -Path $wslConfigPath -Value $wslConfig -Encoding UTF8
Write-Ok ".wslconfig written ($MemoryGB GB mem / $SwapGB GB swap)"
Write-Warn "Run 'wsl --shutdown' for memory settings to take effect"

# --- Step 3: login autostart -------------------------------------------------
Write-Section "STEP 3 - LOGIN AUTOSTART (WSL WAKE)"

# Design: Windows is responsible ONLY for waking the WSL2 VM after login.
# Once WSL starts, systemd (PID 1) uses linger to auto-start user services:
#   openclaw-gateway.service   -- OpenClaw AI gateway
#   n8n-stack.service          -- Docker compose stack (n8n, postgres, redis, mcp)
# No Linux paths or usernames are needed here. deploy.sh owns all of that.

# Remove legacy Startup-folder launcher if present from an older deployment.
$startupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$legacyEntry = Join-Path $startupDir "OpenClaw-n8n-autostart.cmd"
if (Test-Path $legacyEntry) {
  Remove-Item $legacyEntry -Force
  Write-Info "Removed legacy Startup entry: $legacyEntry"
}
$legacyLauncher = Join-Path $env:LOCALAPPDATA "OpenClaw\wsl-autostart.cmd"
if (Test-Path $legacyLauncher) {
  Remove-Item $legacyLauncher -Force
  Write-Info "Removed legacy launcher: $legacyLauncher"
}

# Register (or refresh) the Scheduled Task that wakes WSL 90 s after logon.
# sleep 300 keeps the WSL VM alive for 5 minutes  -- enough time for Docker to
# start and containers to come up, after which Docker processes keep WSL alive.
$autoTaskName = "OpenClaw-Stack-DelayedStart"
if (Get-ScheduledTask -TaskName $autoTaskName -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName $autoTaskName -Confirm:$false
}
$autoAction   = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $WslDistro -- sleep 300"
$autoTrigger  = New-ScheduledTaskTrigger -AtLogOn
$autoTrigger.Delay = "PT1M30S"
$autoSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
$principal    = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $autoTaskName -Action $autoAction -Trigger $autoTrigger -Settings $autoSettings -Principal $principal -Description "OpenClaw: wake WSL2 VM 90s after logon  -- systemd+linger starts all services" | Out-Null
Write-Ok "Scheduled task registered: $autoTaskName (fires 90 s after logon, no path/user dependency)"

# --- Step 4-6: Edge CDP (optional) -------------------------------------------
if ($EnableBrowser) {
  Write-Section "STEP 4 - EDGE CDP (PORTPROXY + FIREWALL + TASK)"

  # Detect Windows WSL vEthernet adapter IP
  # (resolv.conf nameserver can return 10.255.255.254 on some WSL builds, which is not routable for portproxy)
  $winHostIp = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
      $_.InterfaceAlias -like "vEthernet (WSL*" -and
      $_.IPAddress -notlike "169.*"
    } |
    Select-Object -First 1 -ExpandProperty IPAddress)
  if (-not $winHostIp) {
    throw "Could not detect WSL vEthernet IP address. Ensure WSL2 is running and the vEthernet (WSL) adapter is present."
  }
  Write-Info "WSL vEthernet adapter IP: $winHostIp"

  # portproxy (idempotent: delete then add)
  netsh interface portproxy delete v4tov4 listenport=9222 listenaddress=$winHostIp 2>$null | Out-Null
  netsh interface portproxy add v4tov4 `
    listenport=9222 `
    listenaddress=$winHostIp `
    connectport=9222 `
    connectaddress=127.0.0.1 | Out-Null
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

# --- Verification ------------------------------------------------------------
Write-Section "VERIFICATION"
Write-Info "Scheduled tasks (OpenClaw):"
Get-ScheduledTask | Where-Object { $_.TaskName -like "*OpenClaw*" } | Select-Object TaskName, State | Format-Table -AutoSize
if ($EnableBrowser) {
  Write-Info "portproxy:"; netsh interface portproxy show all
}

Write-Host "`n============================================" -ForegroundColor Green
Write-Host "  WINDOWS SETUP COMPLETE" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Next:"
Write-Host "    1. wsl --shutdown        (apply .wslconfig + systemd)"
Write-Host "    2. Reopen WSL, run:  ./deploy.sh"
Write-Host "    3. Validate:         bash ~/InitialSetup/healthcheck.sh (or healthcheck.sh in the deploy folder)"
Write-Host ""
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     