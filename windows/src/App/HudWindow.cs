using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace ClaudeHud {
  /// A transparent, topmost column on the right edge of the primary screen. Transparent pixels pass clicks
  /// through to the apps below; only the drawer, toasts and edge handle take the mouse.
  public class HudWindow : Window {
    const double ColumnWidth = 400;
    readonly Store store;
    readonly Grid root = new Grid();
    readonly Border drawerSlot = new Border { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 18, 12, 18) };
    readonly StackPanel toastStack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 10, 12, 0), Width = 340 };
    readonly Border edge = new Border { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 1, 0) };
    readonly HashSet<Guid> shownToasts = new HashSet<Guid>();
    readonly Dictionary<int, KeyValuePair<string, DateTime>> hostLabels = new Dictionary<int, KeyValuePair<string, DateTime>>();
    string lastSig, hoveredCard;
    bool wasOpen, building, focusSearch, noActivate = true;
    TextBox replyBox, searchBox;
    ScrollViewer scroller;
    DateTime? edgeSince, leftSince;
    IntPtr hwnd;

    public HudWindow(Store s) {
      store = s;
      Title = "Claude HUD";
      WindowStyle = WindowStyle.None;
      AllowsTransparency = true;
      Background = Brushes.Transparent;
      Topmost = true;
      ShowInTaskbar = false;
      ShowActivated = false;
      ResizeMode = ResizeMode.NoResize;
      FontFamily = Ui.Sans;
      TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
      TextOptions.SetTextRenderingMode(this, TextRenderingMode.Grayscale);
      root.Children.Add(edge);
      root.Children.Add(drawerSlot);
      root.Children.Add(toastStack);
      Content = root;
      Place();
      SystemParameters.StaticPropertyChanged += (o, e) => { if (e.PropertyName == "WorkArea") Dispatcher.BeginInvoke(new Action(Place)); };
      Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (o, e) => Dispatcher.BeginInvoke(new Action(Place));
      SourceInitialized += (o, e) => {
        hwnd = new WindowInteropHelper(this).Handle;
        SetWindowLong(hwnd, -20, GetWindowLong(hwnd, -20) | 0x80 | 0x08000000);  // TOOLWINDOW (no Alt+Tab) | NOACTIVATE
        HwndSource.FromHwnd(hwnd).AddHook(WndProc);
      };
      store.Changed += Refresh;
      store.FocusSearchRequested += () => { focusSearch = true; lastSig = null; Refresh(); };
      Prefs.Changed += () => { lastSig = null; Refresh(); };
      PreviewKeyDown += (o, e) => {
        if (e.OriginalSource is TextBox) return;
        if (store.Key(e.Key)) e.Handled = true;
      };
      Deactivated += (o, e) => {
        if (store.Pinned) store.Close();
        else if (store.ReplyTarget != null || store.Searching || otherFocus != null) {
          store.ReplyTarget = null;
          store.Searching = false;
          otherFocus = null;
          store.Notify();
        }
        SetNoActivate(true);
      };
      track = new DispatcherTimer(DispatcherPriority.Input) { Interval = TimeSpan.FromMilliseconds(200) };
      track.Tick += (o, e) => Track();
      track.Start();
      Refresh();
      // Build the drawer once off-screen when idle, so the first hover opens it as fast as later ones (JIT warm-up).
      Store.After(2, () => Dispatcher.BeginInvoke(new Action(() => {
        if (store.DrawerOpen) return;
        var keep = scroller;
        var d = BuildDrawer(false);
        d.Measure(new Size(400, 2000));
        d.Arrange(new Rect(d.DesiredSize));
        Ui.StopAnimations();
        scroller = keep;
        searchBox = replyBox = otherBox = null;
      }), DispatcherPriority.ApplicationIdle));
    }

    void Place() {
      var wa = SystemParameters.WorkArea;
      Left = wa.Right - ColumnWidth;
      Top = wa.Top;
      Width = ColumnWidth;
      Height = wa.Height;
      drawerSlot.MaxHeight = Math.Max(200, wa.Height - 36);
    }

    // MARK: focus

    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    struct POINT { public int X, Y; }
    struct RECT { public int Left, Top, Right, Bottom; }

    /// The window never takes focus by itself (clicking Allow shouldn't pull you out of your editor),
    /// except while you type a reply or search, or drive it from the keyboard.
    void SetNoActivate(bool on) {
      if (hwnd == IntPtr.Zero || noActivate == on) return;
      noActivate = on;
      int ex = GetWindowLong(hwnd, -20);
      SetWindowLong(hwnd, -20, on ? ex | 0x08000000 : ex & ~0x08000000);
    }

    void TakeFocus() {
      SetNoActivate(false);
      SetForegroundWindow(hwnd);
      Activate();
    }

    public void Toggle() {
      if (store.DrawerOpen) { store.Close(); return; }
      store.Selected = 0;
      store.Pinned = true;
      store.DrawerOpen = true;
      TakeFocus();
      store.Notify();
    }

    public bool SetHotkey(int index) {
      if (hwnd == IntPtr.Zero) return false;
      UnregisterHotKey(hwnd, 1);
      uint[] mods = { 0x2 | 0x1, 0x2 | 0x4, 0x1 | 0x4, 0x2 | 0x1 };  // CTRL=2 ALT=1 SHIFT=4
      uint[] keys = { 0x20, 0x20, 0x43, 0x43 };                       // Space, Space, C, C
      if (index < 0 || index >= mods.Length) return true;
      return RegisterHotKey(hwnd, 1, mods[index] | 0x4000, keys[index]);  // MOD_NOREPEAT
    }

    IntPtr WndProc(IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) {
      if (msg == 0x0312 && w.ToInt32() == 1) { Toggle(); handled = true; }  // WM_HOTKEY
      return IntPtr.Zero;
    }

    // MARK: edge tracking

    bool Over(FrameworkElement e, POINT p) {
      if (e == null || !e.IsVisible || e.ActualWidth == 0) return false;
      try {
        var a = e.PointToScreen(new Point(0, 0));
        var b = e.PointToScreen(new Point(e.ActualWidth, e.ActualHeight));
        return p.X >= a.X - 8 && p.X <= b.X + 8 && p.Y >= a.Y - 8 && p.Y <= b.Y + 8;
      } catch { return false; }
    }

    readonly DispatcherTimer track;

    /// Hover the right screen edge to open; leave the drawer to close. Polls fast only while it matters
    /// (cursor near the edge, or drawer open), slowly otherwise.
    void Track() {
      if (hwnd == IntPtr.Zero) return;
      POINT p;
      RECT wr;
      if (!GetCursorPos(out p) || !GetWindowRect(hwnd, out wr)) return;
      int right = GetSystemMetrics(0);  // primary screen width, in the same pixels as the cursor
      bool near = store.DrawerOpen || p.X >= wr.Left;
      var want = TimeSpan.FromMilliseconds(near ? 33 : 200);
      if (track.Interval != want) track.Interval = want;
      if (!near) { edgeSince = null; return; }
      bool atEdge = p.X >= right - 2 && p.Y >= wr.Top && p.Y <= wr.Bottom;
      bool overUI = Over(drawerSlot.Child as FrameworkElement, p) || toastStack.Children.OfType<FrameworkElement>().Any(t => Over(t, p));
      edgeSince = atEdge ? (edgeSince ?? DateTime.UtcNow) : (DateTime?)null;
      if (!store.DrawerOpen && edgeSince.HasValue && (DateTime.UtcNow - edgeSince.Value).TotalSeconds > Prefs.Num("edgeDelay")) {
        store.Selected = 0;
        store.DrawerOpen = true;
        store.Notify();
      }
      if (!store.DrawerOpen || store.Pinned) { leftSince = null; return; }
      if (overUI || atEdge || store.ReplyTarget != null || store.Searching || otherFocus != null || ContextMenuOpen) { leftSince = null; return; }
      leftSince = leftSince ?? DateTime.UtcNow;
      if ((DateTime.UtcNow - leftSince.Value).TotalSeconds > 0.4) store.Close();
    }

    bool ContextMenuOpen;

    // MARK: rendering

    /// Everything the drawer and toasts show, as text: rebuild only when it changes.
    string Signature() {
      var b = new StringBuilder();
      b.Append(store.DrawerOpen).Append(store.Pinned).Append(store.Selected).Append('|').Append(store.ReplyTarget).Append('|')
       .Append(store.Query).Append('|').Append(store.Quiet).Append(store.InMeeting).Append(DateTime.Now.ToString("HHmm")).Append('|')
       .Append(string.Join(",", store.Collapsed.OrderBy(x => x))).Append('|').Append(string.Join(",", store.DismissedTips)).Append('|');
      foreach (var s in store.Sessions.Values.OrderBy(x => x.Id)) {
        var u = store.Use(s);
        long burn;
        store.Burn.TryGetValue(s.Id, out burn);
        string r;
        b.Append(s.Id).Append(s.Phase).Append(s.Since.Ticks).Append(s.Activity).Append(s.Title).Append(s.Cwd)
         .Append(s.Request == null ? "" : s.Request.Id).Append(string.Join(",", s.Agents.Values)).Append(Fmt.N(u.Tokens))
         .Append(Fmt.N(u.Context)).Append(u.LastText.GetHashCode()).Append(Fmt.Money(u.TodayCost)).Append(u.Error == null ? "" : u.Error.Key)
         .Append(burn >= 50000 ? Fmt.N(burn) : "").Append(store.Heavy(s)).Append(store.Retired.TryGetValue(s.Id, out r) ? "R" + r : "").Append(';');
      }
      foreach (var t in store.Toasts) b.Append(t.Id);
      foreach (var l in new[] { store.FiveHour, store.Week }) {
        if (l != null) b.Append((int)Math.Round(l.Pct)).Append(Fmt.Clock(l.Resets)).Append(l.Out.HasValue ? Fmt.Clock(l.Out.Value) : "").Append(l.Paced);
        b.Append('|');
      }
      foreach (var d in store.Devices) b.Append(d.Name).Append(d.Online).Append(d.Live).Append(Fmt.Money(d.Cost)).Append(Fmt.N(d.Tokens));
      foreach (var r in store.Remotes) b.Append(r.Id).Append(r.Connected).Append(r.Working).Append(r.Title);
      b.Append((int)store.Elsewhere).Append(string.Join(",", store.Tips.Select(t => t.Id + t.Text.Length)))
       .Append(Fmt.Money(store.TodayCost)).Append(Fmt.N(store.TodayTokens)).Append(store.Urgent).Append(store.Recent.Count);
      var issue = store.Issue;
      if (issue != null) b.Append(issue.Key);
      return b.ToString();
    }

    void Refresh() {
      string sig = Signature();
      if (sig == lastSig) return;
      lastSig = sig;
      building = true;
      try { Build(); } finally { building = false; }
    }

    void Build() {
      bool open = store.DrawerOpen, justOpened = open && !wasOpen;
      wasOpen = open;
      Ui.StopAnimations();  // everything below is rebuilt; the old spinners must not keep ticking
      replyBox = null;
      searchBox = null;
      otherBox = null;
      var urgent = store.Urgent;

      bool alarm = store.Issue != null;
      edge.Child = !open && (Prefs.Bool("edgeGlow") || urgent == Phase.Permission || alarm) ? EdgeHandle(urgent, alarm) : null;

      if (open) {
        double offset = scroller == null || justOpened ? 0 : scroller.VerticalOffset;
        var d = BuildDrawer(justOpened);
        drawerSlot.Child = d;
        if (justOpened) Ui.SlideIn(d);
        else if (scroller != null) {
          var sv = scroller;
          Dispatcher.BeginInvoke(new Action(() => sv.ScrollToVerticalOffset(offset)), DispatcherPriority.Loaded);
        }
        ScrollToSelected();
      } else if (drawerSlot.Child != null) {
        var d = (FrameworkElement)drawerSlot.Child;
        scroller = null;
        var a = new DoubleAnimation(0, TimeSpan.FromMilliseconds(160));
        a.Completed += (o, e) => { if (!store.DrawerOpen && drawerSlot.Child == d) drawerSlot.Child = null; };
        d.BeginAnimation(UIElement.OpacityProperty, a);
        var t = d.RenderTransform as TranslateTransform;
        if (t == null) { t = new TranslateTransform(); d.RenderTransform = t; }
        t.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(40, TimeSpan.FromMilliseconds(160)));
      }

      toastStack.Children.Clear();
      if (!open) {
        foreach (var t in store.Toasts) {
          Session s = null;
          if (t.Session.Length > 0 && !store.Sessions.TryGetValue(t.Session, out s)) continue;
          var card = s == null ? NoticeCard(t) : ToastCard(t, s);
          card.Margin = new Thickness(0, 0, 0, 10);
          toastStack.Children.Add(card);
          if (shownToasts.Add(t.Id)) {
            Ui.SlideIn(card);
            if (t.Urgent) Nudge(((Grid)card).Children[0] as FrameworkElement);
          }
        }
      }
      shownToasts.IntersectWith(store.Toasts.Select(t => t.Id));

      if (otherBox != null) {
        TakeFocus();
        otherBox.Focus();
        otherBox.CaretIndex = otherBox.Text.Length;
      } else if (store.ReplyTarget != null && replyBox != null) {
        TakeFocus();
        replyBox.Focus();
        replyBox.CaretIndex = replyBox.Text.Length;
      } else if ((focusSearch || store.Searching) && searchBox != null) {
        focusSearch = false;
        store.Searching = true;
        TakeFocus();
        searchBox.Focus();
        searchBox.CaretIndex = searchBox.Text.Length;
      } else if (!store.Pinned && store.ReplyTarget == null) {
        SetNoActivate(true);
      }
    }

    /// A short bounce that says "this one needs you", then stillness (no endless animation).
    static void Nudge(FrameworkElement e) {
      if (e == null) return;
      var s = new ScaleTransform(1, 1);
      e.RenderTransformOrigin = new Point(1, 0.5);
      e.RenderTransform = s;
      var a = new DoubleAnimation(1, 1.035, TimeSpan.FromMilliseconds(140)) {
        AutoReverse = true, RepeatBehavior = new RepeatBehavior(3), BeginTime = TimeSpan.FromMilliseconds(350),
        EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
      };
      s.BeginAnimation(ScaleTransform.ScaleXProperty, a);
      s.BeginAnimation(ScaleTransform.ScaleYProperty, a);
    }

    void ScrollToSelected() {
      if (!store.Pinned || scroller == null) return;
      var vis = store.Visible;
      if (store.Selected < 0 || store.Selected >= vis.Count) return;
      string id = vis[store.Selected].Id;
      var panel = scroller.Content as Panel;
      if (panel == null) return;
      var target = panel.Children.OfType<FrameworkElement>().FirstOrDefault(c => (c.Tag as string) == id);
      if (target != null) Dispatcher.BeginInvoke(new Action(() => target.BringIntoView()), DispatcherPriority.Loaded);
    }

    static bool InTextBox(object src) {
      var d = src as DependencyObject;
      while (d != null) {
        if (d is TextBoxBase) return true;
        d = d is Visual || d is System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d);
      }
      return false;
    }

    static Color W(double a) { return Palette.W(a); }
    static Color A(Color c, double a) { return Palette.A(c, a); }

    FrameworkElement EdgeHandle(Phase? phase, bool alarm) {
      var c = alarm ? Palette.Red : phase.HasValue ? Palette.Of(phase.Value) : W(0.35);
      double h = phase == Phase.Permission || alarm ? 90 : 64;
      var g = new Grid { Width = 16, Height = h, Opacity = phase.HasValue || alarm ? 1 : 0.45 };
      g.Children.Add(new Border { Width = 14, HorizontalAlignment = HorizontalAlignment.Right, CornerRadius = new CornerRadius(7),
                                  Background = new LinearGradientBrush(A(c, 0), A(c, 0.4), 0), Margin = new Thickness(0, 4, 0, 4) });
      g.Children.Add(new Border { Width = 4, HorizontalAlignment = HorizontalAlignment.Right, CornerRadius = new CornerRadius(2),
                                  Background = new LinearGradientBrush(c, A(c, 0.75), 90) });
      g.ToolTip = "Claude HUD — hover the edge or click to open";
      g.Cursor = Cursors.Hand;
      g.MouseLeftButtonUp += (o, e) => { store.Selected = 0; store.DrawerOpen = true; store.Notify(); };
      return g;
    }

    // MARK: drawer

    FrameworkElement BuildDrawer(bool justOpened) {
      var list = store.Filtered;
      var vis = store.Visible;
      var urgent = store.Urgent;
      var dock = new DockPanel { LastChildFill = true, Width = 308 };
      Action<FrameworkElement, double> top = (e, gap) => {
        e.Margin = new Thickness(0, 0, 0, gap);
        DockPanel.SetDock(e, Dock.Top);
        dock.Children.Add(e);
      };

      Border plus = null;
      plus = Ui.Round(Ui.IcAdd, 22, W(0.5), W(0.06), () => RecentMenu(plus), "New session");
      var gear = Ui.Round(Ui.IcGear, 22, W(0.35), W(0.04), store.OpenSettings, "Settings");
      var moon = Ui.Round(Ui.IcMoon, 22, store.Quiet ? Palette.Rgb(0.7, 0.6, 1) : W(0.35), W(store.Quiet ? 0.1 : 0.04),
                          () => store.Dnd = !store.Dnd,
                          store.InMeeting ? "Quiet: you're in a Zoom meeting" : store.Dnd ? "Do not disturb is on" : "Do not disturb");
      var costText = Ui.T(Fmt.Money(store.TodayCost), 16, Colors.White, FontWeights.SemiBold, true);
      costText.HorizontalAlignment = HorizontalAlignment.Right;
      var tokText = Ui.T(Fmt.N(store.TodayTokens) + " tokens today", 9, W(0.4), FontWeights.Medium);
      tokText.HorizontalAlignment = HorizontalAlignment.Right;
      var cost = Ui.Col(1, costText, tokText);
      cost.ToolTip = "Today's usage priced at API rates (your plan isn't billed this way)";
      var header = Ui.Spread(new UIElement[] {
        Ui.StatusDot(urgent ?? Phase.Ready, true),
        Ui.T("C L A U D E", 11, W(0.75), FontWeights.Black),
        Ui.T(list.Count(s => s.Phase != Phase.Ended) + " live", 10.5, W(0.4), FontWeights.Medium),
        plus, gear, moon,
      }, new UIElement[] { cost }, 8);
      header.ContextMenu = Menu(new[] { "Settings…", "Quit Claude HUD" }, new Action[] { store.OpenSettings, Program.Quit });
      top(header, 16);

      var issue = store.Issue;
      if (issue != null) top(IssueBanner(issue), 16);

      var limits = new Grid();
      limits.ColumnDefinitions.Add(new ColumnDefinition());
      limits.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
      limits.ColumnDefinitions.Add(new ColumnDefinition());
      var f = Ui.LimitBar("5-HOUR", store.FiveHour);
      var w = Ui.LimitBar("WEEKLY", store.Week);
      Grid.SetColumn(w, 2);
      limits.Children.Add(f);
      limits.Children.Add(w);
      top(limits, 16);

      if (store.Devices.Count > 0 || store.Remotes.Count > 0 || store.Elsewhere > 0) top(DevicesStrip(), 16);
      var tips = store.Tips;
      if (tips.Count > 0) top(TipsStrip(tips), 16);

      var line = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 0) };
      line.GradientStops.Add(new GradientStop(W(0), 0));
      line.GradientStops.Add(new GradientStop(W(0.12), 0.5));
      line.GradientStops.Add(new GradientStop(W(0), 1));
      top(new Border { Height = 1, Background = line }, 16);

      if (store.Pinned || store.Query.Length > 0) top(SearchField(), 10);

      if (store.Pinned) {
        var hint = Ui.T("↑↓  ↩ open  A allow  D deny  R reply  / search", 9.5, W(0.3), FontWeights.Medium, true);
        hint.HorizontalAlignment = HorizontalAlignment.Center;
        hint.Margin = new Thickness(0, 12, 0, 0);
        DockPanel.SetDock(hint, Dock.Bottom);
        dock.Children.Add(hint);
      }

      if (list.Count == 0) {
        scroller = null;
        var icon = Ui.Icon(store.Query.Length == 0 ? Ui.IcSparkle : Ui.IcSearch, 18, W(0.3));
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        var msg = Ui.T(store.Query.Length == 0 ? "No sessions yet" : "No session matches “" + store.Query + "”", 12, W(0.4), FontWeights.Medium);
        msg.HorizontalAlignment = HorizontalAlignment.Center;
        var empty = Ui.Col(6, icon, msg);
        empty.Margin = new Thickness(0, 18, 0, 18);
        dock.Children.Add(empty);
      } else {
        var cards = new StackPanel();
        bool grouped = Prefs.Bool("groupByWorkspace") && store.Query.Length == 0 && list.Select(s => s.Cwd).Distinct().Count() > 1;
        int n = 0;
        Action<Session> addCard = s => {
          int i = vis.FindIndex(x => x.Id == s.Id);
          bool sel = store.Pinned && store.Selected >= 0 && store.Selected < vis.Count && vis[store.Selected].Id == s.Id;
          var c = Card(s, sel);
          Ui.Add(cards, 8, c);
          if (justOpened && n < 12) Ui.SlideIn(c, 0.05 + Math.Max(0, i) * 0.045);
          n++;
        };
        if (grouped) {
          foreach (var c in list.Select(s => s.Cwd).Distinct().ToList()) {
            var group = list.Where(s => s.Cwd == c).ToList();
            var head = WorkspaceHeader(c, group);
            Ui.Add(cards, 8, head);
            if (cards.Children.Count > 1) head.Margin = new Thickness(0, 14, 0, 0);
            if (!store.Collapsed.Contains(c)) foreach (var s in group) addCard(s);
          }
        } else {
          foreach (var s in list) addCard(s);
        }
        scroller = new ScrollViewer {
          Content = cards, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, Focusable = false,
          HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        dock.Children.Add(scroller);
      }

      var tint = urgent == Phase.Permission ? Palette.Of(Phase.Permission) : Palette.CurrentTheme[1];
      return Ui.Glass(dock, 24, tint, new Thickness(16));
    }

    /// What Anthropic is refusing right now and how to fix it; stays until a real reply comes back.
    FrameworkElement IssueBanner(ApiError e) {
      var red = Palette.Red;
      var col = Ui.Col(5,
        Ui.Row(6, Ui.Icon(Ui.IcWarning, 12, red), Ui.T(e.Title, 12.5, red, FontWeights.SemiBold),
               Ui.T(Fmt.Ago(e.At) + (e.Status > 0 ? " · " + e.Status : ""), 10, W(0.4), FontWeights.Medium)),
        Ui.T(e.Text, 11, W(0.75), FontWeights.Normal, false, 3));
      if (e.Hint.Length > 0) Ui.Add(col, 5, Ui.T(e.Hint, 10.5, W(0.5), FontWeights.Normal, false, 0));
      if (e.Link != null) {
        var link = Pill(e.LinkTitle, Ui.IcOpen, red, () => store.OpenLink(e.Link), true, null, e.Link);
        link.HorizontalAlignment = HorizontalAlignment.Left;
        Ui.Add(col, 8, link);
      }
      var b = Ui.Rounded(col, 12, A(red, 0.1), new Thickness(11));
      b.BorderBrush = Ui.B(A(red, 0.45));
      b.BorderThickness = new Thickness(1);
      b.ToolTip = e.Code.Length > 0 ? "Anthropic error: " + e.Code : null;
      return b;
    }

    ContextMenu Menu(string[] titles, Action[] actions) {
      var m = new ContextMenu();
      for (int i = 0; i < titles.Length; i++) {
        var a = actions[i];
        if (a == null) { m.Items.Add(new MenuItem { Header = titles[i], IsEnabled = false }); continue; }
        var item = new MenuItem { Header = titles[i] };
        item.Click += (o, e) => a();
        m.Items.Add(item);
      }
      m.Opened += (o, e) => ContextMenuOpen = true;
      m.Closed += (o, e) => ContextMenuOpen = false;
      return m;
    }

    void RecentMenu(FrameworkElement anchor) {
      var titles = new List<string> { "New session in…" };
      var actions = new List<Action> { null };
      foreach (var c in store.Recent) {
        string cwd = c;
        titles.Add(Paths.FolderName(c));
        actions.Add(() => store.Launch(cwd));
      }
      if (store.Recent.Count == 0) { titles.Add("(no recent workspaces)"); actions.Add(null); }
      var m = Menu(titles.ToArray(), actions.ToArray());
      m.PlacementTarget = anchor;
      m.Placement = PlacementMode.Bottom;
      m.IsOpen = true;
    }

    FrameworkElement SearchField() {
      var tb = Ui.Field(store.Query, "Search sessions  ( / )", 12);
      tb.TextChanged += (o, e) => {
        if (building) return;
        store.Query = tb.Text;
        store.Selected = 0;
        store.Notify();
      };
      tb.GotKeyboardFocus += (o, e) => { if (!building) store.Searching = true; };
      tb.LostKeyboardFocus += (o, e) => { if (!building) store.Searching = false; };
      tb.PreviewKeyDown += (o, e) => {
        if (e.Key == Key.Enter) {
          e.Handled = true;
          var first = store.Visible.FirstOrDefault();
          if (first != null) store.Jump(first);
        } else if (e.Key == Key.Escape || e.Key == Key.Down) {
          e.Handled = true;
          if (e.Key == Key.Escape) store.Query = "";
          store.Searching = false;
          Keyboard.Focus(this);
          store.Notify();
        }
      };
      searchBox = tb;
      var row = new DockPanel();
      var icon = Ui.Icon(Ui.IcSearch, 10.5, W(0.4));
      icon.Margin = new Thickness(0, 0, 7, 0);
      DockPanel.SetDock(icon, Dock.Left);
      row.Children.Add(icon);
      if (store.Query.Length > 0) {
        var clear = Ui.Round(Ui.IcClose, 16, W(0.4), W(0.06), () => { store.Query = ""; store.Notify(); }, "Clear search");
        DockPanel.SetDock(clear, Dock.Right);
        row.Children.Add(clear);
      }
      row.Children.Add(Ui.WithHint(tb));
      return new Border {
        Child = row, CornerRadius = new CornerRadius(10), Padding = new Thickness(10, 6, 10, 6),
        Background = Ui.B(A(Colors.Black, 0.35)), BorderBrush = Ui.B(W(0.12)), BorderThickness = new Thickness(1),
      };
    }

    string HostLabel(Session s) {
      KeyValuePair<string, DateTime> c;
      if (hostLabels.TryGetValue(s.Pid, out c) && (DateTime.UtcNow - c.Value).TotalSeconds < 15) return c.Key;
      var h = Native.FindHost(s.Pid);
      string label = h != null ? h.Label : Editor.Current.Name;
      hostLabels[s.Pid] = new KeyValuePair<string, DateTime>(label, DateTime.UtcNow);
      return label;
    }

    FrameworkElement Card(Session s, bool selected) {
      if (store.Retired.ContainsKey(s.Id)) return RetiredCard(s);
      var u = store.Use(s);
      bool replying = store.ReplyTarget == s.Id, hover = hoveredCard == s.Id;
      string heavy = store.Heavy(s);
      long burn;
      store.Burn.TryGetValue(s.Id, out burn);
      var pc = Palette.Of(s.Phase);
      var body = new StackPanel();

      var g = new Grid();
      g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
      g.ColumnDefinitions.Add(new ColumnDefinition());
      g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
      g.Children.Add(Ui.StatusDot(s.Phase, true));
      var names = Ui.Col(2, Ui.T(s.Name, 13.5, Colors.White, FontWeights.SemiBold),
                         Ui.Row(5, Ui.T(Palette.Label(s.Phase), 10.5, pc, FontWeights.Medium), Ui.T("·", 10.5, W(0.45)),
                                Ui.T(Fmt.Ago(s.Since), 10.5, W(0.45), FontWeights.Medium)));
      names.Margin = new Thickness(10, 0, 6, 0);
      Grid.SetColumn(names, 1);
      g.Children.Add(names);
      var tokens = Ui.T(Fmt.N(u.Tokens), 12, W(0.85), FontWeights.SemiBold, true);
      tokens.HorizontalAlignment = HorizontalAlignment.Right;
      tokens.ToolTip = Fmt.N(u.Tokens) + " tokens · " + Fmt.Money(u.Cost) + " at API prices (" + Fmt.Money(u.TodayCost) + " today)";
      var right = Ui.Col(3, tokens, Ui.ContextRing(u.Context));
      if (burn >= 50000) {
        var bt = Ui.T("+" + Fmt.N(burn) + "/10m", 9, heavy != null ? Palette.Red : W(0.35), FontWeights.SemiBold, true);
        bt.HorizontalAlignment = HorizontalAlignment.Right;
        bt.ToolTip = "Tokens used in the last 10 minutes";
        Ui.Add(right, 3, bt);
      }
      Grid.SetColumn(right, 2);
      g.Children.Add(right);
      Ui.Add(body, 9, g);

      var from = store.Predecessor(s.Id);
      if (from != null) Ui.Add(body, 9, Ui.Row(5, Ui.Icon(Ui.IcContinue, 10, Palette.Violet), Ui.T("continues " + from.Name, 10, Palette.Violet, FontWeights.Medium)));
      if (s.Agents.Count > 0) {
        string kinds = string.Join(", ", s.Agents.Values.Distinct().OrderBy(x => x));
        Ui.Add(body, 9, Ui.Row(6, Ui.Icon(Ui.IcPeople, 10, Palette.Theme("aurora")[0]),
          Ui.T(s.Agents.Count + " agent" + (s.Agents.Count == 1 ? "" : "s") + " · " + kinds, 10.5, W(0.6), FontWeights.Medium)));
      }
      if (heavy != null) {
        var hb = Ui.Col(7, Ui.Row(6, Ui.Icon(Ui.IcFlame, 11, Palette.Red), Ui.T(heavy, 11, Palette.Red, FontWeights.SemiBold)),
          Ui.Row(6, Pill("Compact", Ui.IcCompact, Palette.Red, () => store.Jump(s, "/compact"), false, null, "Open the tab with /compact ready to send"),
                    Pill("Fresh session", Ui.IcBranch, Palette.Red, () => store.StartHandoff(s), true, null, "New session in this workspace, seeded with a handoff note from this one")));
        Ui.Add(body, 9, Ui.Rounded(hb, 10, A(Palette.Red, 0.08), new Thickness(9)));
      }
      if (u.Error != null && s.Phase != Phase.Ended) {
        var err = Ui.Row(6, Ui.Icon(Ui.IcWarning, 11, Palette.Red),
                         Ui.T(u.Error.Title + (u.Error.Status > 0 ? " (" + u.Error.Status + ")" : ""), 11, Palette.Red, FontWeights.SemiBold));
        err.ToolTip = u.Error.Text;
        Ui.Add(body, 9, err);
      }
      if (s.Phase == Phase.Working && s.Activity.Length > 0) {
        var bar = new Rectangle { Width = 2, Height = 12, Fill = Ui.B(A(Palette.Of(Phase.Working), 0.7)) };
        Ui.Add(body, 9, Ui.Row(6, bar, Ui.T(s.Activity, 10.5, W(0.55), FontWeights.Normal, true)));
      }
      if (s.Request != null) Ui.Add(body, 9, RequestBlock(s, s.Request));
      else if (s.Phase == Phase.Done && u.LastText.Length > 0) Ui.Add(body, 9, Ui.T(u.LastText, 11.5, W(0.6), FontWeights.Normal, false, 2));

      FrameworkElement actions = null;
      if (s.Request == null) {
        var left = new List<UIElement> { Pill("Open", Ui.IcOpen, Colors.White, () => store.Jump(s), false, selected ? "↩" : null, null) };
        var rightItems = new List<UIElement>();
        if (s.Phase != Phase.Ended) {
          left.Add(Pill("Reply", Ui.IcReply, Palette.Of(Phase.Done), () => store.StartReply(s), false, selected ? "R" : null, null));
          bool confirm = false;
          Border end = null;
          end = Pill("End", Ui.IcPower, Palette.Red, () => {
            if (confirm) { store.End(s); return; }
            confirm = true;
            ((TextBlock)end.Tag).Text = "End session?";
            Store.After(3, () => { confirm = false; ((TextBlock)end.Tag).Text = "End"; });
          }, false, null, null);
          rightItems.Add(end);
        }
        actions = Ui.Spread(left.ToArray(), rightItems.ToArray());
        actions.Visibility = hover || selected || replying ? Visibility.Visible : Visibility.Collapsed;
        Ui.Add(body, 9, actions);
      }
      if (replying) Ui.Add(body, 9, ReplyField(s));

      Func<bool, Brush> stroke = lit => Ui.B(heavy != null && s.Phase != Phase.Permission ? A(Palette.Red, 0.55)
        : A(pc, s.Phase == Phase.Permission ? 0.5 : selected ? 0.45 : lit ? 0.22 : 0.07));
      var card = new Border {
        Child = body, Padding = new Thickness(12), CornerRadius = new CornerRadius(16), BorderThickness = new Thickness(1),
        Background = Ui.B(W(hover || selected ? 0.075 : 0.04)), BorderBrush = stroke(hover), Cursor = Cursors.Hand, Tag = s.Id,
        ToolTip = s.Cwd,
      };
      card.MouseEnter += (o, e) => {
        hoveredCard = s.Id;
        card.Background = Ui.B(W(0.075));
        card.BorderBrush = stroke(true);
        if (actions != null) actions.Visibility = Visibility.Visible;
      };
      card.MouseLeave += (o, e) => {
        if (hoveredCard == s.Id) hoveredCard = null;
        card.Background = Ui.B(W(selected ? 0.075 : 0.04));
        card.BorderBrush = stroke(false);
        if (actions != null && !selected && !replying) actions.Visibility = Visibility.Collapsed;
      };
      card.MouseLeftButtonUp += (o, e) => { if (!InTextBox(e.OriginalSource)) store.Jump(s); };
      return card;
    }

    static Border Pill(string title, string glyph, Color tint, Action click, bool primary, string key, string tip) {
      var p = Ui.Pill(title, glyph, tint, click, primary, key);
      if (tip != null) p.ToolTip = tip;
      return p;
    }

    // Picks and "Other" text per request, kept across rebuilds while you answer.
    readonly Dictionary<string, Dictionary<int, List<string>>> picks = new Dictionary<string, Dictionary<int, List<string>>>();
    readonly Dictionary<string, Dictionary<int, string>> others = new Dictionary<string, Dictionary<int, string>>();
    string otherFocus;  // "<request>#<question>" whose Other box has the keyboard
    TextBox otherBox;

    /// Claude's AskUserQuestion, answerable right here. One single-choice question: a click answers it.
    FrameworkElement QuestionBlock(Session s, Request r) {
      var perm = Palette.Of(Phase.Permission);
      Dictionary<int, List<string>> mine;
      if (!picks.TryGetValue(r.Id, out mine)) picks[r.Id] = mine = new Dictionary<int, List<string>>();
      Dictionary<int, string> other;
      if (!others.TryGetValue(r.Id, out other)) others[r.Id] = other = new Dictionary<int, string>();
      bool quick = r.Questions.Count == 1 && !r.Questions[0].Multi;
      Func<Dictionary<string, string>> collect = () => {
        var answers = new Dictionary<string, string>();
        for (int i = 0; i < r.Questions.Count; i++) {
          var parts = new List<string>();
          List<string> chosen;
          if (mine.TryGetValue(i, out chosen)) parts.AddRange(chosen);
          string typed;
          if (other.TryGetValue(i, out typed) && typed.Trim().Length > 0) parts.Add(typed.Trim());
          if (parts.Count == 0) return null;  // every question needs an answer
          answers[r.Questions[i].Text] = string.Join(", ", parts);
        }
        return answers;
      };
      Action submit = () => {
        var a = collect();
        if (a == null) return;
        picks.Remove(r.Id);
        others.Remove(r.Id);
        otherFocus = null;
        store.AnswerQuestions(s, a);
      };

      var col = new StackPanel();
      Ui.Add(col, 0, Ui.Row(6, Ui.Icon(Ui.IcQuestion, 12, perm), Ui.T(r.Questions.Count > 1 ? "Claude has " + r.Questions.Count + " questions" : "Claude has a question", 11.5, perm, FontWeights.SemiBold)));
      for (int qi = 0; qi < r.Questions.Count; qi++) {
        int i = qi;
        var q = r.Questions[i];
        var qcol = new StackPanel();
        if (q.Header.Length > 0) {
          Ui.Add(qcol, 0, new Border {
            Child = Ui.T(q.Header.ToUpperInvariant(), 9, W(0.6), FontWeights.Bold), CornerRadius = new CornerRadius(8),
            Background = Ui.B(W(0.07)), Padding = new Thickness(7, 2, 7, 3), HorizontalAlignment = HorizontalAlignment.Left,
          });
        }
        Ui.Add(qcol, 6, Ui.T(q.Text, 12.5, W(0.92), FontWeights.SemiBold, false, 0));
        var opts = new WrapPanel();
        List<string> chosen;
        if (!mine.TryGetValue(i, out chosen)) mine[i] = chosen = new List<string>();
        for (int k = 0; k < q.Labels.Count; k++) {
          string label = q.Labels[k];
          bool on = chosen.Contains(label);
          var p = Pill((q.Multi ? (on ? "☑ " : "☐ ") : "") + label, null, perm, () => {
            if (quick) { mine[i] = new List<string> { label }; submit(); return; }
            if (q.Multi) { if (!chosen.Remove(label)) chosen.Add(label); }
            else { chosen.Clear(); chosen.Add(label); }
            lastSig = null;
            Refresh();
          }, on, null, q.Descriptions[k].Length > 0 ? q.Descriptions[k] : null);
          p.Margin = new Thickness(0, 0, 6, 6);
          opts.Children.Add(p);
        }
        Ui.Add(qcol, 8, opts);
        string typed;
        other.TryGetValue(i, out typed);
        var tb = Ui.Field(typed, quick ? "Other… (type, then Enter)" : "Other…", 12);
        string key = r.Id + "#" + i;
        if (otherFocus == key) otherBox = tb;
        tb.TextChanged += (o, e) => other[i] = tb.Text;
        tb.PreviewMouseLeftButtonDown += (o, e) => { otherFocus = key; TakeFocus(); tb.Focus(); };
        tb.GotKeyboardFocus += (o, e) => { if (!building) otherFocus = key; };
        tb.LostKeyboardFocus += (o, e) => { if (!building && otherFocus == key) otherFocus = null; };
        tb.PreviewKeyDown += (o, e) => {
          if (e.Key == Key.Enter) {
            e.Handled = true;
            if (quick && tb.Text.Trim().Length > 0) mine[i] = new List<string>();
            submit();
          } else if (e.Key == Key.Escape) { e.Handled = true; otherFocus = null; Keyboard.ClearFocus(); }
        };
        Ui.Add(qcol, 2, new Border {
          Child = Ui.WithHint(tb), CornerRadius = new CornerRadius(9), Padding = new Thickness(9, 6, 9, 6),
          Background = Ui.B(A(Colors.Black, 0.4)), BorderBrush = Ui.B(W(0.1)), BorderThickness = new Thickness(1),
        });
        Ui.Add(col, 10, qcol);
      }
      var buttons = new WrapPanel();
      var items = new List<Border>();
      if (!quick) items.Add(Pill("Send answers", Ui.IcCheck, perm, submit, true, null, null));
      items.Add(Pill("Skip", Ui.IcClose, Palette.Red, () => { picks.Remove(r.Id); others.Remove(r.Id); store.Respond(s, Answer.Deny); }, false, null, "Decline: Claude carries on without an answer"));
      string app = HostLabel(s);
      items.Add(Pill(app, Ui.IcOpen, Colors.White, () => store.Respond(s, Answer.Editor), false, null, "Answer in " + app + " instead"));
      foreach (var p in items) { p.Margin = new Thickness(0, 0, 6, 6); buttons.Children.Add(p); }
      Ui.Add(col, 10, buttons);
      return col;
    }

    FrameworkElement RequestBlock(Session s, Request r) {
      if (r.Questions != null) return QuestionBlock(s, r);
      var perm = Palette.Of(Phase.Permission);
      var col = new StackPanel();
      Ui.Add(col, 0, Ui.Row(6, Ui.Icon(Ui.IcLock, 11, perm), Ui.T(r.Tool, 11.5, Colors.White, FontWeights.SemiBold, true)));
      var detail = new TextBox {
        Text = r.Detail, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, FontFamily = Ui.Mono, FontSize = 11,
        Foreground = Ui.B(W(0.78)), Background = Brushes.Transparent, BorderThickness = new Thickness(0), MaxHeight = 78,
        VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, CaretBrush = Brushes.Transparent, Cursor = Cursors.IBeam,
      };
      Ui.Add(col, 9, Ui.Rounded(detail, 9, A(Colors.Black, 0.4), new Thickness(9)));
      var left = new List<UIElement> { Pill("Allow", Ui.IcCheck, perm, () => store.Respond(s, Answer.Allow), true, null, null) };
      if (r.Always != null) left.Add(Pill("Always", Ui.IcSeal, perm, () => store.Respond(s, Answer.Always), false, null, "Allow and don't ask again: " + r.Always));
      left.Add(Pill("Deny", Ui.IcClose, Palette.Red, () => store.Respond(s, Answer.Deny), false, null, null));
      string app = HostLabel(s);
      left.Add(Pill(app, Ui.IcOpen, Colors.White, () => store.Respond(s, Answer.Editor), false, null, "Answer in " + app + " instead"));
      var buttons = new WrapPanel();
      foreach (FrameworkElement p in left) {
        p.Margin = new Thickness(0, 0, 6, 6);
        buttons.Children.Add(p);
      }
      Ui.Add(col, 9, buttons);
      if (r.Always != null) Ui.Add(col, 9, Ui.T("Always = don't ask again for " + r.Always, 9.5, W(0.35), FontWeights.Normal, true));
      return col;
    }

    FrameworkElement ReplyField(Session s) {
      string draft;
      store.Drafts.TryGetValue(s.Id, out draft);
      var tb = Ui.Field(draft, "Reply to " + s.Name + "…", 12.5);
      var enter = Ui.Icon(Ui.IcEnter, 10, W(string.IsNullOrEmpty(draft) ? 0.25 : 0.7));
      tb.TextChanged += (o, e) => {
        store.Drafts[s.Id] = tb.Text;
        enter.Foreground = Ui.B(W(tb.Text.Length == 0 ? 0.25 : 0.7));
      };
      tb.PreviewKeyDown += (o, e) => {
        if (e.Key == Key.Enter) { e.Handled = true; store.Jump(s, tb.Text); }
        else if (e.Key == Key.Escape) { e.Handled = true; store.ReplyTarget = null; store.Notify(); }
      };
      replyBox = tb;
      var row = new DockPanel();
      DockPanel.SetDock(enter, Dock.Right);
      enter.Margin = new Thickness(8, 0, 0, 0);
      row.Children.Add(enter);
      row.Children.Add(Ui.WithHint(tb));
      return new Border {
        Child = row, CornerRadius = new CornerRadius(11), Padding = new Thickness(11, 8, 11, 8),
        Background = Ui.B(A(Colors.Black, 0.45)), BorderBrush = Ui.B(A(Palette.Of(Phase.Done), 0.55)), BorderThickness = new Thickness(1),
      };
    }

    FrameworkElement WorkspaceHeader(string cwd, List<Session> group) {
      long tokens = group.Sum(s => store.Use(s).Tokens);
      double cost = group.Sum(s => store.Use(s).TodayCost);
      bool folded = store.Collapsed.Contains(cwd);
      var leftItems = new List<UIElement> { Ui.Chevron(folded), Ui.T(Paths.FolderName(cwd).ToUpperInvariant(), 9.5, W(0.55), FontWeights.Bold) };
      if (folded) {
        var dots = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        foreach (var s in group) dots.Children.Add(new Ellipse { Width = 5, Height = 5, Fill = Ui.B(Palette.Of(s.Phase)), Margin = new Thickness(0, 0, 3, 0) });
        leftItems.Add(dots);
      } else {
        leftItems.Add(Ui.T(group.Count.ToString(), 9.5, W(0.3), FontWeights.SemiBold, true));
      }
      var plus = Ui.Round(Ui.IcAdd, 16, W(0.7), W(0.1), () => store.Launch(cwd), "New session in " + Paths.FolderName(cwd));
      plus.Visibility = Visibility.Hidden;
      var total = Ui.T(Fmt.Money(cost) + " · " + Fmt.N(tokens), 9.5, group.Any(s => store.Heavy(s) != null) ? Palette.Red : W(0.4), FontWeights.SemiBold, true);
      total.ToolTip = "Today at API prices · tokens across these sessions";
      var d = new DockPanel { Background = Brushes.Transparent, Cursor = Cursors.Hand, ToolTip = cwd };
      var l = Ui.Row(6, leftItems.ToArray());
      DockPanel.SetDock(l, Dock.Left);
      var r = Ui.Row(6, plus, total);
      DockPanel.SetDock(r, Dock.Right);
      d.Children.Add(l);
      d.Children.Add(r);
      d.Children.Add(new Border { Height = 1, Background = Ui.B(W(0.08)), Margin = new Thickness(6, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
      d.MouseEnter += (o, e) => plus.Visibility = Visibility.Visible;
      d.MouseLeave += (o, e) => plus.Visibility = Visibility.Hidden;
      d.MouseLeftButtonUp += (o, e) => store.ToggleCollapse(cwd);
      var wrap = new Border { Child = d, Padding = new Thickness(4, 2, 4, 2) };
      return wrap;
    }

    /// A session that was handed off to a fresh one: clearly retired, one tap to close it.
    FrameworkElement RetiredCard(Session s) {
      var next = store.Successor(s.Id);
      var v = Palette.Violet;
      var g = new Grid();
      g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
      g.ColumnDefinitions.Add(new ColumnDefinition());
      g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
      var icon = Ui.Icon(Ui.IcArchive, 11, A(v, 0.8));
      icon.Width = 18;
      g.Children.Add(icon);
      var name = Ui.T(s.Name, 13, W(0.55), FontWeights.SemiBold);
      name.TextDecorations = TextDecorations.Strikethrough;
      var col = Ui.Col(2, name, Ui.T(next != null ? "Handed off → " + next.Name : "Handed off · waiting for the new session", 10.5, v, FontWeights.Medium));
      col.Margin = new Thickness(10, 0, 6, 0);
      Grid.SetColumn(col, 1);
      g.Children.Add(col);
      var tok = Ui.T(Fmt.N(store.Use(s).Tokens), 11, W(0.35), FontWeights.SemiBold, true);
      Grid.SetColumn(tok, 2);
      g.Children.Add(tok);
      var body = Ui.Col(8, g);
      var left = new List<UIElement>();
      if (next != null) left.Add(Pill("Go to new", Ui.IcOpen, v, () => store.Jump(next), false, null, null));
      left.Add(Pill("Undo", Ui.IcUndo, Colors.White, () => store.UndoHandoff(s), false, null, null));
      var right = s.Phase != Phase.Ended ? new UIElement[] { Pill("Close old", Ui.IcPower, Palette.Red, () => store.End(s), true, null, null) } : new UIElement[0];
      var actions = Ui.Spread(left.ToArray(), right);
      actions.Visibility = hoveredCard == s.Id ? Visibility.Visible : Visibility.Collapsed;
      Ui.Add(body, 8, actions);
      var card = new Border {
        Child = body, Padding = new Thickness(12), CornerRadius = new CornerRadius(16), Background = Ui.B(A(v, 0.04)),
        BorderBrush = Ui.B(A(v, 0.18)), BorderThickness = new Thickness(1), Tag = s.Id,
        ToolTip = "This session was continued in a fresh one — you don't need it anymore",
      };
      card.MouseEnter += (o, e) => { hoveredCard = s.Id; card.Background = Ui.B(A(v, 0.08)); actions.Visibility = Visibility.Visible; };
      card.MouseLeave += (o, e) => { if (hoveredCard == s.Id) hoveredCard = null; card.Background = Ui.B(A(v, 0.04)); actions.Visibility = Visibility.Collapsed; };
      return card;
    }

    FrameworkElement StripHeader(string title, string key, int count, UIElement right) {
      bool folded = store.Collapsed.Contains(key);
      var d = Ui.Spread(new UIElement[] { Ui.Chevron(folded), Ui.Caps(title, W(0.45)), Ui.T(count.ToString(), 9.5, W(0.3), FontWeights.SemiBold, true) },
                        right == null ? new UIElement[0] : new[] { right });
      d.Background = Brushes.Transparent;
      d.Cursor = Cursors.Hand;
      d.MouseLeftButtonUp += (o, e) => store.ToggleCollapse(key);
      return d;
    }

    FrameworkElement DevicesStrip() {
      bool folded = store.Collapsed.Contains("#devices");
      var col = new StackPanel();
      int count = store.Devices.Count + store.Remotes.Count + (store.Elsewhere > 0 ? 1 : 0);
      Ui.Add(col, 0, StripHeader("DEVICES", "#devices", count,
        Ui.T(Fmt.Money(store.Devices.Sum(d => d.Cost)) + " today", 9.5, W(0.4), FontWeights.SemiBold, true)));
      if (folded) return col;
      Func<string, Color, Color, string, UIElement, string, FrameworkElement> row = (glyph, iconColor, dot, label, rightEl, tip) => {
        var r = Ui.Spread(new UIElement[] { Ui.Icon(glyph, 10, iconColor), new Ellipse { Width = 5, Height = 5, Fill = Ui.B(dot) },
                                            Ui.T(label, 11, Colors.White, FontWeights.Medium) }, new[] { rightEl }, 8);
        r.ToolTip = tip;
        return r;
      };
      foreach (var d in store.Devices) {
        var r = row(Ui.IcLaptop, W(0.5), d.Online ? Palette.Of(Phase.Done) : Palette.Rgb(0.4, 0.4, 0.4),
                    d.Name + (d.Mine ? "  · this PC" : "") + (d.Live > 0 ? "  " + d.Live + " live" : ""),
                    Ui.T(Fmt.Money(d.Cost) + " · " + Fmt.N(d.Tokens), 10, W(0.6), FontWeights.SemiBold, true),
                    d.Online ? "Online" : "Last seen " + Fmt.Clock(d.Updated));
        Ui.Add(col, 7, r);
      }
      if (store.Elsewhere > 0) {
        var perm = Palette.Of(Phase.Permission);
        Ui.Add(col, 7, row(Ui.IcGlobe, perm, perm, "Elsewhere · claude.ai, phone, other computers",
                           Ui.T("+" + (int)Math.Round(store.Elsewhere) + "% of 5h", 10, perm, FontWeights.SemiBold, true),
                           "Your account's 5-hour usage grew this much while this PC wasn't using Claude"));
      }
      foreach (var x in store.Remotes) {
        var rm = x;
        var r = row(Ui.IcRemote, W(0.5), rm.Working ? Palette.Of(Phase.Working) : rm.Connected ? Palette.Of(Phase.Done) : Palette.Rgb(0.4, 0.4, 0.4),
                    rm.Title, Ui.T(rm.Connected ? (rm.Working ? "working" : "connected") : "last " + Fmt.Clock(rm.Last), 9.5, W(0.4), FontWeights.Medium, true),
                    "Remote / cloud session · " + rm.Model + (rm.Branch.Length == 0 ? "" : " · " + rm.Branch) + " — click to open on claude.ai");
        r.Cursor = Cursors.Hand;
        ((Panel)r).Background = Brushes.Transparent;
        r.MouseLeftButtonUp += (o, e) => { try { System.Diagnostics.Process.Start("https://claude.ai/code/" + rm.Id); } catch { } };
        Ui.Add(col, 7, r);
      }
      return col;
    }

    FrameworkElement TipsStrip(List<Tip> tips) {
      bool folded = store.Collapsed.Contains("#tips");
      var col = new StackPanel();
      Ui.Add(col, 0, StripHeader("SAVE TOKENS", "#tips", tips.Count, null));
      if (folded) return col;
      var green = Palette.Of(Phase.Done);
      foreach (var t in tips) {
        var tip = t;
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = Ui.Icon(tip.Icon, 11, green);
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 2, 0, 0);
        g.Children.Add(icon);
        var inner = Ui.Col(6, Ui.T(tip.Text, 11, W(0.7), FontWeights.Normal, false, 0));
        if (tip.ActionTitle != null) {
          var pill = Pill(tip.ActionTitle, Ui.IcOpen, green, () => store.Jump(tip.ActionSession, tip.ActionPrompt), false, null, null);
          pill.HorizontalAlignment = HorizontalAlignment.Left;
          Ui.Add(inner, 6, pill);
        }
        Grid.SetColumn(inner, 1);
        g.Children.Add(inner);
        var x = Ui.Dismiss(() => { store.DismissedTips.Add(tip.Id); store.Notify(); });
        x.VerticalAlignment = VerticalAlignment.Top;
        x.Margin = new Thickness(6, 0, 0, 0);
        Grid.SetColumn(x, 2);
        g.Children.Add(x);
        Ui.Add(col, 8, Ui.Rounded(g, 10, A(green, 0.06), new Thickness(9)));
      }
      return col;
    }

    // MARK: toasts

    FrameworkElement ToastCard(Toast t, Session s) {
      string text = t.Text.Length == 0 ? store.Use(s).LastText : t.Text;
      bool replying = store.ReplyTarget == s.Id;
      var pc = Palette.Of(s.Phase);
      var col = new StackPanel();
      var badge = new Border {
        Child = Ui.T(Palette.Label(s.Phase).ToUpperInvariant(), 9, pc, FontWeights.Black), CornerRadius = new CornerRadius(10),
        Background = Ui.B(A(pc, 0.13)), Padding = new Thickness(7, 2, 7, 3), VerticalAlignment = VerticalAlignment.Center,
      };
      var name = Ui.T(s.Name, 13, Colors.White, FontWeights.SemiBold);
      name.MaxWidth = 170;
      Ui.Add(col, 0, Ui.Spread(new UIElement[] { Ui.StatusDot(s.Phase), name, badge }, new UIElement[] { Ui.Dismiss(() => store.Dismiss(t)) }, 9));
      if (s.Request != null) {
        Ui.Add(col, 10, RequestBlock(s, s.Request));
      } else {
        if (text.Length > 0) Ui.Add(col, 10, Ui.T(text, 12, W(0.68), FontWeights.Normal, false, 3));
        if (replying) {
          Ui.Add(col, 10, ReplyField(s));
        } else if (s.Phase != Phase.Ended) {
          FrameworkElement pills;
          if (t.Heavy) {
            pills = Ui.Row(6, Pill("Fresh session", Ui.IcBranch, Palette.Red, () => store.StartHandoff(s), true, null, null),
                              Pill("Compact", Ui.IcCompact, Palette.Red, () => store.Jump(s, "/compact"), false, null, null));
          } else {
            pills = Ui.Row(6, Pill("Reply", Ui.IcReply, Palette.Of(Phase.Done), () => store.StartReply(s), s.Phase == Phase.Done, null, null),
                              Pill("Open", Ui.IcOpen, Colors.White, () => store.Jump(s), false, null, null));
          }
          Ui.Add(col, 10, pills);
        }
      }
      return Wrap(Ui.Glass(col, 20, pc, new Thickness(14)), pc, t, () => store.Jump(s));
    }

    FrameworkElement NoticeCard(Toast t) {
      var c = t.Tone == "error" ? Palette.Red : t.Tone == "ok" ? Palette.Of(Phase.Done) : Palette.Of(Phase.Permission);
      var g = new Grid();
      g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
      g.ColumnDefinitions.Add(new ColumnDefinition());
      g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
      var icon = Ui.Icon(t.Tone == "error" ? Ui.IcWarning : t.Tone == "ok" ? Ui.IcCheck : Ui.IcGauge, 16, c);
      icon.VerticalAlignment = VerticalAlignment.Top;
      g.Children.Add(icon);
      var texts = Ui.Col(3, Ui.T(t.Title, 13, Colors.White, FontWeights.SemiBold), Ui.T(t.Text, 11.5, W(0.6), FontWeights.Normal, false, 0));
      if (t.Link != null) {
        var link = Pill(t.LinkTitle ?? "Open", Ui.IcOpen, c, () => store.OpenLink(t.Link), true, null, t.Link);
        link.HorizontalAlignment = HorizontalAlignment.Left;
        Ui.Add(texts, 8, link);
      }
      texts.Margin = new Thickness(11, 0, 8, 0);
      Grid.SetColumn(texts, 1);
      g.Children.Add(texts);
      var x = Ui.Dismiss(() => store.Dismiss(t));
      x.VerticalAlignment = VerticalAlignment.Top;
      Grid.SetColumn(x, 2);
      g.Children.Add(x);
      return Wrap(Ui.Glass(g, 20, c, new Thickness(14)), c, t, null);
    }

    FrameworkElement Wrap(FrameworkElement glass, Color accent, Toast t, Action click) {
      var g = new Grid { Width = 340 };
      g.Children.Add(glass);
      g.Children.Add(Ui.AccentBar(accent));
      g.MouseEnter += (o, e) => store.HoveredToast = t.Id;
      g.MouseLeave += (o, e) => { if (store.HoveredToast == t.Id) store.HoveredToast = null; };
      if (click != null) {
        g.Cursor = Cursors.Hand;
        g.MouseLeftButtonUp += (o, e) => { if (!InTextBox(e.OriginalSource)) click(); };
      }
      return g;
    }
  }
}
