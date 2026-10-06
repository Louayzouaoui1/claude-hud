using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;

namespace ClaudeHud {
  /// Visual primitives, built in code (no XAML: the stock compiler can't build it).
  static class Ui {
    public static readonly FontFamily Sans = new FontFamily("Segoe UI Variable Text, Segoe UI");
    public static readonly FontFamily Mono = new FontFamily("Cascadia Mono, Consolas");
    public static readonly FontFamily Icons = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets");

    // Segoe Fluent / MDL2 glyphs
    public const string IcCheck = "", IcClose = "", IcLock = "", IcGear = "", IcAdd = "",
      IcSearch = "", IcMoon = "", IcChevron = "", IcReply = "", IcOpen = "", IcPower = "",
      IcFlame = "", IcCompact = "", IcBranch = "", IcPeople = "", IcArchive = "", IcUndo = "",
      IcGlobe = "", IcLaptop = "", IcRemote = "", IcSparkle = "", IcEnter = "", IcSeal = "",
      IcGauge = "", IcContinue = "", IcQuestion = "", IcWarning = "";

    public static SolidColorBrush B(Color c) {
      var b = new SolidColorBrush(c);
      b.Freeze();
      return b;
    }

    public static Color A(Color c, double a) { return Palette.A(c, a); }
    public static Color W(double a) { return Palette.W(a); }

    public static TextBlock T(string text, double size, Color color, FontWeight weight, bool mono = false, int lines = 1) {
      var t = new TextBlock {
        Text = text ?? "", FontSize = size, Foreground = B(color), FontWeight = weight,
        FontFamily = mono ? Mono : Sans, VerticalAlignment = VerticalAlignment.Center,
      };
      if (lines == 1) {
        t.TextTrimming = TextTrimming.CharacterEllipsis;
      } else if (lines > 1) {
        t.TextWrapping = TextWrapping.Wrap;
        t.TextTrimming = TextTrimming.CharacterEllipsis;
        t.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        t.LineHeight = Math.Round(size * 1.38);
        t.MaxHeight = t.LineHeight * lines;
      } else {
        t.TextWrapping = TextWrapping.Wrap;
      }
      return t;
    }

    public static TextBlock T(string text, double size, Color color) { return T(text, size, color, FontWeights.Normal); }

    public static TextBlock Icon(string glyph, double size, Color color) {
      return new TextBlock { Text = glyph, FontFamily = Icons, FontSize = size, Foreground = B(color), VerticalAlignment = VerticalAlignment.Center };
    }

    public static StackPanel Row(double gap, params UIElement[] items) {
      var p = new StackPanel { Orientation = Orientation.Horizontal };
      foreach (var i in items) {
        if (i == null) continue;
        var fe = i as FrameworkElement;
        if (fe != null && p.Children.Count > 0) fe.Margin = new Thickness(gap, fe.Margin.Top, fe.Margin.Right, fe.Margin.Bottom);
        p.Children.Add(i);
      }
      return p;
    }

    public static StackPanel Col(double gap, params UIElement[] items) {
      var p = new StackPanel();
      foreach (var i in items) Add(p, gap, i);
      return p;
    }

    public static void Add(StackPanel p, double gap, UIElement i) {
      if (i == null) return;
      var fe = i as FrameworkElement;
      if (fe != null && p.Children.Count > 0) fe.Margin = new Thickness(fe.Margin.Left, gap, fe.Margin.Right, fe.Margin.Bottom);
      p.Children.Add(i);
    }

    /// Left items, then a flexible gap, then right items.
    public static DockPanel Spread(UIElement[] left, UIElement[] right, double gap = 6) {
      var d = new DockPanel { LastChildFill = true };
      var r = Row(gap, right);
      DockPanel.SetDock(r, Dock.Right);
      r.Margin = new Thickness(gap, 0, 0, 0);
      d.Children.Add(r);
      var l = Row(gap, left);
      d.Children.Add(l);
      return d;
    }

    public static Border Rounded(UIElement child, double r, Color bg, Thickness pad) {
      return new Border { Child = child, CornerRadius = new CornerRadius(r), Background = B(bg), Padding = pad };
    }

    static void Slow(Timeline t) { Timeline.SetDesiredFrameRate(t, 15); }  // a layered window redraws whole: keep motion cheap

    /// WPF keeps "forever" animations ticking even after their element is thrown away, which keeps the render
    /// loop busy. Every looping animation registers its stop here; StopAnimations() runs before each rebuild.
    static readonly System.Collections.Generic.List<Action> running = new System.Collections.Generic.List<Action>();

    public static void StopAnimations() {
      foreach (var stop in running) stop();
      running.Clear();
    }

