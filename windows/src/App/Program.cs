// Claude HUD for Windows: an edge drawer + toasts for Claude Code sessions running in any IDE or terminal.
// Fed by hooks (hud-hook.exe): events.jsonl = session state, req/ + ans/ = permission requests answered
// from here, limits.json = 5-hour / weekly usage.
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using Forms = System.Windows.Forms;

namespace ClaudeHud {
  static class Program {
    static Mutex mutex;
    static Tray tray;
    static HudWindow hud;
    static Store store;

    [STAThread]
    static void Main(string[] args) {
      bool created;
      mutex = new Mutex(true, Paths.Testing ? "Local\\ClaudeHUD-test" : "Local\\ClaudeHUD", out created);
      if (!created) return;  // already running
      var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
      app.DispatcherUnhandledException += (o, e) => { Log(e.Exception); e.Handled = true; };
      AppDomain.CurrentDomain.UnhandledException += (o, e) => Log(e.ExceptionObject as Exception);
      store = new Store();
      hud = new HudWindow(store);
      hud.Show();
      tray = new Tray(store, hud);
      store.SettingsRequested += () => SettingsWindow.Open(store);
      ApplyPrefs();
      Prefs.Changed += ApplyPrefs;
      if (!Prefs.Bool("welcomed")) {
        Prefs.Set("welcomed", true);
        store.Say("Claude HUD is running",
          "Hover the right edge of your screen, or press " + Prefs.Hotkeys[0] + ", to see your Claude sessions. Questions and permission prompts pop up here.");
      }
      ThreadPool.QueueUserWorkItem(_ => EnsureHooks());
      app.Run();
      GC.KeepAlive(mutex);
    }

    public static void Quit() {
      if (tray != null) tray.Dispose();
      Application.Current.Shutdown();
    }

    static void Log(Exception e) {
      if (e == null) return;
      try {
        string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ClaudeHUD");
        Directory.CreateDirectory(dir);
        File.AppendAllText(Path.Combine(dir, "error.log"), DateTime.Now.ToString("s") + " " + e + "\n\n");
      } catch { }
    }

    /// Self-repair: the hooks must be wired into ~/.claude/settings.json and ~/.claude/hud/hud-hook.exe must be
    /// the one shipped next to this app. Fixes either silently; tells you once when it connected.
    static void EnsureHooks() {
      try {
        string src = Path.Combine(Path.GetDirectoryName(System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName), "hud-hook.exe");
        if (!File.Exists(src)) return;
        string dst = Path.Combine(Paths.Hud, "hud-hook.exe");
        string settings = Path.Combine(Paths.Claude, "settings.json");
        bool wired = File.Exists(settings) &&
                     Paths.ReadShared(settings).Replace("\\\\", "/").Replace('\\', '/').IndexOf("claude/hud/hud-hook.exe", StringComparison.OrdinalIgnoreCase) >= 0;
        bool same = File.Exists(dst) && Same(src, dst);
        if (wired && same) return;
        var p = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(src, "install") {
          UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
        });
        string output = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
        p.WaitForExit(15000);
        int code = p.HasExited ? p.ExitCode : -1;
        Application.Current.Dispatcher.BeginInvoke(new Action(() => {
          if (code != 0) store.Say("Couldn't connect to Claude Code", output.Trim().Length > 0 ? output.Trim() : "hud-hook.exe install failed.");
          else if (!wired) store.Say("Connected to Claude Code", "New Claude sessions report here. Restart sessions that were already open so they pick it up.");
        }));
      } catch (Exception e) { Log(e); }
    }

    static bool Same(string a, string b) {
      var x = new FileInfo(a);
      var y = new FileInfo(b);
      if (x.Length != y.Length) return false;
      byte[] p = File.ReadAllBytes(a), q = File.ReadAllBytes(b);
      for (int i = 0; i < p.Length; i++) if (p[i] != q[i]) return false;
      return true;
    }

    static int appliedHotkey = -2;
    static string appliedLogin;

