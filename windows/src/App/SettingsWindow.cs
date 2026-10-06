using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;

namespace ClaudeHud {
  public class SettingsWindow : Window {
    static SettingsWindow current;
    readonly Store store;
    readonly StackPanel page = new StackPanel { Margin = new Thickness(22, 14, 22, 22) };
    static readonly Color Card = Color.FromRgb(0x1E, 0x21, 0x28), Ground = Color.FromRgb(0x13, 0x15, 0x1A);

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int value, int size);

    public static void Open(Store s) {
      if (current == null) {
        current = new SettingsWindow(s);
        current.Closed += (o, e) => current = null;
      }
      current.Show();
      if (current.WindowState == WindowState.Minimized) current.WindowState = WindowState.Normal;
      current.Activate();
    }

    SettingsWindow(Store s) {
      store = s;
      Title = "Claude HUD Settings";
      Width = 520;
      Height = 760;
      MinWidth = 420;
      WindowStartupLocation = WindowStartupLocation.CenterScreen;
      Background = Ui.B(Ground);
      Foreground = Brushes.White;
      FontFamily = Ui.Sans;
      FontSize = 13;
      try { Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri(Process.GetCurrentProcess().MainModule.FileName)); } catch { }
      SourceInitialized += (o, e) => {
        int on = 1;  // dark title bar
        DwmSetWindowAttribute(new WindowInteropHelper(this).Handle, 20, ref on, 4);
      };
      Content = new ScrollViewer { Content = page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
      Build();
    }

    void Build() {
      page.Children.Clear();
      var theme = Palette.CurrentTheme;

      Section("Appearance", null,
        Labeled("Theme", Swatches()),
        Slider("Glass", "glass", 0.5, 1, 0.05, v => v < 0.7 ? "Clear" : v > 0.9 ? "Dark" : "Medium"),
        Toggle("Glow on the screen edge", "edgeGlow"),
        Slider("Edge hover delay", "edgeDelay", 0, 0.6, 0.02, v => (int)(v * 1000) + " ms"));

      Section("Notifications", null,
        Toggle("Needs permission or input", "notifyPermission"),
        Toggle("Finished — your turn", "notifyDone"),
        Toggle("Session ended", "notifyEnded"),
        Toggle("Usage alerts at 80% and 95%", "notifyUsage"),
        Toggle("Sounds", "sounds"),
        Slider("Keep toasts for", "toastSeconds", 4, 30, 1, v => (int)v + "s"),
        Slider("Remind me when a session waits", "idleMinutes", 0, 60, 5, v => v == 0 ? "Off" : (int)v + " min"),
        Check("Do not disturb", store.Dnd, v => store.Dnd = v),
        Toggle("Quiet during Zoom meetings", "meetingQuiet"));

      string ed = Editor.Current.Name;
      Section("Permissions",
        Prefs.Bool("answerInHUD")
          ? "Prompts go to the HUD first; " + ed + " shows its dialog once you pick “" + ed + "”."
          : "Prompts appear in " + ed + " as usual; the HUD only notifies you.",
        Toggle("Answer permission prompts from the HUD", "answerInHUD"));

      Section("Optimization", "Heavy sessions turn red (also at 350k+ context or 3+ parallel agents) with Compact and Fresh session actions.",
        Slider("Flag a session as heavy at", "heavyBurn", 250000, 5000000, 250000, v => Fmt.N((long)v) + "/10m"),
        Toggle("Group sessions by workspace", "groupByWorkspace"),
        Toggle("Fresh session: send the handoff automatically", "autoSend"),
        Toggle("Fresh session: close the old session", "autoEndOld"));

      string dir = Store.DeviceDir;
      Section("Devices & limits",
        (dir == null
          ? "Install iCloud for Windows or OneDrive to share today's totals across your computers. "
          : "Each computer running Claude HUD writes today's tokens and cost to " + dir + " (iCloud Drive is shared with Claude HUD on your Macs). ") +
        "Live limits and remote sessions use your Claude Code login (~/.claude/.credentials.json) to call the same Anthropic endpoints Claude Code uses; the status line hook works without it.",
        Toggle("Share usage across my computers", "syncDevices"),
        Toggle("Fetch live limits and remote sessions", "fetchLimits"));

      var first = Ui.Field(Prefs.Str("firstPrompt"), "optional — pre-filled when you press +", 13);
      first.LostFocus += (o, e) => Prefs.Set("firstPrompt", first.Text);
      var firstBox = new Border { Child = Ui.WithHint(first), Background = Ui.B(Ground), CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 5, 8, 5),
                                  BorderBrush = Ui.B(Palette.W(0.1)), BorderThickness = new Thickness(1), Margin = new Thickness(0, 6, 0, 0) };
      var hotkey = new ComboBox { Width = 170, HorizontalAlignment = HorizontalAlignment.Right };
      foreach (var h in Prefs.Hotkeys) hotkey.Items.Add(h);
      hotkey.Items.Add("Off");
      hotkey.SelectedIndex = Math.Min(Prefs.Hotkeys.Length, (int)Prefs.Num("hotkey"));
      hotkey.SelectionChanged += (o, e) => Prefs.Set("hotkey", (long)hotkey.SelectedIndex);
      Section("General", null,
        Ui.Col(0, Text("First prompt for new sessions", 13, 0.9), firstBox),
        Labeled("Open drawer shortcut", hotkey),
        Toggle("Show usage in the notification area", "menuBar"),
        Toggle("Launch at sign-in", "loginItem"));

