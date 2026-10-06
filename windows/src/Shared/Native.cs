using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace ClaudeHud {
  public static class Paths {
    /// CLAUDE_HUD_HOME points everything at another folder (testing against a fake ~/.claude).
    public static readonly string Home = Environment.GetEnvironmentVariable("CLAUDE_HUD_HOME") ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public static readonly bool Testing = Environment.GetEnvironmentVariable("CLAUDE_HUD_HOME") != null;
    public static readonly string Claude = Path.Combine(Home, ".claude");
    public static readonly string Hud = Path.Combine(Claude, "hud");
    public static readonly string Events = Path.Combine(Hud, "events.jsonl");
    public static readonly string Req = Path.Combine(Hud, "req");
    public static readonly string Ans = Path.Combine(Hud, "ans");
    public static readonly string Limits = Path.Combine(Hud, "limits.json");
    public static readonly string Projects = Path.Combine(Claude, "projects");
    public static readonly string Sessions = Path.Combine(Claude, "sessions");
    public static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);

    /// Lowercase, backslashes: transcript paths arrive from hooks and from the file system in different shapes.
    public static string Norm(string p) { return string.IsNullOrEmpty(p) ? "" : p.Replace('/', '\\').ToLowerInvariant(); }

    public static string FolderName(string p) {
      if (string.IsNullOrEmpty(p)) return "?";
      string t = p.TrimEnd('/', '\\');
      int i = t.LastIndexOfAny(new[] { '/', '\\' });
      return i >= 0 && i < t.Length - 1 ? t.Substring(i + 1) : t;
    }

    public static double Epoch(DateTime utc) { return (utc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds; }
    public static DateTime FromEpoch(double s) { return new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(s); }

    /// Atomic replace (write a .tmp, then move it over the target).
    public static void WriteAtomic(string path, string text) {
      string tmp = path + "." + Process.GetCurrentProcess().Id + ".tmp";
      File.WriteAllText(tmp, text, Utf8);
      if (!Native.MoveFileEx(tmp, path, 0x1 | 0x8)) { try { File.Delete(tmp); } catch { } }  // REPLACE_EXISTING | WRITE_THROUGH
    }

    public static string ReadShared(string path) {
      using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
      using (var r = new StreamReader(f, Utf8)) return r.ReadToEnd();
    }
  }

  public class Proc { public int Pid, Parent; public string Name; }

  public class HostApp {
    public int Pid;
    public string Name;   // exe name without .exe, e.g. "Code", "WindowsTerminal"
    public string Path;
    public IntPtr Window;
    public string Label {
      get {
        switch (Name.ToLowerInvariant()) {
          case "code": return "VS Code";
          case "code - insiders": return "VS Code Insiders";
          case "cursor": return "Cursor";
          case "windowsterminal": return "Terminal";
          case "openconsole": case "conhost": return "Console";
        }
        try {
          string d = FileVersionInfo.GetVersionInfo(Path).FileDescription;
          if (!string.IsNullOrEmpty(d) && d.Length < 30) return d;
        } catch { }
        return Name;
      }
    }
  }

  public static class Native {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32 {
      public uint dwSize, cntUsage, th32ProcessID;
      public IntPtr th32DefaultHeapID;
      public uint th32ModuleID, cntThreads, th32ParentProcessID;
      public int pcPriClassBase;
      public uint dwFlags;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "Process32FirstW")] static extern bool Process32First(IntPtr h, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "Process32NextW")] static extern bool Process32Next(IntPtr h, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder name, ref int size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool MoveFileEx(string from, string to, int flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern int GetShortPathName(string path, StringBuilder shortPath, int size);

    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    const uint SYNCHRONIZE = 0x00100000, QUERY_LIMITED = 0x1000;

    public static Dictionary<int, Proc> Snapshot() {
      var t = new Dictionary<int, Proc>();
      IntPtr h = CreateToolhelp32Snapshot(0x2, 0);  // TH32CS_SNAPPROCESS
      if (h == IntPtr.Zero || h == new IntPtr(-1)) return t;
      try {
        var e = new PROCESSENTRY32();
        e.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
        if (!Process32First(h, ref e)) return t;
        do {
          t[(int)e.th32ProcessID] = new Proc { Pid = (int)e.th32ProcessID, Parent = (int)e.th32ParentProcessID, Name = e.szExeFile ?? "" };
        } while (Process32Next(h, ref e));
      } finally { CloseHandle(h); }
      return t;
    }

    /// Is a process with this exe name (e.g. "Code.exe") running? Cheaper than Process.GetProcessesByName.
    public static bool Running(string exe) {
      foreach (var p in Snapshot().Values) if (string.Equals(p.Name, exe, StringComparison.OrdinalIgnoreCase)) return true;
      return false;
    }

    /// Pids of processes with this exe name.
    public static List<int> Pids(string exe) {
      var l = new List<int>();
      foreach (var p in Snapshot().Values) if (string.Equals(p.Name, exe, StringComparison.OrdinalIgnoreCase)) l.Add(p.Pid);
      return l;
    }

    /// kill(pid, 0) for Windows: true while the process exists (access denied counts as alive).
    public static bool Alive(int pid) {
      if (pid <= 1) return true;
      IntPtr h = OpenProcess(SYNCHRONIZE | QUERY_LIMITED, false, pid);
      if (h == IntPtr.Zero) return Marshal.GetLastWin32Error() == 5;
      try { return WaitForSingleObject(h, 0) == 0x102; } finally { CloseHandle(h); }  // WAIT_TIMEOUT = still running
    }

    public static string ExePath(int pid) {
      IntPtr h = OpenProcess(QUERY_LIMITED, false, pid);
      if (h == IntPtr.Zero) return null;
      try {
        var b = new StringBuilder(1024);
        int n = b.Capacity;
        return QueryFullProcessImageName(h, 0, b, ref n) ? b.ToString(0, n) : null;
      } finally { CloseHandle(h); }
    }

    static readonly string[] shells = { "bash.exe", "sh.exe", "dash.exe", "zsh.exe", "cmd.exe", "powershell.exe", "pwsh.exe",
                                        "conhost.exe", "env.exe", "timeout.exe" };

    /// The Claude Code process that ran this hook: the first non-shell ancestor (hooks run through a shell).
    public static int ClaudePid() {
      var t = Snapshot();
      Proc me;
      if (!t.TryGetValue(Process.GetCurrentProcess().Id, out me)) return 0;
      int p = me.Parent;
      for (int n = 0; n < 16 && p > 0; n++) {
        Proc x;
        if (!t.TryGetValue(p, out x)) return 0;
        if (Array.IndexOf(shells, x.Name.ToLowerInvariant()) < 0) return p;
        p = x.Parent;
      }
      return 0;
    }

    /// pid → its first visible, unowned, titled top-level window.
    static Dictionary<int, IntPtr> TopWindows() {
      var map = new Dictionary<int, IntPtr>();
      EnumWindows((h, l) => {
        if (IsWindowVisible(h) && GetWindow(h, 4) == IntPtr.Zero && GetWindowTextLength(h) > 0) {  // GW_OWNER
          int pid;
          GetWindowThreadProcessId(h, out pid);
          if (!map.ContainsKey(pid)) map[pid] = h;
        }
        return true;
      }, IntPtr.Zero);
      return map;
    }

    /// The app a session runs in (IDE, terminal, …): the first process up the Claude process's parent chain that owns a window.
    public static HostApp FindHost(int pid) {
      if (pid <= 1) return null;
      var procs = Snapshot();
      var wins = TopWindows();
      int p = pid;
      for (int n = 0; n < 32 && p > 4; n++) {
        Proc x;
        if (!procs.TryGetValue(p, out x)) return null;
        string name = x.Name.ToLowerInvariant();
        if (name == "explorer.exe" || name == "services.exe" || name == "svchost.exe") return null;
        IntPtr w;
        if (wins.TryGetValue(p, out w)) {
          return new HostApp { Pid = p, Name = System.IO.Path.GetFileNameWithoutExtension(x.Name), Path = ExePath(p), Window = w };
        }
        p = x.Parent;
      }
      return null;
    }

    public static string WindowTitle(IntPtr h) {
      var b = new StringBuilder(512);
      GetWindowText(h, b, b.Capacity);
      return b.ToString();
    }

    public static int WindowPid(IntPtr h) { int pid; GetWindowThreadProcessId(h, out pid); return pid; }

    /// Brings a window forward. We just took a click or hotkey, so Windows normally allows it; if the
    /// foreground lock still refuses, an Alt tap lifts it.
    public static void Focus(IntPtr h) {
      if (h == IntPtr.Zero) return;
      if (IsIconic(h)) ShowWindow(h, 9);  // SW_RESTORE
      if (SetForegroundWindow(h) && GetForegroundWindow() == h) return;
      keybd_event(0x12, 0, 0, UIntPtr.Zero);
      keybd_event(0x12, 0, 2, UIntPtr.Zero);
      SetForegroundWindow(h);
    }

    public static void PressEnter() {
      keybd_event(0x0D, 0, 0, UIntPtr.Zero);
      keybd_event(0x0D, 0, 2, UIntPtr.Zero);
    }

    public static void Kill(int pid) {
      if (pid <= 1) return;
      try { Process.GetProcessById(pid).Kill(); } catch { }
    }

    /// 8.3 form for paths with spaces, so a hook command needs no quotes in bash, cmd and PowerShell alike.
    public static string ShortPath(string p) {
      if (p.IndexOf(' ') < 0) return p;
      var b = new StringBuilder(1024);
      int n = GetShortPathName(p, b, b.Capacity);
      return n > 0 && n < b.Capacity ? b.ToString() : p;
    }
  }
}
