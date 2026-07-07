<#
.SYNOPSIS
  Start a named persistent session (like `tmux new -d -s <name>`).

.DESCRIPTION
  By default the session opens a VISIBLE window on the Windows desktop showing
  the shell's live output, so its activity can be watched directly.

  Because a process launched over SSH runs in the SSH logon session (not the
  interactive desktop), a visible launch triggered over SSH is routed into the
  active console session via a one-shot scheduled task, so the window appears on
  the desktop of the logged-in user. This requires that same user to be logged in
  at the console/RDP, and registering the task may require an administrator.

  -Hidden runs the session headless and detached (no window), the way a pure
  background service would; this does not require a logged-in console user.

  If a live session with the same name already exists, this is a no-op.

.EXAMPLE
  session-start.ps1 -Name build -Shell cmd
  session-start.ps1 -Name build -Shell cmd -Hidden
#>
param(
  [Parameter(Mandatory)][string]$Name,
  [ValidateSet('cmd','powershell','pwsh')][string]$Shell = 'cmd',
  [switch]$Hidden,
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
$serverArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $server,
                '-Name', $Name, '-Shell', $Shell)

if ($Hidden) {
  # Headless/detached: no window, no dependency on a logged-in console user.
  Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList (@('-WindowStyle','Hidden') + $serverArgs)
  Start-Sleep -Milliseconds 800
  Write-Host "started session '$Name' (shell: $Shell, hidden)"
}
elseif ($env:SSH_CONNECTION) {
  # Launched over SSH: to get a window on the physical desktop we must run in the
  # active console session, which a scheduled task with an Interactive principal
  # does. This also survives the SSH channel closing.
  $taskName = "claude-session-$Name"
  $argString = ($serverArgs | ForEach-Object {
    if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
  }) -join ' '

  $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argString
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
  $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

  Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
  Start-ScheduledTask -TaskName $taskName
  Start-Sleep -Milliseconds 800
  Write-Host "started session '$Name' (shell: $Shell, visible on console desktop)"
  Write-Host "note: the window shows on the desktop only if '$env:USERNAME' is logged in at the console/RDP."
}
else {
  # Already running interactively on the box: just open a normal window.
  Start-Process -FilePath 'powershell.exe' -ArgumentList $serverArgs
  Start-Sleep -Milliseconds 800
  Write-Host "started session '$Name' (shell: $Shell, visible)"
}
