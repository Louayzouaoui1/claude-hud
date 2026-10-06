using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.AccessControl;
using System.Threading;

namespace ClaudeHud {
  /// hud-hook.exe: the Windows stand-in for the bash + jq hooks.
  ///   event        every session event → one compact line in events.jsonl
  ///   perm         PermissionRequest: hand the prompt to Claude HUD and wait for its answer
  ///   statusline   save the 5-hour / weekly limits, print a compact status line
  ///   install      copy itself to ~/.claude/hud and wire the hooks into ~/.claude/settings.json
  ///   uninstall    take the hooks and status line back out
  static class Hook {
    static int Main(string[] args) {
      string cmd = args.Length > 0 ? args[0] : "";
      switch (cmd) {
        case "event": return Safe(Event);
        case "perm": return Safe(Perm);
        case "statusline": return Safe(Statusline);
        case "install":
        case "uninstall":
          try { return cmd == "install" ? Setup.Install() : Setup.Remove(); }
          catch (Exception e) { Console.Error.WriteLine("Claude HUD: " + e.Message); return 1; }
      }
      Console.Error.WriteLine("usage: hud-hook event | perm | statusline | install | uninstall");
      return 2;
    }

    /// A hook must never get in Claude's way: any failure exits 0 with no output.
    static int Safe(Action a) {
      try { a(); } catch { }
      return 0;
    }

    static string ReadStdin() {
      using (var r = new StreamReader(Console.OpenStandardInput(), Paths.Utf8)) return r.ReadToEnd();
    }

    static void Print(string s) {
      byte[] b = Paths.Utf8.GetBytes(s);
      var o = Console.OpenStandardOutput();
      o.Write(b, 0, b.Length);
      o.Flush();
    }

    static void Event() {
      var j = Json.TryParse(ReadStdin());
      if (j == null) return;
      var input = Json.Get(j, "tool_input");
      string x = "";
      foreach (var k in new[] { "command", "file_path", "pattern", "url", "query", "description" }) {
        object v = Json.Get(input, k);
        if (v == null || false.Equals(v)) continue;
        x = v as string ?? Json.Write(v, false);
        break;
      }
      if (x.Length > 160) x = x.Substring(0, 160);
      var o = new Dictionary<string, object>();
      o["s"] = Json.Get(j, "session_id");
      o["e"] = Json.Get(j, "hook_event_name");
      o["c"] = Json.Get(j, "cwd");
      o["t"] = Json.Get(j, "notification_type");
      o["m"] = Json.Get(j, "message");
      o["tp"] = Json.Get(j, "transcript_path");
      o["tn"] = Json.Get(j, "tool_name");
      o["at"] = Json.Get(j, "agent_type");
      o["ai"] = Json.Get(j, "agent_id");
      o["ts"] = Paths.Epoch(DateTime.UtcNow);
      o["p"] = (long)Native.ClaudePid();
      o["x"] = x;
      Append(Paths.Events, Json.Write(o, false) + "\n");
    }

    /// Append-only handle: Windows appends each write atomically, so parallel hooks never interleave lines.
    static void Append(string path, string line) {
      byte[] bytes = Paths.Utf8.GetBytes(line);
      Directory.CreateDirectory(Path.GetDirectoryName(path));
      for (int i = 0; i < 40; i++) {
        try {
          using (var f = new FileStream(path, FileMode.Append, FileSystemRights.AppendData,
                                        FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.None)) {
            f.Write(bytes, 0, bytes.Length);
          }
          return;
        } catch (IOException) { Thread.Sleep(10); }
      }
    }

    /// Let Claude HUD answer the prompt. Prints nothing (= the normal dialog) if the HUD isn't running,
    /// the user picks "answer in the editor", or ~10 min pass.
    static void Perm() {
      string input = ReadStdin();
      if (Process.GetProcessesByName("ClaudeHUD").Length == 0) return;
      if (File.Exists(Path.Combine(Paths.Hud, "answer-off"))) return;
      var j = Json.TryParse(input) as Dictionary<string, object>;
      if (j == null) return;
      j["pid"] = (long)Native.ClaudePid();
      j["hook_pid"] = (long)Process.GetCurrentProcess().Id;  // lets the HUD drop the request if this hook is killed
      string id = Guid.NewGuid().ToString().ToUpperInvariant();
      Directory.CreateDirectory(Paths.Req);
      Directory.CreateDirectory(Paths.Ans);
      string req = Path.Combine(Paths.Req, id + ".json"), ans = Path.Combine(Paths.Ans, id);
      Paths.WriteAtomic(req, Json.Write(j, false));
      try {
        for (int n = 0; n < 2300; n++) {
          if (File.Exists(ans)) {
            string body;
            try { body = File.ReadAllText(ans, Paths.Utf8); } catch (IOException) { Thread.Sleep(50); continue; }
            try { File.Delete(ans); } catch { }
            Print(body);
            return;
          }
          Thread.Sleep(250);
        }
      } finally {
        try { File.Delete(req); } catch { }
      }
    }

