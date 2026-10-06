using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Media;
using System.Net;
using System.Text;
using System.Threading;
using System.Windows.Input;
using System.Windows.Threading;

namespace ClaudeHud {
  static class Sounds {
    static readonly Dictionary<string, string> files = new Dictionary<string, string> {
      { "Glass", "Windows Notify System Generic.wav" }, { "Hero", "Windows Notify Messaging.wav" },
      { "Pop", "Windows Background.wav" }, { "Basso", "Windows Exclamation.wav" },
      { "Submarine", "Windows Notify Calendar.wav" }, { "Tink", "Windows Notify Email.wav" },
    };

    public static void Play(string name) {
      if (!Prefs.Bool("sounds")) return;
      try {
        string f;
        if (files.TryGetValue(name, out f)) {
          f = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Media", f);
          if (File.Exists(f)) { new SoundPlayer(f).Play(); return; }
        }
        SystemSounds.Asterisk.Play();
      } catch { }
    }
  }

  public enum Answer { Allow, Always, Deny, Editor }

  public class Store {
    public Dictionary<string, Session> Sessions = new Dictionary<string, Session>();
    public Dictionary<string, Usage> UsageMap = new Dictionary<string, Usage>();
    public List<Toast> Toasts = new List<Toast>();
    public bool DrawerOpen, Pinned, Searching, InMeeting;
    public int Selected;
    public string ReplyTarget;
    public readonly Dictionary<string, string> Drafts = new Dictionary<string, string>();
    public Limit FiveHour, Week;
    public Dictionary<string, long> Burn = new Dictionary<string, long>();
    public string Query = "";
    public HashSet<string> Collapsed = Prefs.Set_("collapsed");
    /// Handed-off sessions: old id → the session that continued it ("" until it starts).
    public Dictionary<string, string> Retired = Prefs.Map("retired");
    public List<string> Recent = new List<string>();
    public List<Device> Devices = new List<Device>();
    public List<Remote> Remotes = new List<Remote>();
    /// Share of the current 5-hour window that grew while this PC used nothing: claude.ai, phone, other computers.
    public double Elsewhere;
    public HashSet<string> DismissedTips = new HashSet<string>();
    public Guid? HoveredToast;

    public event Action Changed;
    public event Action LimitsChanged;
    public event Action FocusSearchRequested;
    public event Action SettingsRequested;

    class Pace { public double P; public long Local; public DateTime Resets; }
    class Sample { public DateTime T; public double P; }
    class TokenSample { public DateTime T; public long N; }
    class Handoff { public string Old, Cwd; public DateTime At; }

    Pace lastPace;
    Handoff pendingHandoff;
    readonly Dictionary<string, KeyValuePair<string, DateTime>> prepared = new Dictionary<string, KeyValuePair<string, DateTime>>();
    readonly Dictionary<string, DateTime> reminded = new Dictionary<string, DateTime>();
    readonly Dictionary<string, DateTime> passthrough = new Dictionary<string, DateTime>();
    readonly Dictionary<string, List<Sample>> samples = new Dictionary<string, List<Sample>>();
    readonly Dictionary<string, List<TokenSample>> tokenSamples = new Dictionary<string, List<TokenSample>>();
    readonly HashSet<string> warned = new HashSet<string>();
    HashSet<string> heavyWarned = new HashSet<string>();
    DateTime lastDeviceSync = DateTime.MinValue, limitsMod = DateTime.MinValue;
    long offset;
    bool scanning;
    readonly TokenCounter counter = new TokenCounter();
    readonly Dispatcher ui = Dispatcher.CurrentDispatcher;

    public Store() {
      foreach (var d in new[] { Paths.Req, Paths.Ans }) { try { Directory.CreateDirectory(d); } catch { } }
      try { foreach (var f in Directory.GetFiles(Paths.Ans)) File.Delete(f); } catch { }
      ReadEvents(false);  // rebuild state from history quietly
      if (offset > 2000000) {
        try {
          using (var f = new FileStream(Paths.Events, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) f.SetLength(0);
          offset = 0;
        } catch { }
      }
      RefreshUsage();
      FetchLimits();
      Every(0.35, Tick);
      Every(4, RefreshUsage);
      Every(120, FetchLimits);
    }

    void Every(double seconds, Action a) {
      var t = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(seconds) };
      t.Tick += (o, e) => { try { a(); } catch { } };
      t.Start();
    }

    public static void After(double seconds, Action a) {
      var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
      t.Tick += (o, e) => { t.Stop(); try { a(); } catch { } };
      t.Start();
    }

    public void Notify() { if (Changed != null) Changed(); }

    public bool Dnd {
      get { return Prefs.Bool("dnd"); }
      set { Prefs.Set("dnd", value); Notify(); }
    }
    public bool Quiet { get { return Dnd || (InMeeting && Prefs.Bool("meetingQuiet")); } }

    void SaveRetired() { Prefs.SaveMap("retired", Retired); }

    // MARK: derived state

    int Rank(Session s) { return Retired.ContainsKey(s.Id) ? 9 : (int)s.Phase; }

    public List<Session> Sorted {
      get {
        var list = Sessions.Values.Where(s => s.Phase != Phase.Ready || Use(s).Tokens > 0).ToList();
        if (!Prefs.Bool("groupByWorkspace")) return list.OrderBy(Rank).ThenByDescending(s => s.Since).ToList();
        // Workspaces ordered by their most urgent session, sessions by phase inside each.
        var rank = list.GroupBy(s => s.Cwd).ToDictionary(g => g.Key, g => g.Min(s => Rank(s)));
        return list.OrderBy(s => rank[s.Cwd]).ThenBy(s => s.Cwd, StringComparer.Ordinal)
                   .ThenBy(Rank).ThenByDescending(s => s.Since).ToList();
      }
    }

    public Phase? Urgent {
      get {
        var s = Sorted.FirstOrDefault(x => !Retired.ContainsKey(x.Id));
        return s == null ? (Phase?)null : s.Phase;
      }
    }

    /// Sessions matching the search box.
    public List<Session> Filtered {
      get {
        string q = Query.Trim().ToLowerInvariant();
        if (q.Length == 0) return Sorted;
        return Sorted.Where(s => new[] { s.Name, s.Folder, s.Activity, Use(s).LastText }.Any(x => (x ?? "").ToLowerInvariant().Contains(q))).ToList();
      }
    }

    /// What the keyboard moves through: filtered, minus collapsed workspaces.
    public List<Session> Visible {
      get {
        var f = Filtered;
        return Prefs.Bool("groupByWorkspace") && Query.Length == 0 ? f.Where(s => !Collapsed.Contains(s.Cwd)).ToList() : f;
      }
    }

    public double TodayCost { get { return UsageMap.Values.Sum(u => u.TodayCost); } }
    public long TodayTokens { get { return UsageMap.Values.Sum(u => u.Today); } }

