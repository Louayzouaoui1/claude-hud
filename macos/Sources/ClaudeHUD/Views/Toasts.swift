import AppKit
import SwiftUI
import HUDCore

// MARK: - Toasts

struct ToastCard: View {
  @ObservedObject var store: Store
  let t: Toast
  let s: Session
  var body: some View {
    let text = t.text.isEmpty ? store.usage(s).lastText : t.text
    let replying = store.replyTarget == s.id
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 9) {
        StatusDot(phase: s.phase)
        Text(s.name).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
        Text(s.phase.label.uppercased()).font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1.2)
          .foregroundStyle(s.phase.color)
          .padding(.horizontal, 7).padding(.vertical, 3)
          .background(Capsule().fill(s.phase.color.opacity(0.13)))
        Spacer()
        DismissButton { store.dismiss(t) }
      }
      if let r = s.request {
        RequestBlock(store: store, s: s, r: r)
      } else {
        if !text.isEmpty {
          Text(text).font(.system(size: 12, design: .rounded)).foregroundStyle(.white.opacity(0.68)).lineLimit(3)
        }
        if replying {
          ReplyField(store: store, s: s)
        } else if s.phase != .ended {
          HStack(spacing: 6) {
            if t.heavy {
              Pill(title: "Fresh session", icon: "arrow.triangle.branch", tint: red, primary: true) { store.handoff(s) }
              Pill(title: "Compact", icon: "arrow.down.right.and.arrow.up.left", tint: red) { store.jump(s, prompt: "/compact") }
            } else {
              Pill(title: "Reply", icon: "arrowshape.turn.up.left.fill", tint: Phase.done.color, primary: s.phase == .done) {
                withAnimation(Store.spring) { store.replyTarget = s.id }
              }
              Pill(title: "Open", icon: "arrow.up.right") { store.jump(s) }
            }
          }
        }
      }
    }
    .padding(14)
    .frame(width: 340)
    .glass(20, tint: s.phase.color)
    .overlay(alignment: .leading) { AccentBar(color: s.phase.color) }
    .contentShape(Rectangle())
    .onTapGesture { store.jump(s) }
    .onHover { store.hoveredToast = $0 ? t.id : nil }
    .hitArea()
  }
}

struct NoticeCard: View {
  @ObservedObject var store: Store
  let t: Toast
  var body: some View {
    let c = Phase.permission.color
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 16, weight: .semibold)).foregroundStyle(c)
      VStack(alignment: .leading, spacing: 3) {
        Text(t.title).font(.system(size: 13, weight: .semibold, design: .rounded))
        Text(t.text).font(.system(size: 11.5, design: .rounded)).foregroundStyle(.white.opacity(0.6))
      }
      Spacer()
      DismissButton { store.dismiss(t) }
    }
    .padding(14)
    .frame(width: 340)
    .glass(20, tint: c)
    .overlay(alignment: .leading) { AccentBar(color: c) }
    .onHover { store.hoveredToast = $0 ? t.id : nil }
    .hitArea()
  }
}

struct AccentBar: View {
  let color: Color
  var body: some View {
    Capsule().fill(color).frame(width: 3).padding(.vertical, 16).offset(x: 1)
      .background(Capsule().fill(LinearGradient(colors: [.clear, color.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)).frame(width: 12).padding(.vertical, 14))
  }
}

struct DismissButton: View {
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
        .frame(width: 20, height: 20).background(Circle().fill(.white.opacity(0.07)))
    }
    .buttonStyle(Press())
    .accessibilityLabel("Dismiss")
  }
}

