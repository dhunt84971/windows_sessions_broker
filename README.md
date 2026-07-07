# windows-session-broker

Drive a **persistent Windows shell session** from a Claude Code session (or any
shell) running on **Linux**, over SSH — the way you'd hand a Claude agent a
named `tmux` session on Linux and let it work.

On Linux the trick that makes the tmux workflow work is that Claude never really
"attaches" to tmux; it just runs `tmux send-keys` to type and `tmux capture-pane`
to read the screen. This project reproduces that on a remote Windows box:

- A small **broker** on the Windows target keeps one shell (`cmd.exe` by default,
  or PowerShell) alive with **persistent state** — working directory, environment,
  an initialized MSVC/`vcvars` environment, running jobs — and streams its output
  to a log file. Input arrives over a named pipe.
- A Linux wrapper, **`winctl`**, exposes `start` / `send` / `read` / `stop` / `list`
  that map onto the broker over SSH. `send` ≈ `send-keys`, `read` ≈ `capture-pane`.

```
Linux (Claude Code)                         Windows 10 target
┌───────────────────┐    ssh    ┌──────────────────────────────────┐
│ winctl send/read  │──────────▶│ session-*.ps1  →  named pipe      │
│  (WINBOX=user@win)│           │                    │             │
└───────────────────┘◀──────────│ output.log  ◀── persistent cmd.exe│
        capture                 └──────────────────────────────────┘
```

## What it is good at (and the tradeoff)

The broker uses **redirected stdin/stdout pipes** to a persistent shell, not a
full pseudo-console (ConPTY). So:

- ✅ Persistent shell state across commands (run `vcvars64.bat` once, build all day)
- ✅ Type any command, scrape its output
- ✅ Kick off long builds and poll for completion (`read -Wait`)
- ⚠️ Full-screen TUI apps won't render; true Ctrl-C signal delivery is limited

That's the right fit for MSVC / `dotnet` / `cmake` builds and running your apps.
The broker core (`Broker.cs`) is isolated, so it can later be swapped for a
ConPTY implementation without changing the `winctl` interface.

## Layout

```
windows/    # copy to the Windows target (installed to C:\claude-session)
  Broker.cs           broker core (compiled at runtime via Add-Type)
  session-server.ps1  the long-running server (started detached)
  session-start.ps1   create a detached session         (~ tmux new -d)
  session-send.ps1    send input                         (~ send-keys)
  session-read.ps1    read output                        (~ capture-pane)
  session-stop.ps1    kill a session                     (~ kill-session)
  session-list.ps1    list sessions                      (~ tmux ls)
  install.ps1         copy scripts into the install dir
linux/      # install on the Linux host running Claude Code
  winctl              the wrapper Claude/you call
  install.sh          symlink winctl onto PATH + scaffold config
CLAUDE.md   # guidance so a Claude session knows how to use winctl
```

---

## Install — Windows target (Windows 10)

