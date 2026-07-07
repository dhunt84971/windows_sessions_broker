<#
.SYNOPSIS
  List sessions and whether they are still running (like `tmux ls`).
#>
param(
  [string]$Root = "$env:USERPROFILE\.claude-sessions"
)

if (-not (Test-Path $Root)) { Write-Host "no sessions"; exit 0 }

Get-ChildItem -Path $Root -Directory | ForEach-Object {
  $pidFile = Join-Path $_.FullName 'server.pid'
  $log     = Join-Path $_.FullName 'output.log'

  $alive = $false
  if (Test-Path $pidFile) {
    $sp = Get-Content $pidFile
    if (Get-Process -Id $sp -ErrorAction SilentlyContinue) { $alive = $true }
  }

  $last = $null
  if (Test-Path $log) { $last = (Get-Item $log).LastWriteTime }

  [PSCustomObject]@{
    Name       = $_.Name
    Running    = $alive
    LastOutput = $last
  }
} | Format-Table -AutoSize