    static void Statusline() {
      var j = Json.TryParse(ReadStdin());
      if (j == null) return;
      var rl = Json.Get(j, "rate_limits");
      if (rl != null) {
        Directory.CreateDirectory(Paths.Hud);
        Paths.WriteAtomic(Paths.Limits, Json.Write(rl, false));
      }
      var parts = new List<string>();
      string model = Json.Str(Json.Get(j, "model"), "display_name");
      if (!string.IsNullOrEmpty(model)) parts.Add(model);
      string dir = Json.Str(Json.Get(j, "workspace"), "current_dir");
      if (!string.IsNullOrEmpty(dir)) parts.Add(Paths.FolderName(dir));
      double? f = Json.Num(Json.Get(rl, "five_hour"), "used_percentage");
      if (f.HasValue) parts.Add("5h " + (int)Math.Floor(f.Value) + "%");
      double? w = Json.Num(Json.Get(rl, "seven_day"), "used_percentage");
      if (w.HasValue) parts.Add("wk " + (int)Math.Floor(w.Value) + "%");
      Print(string.Join(" · ", parts) + "\n");
    }
  }

  /// Wires Claude HUD into Claude Code. Other hooks are left alone; a backup is kept as settings.json.bak-claudehud.
  static class Setup {
    static readonly string settings = Path.Combine(Paths.Claude, "settings.json");
    static readonly string[] events = { "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
                                        "Stop", "SessionEnd", "SubagentStart", "SubagentStop" };

    static string Exe { get { return Path.Combine(Paths.Hud, "hud-hook.exe"); } }

    /// Forward slashes and no spaces: runs the same from bash, cmd and PowerShell.
    static string Cmd(string sub) { return Native.ShortPath(Exe).Replace('\\', '/') + " " + sub; }

    static bool Ours(string command) {
      return command != null && command.Replace('\\', '/').IndexOf("claude/hud/", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    static Dictionary<string, object> Load() {
      Directory.CreateDirectory(Paths.Claude);
      if (!File.Exists(settings)) return new Dictionary<string, object>();
      string text = File.ReadAllText(settings, Paths.Utf8);
      if (text.Trim().Length == 0) return new Dictionary<string, object>();
      var s = Json.TryParse(text) as Dictionary<string, object>;
      if (s == null) throw new Exception(settings + " isn't valid JSON; fix it and run again (nothing was changed).");
      File.Copy(settings, settings + ".bak-claudehud", true);
      return s;
    }

    /// Drops every previous Claude HUD entry, keeps everything else.
    static void Strip(Dictionary<string, object> s) {
      var hooks = Json.Obj(s, "hooks");
      if (hooks != null) {
        foreach (var k in hooks.Keys.ToList()) {
          var list = hooks[k] as List<object>;
          if (list == null) continue;
          list.RemoveAll(e => (Json.Arr(e, "hooks") ?? new List<object>()).Any(h => Ours(Json.Str(h, "command"))));
          if (list.Count == 0) hooks.Remove(k);
        }
        if (hooks.Count == 0) s.Remove("hooks");
      }
      if (Ours(Json.Str(Json.Get(s, "statusLine"), "command"))) s.Remove("statusLine");
    }

    static Dictionary<string, object> Entry(string command, int timeout) {
      var h = new Dictionary<string, object>();
      h["type"] = "command";
      h["command"] = command;
      if (timeout > 0) h["timeout"] = (long)timeout;
      var e = new Dictionary<string, object>();
      e["hooks"] = new List<object> { h };
      return e;
    }

    public static int Install() {
      Directory.CreateDirectory(Paths.Req);
      Directory.CreateDirectory(Paths.Ans);
      string me = Process.GetCurrentProcess().MainModule.FileName;
      if (!string.Equals(Path.GetFullPath(me), Path.GetFullPath(Exe), StringComparison.OrdinalIgnoreCase)) {
        // A running perm hook keeps the old exe locked: move it aside first.
        if (File.Exists(Exe)) {
          string old = Exe + ".old";
          try { File.Delete(old); } catch { }
          try { File.Move(Exe, old); } catch { }
        }
        File.Copy(me, Exe, true);
      }
      var s = Load();
      Strip(s);
      var hooks = Json.Obj(s, "hooks");
      if (hooks == null) { hooks = new Dictionary<string, object>(); s["hooks"] = hooks; }
      foreach (var ev in events) Add(hooks, ev, Entry(Cmd("event"), 0));
      Add(hooks, "PermissionRequest", Entry(Cmd("perm"), 600));
      if (Json.Get(s, "statusLine") == null) {
        var sl = new Dictionary<string, object>();
        sl["type"] = "command";
        sl["command"] = Cmd("statusline");
        s["statusLine"] = sl;
      }
      File.WriteAllText(settings, Json.Write(s, true) + "\n", Paths.Utf8);
      Console.WriteLine("Claude HUD hooks installed.");
      return 0;
    }

    static void Add(Dictionary<string, object> hooks, string ev, object entry) {
      var list = hooks.ContainsKey(ev) ? hooks[ev] as List<object> : null;
      if (list == null) { list = new List<object>(); hooks[ev] = list; }
      list.Add(entry);
    }

    public static int Remove() {
      if (!File.Exists(settings)) return 0;
      var s = Load();
      Strip(s);
      File.WriteAllText(settings, Json.Write(s, true) + "\n", Paths.Utf8);
      Console.WriteLine("Claude HUD hooks removed.");
      return 0;
    }
  }
}
