<#
.SYNOPSIS
  The long-running session server (the "tmux server" process).

.DESCRIPTION
  Compiles Broker.cs and runs the broker, which spawns a persistent child
  shell and blocks until it exits. Not normally run directly -- use
  session-start.ps1, which launches this hidden and detached so it survives
  the SSH command that started it.
#>
param(
  [Parameter(Mandatory)][string]$Name,
  [ValidateSet('cmd','powershell','pwsh')][string]$Shell = 'cmd',
  [string]$Root = "$env:USERPROFILE\.claude-sessions"
)

$ErrorActionPreference = 'Stop'

$dir = Join-Path $Root $Name
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# Record this server's PID so session-list / session-stop can find it.
Set-Content -Path (Join-Path $dir 'server.pid') -Value $PID

# Reset the incremental-read offset for a fresh session.
Set-Content -Path (Join-Path $dir 'read.offset') -Value '0'

# Compile the broker core.
$src = Get-Content -Raw -Path (Join-Path $PSScriptRoot 'Broker.cs')
Add-Type -TypeDefinition $src -Language CSharp

switch ($Shell) {
  'cmd' {
    $path    = "$env:SystemRoot\System32\cmd.exe"
    $shArgs  = ''                       # redirected stdin keeps it alive
    $initCmd = 'chcp 65001>nul'         # emit UTF-8 to match the reader
  }
  'powershell' {
    $path    = 'powershell.exe'
    $shArgs  = '-NoLogo -NoProfile -NoExit -Command -'
    $initCmd = '[Console]::OutputEncoding=[Text.Encoding]::UTF8'
  }
  'pwsh' {
    $path    = 'pwsh.exe'
    $shArgs  = '-NoLogo -NoProfile -NoExit -Command -'
    $initCmd = '[Console]::OutputEncoding=[Text.Encoding]::UTF8'
  }
}

[ClaudeSession.Broker]::Run($Name, $path, $shArgs, $dir, $initCmd)
