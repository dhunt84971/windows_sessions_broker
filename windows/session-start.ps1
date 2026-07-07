<#
.SYNOPSIS
  Start a named persistent session (like `tmux new -d -s <name>`).

.DESCRIPTION
  Launches session-server.ps1 hidden and detached so it keeps running after
  the SSH command that started it returns. If a live session with the same
  name already exists, this is a no-op.

.EXAMPLE
  session-start.ps1 -Name build -Shell cmd
#>
param(
  [Parameter(Mandatory)][string]$Name,
  [ValidateSet('cmd','powershell','pwsh')][string]$Shell = 'cmd',
  [string]$Root = "$env:USERPROFILE\.claude-sessions"
)

$dir     = Join-Path $Root $Name
$pidFile = Join-Path $dir 'server.pid'
if (Test-Path $pidFile) {
  $existing = Get-Content $pidFile
  if (Get-Process -Id $existing -ErrorAction SilentlyContinue) {
    Write-Host "session '$Name' already running (pid $existing)"
    exit 0
  }
}

$server = Join-Path $PSScriptRoot 'session-server.ps1'
Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
  '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass',
  '-File', $server, '-Name', $Name, '-Shell', $Shell
)

Start-Sleep -Milliseconds 800
Write-Host "started session '$Name' (shell: $Shell)"
