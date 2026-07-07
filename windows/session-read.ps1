<#
.SYNOPSIS
  Read session output (like `tmux capture-pane -p`).

.DESCRIPTION
  Prints captured output from the session log. Default shows the last -Tail
  lines. -New returns only output produced since the previous -New read
  (incremental, tracked via a byte offset). -All dumps the whole log.
  -Wait <sec> first blocks until output has been idle for ~1.5s or the
  timeout elapses -- handy for letting a build finish before reading.

.EXAMPLE
  session-read.ps1 -Name build
  session-read.ps1 -Name build -New
  session-read.ps1 -Name build -Wait 120 -New
#>
param(
  [Parameter(Mandatory)][string]$Name,
  [int]$Tail = 200,
  [switch]$New,
  [switch]$All,
  [int]$Wait = 0,
  [string]$Root = "$env:USERPROFILE\.claude-sessions"
)

$dir = Join-Path $Root $Name
$log = Join-Path $dir 'output.log'
$offsetFile = Join-Path $dir 'read.offset'

if (-not (Test-Path $log)) {
  Write-Error "no session '$Name' (log not found)"
  exit 1
}

if ($Wait -gt 0) {
  $idleMs   = 1500
  $deadline = (Get-Date).AddSeconds($Wait)
  $lastLen  = (Get-Item $log).Length
  $stable   = Get-Date
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    $now = (Get-Item $log).Length
    if ($now -ne $lastLen) { $lastLen = $now; $stable = Get-Date }
    elseif (((Get-Date) - $stable).TotalMilliseconds -ge $idleMs) { break }
  }
}

if ($New) {
  $off = 0
  if (Test-Path $offsetFile) { $off = [int64](Get-Content $offsetFile) }
  $fs = [System.IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
  try {
    $len = $fs.Length
    if ($off -gt $len) { $off = 0 }   # log was reset
    $fs.Seek($off, 'Begin') | Out-Null
    $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
    $out = $sr.ReadToEnd()
    $sr.Dispose()
    Set-Content -Path $offsetFile -Value $len
  } finally {
    $fs.Dispose()
  }
  if ($out) { Write-Output $out }
}
elseif ($All) {
  Get-Content -Raw -Path $log
}
else {
  Get-Content -Path $log -Tail $Tail
}
