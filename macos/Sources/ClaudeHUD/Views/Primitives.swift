import AppKit
import SwiftUI
import HUDCore

// MARK: - Visual primitives

struct HitKey: PreferenceKey {
  static var defaultValue: [CGRect] = []
  static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
  /// Marks this view as interactive; everywhere else clicks fall through to the apps below.
  func hitArea() -> some View {
    background(GeometryReader { Color.clear.preference(key: HitKey.self, value: [$0.frame(in: .global)]) })
  }

  func glass(_ r: CGFloat, tint: Color) -> some View { modifier(Glass(r: r, tint: tint)) }
}

struct Glass: ViewModifier {
  let r: CGFloat, tint: Color
  @AppStorage("glass") private var dark = 0.85
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
    return content.background {
      ZStack {
        shape.fill(.black.opacity(0.3)).shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        shape.fill(.ultraThinMaterial)
        shape.fill(LinearGradient(colors: [Color(white: 0.09).opacity(dark * 0.92), Color(white: 0.02).opacity(min(1, dark * 1.06))],
                                  startPoint: .top, endPoint: .bottom))
        shape.fill(RadialGradient(colors: [tint.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 280))
      }
    }
    .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.04), tint.opacity(0.4)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
  }
}

/// Slide in from the screen edge, scaling up as it fades in. (No blur: a resting blur(0) keeps the
/// whole view rendering off-screen on the CPU.)
struct EdgeSlide: ViewModifier {
  let x: CGFloat, scale: CGFloat
  func body(content: Content) -> some View {
    content.scaleEffect(scale, anchor: .trailing).offset(x: x).opacity(x == 0 ? 1 : 0)
  }
}

extension AnyTransition {
  static let edge = AnyTransition.asymmetric(
    insertion: .modifier(active: EdgeSlide(x: 380, scale: 0.9), identity: EdgeSlide(x: 0, scale: 1)),
    removal: .modifier(active: EdgeSlide(x: 380, scale: 0.97), identity: EdgeSlide(x: 0, scale: 1)))
}

/// Spinner (working) / sonar ping (needs you) drawn with Core Animation, so it costs no SwiftUI redraws.
struct Motion: NSViewRepresentable {
  let phase: Phase
  func makeNSView(context: Context) -> NSView {
    let v = NSView()
    v.wantsLayer = true
    let ring = CAShapeLayer()
    ring.fillColor = nil
    ring.strokeColor = NSColor(phase.color).cgColor
    ring.lineCap = .round
    let box = CGRect(x: 0, y: 0, width: 18, height: 18)
    ring.frame = box
    if phase == .working {
      ring.path = CGPath(ellipseIn: box.insetBy(dx: 1.5, dy: 1.5), transform: nil)
      ring.lineWidth = 1.6
      ring.strokeEnd = 0.68
      let a = CABasicAnimation(keyPath: "transform.rotation.z")
      a.fromValue = 0
      a.toValue = -2 * Double.pi
      a.duration = 1.1
      a.repeatCount = .infinity
      ring.add(a, forKey: "spin")
    } else {
      ring.path = CGPath(ellipseIn: box.insetBy(dx: 5, dy: 5), transform: nil)
      ring.lineWidth = 1.5
      let scale = CABasicAnimation(keyPath: "transform.scale")
      scale.fromValue = 1
      scale.toValue = 2.2
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0.9
      fade.toValue = 0
      let g = CAAnimationGroup()
      g.animations = [scale, fade]
      g.duration = 1.3
      g.timingFunction = CAMediaTimingFunction(name: .easeOut)
      g.repeatCount = .infinity
      ring.add(g, forKey: "ping")
    }
    v.layer?.addSublayer(ring)
    return v
  }
  func updateNSView(_ v: NSView, context: Context) {}
}

struct StatusDot: View {
  let phase: Phase
  var body: some View {
    ZStack {
      if phase == .working || phase == .permission { Motion(phase: phase).frame(width: 18, height: 18) }
      Circle().fill(RadialGradient(colors: [phase.color.opacity(0.45), .clear], center: .center, startRadius: 2, endRadius: 8))
        .frame(width: 16, height: 16)
      Circle().fill(phase.color).frame(width: 7, height: 7)
    }
    .frame(width: 18, height: 18)
    .id(phase)
  }
}

struct Pill: View {
  let title: String
  var icon: String?
  var tint: Color = .white
  var primary = false
  var key: String?
  let action: () -> Void
  @State private var hover = false
  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if let icon { Image(systemName: icon).font(.system(size: 9.5, weight: .bold)) }
        Text(title)
        if let key { Text(key).font(.system(size: 9, weight: .bold, design: .monospaced)).opacity(0.5) }
      }
      .font(.system(size: 11.5, weight: .semibold, design: .rounded))
      .foregroundStyle(primary ? Color.black.opacity(0.85) : tint.opacity(hover ? 1 : 0.85))
      .padding(.horizontal, 11).padding(.vertical, 6)
      .background(Capsule().fill(primary ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(hover ? 0.16 : 0.08))))
      .overlay(Capsule().strokeBorder(.white.opacity(primary ? 0.3 : 0.08)))
    }
    .buttonStyle(Press())
    .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
  }
}

struct Press: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
  }
}

/// Context-window ring: how close the session is to auto-compact.
struct ContextRing: View {
  let tokens: Int
  var body: some View {
    let window = tokens > 200_000 ? 1_000_000.0 : 200_000.0
    let f = min(1, Double(tokens) / window)
    let c = f > 0.85 ? red : f > 0.7 ? Phase.permission.color : Color.white.opacity(0.45)
    HStack(spacing: 4) {
      ZStack {
        Circle().stroke(.white.opacity(0.1), lineWidth: 2)
        Circle().trim(from: 0, to: f).stroke(c, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
      }
      .frame(width: 10, height: 10)
      Text(fmt(tokens)).font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(c)
    }
    .help("Context: \(fmt(tokens)) of \(fmt(Int(window))) (\(Int(f * 100))%)")
  }
}

