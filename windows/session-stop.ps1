<#
.SYNOPSIS
  Stop a session (like `tmux kill-session`).

.DESCRIPTION
  Sends the STOP sentinel over the pipe so the broker kills its child shell
  and exits cleanly. Falls back to killing the recorded server PID if the
  pipe is unreachable.
#>
param(
  [Parameter(Mandatory)][string]$Name,
  [string]$Root = "$env:USERPROFILE\.claude-sessions"
)

$sent = $false
try {
  $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', "claude-session-$Name", [System.IO.Pipes.PipeDirection]::Out)
  $pipe.Connect(2000)
  $w = New-Object System.IO.StreamWriter($pipe, (New-Object System.Text.UTF8Encoding($false)))
  $w.Write("`0STOP`0"); $w.Flush(); $w.Dispose(); $pipe.Dispose()
  $sent = $true
} catch { }

if (-not $sent) {
  $pidFile = Join-Path (Join-Path $Root $Name) 'server.pid'
  if (Test-Path $pidFile) {
    $sp = Get-Content $pidFile
    Stop-Process -Id $sp -ErrorAction SilentlyContinue
  }
}

# Remove the scheduled task used for visible (SSH-launched) sessions, if any.
Unregister-ScheduledTask -TaskName "claude-session-$Name" -Confirm:$false -ErrorAction SilentlyContinue

Write-Host "stopped session '$Name'"
