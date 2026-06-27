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
  [int]$CdpPort       = 9222,
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

# deploy.sh requires a working systemd user session during preflight. Enable
# systemd before the first Linux deployment while preserving other wsl.conf keys.
$systemdPatch = @'
import re
path = "/etc/wsl.conf"
try:
    text = open(path, encoding="utf-8").read()
except FileNotFoundError:
    text = ""
if re.search(r"(?m)^\[boot\]", text):
    def patch(match):
        block = match.group(0)
        if re.search(r"(?m)^systemd\s*=", block):
            block = re.sub(r"(?m)^systemd\s*=.*$", "systemd=true", block)
        else:
            block = block.rstrip() + "\nsystemd=true\n"
        return block
    text = re.sub(r"(?ms)^\[boot\].*?(?=^\[|\Z)", patch, text)
else:
    text = text.rstrip() + ("\n" if text.strip() else "") + "[boot]\nsystemd=true\n"
open(path, "w", encoding="utf-8").write(text)
'@
$systemdPatchB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($systemdPatch))
wsl -d $WslDistro -u root -- python3 -c "import base64;exec(base64.b64decode('$systemdPatchB64'))"
if ($LASTEXITCODE -ne 0) {
  throw "Could not enable systemd in /etc/wsl.conf for '$WslDistro'."
}
Write-Ok "WSL systemd enabled in /etc/wsl.conf"

