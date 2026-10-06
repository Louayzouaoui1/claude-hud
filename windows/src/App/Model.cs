using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows.Media;

namespace ClaudeHud {
  public enum Phase { Permission, Done, Working, Ready, Ended }  // sort order: most urgent first

  public static class Palette {
    public static Color Rgb(double r, double g, double b) { return Color.FromRgb((byte)(r * 255), (byte)(g * 255), (byte)(b * 255)); }
    public static Color A(Color c, double a) { return Color.FromArgb((byte)(Math.Max(0, Math.Min(1, a)) * 255), c.R, c.G, c.B); }
    public static Color W(double a) { return A(Colors.White, a); }
    public static readonly Color Red = Rgb(1, 0.45, 0.5);
    public static readonly Color Violet = Rgb(0.75, 0.65, 1);

    public static Color Of(Phase p) {
      switch (p) {
        case Phase.Permission: return Rgb(1, 0.67, 0.32);
        case Phase.Done: return Rgb(0.38, 0.96, 0.74);
        case Phase.Working: return Rgb(0.45, 0.72, 1);
        case Phase.Ready: return Rgb(0.62, 0.62, 0.62);
        default: return Rgb(0.42, 0.42, 0.42);
      }
    }

    public static string Label(Phase p) { return new[] { "Needs you", "Your turn", "Working", "Ready", "Ended" }[(int)p]; }

    public static readonly string[] Themes = { "aurora", "nebula", "ember", "mono" };

    public static Color[] Theme(string name) {
      switch (name) {
        case "nebula": return new[] { Rgb(0.86, 0.6, 1), Rgb(1, 0.45, 0.78) };
        case "ember": return new[] { Rgb(1, 0.84, 0.45), Rgb(1, 0.5, 0.32) };
        case "mono": return new[] { Rgb(0.96, 0.96, 0.96), Rgb(0.62, 0.62, 0.62) };
        default: return new[] { Rgb(0.4, 0.95, 0.95), Rgb(0.45, 0.72, 1) };
      }
    }
    public static Color[] CurrentTheme { get { return Theme(Prefs.Str("theme")); } }
  }

  public class Request {
    public string Id, Tool, Detail;
    public string Always;      // human label of Claude's own "don't ask again" suggestion
    public string AlwaysJson;  // that suggestion, passed back as updatedPermissions
    public List<Question> Questions;  // AskUserQuestion: Claude is asking you something
    public object Input;              // the tool input, sent back with the answers
  }

  public class Question {
    public string Text, Header;
    public bool Multi;
    public List<string> Labels = new List<string>(), Descriptions = new List<string>();
  }

  public class Session {
    public string Id, Cwd, Transcript = "", Activity = "", Title = "";
    public Phase Phase;
    public DateTime Since;  // UTC
    public int Pid;
    public Request Request;
    public Dictionary<string, string> Agents = new Dictionary<string, string>();  // running subagents: id → type
    public string Folder { get { return Paths.FolderName(Cwd); } }
    public string Name { get { return string.IsNullOrEmpty(Title) ? Folder : Title; } }
  }

  public class Usage {
    public long Tokens, Today, Context, Recache;  // recache: today's tokens written to cache again because it expired
    public double Cost, TodayCost;
    public string LastText = "", Model = "";
    public ApiError Error;   // the last thing Anthropic answered was an error (cleared by the next real reply)
    public Usage Clone() { return (Usage)MemberwiseClone(); }
  }

  /// An error Anthropic returned instead of a reply: payment due, access disabled, limits, outages.
  public class ApiError {
    public string Kind, Title, Hint, Text, Code, LinkTitle, Link;
    public long Status;
    public DateTime At;  // UTC
    public string Key { get { return Code + "|" + Status + "|" + At.Ticks; } }

    /// Sorts what Claude Code logged into something you can act on.
    public static ApiError From(long status, string code, string text, DateTime at) {
      string t = ((text ?? "") + " " + (code ?? "")).ToLowerInvariant();
      var e = new ApiError { Status = status, Code = code ?? "", Text = (text ?? "").Trim(), At = at };
      bool apiKey = t.Contains("credit balance") || t.Contains("api key") || t.Contains("console");
      if (status == 402 || t.Contains("credit balance") || t.Contains("billing") || t.Contains("payment") || t.Contains("past due") ||
          t.Contains("past_due") || t.Contains("insufficient") || t.Contains("subscription has expired") || t.Contains("unpaid")) {
        e.Kind = "payment"; e.Title = "Payment needed"; e.Hint = "Claude can't answer until the payment goes through. The HUD tells you when it's working again.";
        e.LinkTitle = "Open billing";
        e.Link = apiKey ? "https://console.anthropic.com/settings/billing" : "https://claude.ai/settings/billing";
      } else if (status == 401 || t.Contains("oauth token") || t.Contains("invalid api key") || t.Contains("authentication") || t.Contains("/login") || t.Contains("expired")) {
        e.Kind = "auth"; e.Title = "Signed out"; e.Hint = "Run /login in Claude Code to sign in again.";
      } else if (status == 403 || t.Contains("disabled") || t.Contains("not allowed") || t.Contains("not_allowed") || t.Contains("forbidden") || t.Contains("permission")) {
        e.Kind = "access"; e.Title = "Access blocked"; e.Hint = "Ask your admin to enable access, or sign in with an Anthropic API key.";
      } else if (status == 429 || t.Contains("rate limit") || t.Contains("rate_limit") || t.Contains("usage limit") || t.Contains("limit reached")) {
        e.Kind = "limit"; e.Title = "Usage limit reached"; e.Hint = "Claude carries on when the limit resets.";
      } else if (status == 529 || t.Contains("overloaded")) {
        e.Kind = "overloaded"; e.Title = "Anthropic is overloaded"; e.Hint = "Claude Code retries by itself; try again in a moment.";
      } else if (status >= 500) {
        e.Kind = "server"; e.Title = "Anthropic API error"; e.Hint = "A problem on Anthropic's side; try again shortly.";
        e.LinkTitle = "Status page"; e.Link = "https://status.anthropic.com";
      } else {
        e.Kind = "other"; e.Title = "Claude couldn't answer"; e.Hint = "";
      }
      return e;
    }
  }