    public void ToggleCollapse(string key) {
      if (!Collapsed.Remove(key)) Collapsed.Add(key);
      Prefs.SaveSet("collapsed", Collapsed);
      Notify();
    }

    public Session Successor(string id) {
      string n;
      Session s;
      return Retired.TryGetValue(id, out n) && n != null && Sessions.TryGetValue(n, out s) ? s : null;
    }

    public Session Predecessor(string id) {
      foreach (var kv in Retired) {
        Session s;
        if (kv.Value == id && Sessions.TryGetValue(kv.Key, out s)) return s;
      }
      return null;
    }

    /// The session's own transcript plus its subagents' transcripts.
    public Usage Use(Session s) {
      Usage u = null;
      string key = Paths.Norm(s.Transcript), id = s.Id.ToLowerInvariant();
      if (key.Length > 0) UsageMap.TryGetValue(key, out u);
      if (u == null) {
        string tail = "\\" + id + ".jsonl";
        u = UsageMap.Where(kv => kv.Key.EndsWith(tail)).Select(kv => kv.Value).FirstOrDefault();
      }
      u = u == null ? new Usage() : u.Clone();
      string sub = "\\" + id + "\\subagents\\";
      foreach (var kv in UsageMap) {
        if (kv.Key.Contains(sub)) { u.Tokens += kv.Value.Tokens; u.Today += kv.Value.Today; }
      }
      return u;
    }

    /// Why a session is expensive right now, or null.
    public string Heavy(Session s) {
      if (s.Phase == Phase.Ended || Retired.ContainsKey(s.Id)) return null;
      var u = Use(s);
      long b;
      Burn.TryGetValue(s.Id, out b);
      if (b >= Prefs.Num("heavyBurn")) return Fmt.N(b) + " tokens in the last 10 min";
      if (u.Context >= 350000) return "context " + Fmt.N(u.Context) + " is re-sent every turn";
      if (s.Agents.Count >= 3) return s.Agents.Count + " agents running at once";
      return null;
    }

    /// Concrete ways to use fewer tokens, worst first. Sessions already flagged heavy get their own banner instead.
    public List<Tip> Tips {
      get {
        var t = new List<Tip>();
        foreach (var s in Sessions.Values.Where(x => x.Phase != Phase.Ended && !Retired.ContainsKey(x.Id) && Heavy(x) == null)) {
          var u = Use(s);
          if (u.Context >= 120000 && s.Phase != Phase.Working) {
            t.Add(new Tip { Id = "ctx" + s.Id, Icon = "",
              Text = s.Name + " re-sends " + Fmt.N(u.Context) + " of context with every message. Compact it, or start a fresh session for the next task.",
              ActionTitle = "Compact", ActionSession = s, ActionPrompt = "/compact", Weight = u.Context });
          }
          if (u.Recache >= 150000) {
            t.Add(new Tip { Id = "cache" + s.Id, Icon = "",
              Text = s.Name + " paid full price for " + Fmt.N(u.Recache) + " tokens today because its cache expired during breaks (5 min). Compact before stepping away, and end sessions you're done with.",
              ActionTitle = "Compact", ActionSession = s, ActionPrompt = "/compact", Weight = u.Recache });
          }
          string m = u.Model.ToLowerInvariant();
          double save = 1 - Pricing.Of("sonnet-5")[1] / Pricing.Of(m)[1];
          if ((m.Contains("opus") || m.Contains("fable")) && u.Today >= 500000 && save >= 0.3) {
            t.Add(new Tip { Id = "model" + s.Id, Icon = "",
              Text = s.Name + " runs on " + (m.Contains("fable") ? "Fable" : "Opus") + ". Sonnet costs " + (int)(save * 100) + "% less and handles routine edits, tests and renames well.",
              ActionTitle = "Use Sonnet", ActionSession = s, ActionPrompt = "/model sonnet", Weight = (long)(u.Today * save) });
          }
        }
        long sub = UsageMap.Where(kv => kv.Key.Contains("\\subagents\\")).Sum(kv => kv.Value.Today);
        long today = TodayTokens;
        if (today >= 1000000 && sub >= 0.4 * today) {
          t.Add(new Tip { Id = "agents", Icon = "",
            Text = "Subagents used " + sub * 100 / today + "% of today's tokens. Ask for fewer parallel agents, or name the files to look at instead of a broad search.", Weight = sub });
        }
        t = t.OrderByDescending(x => x.Weight).ToList();
        if (FiveHour != null && FiveHour.Out.HasValue) {
          t.Insert(0, new Tip { Id = "pace", Icon = "",
            Text = "At this pace you hit the 5-hour limit at " + Fmt.Clock(FiveHour.Out.Value) + ". Pause the sessions you aren't watching, or move routine work to Sonnet." });
        }
        return t.Where(x => !DismissedTips.Contains(x.Id)).Take(3).ToList();
      }
    }

    // MARK: ticking

    /// Runs ~3×/s.
    void Tick() {
      ReadEvents(true);
      ReadRequests();
      var now = DateTime.UtcNow;
      foreach (var s in Sessions.Values) {
        if (s.Phase != Phase.Ended && s.Pid > 1 && !Native.Alive(s.Pid)) {
          // The claude process is gone without a SessionEnd (terminal closed, crash, killed).
          s.Phase = Phase.Ended;
          s.Since = now;
          s.Activity = "";
          s.Agents.Clear();
          Alert(s, "Session ended", "Pop", "notifyEnded");
        }
      }
      foreach (var id in Sessions.Keys.ToList()) {
        var s = Sessions[id];
        double age = (now - s.Since).TotalSeconds;
        if (s.Phase == Phase.Ended ? age >= 60 : age >= 8 * 3600) Sessions.Remove(id);
      }
      Toasts.RemoveAll(t => {
        if (HoveredToast == t.Id) return false;
        double age = (now - t.Created).TotalSeconds;
        if (t.Session.Length == 0) return age >= t.Life;
        Session s;
        if (!Sessions.TryGetValue(t.Session, out s)) return true;
        return !(s.Phase == Phase.Permission || ReplyTarget == t.Session || age < Prefs.Num("toastSeconds"));
      });
      Notify();
    }

    // MARK: events.jsonl

