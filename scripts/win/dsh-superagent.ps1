# dsh-superagent service control for Windows.
#
# The upstream helper (scripts/dsh-superagent) is POSIX-only: it uses Python's
# fcntl, `ps` and tmux, none of which exist on Windows. This script launches the
# same DSH profile directly and manages the process by its listening port.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\win\dsh-superagent.ps1 start
#   ... stop | restart | status | url | log
#
# Environment overrides (set them as *user* environment variables: the service is
# created through WMI, so it does not inherit variables that exist only in the
# shell you run this script from):
#   DSH_PROFILE  profile to run     (default: superagent)
#   DSH_PORT     panel port         (default: 3082)
#   DSH_LOG      service log file   (default: %LOCALAPPDATA%\dsh-superagent\service.log)
#
# The profile itself, its state directory and the panel port live in
# <DSH_HOME>\profiles\<profile>\cordis.patch.yml; see WINDOWS.md.

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('start', 'stop', 'restart', 'status', 'url', 'log')]
  [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'

$Profile = if ($env:DSH_PROFILE) { $env:DSH_PROFILE } else { 'superagent' }
$Port = if ($env:DSH_PORT) { [int]$env:DSH_PORT } else { 3082 }
$RunCmd = Join-Path $PSScriptRoot 'run-superagent.cmd'
$LogFile = if ($env:DSH_LOG) { $env:DSH_LOG } else { Join-Path $env:LOCALAPPDATA 'dsh-superagent\service.log' }

function Get-ServicePid {
  $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($conn) { return $conn.OwningProcess }
  return $null
}

function Get-Url {
  if (-not (Test-Path $LogFile)) { return $null }
  $match = [regex]::Match((Get-Content $LogFile -Raw -ErrorAction SilentlyContinue),
    'http://127\.0\.0\.1:' + $Port + '/\?token=\S+')
  if ($match.Success) { return $match.Value }
  return $null
}

function Test-Api {
  try {
    $reply = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/orchestrator/api/state" `
      -Headers @{ 'x-orchestrator-request' = '1' } -TimeoutSec 5
    return $reply
  } catch { return $null }
}

function Start-Service {
  $running = Get-ServicePid
  if ($running) { Write-Host "already running (pid $running)"; Show-Status; return }
  if (-not (Test-Path $RunCmd)) { throw "launcher not found: $RunCmd" }

  # Create the process through WMI rather than as a child of this shell: a child
  # would sit inside the same job object, and would be killed together with the
  # terminal (or agent session) that ran this script. Created this way the
  # service outlives it.
  Write-Host "starting profile '$Profile'; the panel needs 20-40 s to answer"
  Write-Host "log: $LogFile"
  $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
    -Arguments @{ CommandLine = "cmd.exe /d /c `"`"$RunCmd`"`"" }
  if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create failed: $($result.ReturnValue)" }

  for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep -Seconds 2
    if (Test-Api) { break }
  }

  if (Test-Api) {
    Show-Status
  } else {
    Write-Host 'did not come up; last lines of the log:'
    if (Test-Path $LogFile) { Get-Content $LogFile -Tail 20 }
  }
}

function Stop-Service {
  $servicePid = Get-ServicePid
  if (-not $servicePid) { Write-Host 'not running'; return }

  # Kill the launcher cmd.exe first. DSH can re-exec itself, and a child started
  # by that launcher inherits the launcher's environment: leaving it alive is how
  # a restart silently keeps running with the previous DSH_HOME or GH_CONFIG_DIR.
  $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$servicePid" -ErrorAction SilentlyContinue).ParentProcessId
  if ($parent) {
    $parentProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$parent" -ErrorAction SilentlyContinue
    if ($parentProcess -and $parentProcess.Name -eq 'cmd.exe' -and $parentProcess.CommandLine -like '*run-superagent.cmd*') {
      Stop-Process -Id $parent -Force -ErrorAction SilentlyContinue
    }
  }

  Stop-Process -Id $servicePid -Force
  Write-Host "stopped (pid $servicePid)"

  # proper-lockfile leaves <stateDir>.lock behind after a force-kill and treats it
  # as held for 30 s (src/app/runtime.ts:93, stale: 30_000); a restart inside that
  # window fails with "Lock file is already being held". Only report it: deleting
  # the lock of a service that is still starting would be worse.
  if ($env:DSH_STATE_DIR) {
    $lock = "$($env:DSH_STATE_DIR).lock"
    if (Test-Path $lock) {
      Write-Host "note: $lock is still there; a restart within 30 s will fail with"
      Write-Host '      "Lock file is already being held". Wait, or stop again.'
    }
  }
}

function Show-Status {
  $state = Test-Api
  if (-not $state) { Write-Host 'state: not running'; return }
  Write-Host "state:      running (pid $(Get-ServicePid))"
  Write-Host "stateDir:   $($state.setup.machine.stateDir)"
  Write-Host "paused:     $($state.setup.paused)"
  if ($state.setup.problem) {
    Write-Host "setup:      $($state.setup.problem.detail)"
  } else {
    Write-Host 'setup:      ok'
  }
  if ($state.setup.feishuProblem) { Write-Host "feishu:     $($state.setup.feishuProblem.detail)" }
  Write-Host "queued:     $($state.load.queued)  running: $($state.load.running)  maxWorkers: $($state.load.maxWorkers)"
  foreach ($name in $state.health.PSObject.Properties.Name) {
    $part = $state.health.$name
    Write-Host ("  {0,-12} {1,-8} {2}" -f $name, $part.state, $part.detail)
  }
  $url = Get-Url
  if ($url) { Write-Host "panel:      $url" }
}

switch ($Action) {
  'start' { Start-Service }
  'stop' { Stop-Service }
  'restart' { Stop-Service; Start-Sleep -Seconds 2; Start-Service }
  'status' { Show-Status }
  'url' {
    $url = Get-Url
    if ($url) { Write-Host $url } else { Write-Host 'no panel URL in the log yet' }
  }
  'log' {
    if (Test-Path $LogFile) { Get-Content $LogFile -Tail 60 } else { Write-Host 'no log yet' }
  }
}