  public class Limit {
    public double Pct;
    public DateTime Resets;  // UTC
    public DateTime? Out;    // when it runs out at the current pace (only if before the reset)
    public bool Paced;       // a pace is known; with Out == null that means "lasts until reset"
  }

  public class Toast {
    public readonly Guid Id = Guid.NewGuid();
    public string Session = "";  // "" = a usage notice
    public string Text = "", Title = "";
    public bool Heavy, Urgent;
    public string Tone = "";               // "error" (red) / "ok" (green) for notices
    public string Link, LinkTitle;         // optional button on a notice
    public double Life = 12;  // seconds a notice stays (session toasts follow the toastSeconds setting)
    public readonly DateTime Created = DateTime.UtcNow;
  }

  /// A way to spend fewer tokens, shown in the drawer's Tips section.
  public class Tip {
    public string Id, Icon, Text, ActionTitle, ActionPrompt;
    public Session ActionSession;
    public long Weight;  // tokens at stake, for ordering
  }

  public class Device {
    public string Id, Name;
    public DateTime Updated;
    public long Tokens, Live;
    public double Cost;
    public bool Mine;
    public bool Online { get { return (DateTime.UtcNow - Updated).TotalSeconds < 180; } }
  }

  /// A Claude Code session on your account that lives elsewhere (remote control, claude.ai/code).
  public class Remote {
    public string Id, Title, Model, Branch;
    public bool Connected, Working;
    public DateTime Last;
  }

  /// Editors whose Claude Code extension answers `<scheme>://anthropic.claude-code/open`.
  public class Editor {
    public string Name, Exe, Scheme;
    public string[] Installs;

    public static readonly Editor[] All = {
      new Editor { Name = "VS Code", Exe = "Code", Scheme = "vscode",
                   Installs = new[] { @"%LOCALAPPDATA%\Programs\Microsoft VS Code\Code.exe", @"%ProgramFiles%\Microsoft VS Code\Code.exe" } },
      new Editor { Name = "Cursor", Exe = "Cursor", Scheme = "cursor",
                   Installs = new[] { @"%LOCALAPPDATA%\Programs\cursor\Cursor.exe", @"%ProgramFiles%\Cursor\Cursor.exe" } },
      new Editor { Name = "VS Code Insiders", Exe = "Code - Insiders", Scheme = "vscode-insiders",
                   Installs = new[] { @"%LOCALAPPDATA%\Programs\Microsoft VS Code Insiders\Code - Insiders.exe" } },
    };

    public static Editor For(HostApp h) {
      if (h == null) return null;
      return All.FirstOrDefault(e => string.Equals(e.Exe, h.Name, StringComparison.OrdinalIgnoreCase));
    }

    /// The running editor (first match wins), else the first one installed.
    public static Editor Current {
      get {
        foreach (var e in All) if (Native.Running(e.Exe + ".exe")) return e;
        foreach (var e in All) if (e.InstalledPath() != null) return e;
        return All[0];
      }
    }

    public string ExePath() {
      foreach (var pid in Native.Pids(Exe + ".exe")) {
        string path = Native.ExePath(pid);
        if (path != null) return path;
      }
      return InstalledPath();
    }

    string InstalledPath() {
      foreach (var i in Installs) {
        string p = Environment.ExpandEnvironmentVariables(i);
        if (File.Exists(p)) return p;
      }
      return null;
    }
  }

  public static class Fmt {
    public static string N(long n) {
      if (n >= 1000000) return (n / 1e6).ToString("0.0", CultureInfo.InvariantCulture) + "M";
      if (n >= 1000) return (n / 1e3).ToString("0", CultureInfo.InvariantCulture) + "k";
      return n.ToString(CultureInfo.InvariantCulture);
    }

    public static string Money(double d) {
      return d >= 100 ? "$" + d.ToString("0", CultureInfo.InvariantCulture) : "$" + d.ToString("0.00", CultureInfo.InvariantCulture);
    }