    void ReadEvents(bool alert) {
      if (!File.Exists(Paths.Events)) return;
      byte[] data;
      try {
        using (var f = new FileStream(Paths.Events, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
          long size = f.Length;
          if (size < offset) offset = 0;
          if (size <= offset) return;
          f.Seek(offset, SeekOrigin.Begin);
          data = new byte[size - offset];
          int got = 0;
          while (got < data.Length) {
            int n = f.Read(data, got, data.Length - got);
            if (n <= 0) break;
            got += n;
          }
          if (got < data.Length) Array.Resize(ref data, got);
        }
      } catch (IOException) { return; }
      int nl = Array.LastIndexOf(data, (byte)10);
      if (nl < 0) return;  // a half-written line waits for next time
      offset += nl + 1;
      foreach (var line in Encoding.UTF8.GetString(data, 0, nl).Split('\n')) {
        var j = Json.TryParse(line);
        if (j != null) Apply(j, alert);
      }
    }

    static bool LooksLikePath(string x) {
      return x.StartsWith("/") || (x.Length > 2 && char.IsLetter(x[0]) && x[1] == ':' && (x[2] == '\\' || x[2] == '/'));
    }

    void Apply(object j, bool doAlert) {
      string id = Json.Str(j, "s"), ev = Json.Str(j, "e");
      if (id == null || ev == null) return;
      Session s;
      Sessions.TryGetValue(id, out s);
      if (ev == "SubagentStart" || ev == "SubagentStop") {
        string aid = Json.Str(j, "ai");
        if (s == null || aid == null) return;
        if (ev == "SubagentStart") s.Agents[aid] = Json.Str(j, "at") ?? "agent";
        else s.Agents.Remove(aid);
        return;
      }
      string type = Json.Str(j, "t") ?? "", msg = Json.Str(j, "m") ?? "";
      Phase next;
      switch (ev) {
        case "SessionStart": next = Phase.Ready; break;
        case "UserPromptSubmit": case "PreToolUse": case "PostToolUse": next = Phase.Working; break;
        case "Stop": next = Phase.Done; break;
        case "SessionEnd": next = Phase.Ended; break;
        case "Notification":
          if (type == "permission_prompt" || type == "elicitation_dialog" || type == "elicitation_url_dialog") { next = Phase.Permission; break; }
          return;
        default: return;
      }
      double? tsn = Json.Num(j, "ts");
      DateTime ts = tsn.HasValue ? Paths.FromEpoch(tsn.Value) : DateTime.UtcNow;
      Phase? prev = s == null ? (Phase?)null : s.Phase;
      string cwd = Json.Str(j, "c") ?? "?";
      var h = pendingHandoff;
      if (s == null && h != null && h.Old != id && ts > h.At && (ts - h.At).TotalSeconds < 900 &&
          cwd.StartsWith(h.Cwd, StringComparison.OrdinalIgnoreCase)) {
        Retired[h.Old] = id;
        SaveRetired();
        pendingHandoff = null;
      }
      if (s == null) {
        s = new Session { Id = id, Cwd = cwd, Phase = next, Since = ts };
        Sessions[id] = s;
      }
      long p = Json.Long(j, "p");
      if (p > 1) s.Pid = (int)p;
      string tp = Json.Str(j, "tp");
      if (!string.IsNullOrEmpty(tp)) s.Transcript = tp;
      string tool = Json.Str(j, "tn");
      if (ev == "PreToolUse" && tool != null) {
        string x = Json.Str(j, "x") ?? "";
        s.Activity = tool + (x.Length == 0 ? "" : " · " + (LooksLikePath(x) ? Paths.FolderName(x) : x));
      } else if (next == Phase.Done || next == Phase.Ended || ev == "UserPromptSubmit") {
        s.Activity = "";
      }
      if (next == Phase.Ended) s.Agents.Clear();
      bool keep = (prev == Phase.Working && next == Phase.Working) ||
                  (s.Request != null && (next == Phase.Working || next == Phase.Permission));
      if (!keep) { s.Phase = next; s.Since = ts; }
      if (!doAlert || keep || prev == next) return;
      switch (next) {
        case Phase.Permission:
          DateTime pt;
          if (!passthrough.TryGetValue(id, out pt) || (DateTime.UtcNow - pt).TotalSeconds > 120)
            Alert(s, msg.Length == 0 ? "Needs your attention" : msg, "Glass", "notifyPermission");
          break;
        case Phase.Done: Alert(s, "", "Hero", "notifyDone"); break;
        case Phase.Ended: Alert(s, "Session ended", "Pop", "notifyEnded"); break;
      }
    }

    // MARK: permission requests (req/<id>.json written by the perm hook, answered via ans/<id>)

    readonly HashSet<string> answered = new HashSet<string>();

    /// Hands the answer to the waiting perm hook, and makes sure the request can't pop up again.
    void SendAnswer(Request r, string body) {
      answered.Add(r.Id);
      try { Paths.WriteAtomic(Path.Combine(Paths.Ans, r.Id), body); } catch { }
      try { File.Delete(Path.Combine(Paths.Req, r.Id + ".json")); } catch { }
    }

    void ReadRequests() {
      string[] files;
      try { files = Directory.GetFiles(Paths.Req, "*.json"); } catch { files = new string[0]; }
      if (files.Length == 0 && !Sessions.Values.Any(s => s.Request != null)) return;
      var live = new HashSet<string>();
      foreach (var f in files) {
        string rid = Path.GetFileNameWithoutExtension(f);
        if (answered.Contains(rid)) continue;  // answered; the hook just hasn't picked it up yet
        object j;
        try { j = Json.TryParse(Paths.ReadShared(f)); } catch { continue; }
        string sid = Json.Str(j, "session_id");
        if (sid == null) continue;
        int pid = (int)Json.Long(j, "pid"), hook = (int)Json.Long(j, "hook_pid");
        if ((pid > 1 && !Native.Alive(pid)) || (hook > 1 && !Native.Alive(hook))) {
          try { File.Delete(f); } catch { }
          continue;
        }
        live.Add(rid);
        Session s;
        Sessions.TryGetValue(sid, out s);
        if (s != null && s.Request != null) continue;  // one at a time per session
        var input = Json.Get(j, "tool_input");
        string detail = new[] { "command", "file_path", "url", "pattern", "query", "description", "prompt" }
          .Select(k => Json.Str(input, k)).FirstOrDefault(v => v != null)
          ?? Json.Write(input ?? new Dictionary<string, object>(), false);
        var r = new Request { Id = rid, Tool = Json.Str(j, "tool_name") ?? "Tool", Detail = detail, Input = input };
        var qs = Json.Arr(input, "questions");
        if (r.Tool == "AskUserQuestion" && qs != null && qs.Count > 0) {
          r.Questions = new List<Question>();
          foreach (var q in qs) {
            var item = new Question { Text = Json.Str(q, "question") ?? "", Header = Json.Str(q, "header") ?? "", Multi = Json.Bool(q, "multiSelect") };
            foreach (var o in Json.Arr(q, "options") ?? new List<object>()) {
              string label = o as string ?? Json.Str(o, "label");
              if (label == null) continue;
              item.Labels.Add(label);
              item.Descriptions.Add(Json.Str(o, "description") ?? "");
            }
            r.Questions.Add(item);
          }
          r.Detail = r.Questions[0].Text;
        }
        var sug = Json.Arr(j, "permission_suggestions");
        if (sug != null && sug.Count > 0) {
          r.AlwaysJson = Json.Write(sug, false);
          r.Always = string.Join(" + ", sug.Select(SuggestionLabel));
        }
        if (s == null) {
          s = new Session { Id = sid, Cwd = Json.Str(j, "cwd") ?? "?", Phase = Phase.Permission, Since = DateTime.UtcNow };
          Sessions[sid] = s;
        }
        s.Request = r;
        s.Phase = Phase.Permission;
        s.Since = DateTime.UtcNow;
        if (s.Pid < 2) s.Pid = pid;
        if (s.Transcript.Length == 0) s.Transcript = Json.Str(j, "transcript_path") ?? "";
        Alert(s, "", "Glass", "notifyPermission", false, r.Questions != null);
      }
      foreach (var s in Sessions.Values) {
        if (s.Request != null && !live.Contains(s.Request.Id)) {
          s.Request = null;
          if (s.Phase == Phase.Permission) s.Phase = Phase.Working;
        }
      }
    }

    static string SuggestionLabel(object s) {
      var rules = Json.Arr(s, "rules");
      if (rules != null) {
        return string.Join(", ", rules.Select(r => {
          string t = Json.Str(r, "toolName") ?? "", c = Json.Str(r, "ruleContent");
          return c != null ? t + "(" + c + ")" : t;
        }));
      }
      string mode = Json.Str(s, "mode");
      if (mode != null) return "mode: " + mode;
      var dirs = Json.Arr(s, "directories");
      if (dirs != null) return string.Join(", ", dirs.OfType<string>());
      return Json.Str(s, "type") ?? "rule";
    }

    public void Respond(Session s, Answer a) {
      var r = s.Request;
      if (r == null) { Jump(s); return; }
      if (r.Questions != null && (a == Answer.Allow || a == Answer.Always)) return;  // a question needs an answer, not a yes
      string decision;
      switch (a) {
        case Answer.Always: decision = "{\"behavior\":\"allow\",\"updatedPermissions\":" + (r.AlwaysJson ?? "[]") + "}"; break;
        case Answer.Deny: decision = "{\"behavior\":\"deny\",\"message\":\"Denied from Claude HUD\"}"; break;
        default: decision = "{\"behavior\":\"allow\"}"; break;
      }
      string body = a == Answer.Editor ? "" : "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":" + decision + "}}";
      SendAnswer(r, body);
      s.Request = null;
      if (a != Answer.Editor) s.Phase = Phase.Working;
      Toasts.RemoveAll(t => t.Session == s.Id);
      if (a == Answer.Editor) { passthrough[s.Id] = DateTime.UtcNow; Jump(s); }
      Notify();
    }

