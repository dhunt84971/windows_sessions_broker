// Broker.cs - persistent-session broker core for the Windows target.
//
// Spawns a long-lived child shell (cmd.exe or PowerShell) with redirected
// stdin/stdout/stderr, streams all output to a log file, and accepts input
// over a named pipe. This is the "tmux server" half of the system: it keeps
// one shell alive with persistent state (cwd, environment, vcvars, running
// jobs) and exposes "type into it" and "read its screen" as file/pipe ops.
//
// Compiled at runtime via Add-Type in session-server.ps1 (works on both
// Windows PowerShell 5.1 / .NET Framework and PowerShell 7 / .NET).

using System;
using System.IO;
using System.IO.Pipes;
using System.Diagnostics;
using System.Threading;
using System.Text;

namespace ClaudeSession {
  public class Broker {
    static readonly object logLock = new object();
    static StreamWriter log;
    static Process child;

    // name     : session name (used for the named pipe + log dir)
    // shellPath : full path to cmd.exe / powershell.exe / pwsh.exe
    // shellArgs : arguments for the shell
    // dir       : session working dir (holds output.log)
    // initCmd   : command written to the child immediately after start
    //             (e.g. "chcp 65001>nul" so cmd emits UTF-8), or null
    public static void Run(string name, string shellPath, string shellArgs, string dir, string initCmd) {
      string logPath = Path.Combine(dir, "output.log");
      string pipeName = "claude-session-" + name;

      // FileShare.ReadWrite so session-read.ps1 can read while we append.
      log = new StreamWriter(new FileStream(logPath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite));
      log.AutoFlush = true;

      var psi = new ProcessStartInfo {
        FileName = shellPath,
        Arguments = shellArgs,
        RedirectStandardInput = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        UseShellExecute = false,
        CreateNoWindow = true,
        WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        StandardOutputEncoding = Encoding.UTF8,
        StandardErrorEncoding = Encoding.UTF8,
      };

      child = new Process { StartInfo = psi };
      child.OutputDataReceived += (s, e) => { if (e.Data != null) Write(e.Data); };
      child.ErrorDataReceived  += (s, e) => { if (e.Data != null) Write(e.Data); };
      child.Start();
      // .NET fires these callbacks on threadpool threads, independent of the
      // PowerShell event pump, so output capture keeps working while the main
      // thread blocks in WaitForExit().
      child.BeginOutputReadLine();
      child.BeginErrorReadLine();

      if (!string.IsNullOrEmpty(initCmd)) {
        child.StandardInput.Write(initCmd + "\r\n");
        child.StandardInput.Flush();
      }

      var pipeThread = new Thread(() => PipeLoop(pipeName)) { IsBackground = true };
      pipeThread.Start();

      child.WaitForExit();
      Write("[claude-session: shell exited]");
      log.Flush();
    }

    static void Write(string s) {
      lock (logLock) { log.WriteLine(s); }
    }

    static void PipeLoop(string pipeName) {
      while (!child.HasExited) {
        try {
          using (var server = new NamedPipeServerStream(
                     pipeName, PipeDirection.In, 1,
                     PipeTransmissionMode.Byte, PipeOptions.None)) {
            server.WaitForConnection();
            using (var reader = new StreamReader(server, new UTF8Encoding(false))) {
              string text = reader.ReadToEnd();
              if (text == "\0STOP\0") {
                try { child.Kill(); } catch { }
                return;
              }
              child.StandardInput.Write(text);
              child.StandardInput.Flush();
            }
          }
        } catch {
          Thread.Sleep(200);
        }
      }
    }
  }
}