> **Important:** installing OpenSSH via `Add-WindowsCapability` only lays down the
> binaries and registers the service — it does **not** complete first-time setup.
> You must also generate host keys, create `sshd_config`, and (the easy-to-miss
> part) fix the **owner and permissions** on those files, or the service fails to
> start. `install.ps1 -SetupSsh` does all of it for you; the manual steps and the
> reasons are spelled out below and in [Troubleshooting](#troubleshooting).

1. **Get the code onto the box** (clone the repo, or copy the `windows/` folder).

2. **Run the installer from an *elevated* PowerShell** (from the `windows` folder):

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -SetupSsh
   ```

   `-SetupSsh` performs the full OpenSSH first-time setup **and** copies the broker
   scripts to `C:\claude-session` (use `-InstallDir` to change it; match
   `WINCLAUDE_DIR` on the Linux side). It is idempotent — safe to re-run.

   Concretely, `-SetupSsh` does what the capability install skips:
   1. installs the `OpenSSH.Server` capability if missing;
   2. **generates host keys** (`ssh-keygen -A`);
   3. **creates `sshd_config`** from `C:\Windows\System32\OpenSSH\sshd_config_default`;
   4. **sets owner → `Administrators` and locks the DACL to `SYSTEM` + `Administrators`**
      on the host keys and `sshd_config` (this is the step whose absence makes the
      service die with exit code `1067`);
   5. starts the service and sets it to **Automatic**;
   6. opens the **firewall** for inbound TCP 22.

3. **Set up key-based auth** from the Linux host so Claude never needs a password
   (see "Wire up SSH" below).

<details>
<summary>Doing it by hand instead of <code>-SetupSsh</code></summary>

Elevated PowerShell:

```powershell
# 1. install the server
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0

# 2. host keys (capability install skips these)
& "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe" -A

# 3. config from the template (capability install skips this too)
Copy-Item "$env:SystemRoot\System32\OpenSSH\sshd_config_default" `
          "$env:ProgramData\ssh\sshd_config" -Force

# 4. OWNER + permissions — the step everyone misses. Files created by an admin
#    user are owned by that user; sshd runs as LocalSystem and refuses host
#    keys / config not owned by SYSTEM or the Administrators group.
$secure = @("$env:ProgramData\ssh\sshd_config") +
          (Get-ChildItem "$env:ProgramData\ssh\ssh_host_*" | ForEach-Object FullName)
foreach ($f in $secure) {
  icacls $f /setowner "BUILTIN\Administrators"
  icacls $f /inheritance:r /grant:r "NT AUTHORITY\SYSTEM:(F)" "BUILTIN\Administrators:(F)"
}

# 5. start + enable
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

# 6. firewall
New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
  -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```
</details>

> Notes: works with the built-in Windows PowerShell 5.1 — no extra runtime needed
> (`Broker.cs` compiles via the .NET Framework compiler). PowerShell 7 also works.
> To build with MSVC in a session, start a `cmd` session and `send` the path to
> your `vcvars64.bat` first; the environment then persists for the session.

## Install — Linux host (the Claude Code machine)

1. **Get the code** and run the installer:

   ```bash
   git clone <your-fork-url> windows-session-broker
   cd windows-session-broker/linux
   ./install.sh                 # symlinks winctl into ~/.local/bin
   ```

2. **Point it at your Windows box** — edit `~/.config/winclaude/config`:

   ```sh
   WINBOX=dave@winbuild            # user@host of the Windows target
   WINCLAUDE_DIR=C:/claude-session # must match the Windows install dir
   # WINSSH_OPTS="-p 22 -i ~/.ssh/id_ed25519"
   ```

   (Or just `export WINBOX=...` in your shell; the config file is optional.)

### Wire up SSH (passwordless)

From the Linux host:

```bash
ssh-keygen -t ed25519           # if you don't have a key
ssh-copy-id dave@winbuild       # or paste the pubkey into the Windows authorized_keys
ssh dave@winbuild "powershell -c 'hostname'"   # verify it works without a password
```

On Windows, an **administrator** account's keys go in
`C:\ProgramData\ssh\administrators_authorized_keys` (not `~\.ssh`); a standard
user's keys go in `%USERPROFILE%\.ssh\authorized_keys`.

---

## Usage

```bash
winctl start build              # create a detached cmd session named "build"
winctl start ps powershell      # or a PowerShell session

winctl send build "cd C:\src\myapp"
winctl send build "dotnet build -c Release"
winctl read build -- -Wait 300 -New   # wait for the build to go idle, show new output

winctl send build "\"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat\""
winctl send build "cl /EHsc main.cpp"

winctl list                     # what's running
winctl stop build               # tear it down
```

`read` options (after `--`): `-New` (only output since last `-New`), `-Tail N`
(last N lines, default 200), `-All` (whole log), `-Wait S` (block until output
is idle or S seconds pass, then read).

### Handing it to Claude

Same as your tmux flow: start and log in the session yourself, then tell the
agent the session name and the task, e.g. *"Session `build` is a cmd shell on the
Windows box in `C:\src\myapp`. Build it with `dotnet build`, read the output, and
fix any errors."* `CLAUDE.md` in this repo tells the agent how to use `winctl`.

## Troubleshooting

### The sshd service won't start

Almost always a leftover from the incomplete capability install. `Start-Service sshd`
gives a useless generic error, so diagnose from the bottom up:

1. **Get the real reason, not the SCM wrapper error.** Run sshd by hand — it prints
   the actual fatal line and (if healthy) stays listening:
   ```powershell
   & "$env:SystemRoot\System32\OpenSSH\sshd.exe" -d
   ```
   Common messages and fixes:
   - `Permissions for 'ssh_host_ed25519_key' are too open` → a non-admin user has
     an ACE on a private host key. Strip it (see step 4 of the manual setup).
   - `__PROGRAMDATA__\ssh/sshd_config: No such file or directory` → config missing;
     copy it from `sshd_config_default` (step 3).
   - It prints `debug1:` lines and **sits there listening** → sshd is fine; the
     problem is the *service*, continue below. (Press `Ctrl+C` to stop it, and make
     sure no stray `sshd` is left holding port 22 before starting the service.)

2. **Service exits with code `1067` (`ERROR_PROCESS_ABORTED`) and logs nothing**,
   even though `sshd -d` works:
   ```powershell
   sc.exe query sshd    # WIN32_EXIT_CODE : 1067
   ```
   This is the **file-ownership** trap. `sshd -d` runs as *you* (an admin) and
   passes the security check because you own the files; the service runs as
   `LocalSystem`, which does not, so it aborts before it can log. Fix the owner:
   ```powershell
   $secure = @("$env:ProgramData\ssh\sshd_config") +
             (Get-ChildItem "$env:ProgramData\ssh\ssh_host_*" | ForEach-Object FullName)
   foreach ($f in $secure) {
     icacls $f /setowner "BUILTIN\Administrators"
     icacls $f /inheritance:r /grant:r "NT AUTHORITY\SYSTEM:(F)" "BUILTIN\Administrators:(F)"
   }
   ```

3. **Still failing?** Turn on sshd's file logging (works in service mode) and read
   the exact fatal:
   ```powershell
   New-Item -ItemType Directory -Force -Path "$env:ProgramData\ssh\logs" | Out-Null
   Add-Content "$env:ProgramData\ssh\sshd_config" "`nSyslogFacility LOCAL0`nLogLevel DEBUG3"
   Start-Service sshd -ErrorAction SilentlyContinue
   Start-Sleep 2
   Get-Content "$env:ProgramData\ssh\logs\sshd.log" -Tail 60
   ```

Running `install.ps1 -SetupSsh` from the start avoids all of the above — it sets
the host keys, config, ownership, and permissions correctly in one shot.

### Broker / winctl

- **`session '<name>' is not running`** — the broker isn't up. `winctl start` it;
  check `winctl list`.
- **Session dies right after `start`** — some OpenSSH setups kill detached
  children when the SSH channel closes. If `Start-Process` doesn't survive on your
  box, run the server via Task Scheduler instead (see comments in
  `session-start.ps1`) or launch it from an interactive session on the desktop.
- **Garbled/box characters in output** — encoding mismatch. `cmd` sessions run
  `chcp 65001` automatically; if a specific tool insists on another codepage,
  `send` its `chcp` first.
- **No output after a command** — give it a moment and `read` again, or use
  `read -- -Wait <sec> -New`; the log is written asynchronously.