    /// Spinner (working) / sonar ping (needs you) around a phase-colored dot. Motion only when `animate`:
    /// every frame repaints the whole transparent window, so idle surfaces (toasts, edge) stay still.
    public static Grid StatusDot(Phase p, bool animate = false) {
      var c = Palette.Of(p);
      var g = new Grid { Width = 18, Height = 18, VerticalAlignment = VerticalAlignment.Center };
      if (!animate && (p == Phase.Working || p == Phase.Permission)) {
        g.Children.Add(new Ellipse { Width = 15, Height = 15, Stroke = B(A(c, 0.6)), StrokeThickness = 1.4 });
      } else if (p == Phase.Working) {
        var arc = Arc(0.68, 15, 1.6, c);
        arc.HorizontalAlignment = HorizontalAlignment.Center;
        arc.VerticalAlignment = VerticalAlignment.Center;
        var rot = new RotateTransform(0, 7.5, 7.5);
        arc.RenderTransform = rot;
        var a = new DoubleAnimation(0, -360, TimeSpan.FromSeconds(1.1)) { RepeatBehavior = RepeatBehavior.Forever };
        Slow(a);
        rot.BeginAnimation(RotateTransform.AngleProperty, a);
        running.Add(() => rot.BeginAnimation(RotateTransform.AngleProperty, null));
        g.Children.Add(arc);
      } else if (p == Phase.Permission) {
        var ring = new Ellipse { Width = 8, Height = 8, Stroke = B(c), StrokeThickness = 1.5, RenderTransformOrigin = new Point(0.5, 0.5) };
        var sc = new ScaleTransform(1, 1);
        ring.RenderTransform = sc;
        var grow = new DoubleAnimation(1, 2.2, TimeSpan.FromSeconds(1.3)) { RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } };
        var fade = new DoubleAnimation(0.9, 0, TimeSpan.FromSeconds(1.3)) { RepeatBehavior = RepeatBehavior.Forever };
        Slow(grow);
        Slow(fade);
        sc.BeginAnimation(ScaleTransform.ScaleXProperty, grow);
        sc.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
        ring.BeginAnimation(UIElement.OpacityProperty, fade);
        running.Add(() => {
          sc.BeginAnimation(ScaleTransform.ScaleXProperty, null);
          sc.BeginAnimation(ScaleTransform.ScaleYProperty, null);
          ring.BeginAnimation(UIElement.OpacityProperty, null);
        });
        g.Children.Add(ring);
      }
      var glow = new RadialGradientBrush(A(c, 0.45), A(c, 0));
      glow.Freeze();
      g.Children.Add(new Ellipse { Width = 16, Height = 16, Fill = glow });
      g.Children.Add(new Ellipse { Width = 7, Height = 7, Fill = B(c) });
      return g;
    }

    /// A circular arc from 12 o'clock, clockwise, covering `f` of the circle.
    public static Shape Arc(double f, double size, double thick, Color c) {
      f = Math.Max(0, Math.Min(0.9999, f));
      double r = (size - thick) / 2, cx = size / 2, cy = size / 2;
      double ang = f * 2 * Math.PI;
      var start = new Point(cx, cy - r);
      var end = new Point(cx + r * Math.Sin(ang), cy - r * Math.Cos(ang));
      var fig = new PathFigure { StartPoint = start, IsClosed = false };
      fig.Segments.Add(new ArcSegment(end, new Size(r, r), 0, f > 0.5, SweepDirection.Clockwise, true));
      var geo = new PathGeometry();
      geo.Figures.Add(fig);
      return new Path { Data = geo, Stroke = B(c), StrokeThickness = thick, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, Width = size, Height = size };
    }

    /// Context-window ring: how close the session is to auto-compact.
    public static FrameworkElement ContextRing(long tokens) {
      double window = tokens > 200000 ? 1000000 : 200000;
      double f = Math.Min(1, tokens / window);
      var c = f > 0.85 ? Palette.Red : f > 0.7 ? Palette.Of(Phase.Permission) : W(0.45);
      var ring = new Grid { Width = 10, Height = 10 };
      ring.Children.Add(new Ellipse { Stroke = B(W(0.1)), StrokeThickness = 2 });
      if (f > 0) ring.Children.Add(Arc(f, 10, 2, c));
      var row = Row(4, ring, T(Fmt.N(tokens), 9.5, c, FontWeights.Medium, true));
      row.HorizontalAlignment = HorizontalAlignment.Right;
      row.ToolTip = "Context: " + Fmt.N(tokens) + " of " + Fmt.N((long)window) + " (" + (int)(f * 100) + "%)";
      return row;
    }