    public static string Span(double seconds) {
      long s = Math.Max(0, (long)seconds), h = s / 3600, m = s % 3600 / 60;
      if (h >= 24) return h / 24 + "d " + h % 24 + "h";
      return h > 0 ? h + "h " + m + "m" : m + "m";
    }

    /// "15:42" today, "Sat 14:00" later.
    public static string Clock(DateTime utc) {
      var d = utc.ToLocalTime();
      return d.ToString(d.Date == DateTime.Today ? "HH:mm" : "ddd HH:mm", CultureInfo.InvariantCulture);
    }

    public static string Ago(DateTime utc) {
      double s = (DateTime.UtcNow - utc).TotalSeconds;
      return s < 60 ? "just now" : Span(s);
    }

    public static string Cut(string t, int n) { return t.Length > n ? t.Substring(0, n) + "…" : t; }
  }

  public static class Pricing {
    /// API list price per million tokens (input, output, cache read). Cache writes cost 1.25× input (5 min) / 2× (1 h).
    public static double[] Of(string model) {
      model = (model ?? "").ToLowerInvariant();
      if (model.Contains("fable") || model.Contains("mythos")) return new[] { 10.0, 50, 0.25 };
      if (model.Contains("opus-5-5")) return new[] { 4.0, 20, 0.2 };
      if (model.Contains("opus-4-1") || model.Contains("opus-4-2025")) return new[] { 15.0, 75, 1.5 };
      if (model.Contains("opus")) return new[] { 5.0, 25, 0.5 };
      if (model.Contains("sonnet-5")) return new[] { 2.0, 10, 0.2 };
      if (model.Contains("sonnet")) return new[] { 3.0, 15, 0.3 };
      if (model.Contains("haiku")) return new[] { 1.0, 5, 0.1 };
      return new[] { 5.0, 25, 0.5 };
    }
  }

  /// Settings, persisted as JSON in %APPDATA%\ClaudeHUD\prefs.json.
  public static class Prefs {
    static readonly string file = Environment.GetEnvironmentVariable("CLAUDE_HUD_HOME") != null
      ? Path.Combine(Paths.Hud, "prefs.json")
      : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ClaudeHUD", "prefs.json");
    static Dictionary<string, object> d;
    public static event Action Changed;

    public static readonly string[] Hotkeys = { "Ctrl+Alt+Space", "Ctrl+Shift+Space", "Alt+Shift+C", "Ctrl+Alt+C" };

    static readonly Dictionary<string, object> defaults = new Dictionary<string, object> {
      { "theme", "aurora" }, { "glass", 0.85 }, { "edgeGlow", true }, { "edgeDelay", 0.12 },
      { "notifyPermission", true }, { "notifyDone", true }, { "notifyEnded", true }, { "notifyUsage", true },
      { "sounds", true }, { "toastSeconds", 9.0 }, { "meetingQuiet", true }, { "answerInHUD", true },
      { "hotkey", 0L }, { "menuBar", true }, { "loginItem", true }, { "heavyBurn", 1000000.0 }, { "groupByWorkspace", true },
      { "idleMinutes", 10.0 }, { "firstPrompt", "" }, { "autoEndOld", true }, { "autoSend", true }, { "syncDevices", true },
      { "dnd", false }, { "fetchLimits", true },
    };

    static Dictionary<string, object> D {
      get {
        if (d == null) {
          try { d = Json.TryParse(File.ReadAllText(file, Paths.Utf8)) as Dictionary<string, object>; } catch { }
          if (d == null) d = new Dictionary<string, object>();
        }
        return d;
      }
    }

    public static object Get(string k) {
      object v;
      if (D.TryGetValue(k, out v)) return v;
      return defaults.TryGetValue(k, out v) ? v : null;
    }

    public static bool Bool(string k) { object v = Get(k); return v is bool && (bool)v; }
    public static double Num(string k) { object v = Get(k); return v is long ? (long)v : v is double ? (double)v : 0; }
    public static string Str(string k) { return Get(k) as string ?? ""; }

    public static void Set(string k, object v) {
      if (v is int) v = (long)(int)v;
      object old = Get(k);
      if (Equals(old, v)) return;
      D[k] = v;
      try {
        Directory.CreateDirectory(Path.GetDirectoryName(file));
        Paths.WriteAtomic(file, Json.Write(D, true));
      } catch { }
      if (Changed != null) Changed();
    }

    public static HashSet<string> Set_(string k) {
      var l = Get(k) as List<object>;
      return new HashSet<string>(l == null ? new string[0] : l.OfType<string>());
    }

    public static void SaveSet(string k, IEnumerable<string> v) { Set(k, v.Cast<object>().ToList()); }

    public static Dictionary<string, string> Map(string k) {
      var m = Get(k) as Dictionary<string, object>;
      var r = new Dictionary<string, string>();
      if (m != null) foreach (var kv in m) r[kv.Key] = kv.Value as string ?? "";
      return r;
    }

    public static void SaveMap(string k, Dictionary<string, string> m) {
      var o = new Dictionary<string, object>();
      foreach (var kv in m) o[kv.Key] = kv.Value;
      D[k] = o;
      try { Paths.WriteAtomic(file, Json.Write(D, true)); } catch { }
    }
  }
}
