<#
.SYNOPSIS
  Install the broker scripts on the Windows target.

.DESCRIPTION
  Copies the broker scripts to a stable install directory (default
  C:\claude-session) so the Linux-side wrapper can find them at a known path.
  Run this from the `windows` folder of the repo on the target machine.

  Optionally checks that OpenSSH Server is present/running.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -InstallDir D:\tools\claude-session
#>
param(
  [string]$InstallDir = 'C:\claude-session',
  [switch]$CheckSsh
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$files = @(
  'Broker.cs','session-server.ps1','session-start.ps1','session-send.ps1',
  'session-read.ps1','session-stop.ps1','session-list.ps1'
)
foreach ($f in $files) {
  Copy-Item -Path (Join-Path $PSScriptRoot $f) -Destination $InstallDir -Force
}
Write-Host "Installed broker scripts to $InstallDir"

if ($CheckSsh) {
  $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
  if ($null -eq $svc) {
    Write-Warning "OpenSSH Server (sshd) not installed. To install (elevated):"
    Write-Host   "  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
    Write-Host   "  Start-Service sshd; Set-Service -Name sshd -StartupType Automatic"
  } elseif ($svc.Status -ne 'Running') {
    Write-Warning "sshd is installed but not running. Start it (elevated) with: Start-Service sshd"
  } else {
    Write-Host "OpenSSH Server is installed and running."
  }
}

Write-Host ""
Write-Host "Done. On the Linux host, point the wrapper at this machine:"
Write-Host "  export WINBOX=<user>@<this-host>"
Write-Host "  export WINCLAUDE_DIR=$($InstallDir -replace '\\','/')"
