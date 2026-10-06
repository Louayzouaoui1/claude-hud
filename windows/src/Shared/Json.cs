using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace ClaudeHud {
  /// Minimal JSON: objects → Dictionary<string, object> (key order kept), arrays → List<object>,
  /// numbers → long or double, plus string / bool / null. No dependencies.
  public static class Json {
    public static object Parse(string s) {
      if (s.Length > 0 && s[0] == '﻿') s = s.Substring(1);
      int i = 0;
      Ws(s, ref i);
      object v = Value(s, ref i);
      Ws(s, ref i);
      if (i != s.Length) throw new FormatException("trailing data at " + i);
      return v;
    }

    public static object TryParse(string s) {
      if (string.IsNullOrEmpty(s)) return null;
      try { return Parse(s); } catch { return null; }
    }

    static void Ws(string s, ref int i) { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }

    static void Expect(string s, ref int i, char c) {
      if (i >= s.Length || s[i] != c) throw new FormatException("expected '" + c + "' at " + i);
      i++;
    }

    static bool Lit(string s, ref int i, string word) {
      if (string.CompareOrdinal(s, i, word, 0, word.Length) != 0) return false;
      i += word.Length;
      return true;
    }

    static object Value(string s, ref int i) {
      if (i >= s.Length) throw new FormatException("unexpected end");
      char c = s[i];
      if (c == '{') {
        i++;
        var d = new Dictionary<string, object>();
        Ws(s, ref i);
        if (i < s.Length && s[i] == '}') { i++; return d; }
        while (true) {
          Ws(s, ref i);
          string k = ReadString(s, ref i);
          Ws(s, ref i);
          Expect(s, ref i, ':');
          Ws(s, ref i);
          d[k] = Value(s, ref i);
          Ws(s, ref i);
          if (i < s.Length && s[i] == ',') { i++; continue; }
          Expect(s, ref i, '}');
          return d;
        }
      }
      if (c == '[') {
        i++;
        var l = new List<object>();
        Ws(s, ref i);
        if (i < s.Length && s[i] == ']') { i++; return l; }
        while (true) {
          Ws(s, ref i);
          l.Add(Value(s, ref i));
          Ws(s, ref i);
          if (i < s.Length && s[i] == ',') { i++; continue; }
          Expect(s, ref i, ']');
          return l;
        }
      }
      if (c == '"') return ReadString(s, ref i);
      if (Lit(s, ref i, "true")) return true;
      if (Lit(s, ref i, "false")) return false;
      if (Lit(s, ref i, "null")) return null;
      int st = i;
      while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
      if (i == st) throw new FormatException("bad value at " + i);
      string num = s.Substring(st, i - st);
      long n;
      if (num.IndexOfAny(new[] { '.', 'e', 'E' }) < 0 &&
          long.TryParse(num, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out n)) return n;
      return double.Parse(num, NumberStyles.Float, CultureInfo.InvariantCulture);
    }

    static string ReadString(string s, ref int i) {
      Expect(s, ref i, '"');
      var b = new StringBuilder();
      while (true) {
        if (i >= s.Length) throw new FormatException("unterminated string");
        char c = s[i++];
        if (c == '"') return b.ToString();
        if (c != '\\') { b.Append(c); continue; }
        char e = s[i++];
        switch (e) {
          case 'n': b.Append('\n'); break;
          case 'r': b.Append('\r'); break;
          case 't': b.Append('\t'); break;
          case 'b': b.Append('\b'); break;
          case 'f': b.Append('\f'); break;
          case 'u': b.Append((char)int.Parse(s.Substring(i, 4), NumberStyles.HexNumber)); i += 4; break;
          default: b.Append(e); break;
        }
      }
    }

    // MARK: writing

    public static string Write(object v, bool pretty) {
      var b = new StringBuilder();
      Emit(b, v, pretty, 0);
      return b.ToString();
    }

    static void Indent(StringBuilder b, bool pretty, int depth) {
      if (!pretty) return;
      b.Append('\n');
      b.Append(' ', depth * 2);
    }

    static void Emit(StringBuilder b, object v, bool pretty, int depth) {
      if (v == null) { b.Append("null"); return; }
      if (v is string) { Quote(b, (string)v); return; }
      if (v is bool) { b.Append((bool)v ? "true" : "false"); return; }
      if (v is int || v is long || v is short || v is uint || v is ulong) {
        b.Append(Convert.ToString(v, CultureInfo.InvariantCulture));
        return;
      }
      if (v is double || v is float || v is decimal) {
        double d = Convert.ToDouble(v, CultureInfo.InvariantCulture);
        if (double.IsNaN(d) || double.IsInfinity(d)) { b.Append("null"); return; }
        b.Append(d.ToString("R", CultureInfo.InvariantCulture));
        return;
      }
      var dict = v as IDictionary;
      if (dict != null) {
        if (dict.Count == 0) { b.Append("{}"); return; }
        b.Append('{');
        bool first = true;
        foreach (DictionaryEntry kv in dict) {
          if (!first) b.Append(',');
          first = false;
          Indent(b, pretty, depth + 1);
          Quote(b, Convert.ToString(kv.Key, CultureInfo.InvariantCulture));
          b.Append(pretty ? ": " : ":");
          Emit(b, kv.Value, pretty, depth + 1);
        }
        Indent(b, pretty, depth);
        b.Append('}');
        return;
      }
      var list = v as IEnumerable;
      if (list != null) {
        bool first = true, any = false;
        b.Append('[');
        foreach (object x in list) {
          if (!first) b.Append(',');
          first = false;
          any = true;
          Indent(b, pretty, depth + 1);
          Emit(b, x, pretty, depth + 1);
        }
        if (any) Indent(b, pretty, depth);
        b.Append(']');
        return;
      }
      Quote(b, Convert.ToString(v, CultureInfo.InvariantCulture));
    }

    static void Quote(StringBuilder b, string s) {
      b.Append('"');
      foreach (char c in s) {
        switch (c) {
          case '"': b.Append("\\\""); break;
          case '\\': b.Append("\\\\"); break;
          case '\n': b.Append("\\n"); break;
          case '\r': b.Append("\\r"); break;
          case '\t': b.Append("\\t"); break;
          default:
            if (c < 0x20) b.Append("\\u").Append(((int)c).ToString("x4"));
            else b.Append(c);
            break;
        }
      }
      b.Append('"');
    }

    // MARK: reading helpers

    public static object Get(object o, string k) {
      var d = o as Dictionary<string, object>;
      object v;
      return d != null && d.TryGetValue(k, out v) ? v : null;
    }

    public static string Str(object o, string k) { return Get(o, k) as string; }

    public static double? Num(object o, string k) {
      object v = Get(o, k);
      if (v is long) return (long)v;
      if (v is double) return (double)v;
      return null;
    }

    public static long Long(object o, string k) {
      double? n = Num(o, k);
      return n.HasValue ? (long)n.Value : 0;
    }

    public static bool Bool(object o, string k) { object v = Get(o, k); return v is bool && (bool)v; }

    public static List<object> Arr(object o, string k) { return Get(o, k) as List<object>; }

    public static Dictionary<string, object> Obj(object o, string k) { return Get(o, k) as Dictionary<string, object>; }
  }
}
