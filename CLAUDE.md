# Using winctl to drive a Windows session

This repo installs `winctl`, which drives a **persistent shell on a remote Windows
box** over SSH — analogous to driving a named `tmux` session on Linux. Prefer these
commands over ad-hoc `ssh` calls: each plain `ssh <host> <cmd>` is a fresh shell
with **no persistent state**, whereas a winctl session keeps its working directory,
environment (including `vcvars`), and running jobs alive between calls.

## Commands

- `winctl list` — see which sessions exist and whether they're running.
- `winctl start <name> [cmd|powershell|pwsh]` — create a detached session.
- `winctl send <name> <command...>` — type a command and press Enter.
- `winctl key <name> <text...>` — send raw text with **no** Enter (e.g. a `y`
  answer, or partial input).
- `winctl read <name>` — show the last ~200 lines of output.
- `winctl read <name> -- -New` — show only output since the last `-New` read.
  Use this to follow along without re-reading everything.
- `winctl read <name> -- -Wait <sec> -New` — block until output goes idle (or the
  timeout hits), then show new output. Use this after kicking off a build to avoid
  polling in a tight loop.
- `winctl watch <name> [lines]` — live-tail the session. **Blocks until Ctrl-C** —
  it's for a human watching. As an agent, do **not** use `watch` (it will hang);
  use `read -- -New` or `read -- -Wait <sec> -New` instead.
- `winctl stop <name>` — kill the session.

## Working pattern

1. Run `winctl list` first. If the named session isn't there, ask the operator
   (they usually start and log the session in), or `winctl start` it.
2. `send` a command, then `read -- -New` (or `read -- -Wait N -New`) to see the
   result before sending the next one. Output is captured asynchronously, so if a
   read looks empty, wait briefly and read again.
3. For builds/tests that take a while, use `-Wait`. A returned `send` only means
   the keystrokes were delivered, not that the command finished.

## Gotchas

- It's a redirected pipe, not a full TTY: full-screen/curses apps won't render,
  and Ctrl-C can't be delivered reliably. Prefer non-interactive flags.
- Paths with spaces need Windows quoting inside the sent command, e.g.
  `winctl send build "\"C:\Program Files\...\vcvars64.bat\""`.
- Never send secrets in plain commands that should not appear in `output.log`.