    /// Answers Claude's AskUserQuestion from the HUD: the tool runs with your answers filled in
    /// (question text → chosen label; several labels joined with ", ").
    public void AnswerQuestions(Session s, Dictionary<string, string> answers) {
      var r = s.Request;
      if (r == null || r.Questions == null) return;
      var input = new Dictionary<string, object>();
      var given = r.Input as Dictionary<string, object>;
      if (given != null) foreach (var kv in given) input[kv.Key] = kv.Value;
      var a = new Dictionary<string, object>();
      foreach (var kv in answers) a[kv.Key] = kv.Value;
      input["answers"] = a;
      var decision = new Dictionary<string, object>();
      decision["behavior"] = "allow";
      decision["updatedInput"] = input;
      var hso = new Dictionary<string, object>();
      hso["hookEventName"] = "PermissionRequest";
      hso["decision"] = decision;
      var body = new Dictionary<string, object>();
      body["hookSpecificOutput"] = hso;
      SendAnswer(r, Json.Write(body, false));
      s.Request = null;
      s.Phase = Phase.Working;
      Toasts.RemoveAll(t => t.Session == s.Id);
      Notify();
    }

    // MARK: usage

    void RefreshUsage() {
      try {
        if (File.Exists(Paths.Limits)) {
          var mod = File.GetLastWriteTimeUtc(Paths.Limits);
          if (mod != limitsMod) {
            var j = Json.TryParse(Paths.ReadShared(Paths.Limits));
            if (j != null) {
              limitsMod = mod;
              ApplyLimits(j);
            }
          }
        }
      } catch { }
      InMeeting = Native.Running("CptHost.exe");  // Zoom's in-meeting helper
      if (scanning) return;
      scanning = true;
      ThreadPool.QueueUserWorkItem(_ => {
        Dictionary<string, Usage> u = null;
        try { u = counter.Scan(); } catch { }
        ui.BeginInvoke(new Action(() => {
          scanning = false;
          if (u != null) UsageMap = u;
          try {
            CheckErrors();
            ReadRegistry();
            UpdateBurn();
            RemindIdle();
            SyncDevices();
          } catch { }
          Notify();
        }));
      });
    }

    // MARK: errors from Anthropic (payment due, access disabled, signed out, limits, outages)

    readonly DateTime started = DateTime.UtcNow;
    readonly Dictionary<string, ApiError> announced = new Dictionary<string, ApiError>();  // transcript → error we told you about
    public event Action IssueChanged;
    string lastIssue;

    /// The account problem blocking Claude right now (most recent unresolved error of the last day), or null.
    public ApiError Issue {
      get {
        return UsageMap.Values.Where(u => u.Error != null && (DateTime.UtcNow - u.Error.At).TotalHours < 24)
                       .Select(u => u.Error).OrderByDescending(e => e.At).FirstOrDefault();
      }
    }

    Session SessionFor(string transcriptKey) {
      foreach (var s in Sessions.Values) {
        if (Paths.Norm(s.Transcript) == transcriptKey || transcriptKey.EndsWith("\\" + s.Id.ToLowerInvariant() + ".jsonl")) return s;
      }
      return null;
    }