    public static Border Pill(string title, string glyph, Color tint, Action click, bool primary = false, string key = null) {
      var fg = primary ? A(Colors.Black, 0.85) : A(tint, 0.88);
      var label = T(title, 11.5, fg, FontWeights.SemiBold);
      var sp = Row(5, glyph == null ? null : Icon(glyph, 10, fg), label,
                   key == null ? null : T(key, 9, A(fg, 0.5), FontWeights.Bold, true));
      Brush rest, hover;
      if (primary) {
        var g = new LinearGradientBrush(tint, Color.FromRgb((byte)(tint.R * 0.82), (byte)(tint.G * 0.82), (byte)(tint.B * 0.82)), 90);
        g.Freeze();
        rest = g;
        hover = B(tint);
      } else {
        rest = B(A(tint, 0.08));
        hover = B(A(tint, 0.17));
      }
      var b = new Border {
        Child = sp, CornerRadius = new CornerRadius(20), Padding = new Thickness(11, 5, 11, 6), Background = rest,
        BorderBrush = B(W(primary ? 0.3 : 0.08)), BorderThickness = new Thickness(1), Cursor = Cursors.Hand,
        RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = new ScaleTransform(1, 1), Tag = label,
      };
      b.MouseEnter += (o, e) => b.Background = hover;
      b.MouseLeave += (o, e) => { b.Background = rest; b.RenderTransform = new ScaleTransform(1, 1); };
      b.MouseLeftButtonDown += (o, e) => { e.Handled = true; b.RenderTransform = new ScaleTransform(0.94, 0.94); };
      b.MouseLeftButtonUp += (o, e) => {
        e.Handled = true;
        b.RenderTransform = new ScaleTransform(1, 1);
        click();
      };
      return b;
    }

