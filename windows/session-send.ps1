<#
.SYNOPSIS
  Send input to a session (like `tmux send-keys`).

.DESCRIPTION
  Connects to the session's named pipe and writes text to the child shell's
  stdin. By default a CRLF is appended (i.e. "press Enter"). Text is normally
  passed base64-encoded from the Linux wrapper so quoting survives the
  bash -> ssh -> powershell hops intact.

.EXAMPLE
  session-send.ps1 -Name build -Text 'dotnet build -c Release'
  session-send.ps1 -Name build -Base64 ZG90bmV0IGJ1aWxk
  session-send.ps1 -Name build -Text 'y' -NoEnter
#>
param(
  [Parameter(Mandatory)][string]$Name,
  [string]$Text,
  [string]$Base64,
  [switch]$NoEnter
)

if ($Base64) {
  $msg = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
} else {
  $msg = $Text
}
if (-not $NoEnter) { $msg += "`r`n" }

$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', "claude-session-$Name", [System.IO.Pipes.PipeDirection]::Out)
try {
  $pipe.Connect(3000)
} catch {
  Write-Error "session '$Name' is not running (could not connect to pipe)"
  exit 1
}
$w = New-Object System.IO.StreamWriter($pipe, (New-Object System.Text.UTF8Encoding($false)))
$w.Write($msg); $w.Flush(); $w.Dispose(); $pipe.Dispose()