    /// Applies settings that live outside the UI. Only acts on values that changed.
    static void ApplyPrefs() {
      int hk = (int)Prefs.Num("hotkey");
      if (hk != appliedHotkey) {
        appliedHotkey = hk;
        if (!hud.SetHotkey(hk) && hk < Prefs.Hotkeys.Length) {
          store.Notice("Shortcut unavailable", Prefs.Hotkeys[hk] + " is taken by another app. Pick another one in Settings.");
        }
      }
      tray.Visible = Prefs.Bool("menuBar");
      string off = Path.Combine(Paths.Hud, "answer-off");  // the perm hook steps aside when this exists
      try {
        if (Prefs.Bool("answerInHUD")) File.Delete(off);
        else File.WriteAllText(off, "");
      } catch { }
      string exe = System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName;
      string login = Prefs.Bool("loginItem") ? exe : "";
      if (login != appliedLogin && !Paths.Testing) {
        appliedLogin = login;
        try {
          using (var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) {
            if (login.Length > 0) k.SetValue("ClaudeHUD", "\"" + exe + "\"");
            else k.DeleteValue("ClaudeHUD", false);
          }
        } catch { }
      }
    }
  }

  /// The menu-bar item, as a tray icon: the 5-hour usage drawn into the icon itself.
  class Tray : IDisposable {
    readonly Forms.NotifyIcon icon = new Forms.NotifyIcon();
    readonly Store store;
    IntPtr handle;

    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);

    public Tray(Store s, HudWindow hud) {
      store = s;
      icon.MouseUp += (o, e) => { if (e.Button == Forms.MouseButtons.Left) hud.Toggle(); };
      var menu = new Forms.ContextMenuStrip();
      var dnd = new Forms.ToolStripMenuItem("Do Not Disturb");
      dnd.Click += (o, e) => store.Dnd = !store.Dnd;
      var settings = new Forms.ToolStripMenuItem("Settings…");
      settings.Click += (o, e) => store.OpenSettings();
      var quit = new Forms.ToolStripMenuItem("Quit Claude HUD");
      quit.Click += (o, e) => Program.Quit();
      menu.Items.Add(settings);
      menu.Items.Add(dnd);
      menu.Items.Add(new Forms.ToolStripSeparator());
      menu.Items.Add(quit);
      menu.Opening += (o, e) => dnd.Checked = store.Dnd;
      icon.ContextMenuStrip = menu;
      store.LimitsChanged += Update;
      store.IssueChanged += Update;
      Update();
    }

    public bool Visible { set { icon.Visible = value; } }

    void Update() {
      string f = store.FiveHour == null ? "–" : (int)Math.Round(store.FiveHour.Pct) + "%";
      string w = store.Week == null ? "–" : (int)Math.Round(store.Week.Pct) + "%";
      var issue = store.Issue;
      string tip = issue != null ? "Claude: " + issue.Title + " — 5h " + f + " · wk " + w : "Claude usage — 5-hour " + f + " · weekly " + w;
      icon.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;
      var old = handle;
      using (var bmp = Draw(store.FiveHour == null ? (int?)null : (int)Math.Round(store.FiveHour.Pct), issue != null)) {
        handle = bmp.GetHicon();
        icon.Icon = Icon.FromHandle(handle);
      }
      if (old != IntPtr.Zero) DestroyIcon(old);
    }

    static Bitmap Draw(int? pct, bool alarm) {
      int s = Math.Max(16, Forms.SystemInformation.SmallIconSize.Width);
      var bmp = new Bitmap(s, s);
      using (var g = Graphics.FromImage(bmp)) {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        if (alarm) {  // Anthropic is refusing requests (payment, access, sign-in): a red "!"
          using (var bg = new SolidBrush(Color.FromArgb(255, 102, 128))) g.FillEllipse(bg, 0, 0, s - 1, s - 1);
          using (var font = new Font("Segoe UI", s * 0.62f, System.Drawing.FontStyle.Bold, GraphicsUnit.Pixel))
          using (var b = new SolidBrush(Color.White)) {
            var sz = g.MeasureString("!", font);
            g.DrawString("!", font, b, (s - sz.Width) / 2 + 0.5f, (s - sz.Height) / 2);
          }
          return bmp;
        }
        var c = pct > 85 ? Color.FromArgb(255, 102, 128) : pct > 60 ? Color.FromArgb(255, 171, 82) : Color.FromArgb(115, 200, 255);
        using (var bg = new SolidBrush(Color.FromArgb(235, 18, 20, 26))) g.FillEllipse(bg, 0, 0, s - 1, s - 1);
        if (!pct.HasValue) {
          float w = s * 0.18f, h = s * 0.6f;
          using (var b = new SolidBrush(Color.FromArgb(102, 242, 242))) g.FillRectangle(b, (s - w) / 2, (s - h) / 2, w, h);
        } else {
          // Ring = 5-hour usage; number in the middle.
          using (var track = new Pen(Color.FromArgb(60, 255, 255, 255), s * 0.1f)) g.DrawArc(track, s * 0.08f, s * 0.08f, s * 0.84f, s * 0.84f, 0, 360);
          using (var p = new Pen(c, s * 0.1f)) g.DrawArc(p, s * 0.08f, s * 0.08f, s * 0.84f, s * 0.84f, -90, 360f * Math.Min(100, pct.Value) / 100);
          string t = Math.Min(99, pct.Value).ToString();
          using (var font = new Font("Segoe UI", s * (t.Length > 1 ? 0.36f : 0.44f), System.Drawing.FontStyle.Bold, GraphicsUnit.Pixel))
          using (var b = new SolidBrush(Color.White)) {
            var sz = g.MeasureString(t, font);
            g.DrawString(t, font, b, (s - sz.Width) / 2 + 0.5f, (s - sz.Height) / 2 + 0.5f);
          }
        }
      }
      return bmp;
    }

    public void Dispose() {
      icon.Visible = false;
      icon.Dispose();
      if (handle != IntPtr.Zero) DestroyIcon(handle);
    }
  }
}