    /// Small round icon button.
    public static Border Round(string glyph, double size, Color fg, Color bg, Action click, string tip) {
      var b = new Border {
        Width = size, Height = size, CornerRadius = new CornerRadius(size / 2), Background = B(bg), Cursor = Cursors.Hand,
        Child = new TextBlock { Text = glyph, FontFamily = Icons, FontSize = size * 0.45, Foreground = B(fg),
                                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        ToolTip = tip, VerticalAlignment = VerticalAlignment.Center,
      };
      var rest = b.Background;
      var hover = B(A(Colors.White, Math.Min(1, bg.A / 255.0 + 0.08)));
      b.MouseEnter += (o, e) => b.Background = hover;
      b.MouseLeave += (o, e) => b.Background = rest;
      b.MouseLeftButtonDown += (o, e) => e.Handled = true;
      b.MouseLeftButtonUp += (o, e) => { e.Handled = true; click(); };
      return b;
    }

    public static Border Dismiss(Action click) { return Round(IcClose, 20, W(0.5), W(0.07), click, "Dismiss"); }

    public static FrameworkElement Chevron(bool folded) {
      var i = Icon(IcChevron, 8, W(0.4));
      i.RenderTransformOrigin = new Point(0.5, 0.5);
      i.RenderTransform = new RotateTransform(folded ? 0 : 90);
      return i;
    }

    public static FrameworkElement Caps(string text, Color color) {
      // No letter-spacing in WPF text: thin spaces stand in for the tracking.
      return T(string.Join(" ", text.ToCharArray()), 9.5, color, FontWeights.Bold);
    }

    public static FrameworkElement LimitBar(string title, Limit limit) {
      double pct = Math.Min(100, limit == null ? 0 : limit.Pct);
      Color[] colors = pct > 85 ? new[] { Palette.Rgb(1, 0.4, 0.5), Palette.Rgb(1, 0.25, 0.4) }
                     : pct > 60 ? new[] { Palette.Rgb(1, 0.8, 0.35), Palette.Of(Phase.Permission) }
                     : Palette.CurrentTheme;
      var head = Spread(new UIElement[] { Caps(title, W(0.45)) },
                        new UIElement[] { T(limit == null ? "—" : (int)Math.Round(limit.Pct) + "%", 13, Colors.White, FontWeights.SemiBold, true) });
      var track = new Grid { Height = 5, Margin = new Thickness(0, 6, 0, 0) };
      track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(2.5, pct), GridUnitType.Star) });
      track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(100 - Math.Max(2.5, pct), GridUnitType.Star) });
      var bg = new Border { CornerRadius = new CornerRadius(3), Background = B(W(0.07)) };
      Grid.SetColumnSpan(bg, 2);
      track.Children.Add(bg);
      var fill = new Border {
        CornerRadius = new CornerRadius(3), Background = new LinearGradientBrush(colors[0], colors[1], 0),
        Effect = new DropShadowEffect { Color = colors[1], BlurRadius = 8, ShadowDepth = 0, Opacity = 0.6 },
      };
      track.Children.Add(fill);
      var col = Col(0, head, track);
      var sub = T(limit == null ? "waiting for data" : "resets in " + Fmt.Span((limit.Resets - DateTime.UtcNow).TotalSeconds) + " · " + Fmt.Clock(limit.Resets),
                  9.5, W(0.4), FontWeights.Medium);
      sub.Margin = new Thickness(0, 6, 0, 0);
      col.Children.Add(sub);
      if (limit != null && limit.Out.HasValue) {
        col.Children.Add(T("out ≈ " + Fmt.Clock(limit.Out.Value) + " at this pace", 9.5, A(Palette.Of(Phase.Permission), 0.9), FontWeights.Medium));
      } else if (limit != null && limit.Paced) {
        col.Children.Add(T("lasts until reset at this pace", 9.5, A(Palette.Of(Phase.Done), 0.7), FontWeights.Medium));
      }
      return col;
    }

    /// Dark glass panel: no backdrop blur on Windows layered windows, so it's a deep tinted gradient instead.
    public static Border Glass(UIElement content, double r, Color tint, Thickness pad) {
      double dark = Math.Max(0.5, Math.Min(1, Prefs.Num("glass")));
      double top = 0.86 + (dark - 0.5) * 0.26, bottom = Math.Min(1, top + 0.04);
      var grid = new Grid();
      grid.Children.Add(new Border {
        CornerRadius = new CornerRadius(r),
        Background = new LinearGradientBrush(A(Palette.Rgb(0.09, 0.095, 0.11), top), A(Palette.Rgb(0.02, 0.022, 0.03), bottom), 90),
      });
      var radial = new RadialGradientBrush { GradientOrigin = new Point(0, 0), Center = new Point(0, 0), RadiusX = 1.1, RadiusY = 0.7 };
      radial.GradientStops.Add(new GradientStop(A(tint, 0.2), 0));
      radial.GradientStops.Add(new GradientStop(A(tint, 0), 1));
      grid.Children.Add(new Border { CornerRadius = new CornerRadius(r), Background = radial });
      grid.Children.Add(new Border { Padding = pad, Child = content });
      var stroke = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
      stroke.GradientStops.Add(new GradientStop(W(0.24), 0));
      stroke.GradientStops.Add(new GradientStop(W(0.04), 0.5));
      stroke.GradientStops.Add(new GradientStop(A(tint, 0.4), 1));
      grid.Children.Add(new Border { CornerRadius = new CornerRadius(r), BorderThickness = new Thickness(1), BorderBrush = stroke, IsHitTestVisible = false });
      return new Border {
        Child = grid, Margin = new Thickness(0, 0, 0, 0),
        Effect = new DropShadowEffect { Color = Colors.Black, BlurRadius = 18, ShadowDepth = 6, Direction = 270, Opacity = 0.45 },
      };
    }

    /// Colored bar on a toast's left edge.
    public static FrameworkElement AccentBar(Color c) {
      var g = new Grid { HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(-1, 16, 0, 16), IsHitTestVisible = false };
      var glow = new LinearGradientBrush(A(c, 0.35), A(c, 0), 0);
      g.Children.Add(new Border { Width = 12, Background = glow, CornerRadius = new CornerRadius(6) });
      g.Children.Add(new Border { Width = 3, Background = B(c), CornerRadius = new CornerRadius(2), HorizontalAlignment = HorizontalAlignment.Left });
      return g;
    }

    public static void SlideIn(FrameworkElement e, double delay = 0) {
      var t = new TranslateTransform(36, 0);
      e.RenderTransform = t;
      e.Opacity = 0;
      var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
      var x = new DoubleAnimation(36, 0, TimeSpan.FromMilliseconds(320)) { BeginTime = TimeSpan.FromSeconds(delay), EasingFunction = ease };
      var o = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(240)) { BeginTime = TimeSpan.FromSeconds(delay) };
      t.BeginAnimation(TranslateTransform.XProperty, x);
      e.BeginAnimation(UIElement.OpacityProperty, o);
    }

    public static TextBox Field(string text, string hint, double size) {
      var tb = new TextBox {
        Text = text ?? "", FontSize = size, FontFamily = Sans, Foreground = B(Colors.White), CaretBrush = B(Colors.White),
        Background = Brushes.Transparent, BorderThickness = new Thickness(0), VerticalContentAlignment = VerticalAlignment.Center,
        SelectionBrush = B(Palette.Of(Phase.Working)),
      };
      // Placeholder: a hint shown while the box is empty.
      var hintBlock = T(hint, size, W(0.35));
      hintBlock.IsHitTestVisible = false;
      hintBlock.Margin = new Thickness(2, 0, 0, 0);
      hintBlock.Visibility = tb.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
      tb.TextChanged += (o, e) => hintBlock.Visibility = tb.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
      tb.Tag = hintBlock;
      return tb;
    }

    public static Grid WithHint(TextBox tb) {
      var g = new Grid();
      g.Children.Add((UIElement)tb.Tag);
      g.Children.Add(tb);
      return g;
    }
  }
}
