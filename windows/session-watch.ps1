<#
.SYNOPSIS
  Live-tail a session's output (like `tail -f`, or watching a tmux pane).

.DESCRIPTION
  Streams the session log as new output is appended, so activity can be watched
  from the Linux host over SSH regardless of Windows desktop session isolation.
  Runs until interrupted (Ctrl-C from the caller / closing the SSH connection).
#>
param(
  [Parameter(Mandatory)][string]$Name,
  [int]$Tail = 40,
  [string]$Root = "$env:USERPROFILE\.claude-sessions"
)

$log = Join-Path (Join-Path $Root $Name) 'output.log'
if (-not (Test-Path $log)) {
  Write-Error "no session '$Name' (log not found)"
  exit 1
}

Get-Content -Path $log -Tail $Tail -Wait