    /// One alert per new error, and one "working again" when the next real reply shows it's fixed
    /// (payment went through, access restored, limit reset). Errors from before the HUD started stay quiet.
    void CheckErrors() {
      foreach (var kv in UsageMap) {
        var e = kv.Value.Error;
        ApiError told;
        announced.TryGetValue(kv.Key, out told);
        if (e != null && (told == null || told.Key != e.Key)) {
          announced[kv.Key] = e;
          if (e.At < started.AddMinutes(-10) || (told != null && told.Kind == e.Kind)) continue;  // old, or the same problem again
          var s = SessionFor(kv.Key);
          if (!Quiet) Sounds.Play("Basso");
          Toasts.RemoveAll(t => t.Tone == "error" && t.Title == e.Title);
          Toasts.Add(new Toast {
            Title = e.Title + (s != null ? " · " + s.Name : ""), Text = e.Text + (e.Hint.Length > 0 ? "\n" + e.Hint : ""),
            Tone = "error", Link = e.Link, LinkTitle = e.LinkTitle, Life = 120, Urgent = true,
          });
        } else if (e == null && told != null) {
          announced.Remove(kv.Key);
          if ((DateTime.UtcNow - told.At).TotalHours >= 24) continue;  // a stale error from another day
          Toasts.RemoveAll(t => t.Tone == "error");
          var s = SessionFor(kv.Key);
          Toasts.Add(new Toast {
            Title = told.Kind == "payment" ? "Payment went through" : told.Title + " — resolved",
            Text = "Claude is answering again" + (s != null ? " in " + s.Name : "") + ".", Tone = "ok", Life = 20,
          });
          if (!Quiet) Sounds.Play("Hero");
        }
      }
      var issue = Issue;
      string key = issue == null ? null : issue.Key;
      if (key != lastIssue) { lastIssue = key; if (IssueChanged != null) IssueChanged(); }
    }

    public void OpenLink(string url) {
      if (string.IsNullOrEmpty(url) || Trace("link " + url)) return;
      try { Process.Start(url); } catch { }
    }

    void ApplyLimits(object j) {
      var f = Lim(j, "five_hour", "5-hour");
      var w = Lim(j, "seven_day", "Weekly");
      if (f != null) {
        long local = TodayTokens;
        if (lastPace != null && f.Resets == lastPace.Resets) {
          if (f.Pct - lastPace.P >= 0.5 && local - lastPace.Local < 20000) {
            Elsewhere += f.Pct - lastPace.P;
            if (Elsewhere >= 3 && warned.Add("elsewhere" + Paths.Epoch(f.Resets)))
              Notice("Claude is being used elsewhere", "+" + (int)Elsewhere + "% of your 5-hour window came from claude.ai, a phone or another computer while this PC was idle");
          }
        } else if (lastPace != null) {
          Elsewhere = 0;  // new window
        }
        lastPace = new Pace { P = f.Pct, Local = local, Resets = f.Resets };
      }
      FiveHour = f;
      Week = w;
      if (LimitsChanged != null) LimitsChanged();
    }

