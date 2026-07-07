<#
.SYNOPSIS
  Install the broker scripts on the Windows target, and (optionally) perform the
  full OpenSSH Server first-time setup.

.DESCRIPTION
  -InstallDir  Copies the broker scripts to a stable install dir (default
               C:\claude-session) so the Linux-side wrapper finds them.

  -SetupSsh    Runs the complete OpenSSH Server setup that
               `Add-WindowsCapability` skips: installs the capability if
               missing, generates host keys, creates sshd_config from the
               template, fixes OWNER + permissions on the keys and config,
               starts + auto-enables the service, and opens the firewall.
               Requires an elevated (Administrator) PowerShell.

  -CheckSsh    Only reports OpenSSH status; changes nothing.

.EXAMPLE
  # elevated: full setup + install the broker scripts
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -SetupSsh

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -InstallDir D:\tools\claude-session
#>
param(
  [string]$InstallDir = 'C:\claude-session',
  [switch]$SetupSsh,
  [switch]$CheckSsh
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-OpenSSHServer {
  if (-not (Test-Admin)) {
    throw "-SetupSsh requires an elevated PowerShell (Run as Administrator)."
  }

  $sshDir = "$env:ProgramData\ssh"
  $bin    = "$env:SystemRoot\System32\OpenSSH"

  # 1. Ensure the OpenSSH Server capability is installed.
  $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
  if ($cap -and $cap.State -ne 'Installed') {
    Write-Host "Installing OpenSSH Server capability..."
    Add-WindowsCapability -Online -Name $cap.Name | Out-Null
  }

  # 2. Generate host keys if the capability install left them missing.
  if (-not (Get-ChildItem "$sshDir\ssh_host_*_key" -ErrorAction SilentlyContinue)) {
    Write-Host "Generating host keys (ssh-keygen -A)..."
    & "$bin\ssh-keygen.exe" -A | Out-Null
  }

  # 3. Create sshd_config from the shipped template if it's missing.
  if (-not (Test-Path "$sshDir\sshd_config")) {
    Write-Host "Creating sshd_config from template..."
    Copy-Item "$bin\sshd_config_default" "$sshDir\sshd_config" -Force
  }

  # 4. Fix OWNER + DACL on host keys and sshd_config. This is the step the
  #    capability install skips and the usual reason the service won't start:
  #    files created/copied by an admin USER are owned by that user, but sshd
  #    runs as LocalSystem and rejects host keys / config not owned by SYSTEM
  #    or the Administrators GROUP -- it aborts before logging (exit 1067).
  Write-Host "Securing host keys and config (owner -> Administrators, SYSTEM+Admins only)..."
  $secure = @("$sshDir\sshd_config") +
            (Get-ChildItem "$sshDir\ssh_host_*" -ErrorAction SilentlyContinue | ForEach-Object FullName)
  foreach ($f in $secure) {
    & icacls $f /setowner "BUILTIN\Administrators" | Out-Null
    & icacls $f /inheritance:r /grant:r "NT AUTHORITY\SYSTEM:(F)" "BUILTIN\Administrators:(F)" | Out-Null
  }

  # 5. Start + auto-enable the service.
  Set-Service -Name sshd -StartupType Automatic
  Start-Service sshd
  Write-Host "sshd service status: $((Get-Service sshd).Status)"

  # 6. Firewall rule for inbound TCP 22 (idempotent).
  if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    Write-Host "Adding firewall rule for TCP 22..."
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
      -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
  }

  Write-Host "OpenSSH Server setup complete."
}

# --- OpenSSH setup / status ------------------------------------------------
if ($SetupSsh) {
  Initialize-OpenSSHServer
}
elseif ($CheckSsh) {
  $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
  if ($null -eq $svc) {
    Write-Warning "OpenSSH Server (sshd) is not installed. Re-run with -SetupSsh (elevated)."
  } elseif ($svc.Status -ne 'Running') {
    Write-Warning "sshd is installed but $($svc.Status). Re-run with -SetupSsh (elevated) to finish setup."
  } else {
    Write-Host "OpenSSH Server is installed and running."
  }
}

# --- Install the broker scripts --------------------------------------------
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$files = @(
  'Broker.cs','session-server.ps1','session-start.ps1','session-send.ps1',
  'session-read.ps1','session-stop.ps1','session-list.ps1'
)
foreach ($f in $files) {
  Copy-Item -Path (Join-Path $PSScriptRoot $f) -Destination $InstallDir -Force
}
Write-Host "Installed broker scripts to $InstallDir"

Write-Host ""
Write-Host "On the Linux host, point the wrapper at this machine:"
Write-Host "  export WINBOX=<user>@<this-host>"
Write-Host "  export WINCLAUDE_DIR=$($InstallDir -replace '\\','/')"