# Apply .wslconfig and wsl.conf now, before detecting the adapter used by CDP.
Write-Info "Restarting WSL to apply memory and systemd settings..."
wsl --shutdown
Start-Sleep -Seconds 5
wsl -d $WslDistro -- sh -lc "echo wsl-ready" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "WSL distro '$WslDistro' did not restart successfully."
}
Start-Sleep -Seconds 5
Write-Ok "WSL restarted with systemd enabled"

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
# Wake via a logged launcher script (so a reboot leaves an audit trail you can
# inspect at %LOCALAPPDATA%\OpenClaw\openclaw-stack.log if the stack does not come up).
$scriptDir = "C:\Scripts"
New-Item -ItemType Directory -Force -Path $scriptDir | Out-Null
$stackScript = Join-Path $scriptDir "Start-OpenClaw-Stack.ps1"
$stackBody = @'
# Auto-generated by windows-setup.ps1 -- wakes the WSL2 VM at logon so systemd +
# linger start the OpenClaw gateway and the docker stack. Once the containers are
# running they keep the VM alive on their own. Logs next to itself.
$ErrorActionPreference = 'SilentlyContinue'
$logDir = Join-Path $env:LOCALAPPDATA 'OpenClaw'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'openclaw-stack.log'
('{0}  wake WSL (__DISTRO__)' -f (Get-Date -Format s)) | Out-File -FilePath $log -Append -Encoding utf8
Start-Process -WindowStyle Hidden -FilePath 'wsl.exe' -ArgumentList @('-d','__DISTRO__','--','sh','-c','sleep 300')
'@
$stackBody = $stackBody.Replace("__DISTRO__", $WslDistro)
Set-Content -Path $stackScript -Value $stackBody -Encoding UTF8
$autoAction   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$stackScript`""
$autoTrigger  = New-ScheduledTaskTrigger -AtLogOn
$autoTrigger.Delay = "PT1M30S"
$autoSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
$principal    = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $autoTaskName -Action $autoAction -Trigger $autoTrigger -Settings $autoSettings -Principal $principal -Description "OpenClaw: wake WSL2 VM 90s after logon  -- systemd+linger starts all services" | Out-Null
Write-Ok "Scheduled task registered: $autoTaskName (fires 90 s after logon, no path/user dependency)"

# --- Step 4: Edge CDP (optional) ---------------------------------------------
if ($EnableBrowser) {
  Write-Section "STEP 4 - EDGE CDP (PORTPROXY + FIREWALL + TASK)"

  # The vEthernet (WSL) adapter only exists while WSL2 is running.
  # Wake WSL now so the adapter appears, then detect the IP.
  Write-Info "Starting WSL2 to activate vEthernet adapter..."
  wsl -d $WslDistro -- echo "wsl ready" 2>&1 | Out-Null
  Start-Sleep -Seconds 4

  # Detect the Windows side of the WSL virtual adapter. The interface is used to
  # scope the firewall rule so CDP is not exposed through Wi-Fi or Ethernet.
  $wslAdapter = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
      $_.InterfaceAlias -like "vEthernet (WSL*" -and
      $_.IPAddress -notlike "169.*"
    } |
    Select-Object -First 1
  if (-not $wslAdapter) {
    throw "Could not detect the WSL vEthernet adapter after starting WSL2."
  }
  $winHostIp = $wslAdapter.IPAddress
  $wslInterface = $wslAdapter.InterfaceAlias
  Write-Info "WSL adapter: $wslInterface ($winHostIp)"

  # netsh portproxy relies on the Windows IP Helper service.
  Set-Service -Name iphlpsvc -StartupType Automatic
  Start-Service -Name iphlpsvc
  Write-Ok "Windows IP Helper service is running"

  # Bind the proxy independently of the current WSL gateway IP. The firewall
  # rule below limits access to the WSL virtual interface only.
  netsh interface portproxy delete v4tov4 listenport=$CdpPort listenaddress=0.0.0.0 2>$null | Out-Null
  netsh interface portproxy delete v4tov4 listenport=$CdpPort listenaddress=$winHostIp 2>$null | Out-Null
  netsh interface portproxy add v4tov4 `
    listenport=$CdpPort `
    listenaddress=0.0.0.0 `
    connectport=$CdpPort `
    connectaddress=127.0.0.1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Could not create the Edge CDP portproxy." }
  Write-Ok "portproxy: WSL interface port $CdpPort -> 127.0.0.1:$CdpPort"

  # Recreate the rule to keep its interface scope correct and deterministic.
  $fwName = "OpenClaw Edge CDP $CdpPort"
  Remove-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue
  New-NetFirewallRule `
    -DisplayName $fwName `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort $CdpPort `
    -InterfaceAlias $wslInterface | Out-Null
  Write-Ok "Firewall rule restricted to: $wslInterface"

  # Resolve Edge path
  $edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
  if (-not (Test-Path $edge)) { $edge = "C:\Program Files\Microsoft\Edge\Application\msedge.exe" }
  if (-not (Test-Path $edge)) { throw "Microsoft Edge executable was not found." }

  # This script is run immediately and at every Windows login. It uses a
  # dedicated Edge profile, leaving the user's normal Edge windows untouched.
  $scriptDir = "C:\Scripts"
  New-Item -ItemType Directory -Force -Path $scriptDir | Out-Null
  $cdpScript = Join-Path $scriptDir "Start-OpenClaw-CDP.ps1"
  $cdpBody = @'
# Auto-generated by windows-setup.ps1  -- runs at every logon (elevated).
# Reboot-proof: wakes WSL, restores the portproxy, and launches a dedicated Edge
# automation profile with CDP. Logs to %LOCALAPPDATA%\OpenClaw.
$ErrorActionPreference = 'Stop'
$logDir = Join-Path $env:LOCALAPPDATA 'OpenClaw'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'openclaw-cdp.log'
function Log($m) { ('{0}  {1}' -f (Get-Date -Format s), $m) | Out-File -FilePath $log -Append -Encoding utf8 }
$Distro = '__DISTRO__'
$Edge   = '__EDGE__'
$CdpPort = __CDP_PORT__
$Profile = Join-Path $env:LOCALAPPDATA 'OpenClaw\Edge-CDP-Profile'
New-Item -ItemType Directory -Force -Path $Profile | Out-Null
Log '=== logon run ==='