    static DateTime? ParseDate(object v) {
      if (v is long || v is double) return Paths.FromEpoch(Convert.ToDouble(v));
      var s = v as string;
      DateTime d;
      if (s != null && DateTime.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out d)) return d;
      return null;
    }

    Limit Lim(object j, string k, string label) {
      var o = Json.Get(j, k);
      double? pp = Json.Num(o, "used_percentage");
      if (!pp.HasValue) return null;
      double p = pp.Value;
      var now = DateTime.UtcNow;
      DateTime r = ParseDate(Json.Get(o, "resets_at")) ?? now;
      if (r < now) return new Limit { Pct = 0, Resets = r };
      // Forecast: burn rate over the last hour of samples → time until 100%.
      List<Sample> arr;
      if (!samples.TryGetValue(k, out arr)) arr = new List<Sample>();
      arr = arr.Where(x => (now - x.T).TotalSeconds < 3600 && x.P <= p).ToList();
      arr.Add(new Sample { T = now, P = p });
      samples[k] = arr;
      // Pace: recent samples when they span 5+ min, else the average since the window opened.
      DateTime start = r.AddSeconds(k == "five_hour" ? -5 * 3600 : -7 * 86400);
      double? rate = null;
      var first = arr[0];
      if (p > first.P && (now - first.T).TotalSeconds >= 300) rate = (p - first.P) / (now - first.T).TotalSeconds;
      else if (p > 0 && (now - start).TotalSeconds > 600) rate = p / (now - start).TotalSeconds;
      double? eta = null;
      if (rate.HasValue && rate.Value > 0 && (100 - p) / rate.Value < (r - now).TotalSeconds) eta = (100 - p) / rate.Value;
      foreach (var th in new[] { 80.0, 95.0 }) {
        if (p >= th && warned.Add(k + th + Paths.Epoch(r))) {
          Notice(label + " usage at " + (int)p + "%",
                 eta.HasValue ? "At this pace you hit the limit in ~" + Fmt.Span(eta.Value) : "Resets in " + Fmt.Span((r - now).TotalSeconds));
        }
      }
      return new Limit { Pct = p, Resets = r, Out = eta.HasValue ? now.AddSeconds(eta.Value) : (DateTime?)null, Paced = rate.HasValue };
    }

    /// 5-hour / weekly usage from the endpoint `/usage` uses, signed in with Claude Code's own login
    /// (~/.claude/.credentials.json on Windows). Saved in the statusline's format.
    void FetchLimits() {
      if (!Prefs.Bool("fetchLimits")) return;
      ThreadPool.QueueUserWorkItem(_ => {
        try {
          string cred = Path.Combine(Paths.Claude, ".credentials.json");
          if (!File.Exists(cred)) return;
          string token = Json.Str(Json.Get(Json.TryParse(Paths.ReadShared(cred)), "claudeAiOauth"), "accessToken");
          if (token == null) return;
          FetchRemote(token);
          var u = Json.TryParse(Http("https://api.anthropic.com/api/oauth/usage", token, false));
          if (u == null) return;
          var limits = new Dictionary<string, object>();
          foreach (var k in new[] { "five_hour", "seven_day" }) {
            var o = Json.Get(u, k);
            double? pct = Json.Num(o, "utilization");
            DateTime? r = ParseDate(Json.Get(o, "resets_at"));
            if (!pct.HasValue || !r.HasValue) continue;
            var l = new Dictionary<string, object>();
            l["used_percentage"] = pct.Value;
            l["resets_at"] = Paths.Epoch(r.Value);
            limits[k] = l;
          }
          if (limits.Count > 0) Paths.WriteAtomic(Paths.Limits, Json.Write(limits, false));
        } catch { }
      });
    }

    static string Http(string url, string token, bool version) {
      ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
      var req = (HttpWebRequest)WebRequest.Create(url);
      req.Timeout = 10000;
      req.UserAgent = "ClaudeHUD-Windows";
      req.Headers["Authorization"] = "Bearer " + token;
      req.Headers["anthropic-beta"] = "oauth-2025-04-20";
      if (version) req.Headers["anthropic-version"] = "2023-06-01";
      using (var resp = (HttpWebResponse)req.GetResponse()) {
        if (resp.StatusCode != HttpStatusCode.OK) return null;
        using (var r = new StreamReader(resp.GetResponseStream(), Encoding.UTF8)) return r.ReadToEnd();
      }
    }

    /// Claude Code sessions on the account that run elsewhere (remote control, claude.ai/code), active in the last 2 days.
    void FetchRemote(string token) {
      try {
        var rows = Json.Arr(Json.TryParse(Http("https://api.anthropic.com/v1/code/sessions", token, true)), "data");
        if (rows == null) return;
        var list = new List<Remote>();
        foreach (var x in rows) {
          string id = Json.Str(x, "id");
          DateTime? last = ParseDate(Json.Get(x, "last_event_at"));
          if (id == null || Json.Str(x, "status") != "active" || !last.HasValue || (DateTime.UtcNow - last.Value).TotalDays >= 2) continue;
          var meta = Json.Get(x, "external_metadata");
          string branch = "";
          var branches = Json.TryParse(Json.Str(meta, "current_branches") ?? "") as Dictionary<string, object>;
          if (branches != null && branches.Count > 0) {
            var b = branches.First();
            branch = Paths.FolderName(b.Key) + " · " + b.Value;
          }
          string worker = Json.Str(x, "worker_status");
          list.Add(new Remote {
            Id = id, Title = Json.Str(x, "title") ?? "Session", Connected = Json.Str(x, "connection_status") == "connected",
            Working = worker == "running" || worker == "busy", Model = (Json.Str(meta, "model") ?? "").Replace("claude-", ""),
            Branch = branch, Last = last.Value,
          });
        }
        ui.BeginInvoke(new Action(() => { Remotes = list; Notify(); }));
      } catch { }
    }

    /// Token growth per session over the last 10 minutes; warns once when a session turns heavy.
    void UpdateBurn() {
      var now = DateTime.UtcNow;
      var b = new Dictionary<string, long>();
      foreach (var s in Sessions.Values) {
        long n = Use(s).Tokens;
        List<TokenSample> arr;
        if (!tokenSamples.TryGetValue(s.Id, out arr)) arr = new List<TokenSample>();
        arr = arr.Where(x => (now - x.T).TotalSeconds < 600).ToList();
        arr.Add(new TokenSample { T = now, N = n });
        tokenSamples[s.Id] = arr;
        b[s.Id] = Math.Max(0, n - arr[0].N);
      }
      Burn = b;
      foreach (var s in Sessions.Values.Where(x => x.Phase != Phase.Permission).ToList()) {
        string why = Heavy(s);
        if (why == null || !heavyWarned.Add(s.Id)) continue;
        Alert(s, "Heavy: " + why, "Basso", "notifyUsage", true);
        PrepareHandoff(s);
      }
      heavyWarned = new HashSet<string>(heavyWarned.Where(id => Sessions.ContainsKey(id) && Heavy(Sessions[id]) != null));
    }

    /// Claude's session registry: gives each live session its own name.
    void ReadRegistry() {
      if (!Directory.Exists(Paths.Sessions)) return;
      var names = new Dictionary<string, string>();
      var dirs = new Dictionary<string, string>();
      var seen = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
      foreach (var f in Directory.GetFiles(Paths.Sessions, "*.json")) {
        object j;
        try { j = Json.TryParse(Paths.ReadShared(f)); } catch { continue; }
        string id = Json.Str(j, "sessionId"), n = Json.Str(j, "name"), c = Json.Str(j, "cwd");
        if (id == null) continue;
        if (n != null) names[id] = n;
        if (c != null) {
          dirs[id] = c;
          double at = Json.Num(j, "updatedAt") ?? 0, cur;
          seen[c] = seen.TryGetValue(c, out cur) ? Math.Max(cur, at) : at;
        }
      }
      Recent = seen.OrderByDescending(kv => kv.Value).Select(kv => kv.Key).Take(10).ToList();
      foreach (var s in Sessions.Values) {
        string n, c;
        if (names.TryGetValue(s.Id, out n)) s.Title = n;
        if (dirs.TryGetValue(s.Id, out c)) s.Cwd = c;
      }
    }

    // MARK: actions

    public void Alert(Session s, string text, string sound, string pref, bool heavy = false, bool urgent = false) {
      if (Quiet || !Prefs.Bool(pref) || Retired.ContainsKey(s.Id)) return;  // muted: state still updates, the edge still glows
      Sounds.Play(sound);
      Toasts.RemoveAll(t => t.Session == s.Id);
      Toasts.Add(new Toast { Session = s.Id, Text = text, Heavy = heavy, Urgent = urgent });
      if (Toasts.Count > 4) {
        int i = Toasts.FindIndex(t => { Session x; return !Sessions.TryGetValue(t.Session, out x) || x.Phase != Phase.Permission; });
        if (i >= 0) Toasts.RemoveAt(i);
      }
      Notify();
    }

    public void Notice(string title, string text) {
      if (Quiet || !Prefs.Bool("notifyUsage")) return;
      Sounds.Play("Submarine");
      Toasts.Add(new Toast { Title = title, Text = text });
      Notify();
    }

    /// Setup and welcome messages: always shown, whatever the notification settings.
    public void Say(string title, string text) {
      Toasts.Add(new Toast { Title = title, Text = text, Life = 30 });
      Notify();
    }

    public HostApp Host(Session s) { return Native.FindHost(s.Pid); }

    /// The editor a session runs in, when it's one we can deep-link into (else the running editor).
    Editor HostEditor(Session s) { return Editor.For(Host(s)) ?? Editor.Current; }

    /// Sessions in an app without a deep link (terminal, JetBrains, …): bring that app forward and put any
    /// text on the clipboard. Returns false when the session's app is a supported editor (or unknown).
    bool Reach(Session s, string text, bool fresh) {
      var app = Host(s);
      if (app == null || Editor.For(app) != null) return false;
      if (!string.IsNullOrEmpty(text)) {
        for (int i = 0; i < 5 && !Trace("clipboard " + text); i++) {
          try { System.Windows.Clipboard.SetText(text); break; } catch { Thread.Sleep(40); }
        }
        Toasts.Add(new Toast {
          Title = fresh ? "Handoff copied" : "Reply copied",
          Text = fresh ? "Start a new claude session in " + app.Label + " and paste (Ctrl+V)." : "Paste it into " + s.Name + " in " + app.Label + " (Ctrl+V).",
        });
      }
      if (!Trace("focus " + app.Name)) Native.Focus(app.Window);
      return true;
    }

    /// Test mode (CLAUDE_HUD_HOME): log outward actions (opening editors, focusing windows, the clipboard)
    /// to hud/actions.log instead of doing them. Returns true when it logged.
    static bool Trace(string what) {
      if (!Paths.Testing) return false;
      try { File.AppendAllText(Path.Combine(Paths.Hud, "actions.log"), what.Replace("\n", "\\n") + "\n", Paths.Utf8); } catch { }
      return true;
    }

    public void Dismiss(Toast t) { Toasts.Remove(t); Notify(); }

    public void Close() {
      DrawerOpen = false;
      Pinned = false;
      ReplyTarget = null;
      Searching = false;
      Notify();
    }

    public void OpenSettings() { Close(); if (SettingsRequested != null) SettingsRequested(); }

    static KeyValuePair<string, string> Kv(string k, string v) { return new KeyValuePair<string, string>(k, v); }

    /// Focus the editor window holding the session's folder, then its exact chat tab (optionally pre-filling a reply).
    public void Jump(Session s, string prompt = null) {
      var q = new List<KeyValuePair<string, string>> { Kv("session", s.Id) };
      if (!string.IsNullOrEmpty(prompt)) q.Add(Kv("prompt", prompt));
      if (!Reach(s, prompt, false)) OpenInEditor(s.Cwd, q, false, HostEditor(s));
      if (prompt != null) Drafts.Remove(s.Id);
      Toasts.RemoveAll(t => t.Session == s.Id);
      Close();
    }

    /// Starts a fresh session in the same workspace, seeded with a handoff note built from the old transcript
    /// (no tokens spent summarising). The old session stays open.
    public void StartHandoff(Session s) {
      string note = null;
      KeyValuePair<string, DateTime> p;
      if (prepared.TryGetValue(s.Id, out p) && (DateTime.UtcNow - p.Value).TotalSeconds < 900) {
        try { note = File.ReadAllText(p.Key, Paths.Utf8); } catch { }
      }
      if (note == null) {
        note = HandoffNote(s);
        WriteHandoff(s);  // keep a copy on disk
      }
      string prompt = "I'm continuing a previous Claude session (\"" + s.Name + "\") that got too expensive to keep going. " +
                      "Pick up where it stopped using the handoff below. Open only the files you actually need; don't re-explore the codebase.\n\n" + note;
      bool manual = Reach(s, prompt, true);
      if (!manual) OpenInEditor(s.Cwd, new List<KeyValuePair<string, string>> { Kv("prompt", prompt) }, Prefs.Bool("autoSend"), HostEditor(s));
      pendingHandoff = new Handoff { Old = s.Id, Cwd = s.Cwd, At = DateTime.UtcNow };
      if (!manual && Prefs.Bool("autoEndOld") && s.Pid > 1) {  // pasted by hand: the user ends the old one
        int pid = s.Pid;
        After(15, () => Native.Kill(pid));  // after the new one has its prompt
      }
      Retired[s.Id] = "";
      SaveRetired();
      Toasts.RemoveAll(t => t.Session == s.Id);
      Close();
    }

    string WriteHandoff(Session s) {
      string dir = Path.Combine(Paths.Hud, "handoff");
      Directory.CreateDirectory(dir);
      string safe = new string(s.Name.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '-' : c).ToArray());
      string file = Path.Combine(dir, safe + "-" + DateTime.Now.ToString("yyyy-MM-ddTHHmm", CultureInfo.InvariantCulture) + ".md");
      File.WriteAllText(file, HandoffNote(s), Paths.Utf8);
      return file;
    }

    /// Auto-handoff: write the note in the background as soon as a session turns heavy, so Fresh session is instant.
    void PrepareHandoff(Session s) {
      ThreadPool.QueueUserWorkItem(_ => {
        try {
          string f = WriteHandoff(s);
          ui.BeginInvoke(new Action(() => prepared[s.Id] = new KeyValuePair<string, DateTime>(f, DateTime.UtcNow)));
        } catch { }
      });
    }

    /// Brings up the editor window for `cwd`, waits until it's really in front (so the tab lands in the right
    /// workspace), then opens the Claude tab. With `send`, presses Enter in the new chat box.
    void OpenInEditor(string cwd, List<KeyValuePair<string, string>> query, bool send, Editor ed) {
      string url = ed.Scheme + "://anthropic.claude-code/open" +
                   (query.Count > 0 ? "?" + string.Join("&", query.Select(kv => kv.Key + "=" + Uri.EscapeDataString(kv.Value))) : "");
      if (Trace("open " + url + (send ? " +send" : ""))) return;
      string exe = ed.ExePath();
      if (exe != null && Directory.Exists(cwd)) {
        try { Process.Start(new ProcessStartInfo(exe, "\"" + cwd.TrimEnd('\\', '/') + "\"") { UseShellExecute = false }); } catch { }
      }
      string name = Paths.FolderName(cwd);
      Func<bool> ready = () => {
        IntPtr h = Native.GetForegroundWindow();
        string path = Native.ExePath(Native.WindowPid(h)) ?? "";
        return string.Equals(Path.GetFileNameWithoutExtension(path), ed.Exe, StringComparison.OrdinalIgnoreCase) &&
               Native.WindowTitle(h).IndexOf(name, StringComparison.OrdinalIgnoreCase) >= 0;
      };
      int tries = 0;
      var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
      timer.Tick += (o, e) => {
        tries++;
        if (!ready() && tries <= 30) return;
        timer.Stop();
        try { Process.Start(url); } catch { }
        // Focus moved elsewhere: leave the prompt waiting rather than type into the wrong place.
        if (send) After(1.6, () => { if (ready()) Native.PressEnter(); });
      };
      timer.Start();
    }

    public void UndoHandoff(Session s) { Retired.Remove(s.Id); SaveRetired(); Notify(); }

    /// New session in a workspace (focuses its editor window), pre-filled with the default first prompt.
    public void Launch(string cwd) {
      string first = Prefs.Str("firstPrompt");
      var q = new List<KeyValuePair<string, string>>();
      if (first.Length > 0) q.Add(Kv("prompt", first));
      OpenInEditor(cwd, q, false, Editor.Current);
      Close();
    }

    /// One nudge per wait when a session has been waiting on you longer than the idle setting.
    void RemindIdle() {
      double mins = Prefs.Num("idleMinutes");
      if (mins <= 0) return;
      foreach (var s in Sessions.Values.ToList()) {
        if ((s.Phase != Phase.Done && s.Phase != Phase.Permission) || Retired.ContainsKey(s.Id)) continue;
        double waited = (DateTime.UtcNow - s.Since).TotalSeconds;
        DateTime r;
        if (waited <= mins * 60 || (reminded.TryGetValue(s.Id, out r) && r == s.Since)) continue;
        reminded[s.Id] = s.Since;
        Alert(s, "Waiting on you for " + Fmt.Span(waited), "Tink", s.Phase == Phase.Done ? "notifyDone" : "notifyPermission");
      }
    }

    /// iCloud Drive (shared with Claude HUD on your Macs) when installed, else OneDrive.
    public static string DeviceDir {
      get {
        if (Paths.Testing) return Path.Combine(Paths.Home, "cloud", "Claude HUD", "devices");
        string ic = Path.Combine(Paths.Home, "iCloudDrive");
        if (Directory.Exists(ic)) return Path.Combine(ic, "Claude HUD", "devices");
        string od = Environment.GetEnvironmentVariable("OneDrive");
        if (!string.IsNullOrEmpty(od) && Directory.Exists(od)) return Path.Combine(od, "Claude HUD", "devices");
        return null;
      }
    }

    /// Devices: every computer running Claude HUD drops today's totals in the cloud folder and reads the others'.
    void SyncDevices() {
      string dir = DeviceDir;
      if (!Prefs.Bool("syncDevices") || dir == null) { Devices = new List<Device>(); return; }
      if ((DateTime.UtcNow - lastDeviceSync).TotalSeconds <= 60) return;
      lastDeviceSync = DateTime.UtcNow;
      string myId = Prefs.Str("deviceID");
      if (myId.Length == 0) { myId = Guid.NewGuid().ToString().ToUpperInvariant(); Prefs.Set("deviceID", myId); }
      double day = Paths.Epoch(DateTime.Today.ToUniversalTime());
      var mine = new Dictionary<string, object>();
      mine["name"] = Environment.MachineName;
      mine["updated"] = Paths.Epoch(DateTime.UtcNow);
      mine["day"] = day;
      mine["tokens"] = TodayTokens;
      mine["cost"] = TodayCost;
      mine["live"] = (long)Sorted.Count(s => s.Phase != Phase.Ended && !Retired.ContainsKey(s.Id));
      string me = myId;
      ThreadPool.QueueUserWorkItem(_ => {
        var list = new List<Device>();
        try {
          Directory.CreateDirectory(dir);
          Paths.WriteAtomic(Path.Combine(dir, me + ".json"), Json.Write(mine, false));
          foreach (var f in Directory.GetFiles(dir, "*.json")) {
            object j;
            try { j = Json.TryParse(Paths.ReadShared(f)); } catch { continue; }
            if (j == null) continue;
            string id = Path.GetFileNameWithoutExtension(f);
            bool today = Math.Abs((Json.Num(j, "day") ?? 0) - day) < 1;
            list.Add(new Device {
              Id = id, Name = Json.Str(j, "name") ?? "Computer", Updated = Paths.FromEpoch(Json.Num(j, "updated") ?? 0),
              Tokens = today ? Json.Long(j, "tokens") : 0, Cost = today ? (Json.Num(j, "cost") ?? 0) : 0,
              Live = Json.Long(j, "live"), Mine = id == me,
            });
          }
        } catch { }
        list = list.OrderBy(d => d.Mine ? 0 : 1).ThenByDescending(d => d.Cost).ToList();
        ui.BeginInvoke(new Action(() => { Devices = list; Notify(); }));
      });
    }

    string HandoffNote(Session s) {
      var prompts = new List<string>();
      var files = new List<string>();
      string last = "", branch = "", text = "";
      try { if (s.Transcript.Length > 0) text = Paths.ReadShared(s.Transcript); } catch { }
      foreach (var line in text.Split('\n')) {
        var j = Json.TryParse(line);
        var m = Json.Get(j, "message");
        if (m == null) continue;
        string b = Json.Str(j, "gitBranch");
        if (!string.IsNullOrEmpty(b)) branch = b;
        var parts = Json.Arr(m, "content") ?? new List<object>();
        string type = Json.Str(j, "type");
        if (type == "user" && !Json.Bool(j, "isMeta")) {
          string t = Json.Str(m, "content") ?? Json.Str(parts.FirstOrDefault(p => Json.Str(p, "type") == "text"), "text") ?? "";
          t = t.Trim();
          if (t.Length > 0 && !t.StartsWith("<")) prompts.Add(t);
        } else if (type == "assistant") {
          foreach (var p in parts) {
            if (Json.Str(p, "type") == "text" && Json.Str(p, "text") != null) last = Json.Str(p, "text");
            string f = Json.Str(Json.Get(p, "input"), "file_path");
            if (Json.Str(p, "type") == "tool_use" && new[] { "Edit", "Write", "MultiEdit", "NotebookEdit" }.Contains(Json.Str(p, "name")) &&
                f != null && !files.Contains(f)) files.Add(f);
          }
        }
      }
      var sb = new StringBuilder();
      sb.Append("# Handoff from \"").Append(s.Name).Append("\"\n\n");
      sb.Append("- Workspace: ").Append(s.Cwd).Append('\n');
      sb.Append("- Branch: ").Append(branch.Length == 0 ? "unknown" : branch).Append('\n');
      sb.Append("- Previous session: ").Append(s.Id).Append(" (\"").Append(s.Name).Append("\")\n\n");
      sb.Append("## Original request\n").Append(Fmt.Cut(prompts.FirstOrDefault() ?? "(none found)", 1000)).Append("\n\n");
      sb.Append("## Recent requests (oldest first)\n")
        .Append(string.Join("\n", prompts.Skip(Math.Max(0, prompts.Count - 6)).Select(p => "- " + Fmt.Cut(p.Replace("\n", " "), 300)))).Append("\n\n");
      sb.Append("## Files touched\n")
        .Append(files.Count == 0 ? "(none)" : string.Join("\n", files.Skip(Math.Max(0, files.Count - 30)).Select(f => "- " + f))).Append("\n\n");
      sb.Append("## Where it stopped (last reply)\n").Append(Fmt.Cut(last, 2500));
      return sb.ToString();
    }

    public void End(Session s) {
      Native.Kill(s.Pid);
      s.Phase = Phase.Ended;
      s.Since = DateTime.UtcNow;
      Notify();
    }

    public void StartReply(Session s) {
      ReplyTarget = ReplyTarget == s.Id ? null : s.Id;
      Notify();
    }

    /// Keyboard control while the drawer is open. Returns true when the key was handled.
    public bool Key(Key k) {
      if (!DrawerOpen || ReplyTarget != null || Searching) return false;
      var list = Visible;
      Session s = Selected >= 0 && Selected < list.Count ? list[Selected] : null;
      switch (k) {
        case System.Windows.Input.Key.Escape: Close(); return true;
        case System.Windows.Input.Key.OemQuestion:
        case System.Windows.Input.Key.Divide:
          if (FocusSearchRequested != null) FocusSearchRequested();
          return true;
        case System.Windows.Input.Key.Down: Selected = Math.Min(Selected + 1, Math.Max(0, list.Count - 1)); Notify(); return true;
        case System.Windows.Input.Key.Up: Selected = Math.Max(Selected - 1, 0); Notify(); return true;
        case System.Windows.Input.Key.Enter: if (s != null) Jump(s); return true;
        case System.Windows.Input.Key.A: if (s != null) Respond(s, Answer.Allow); return true;
        case System.Windows.Input.Key.W: if (s != null && s.Request != null && s.Request.Always != null) Respond(s, Answer.Always); return true;
        case System.Windows.Input.Key.D: if (s != null) Respond(s, Answer.Deny); return true;
        case System.Windows.Input.Key.R: if (s != null && s.Phase != Phase.Ended) { ReplyTarget = s.Id; Notify(); } return true;
      }
      return false;
    }
  }
}
