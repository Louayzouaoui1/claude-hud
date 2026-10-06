using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace ClaudeHud {
  /// Token counting: background, incremental over today's transcripts. Keys are Paths.Norm(transcript path).
  public class TokenCounter {
    class Msg { public long N; public bool Today; public double Cost; }

    DateTime day = DateTime.MinValue;
    readonly Dictionary<string, long> offsets = new Dictionary<string, long>();
    readonly Dictionary<string, Dictionary<string, Msg>> msgs = new Dictionary<string, Dictionary<string, Msg>>();
    readonly Dictionary<string, Usage> usage = new Dictionary<string, Usage>();
    static readonly byte[] marker = Encoding.UTF8.GetBytes("\"assistant\"");
    static readonly byte[] commandMarker = Encoding.UTF8.GetBytes("\"local_command\"");

    /// A snapshot (copies), safe to hand to the UI thread.
    public Dictionary<string, Usage> Scan() {
      DateTime today = DateTime.Today;
      if (today != day) { day = today; offsets.Clear(); msgs.Clear(); usage.Clear(); }
      if (Directory.Exists(Paths.Projects)) {
        IEnumerable<string> files;
        try { files = Directory.EnumerateFiles(Paths.Projects, "*.jsonl", SearchOption.AllDirectories).ToList(); } catch { files = new string[0]; }
        foreach (var f in files) {
          try { if (File.GetLastWriteTime(f) >= today) Read(f); } catch { }
        }
      }
      return usage.ToDictionary(kv => kv.Key, kv => kv.Value.Clone());
    }

    void Read(string path) {
      string key = Paths.Norm(path);
      long off;
      offsets.TryGetValue(key, out off);
      byte[] data;
      using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
        long size = f.Length;
        if (size < off) { off = 0; msgs.Remove(key); usage.Remove(key); }
        if (size <= off) return;
        f.Seek(off, SeekOrigin.Begin);
        data = new byte[size - off];
        int got = 0;
        while (got < data.Length) {
          int n = f.Read(data, got, data.Length - got);
          if (n <= 0) break;
          got += n;
        }
        if (got < data.Length) Array.Resize(ref data, got);
      }
      int nl = Array.LastIndexOf(data, (byte)10);
      if (nl < 0) return;  // a half-written line waits for next time
      offsets[key] = off + nl + 1;

      Usage u;
      if (!usage.TryGetValue(key, out u)) u = new Usage();
      Dictionary<string, Msg> m;
      if (!msgs.TryGetValue(key, out m)) m = new Dictionary<string, Msg>();

      int start = 0;
      while (start <= nl) {
        int end = Array.IndexOf(data, (byte)10, start, nl - start + 1);
        if (end < 0) end = nl;
        if (end > start && (Contains(data, start, end - start, marker) || Contains(data, start, end - start, commandMarker)))
          Line(Encoding.UTF8.GetString(data, start, end - start), u, m);
        start = end + 1;
      }
      u.Tokens = m.Values.Sum(x => x.N);
      u.Today = m.Values.Sum(x => x.Today ? x.N : 0);
      u.Cost = m.Values.Sum(x => x.Cost);
      u.TodayCost = m.Values.Sum(x => x.Today ? x.Cost : 0);
      msgs[key] = m;
      usage[key] = u;
    }

    static DateTime When(object j) {
      string ts = Json.Str(j, "timestamp");
      DateTime when;
      return ts != null && DateTime.TryParse(ts, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out when)
        ? when : DateTime.UtcNow;
    }

    void Line(string line, Usage u, Dictionary<string, Msg> m) {
      var j = Json.TryParse(line);
      string type = Json.Str(j, "type");
      // A slash command that failed because of the account (e.g. /compact refused: access disabled, payment due).
      if (type == "system" && Json.Str(j, "subtype") == "local_command" && Json.Str(Json.Get(j, "commandOutcome"), "kind") == "failed") {
        string text = System.Text.RegularExpressions.Regex.Replace(Json.Str(j, "content") ?? "", "<[^>]+>", "").Trim();
        var e = ApiError.From(0, "", text, When(j));
        if (e.Kind != "other") u.Error = e;
        return;
      }
      if (type != "assistant") return;
      var msg = Json.Get(j, "message");
      if (msg == null) return;
      // Anthropic answered with an error instead of a reply: Claude Code logs it as a synthetic message.
      if (Json.Bool(j, "isApiErrorMessage")) {
        var parts0 = Json.Arr(msg, "content");
        string text = Json.Str(parts0 == null ? null : parts0.LastOrDefault(p => Json.Str(p, "type") == "text"), "text") ?? Json.Str(j, "error") ?? "";
        u.Error = ApiError.From(Json.Long(j, "apiErrorStatus"), Json.Str(j, "apiErrorCode") ?? Json.Str(j, "error"), text, When(j));
        return;
      }
      // A real reply: whatever was wrong is fixed (payment went through, access restored, limit reset).
      if ((Json.Str(msg, "model") ?? "") != "<synthetic>" && Json.Get(msg, "usage") != null) u.Error = null;
      var parts = Json.Arr(msg, "content");
      if (parts != null) {
        var text = parts.LastOrDefault(p => Json.Str(p, "type") == "text");
        string t = Json.Str(text, "text");
        if (t != null) u.LastText = t.Trim();
      }
      var us = Json.Get(msg, "usage");
      string id = Json.Str(msg, "id");
      if (us == null || id == null) return;
      Func<string, long> n = k => Json.Long(us, k);
      long cw = n("cache_creation_input_tokens");
      u.Context = n("input_tokens") + cw + n("cache_read_input_tokens");
      bool isToday = true;
      string ts = Json.Str(j, "timestamp");
      DateTime when;
      if (ts != null && DateTime.TryParse(ts, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out when))
        isToday = when.ToLocalTime() >= day;
      long cw1h = Math.Min(cw, Json.Long(Json.Get(us, "cache_creation"), "ephemeral_1h_input_tokens"));
      string model = Json.Str(msg, "model") ?? "";
      double[] pr = Pricing.Of(model);
      double cost = (n("input_tokens") * pr[0] + n("output_tokens") * pr[1] + (cw - cw1h) * pr[0] * 1.25
                     + cw1h * pr[0] * 2 + n("cache_read_input_tokens") * pr[2]) / 1e6;
      // Most of the context written again = the cache had expired, so the whole history was paid at full price.
      if (!m.ContainsKey(id) && isToday && cw >= 50000 && cw * 2 > u.Context) u.Recache += cw;
      if (model.Length > 0 && !model.StartsWith("<")) u.Model = model;
      m[id] = new Msg { N = n("input_tokens") + cw + n("output_tokens"), Today = isToday, Cost = cost };
    }

    static bool Contains(byte[] d, int start, int len, byte[] pat) {
      int last = start + len - pat.Length;
      for (int i = start; i <= last; i++) {
        int k = 0;
        while (k < pat.Length && d[i + k] == pat[k]) k++;
        if (k == pat.Length) return true;
      }
      return false;
    }
  }
}
