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

1. **Enable OpenSSH Server** (once, elevated PowerShell):

   ```powershell
   Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
   Start-Service sshd
   Set-Service -Name sshd -StartupType Automatic
   # allow inbound 22 if your firewall blocks it:
   New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' `
     -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
   ```

   Set up **key-based auth** from the Linux host so Claude never needs a password
   (see "Wire up SSH" below).

2. **Get the code onto the box** (clone the repo, or copy the `windows/` folder).

3. **Install the broker scripts** (from the `windows` folder):

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckSsh
   ```

   This copies the scripts to `C:\claude-session`. Use `-InstallDir` to change it
   (match `WINCLAUDE_DIR` on the Linux side).

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