# 1) Boot the WSL2 VM in the background so systemd + linger start the OpenClaw
#    gateway and the docker stack. Keep a session ~5 min while containers come up;
#    once running, the containers keep the VM alive on their own.
Start-Process -WindowStyle Hidden -FilePath 'wsl.exe' -ArgumentList @('-d', $Distro, '--', 'sh', '-c', 'sleep 300')
Log ('WSL boot requested (distro=' + $Distro + ')')

# 2) Restore the WSL-only proxy. Firewall scope is managed by windows-setup.ps1.
Set-Service -Name iphlpsvc -StartupType Automatic
Start-Service -Name iphlpsvc
netsh interface portproxy delete v4tov4 listenport=$CdpPort listenaddress=0.0.0.0 2>$null | Out-Null
netsh interface portproxy add v4tov4 listenport=$CdpPort listenaddress=0.0.0.0 connectport=$CdpPort connectaddress=127.0.0.1 | Out-Null
Log ('portproxy restored on port ' + $CdpPort)

# 3) Launch Edge only when the CDP endpoint is not already healthy.
$up = $false
try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:$CdpPort/json/version" | Out-Null; $up = $true } catch { $up = $false }
if (-not $up) {
  Start-Process -FilePath $Edge -ArgumentList @(
    "--remote-debugging-port=$CdpPort",
    '--remote-debugging-address=127.0.0.1',
    '--remote-allow-origins=*',
    "--user-data-dir=`"$Profile`"",
    '--no-first-run',
    '--no-default-browser-check'
  )
  Log ('launched dedicated Edge CDP profile: ' + $Profile)
} else {
  Log ('Edge CDP already listening on ' + $CdpPort)
}

# 4) Do not report success until Edge actually exposes /json/version.
$up = $false
for ($i = 0; $i -lt 30; $i++) {
  try {
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:$CdpPort/json/version" | Out-Null
    $up = $true
    break
  } catch {
    Start-Sleep -Seconds 2
  }
}
if (-not $up) { Log 'ERROR: Edge CDP did not become ready after 60 seconds'; exit 1 }
Log 'Edge CDP is ready'
exit 0
'@
  $cdpBody = $cdpBody.Replace("__DISTRO__", $WslDistro).Replace("__EDGE__", $edge).Replace("__CDP_PORT__", [string]$CdpPort)
  Set-Content -Path $cdpScript -Value $cdpBody -Encoding UTF8
  Write-Ok "Edge CDP startup script: $cdpScript"

  # Scheduled task at logon (idempotent)
  $taskName = "OpenClaw-CDP-Autostart"
  if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  }
  $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$cdpScript`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  $settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew
  $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "OpenClaw: restore portproxy + start dedicated Edge CDP at logon" | Out-Null
  Write-Ok "Scheduled task registered: $taskName (runs at logon)"

  # Run the same scheduled task now so the first deploy does not need a logout.
  Write-Info "Starting Edge CDP now..."
  Start-ScheduledTask -TaskName $taskName
  $cdpReady = $false
  for ($i = 0; $i -lt 45; $i++) {
    try {
      $cdp = Invoke-RestMethod -TimeoutSec 2 "http://127.0.0.1:$CdpPort/json/version"
      $cdpReady = $true
      break
    } catch {
      Start-Sleep -Seconds 2
    }
  }
  if (-not $cdpReady) {
    throw "Edge CDP did not start. Check: $env:LOCALAPPDATA\OpenClaw\openclaw-cdp.log"
  }
  if (-not (Test-NetConnection -ComputerName $winHostIp -Port $CdpPort -InformationLevel Quiet)) {
    throw "CDP works on localhost but the WSL portproxy is not reachable at ${winHostIp}:$CdpPort."
  }
  Write-Ok "Edge CDP ready: $($cdp.Browser)"
  Write-Ok "WSL portproxy reachable at ${winHostIp}:$CdpPort"
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
Write-Host "    1. Open $WslDistro"
Write-Host "    2. Clone saai-zero-touch and run: ./deploy.sh"
Write-Host "    3. Validate: bash ~/saai-deploy/healthcheck.sh"
Write-Host ""