      var reinstall = Button("Reinstall hooks", false, Reinstall);
      var quit = Button("Quit Claude HUD", true, Program.Quit);
      var row = new DockPanel { Margin = new Thickness(0, 6, 0, 0) };
      DockPanel.SetDock(quit, Dock.Right);
      row.Children.Add(quit);
      row.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Children = { reinstall } });
      page.Children.Add(row);
      var foot = Text("Right-click the tray icon for quick actions. Hooks live in " + Paths.Hud + ".", 11.5, 0.45);
      foot.Margin = new Thickness(2, 12, 0, 0);
      page.Children.Add(foot);
    }

    void Reinstall() {
      string exe = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(Process.GetCurrentProcess().MainModule.FileName), "hud-hook.exe");
      if (!File.Exists(exe)) exe = System.IO.Path.Combine(Paths.Hud, "hud-hook.exe");
      try {
        var p = Process.Start(new ProcessStartInfo(exe, "install") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true });
        string output = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
        p.WaitForExit();
        store.Notice("Claude HUD", output.Trim().Length > 0 ? output.Trim() : "Hooks installed.");
      } catch (Exception e) {
        store.Notice("Couldn't install hooks", e.Message);
      }
    }

    static TextBlock Text(string s, double size, double alpha) {
      return new TextBlock { Text = s, FontSize = size, Foreground = Ui.B(Palette.W(alpha)), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    }

    void Section(string title, string footer, params FrameworkElement[] rows) {
      var head = Text(title.ToUpperInvariant(), 11, 0.5);
      head.FontWeight = FontWeights.SemiBold;
      head.Margin = new Thickness(4, 16, 0, 6);
      page.Children.Add(head);
      var col = new StackPanel();
      for (int i = 0; i < rows.Length; i++) {
        if (i > 0) col.Children.Add(new Rectangle { Height = 1, Fill = Ui.B(Palette.W(0.06)), Margin = new Thickness(0, 9, 0, 9) });
        col.Children.Add(rows[i]);
      }
      page.Children.Add(new Border { Child = col, Background = Ui.B(Card), CornerRadius = new CornerRadius(10), Padding = new Thickness(14, 12, 14, 12) });
      if (footer != null) {
        var f = Text(footer, 11.5, 0.45);
        f.Margin = new Thickness(4, 6, 4, 0);
        page.Children.Add(f);
      }
    }

    static FrameworkElement Labeled(string label, FrameworkElement control) {
      var d = new DockPanel();
      DockPanel.SetDock(control, Dock.Right);
      d.Children.Add(control);
      d.Children.Add(Text(label, 13, 0.9));
      return d;
    }

    static FrameworkElement Check(string label, bool value, Action<bool> set) {
      var c = new CheckBox { IsChecked = value, VerticalAlignment = VerticalAlignment.Center };
      c.Checked += (o, e) => set(true);
      c.Unchecked += (o, e) => set(false);
      var row = Labeled(label, c);
      ((Panel)row).Background = Brushes.Transparent;
      row.MouseLeftButtonUp += (o, e) => { if (!(e.OriginalSource is CheckBox) && !c.IsMouseOver) c.IsChecked = !c.IsChecked; };
      return row;
    }

    static FrameworkElement Toggle(string label, string key) { return Check(label, Prefs.Bool(key), v => Prefs.Set(key, v)); }

    FrameworkElement Slider(string label, string key, double min, double max, double step, Func<double, string> show) {
      var value = Text(show(Prefs.Num(key)), 12, 0.6);
      value.Width = 72;
      value.TextAlignment = TextAlignment.Right;
      var s = new Slider { Minimum = min, Maximum = max, Value = Prefs.Num(key), TickFrequency = step, IsSnapToTickEnabled = true, Width = 170, VerticalAlignment = VerticalAlignment.Center };
      s.ValueChanged += (o, e) => value.Text = show(s.Value);
      s.PreviewMouseUp += (o, e) => Prefs.Set(key, s.Value);
      s.LostKeyboardFocus += (o, e) => Prefs.Set(key, s.Value);
      return Labeled(label, new StackPanel { Orientation = Orientation.Horizontal, Children = { s, value } });
    }

    FrameworkElement Swatches() {
      var row = new StackPanel { Orientation = Orientation.Horizontal };
      foreach (var name in Palette.Themes) {
        string n = name;
        var c = Palette.Theme(n);
        bool on = Prefs.Str("theme") == n;
        var dot = new Ellipse { Width = 24, Height = 24, Fill = new LinearGradientBrush(c[0], c[1], 45) };
        var ring = new Ellipse { Width = 32, Height = 32, Stroke = Ui.B(Palette.W(on ? 0.9 : 0)), StrokeThickness = 2 };
        var g = new Grid { Width = 32, Height = 32, Children = { ring, dot } };
        var label = Text(char.ToUpper(n[0]) + n.Substring(1), 10.5, on ? 0.95 : 0.5);
        label.HorizontalAlignment = HorizontalAlignment.Center;
        var col = new StackPanel { Margin = new Thickness(6, 0, 6, 0), Cursor = Cursors.Hand, Background = Brushes.Transparent, Children = { g, label } };
        col.MouseLeftButtonUp += (o, e) => { Prefs.Set("theme", n); Build(); };
        row.Children.Add(col);
      }
      return row;
    }

    static Button Button(string title, bool destructive, Action click) {
      var b = new Button {
        Content = title, Padding = new Thickness(14, 6, 14, 6), Foreground = Ui.B(destructive ? Palette.Red : Colors.White),
        Background = Ui.B(Palette.W(0.08)), BorderBrush = Ui.B(Palette.W(0.15)), Cursor = Cursors.Hand,
      };
      b.Click += (o, e) => click();
      return b;
    }
  }
}
