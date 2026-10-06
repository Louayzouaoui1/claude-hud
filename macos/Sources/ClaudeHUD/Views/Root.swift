import AppKit
import SwiftUI

// MARK: - Root

struct EdgeHandle: View {
  let phase: Phase?
  @State private var pulse = false
  var body: some View {
    let c = phase?.color ?? .white.opacity(0.35)
    Capsule().fill(c.gradient)
      .frame(width: 4, height: phase == .permission ? 90 : 64)
      .background(Capsule().fill(LinearGradient(colors: [.clear, c.opacity(0.4)], startPoint: .leading, endPoint: .trailing)).frame(width: 14).offset(x: -5))
      .opacity(phase == nil ? 0.45 : phase == .permission && pulse ? 0.45 : 1)
      .animation(phase == .permission ? .easeInOut(duration: 0.7).repeatForever() : .default, value: pulse)
      .onAppear { pulse = true }
      .id(phase)
  }
}

struct Root: View {
  @ObservedObject var store: Store
  @AppStorage("edgeGlow") private var edgeGlow = true
  var body: some View {
    ZStack(alignment: .trailing) {
      Color.clear
      if store.drawerOpen {
        Drawer(store: store).padding(.trailing, 12).padding(.vertical, 18).transition(.edge)
      } else if edgeGlow || store.urgent == .permission {
        EdgeHandle(phase: store.urgent).padding(.trailing, 1).transition(.opacity)
      }
    }
    .overlay(alignment: .topTrailing) {
      if !store.drawerOpen {
        VStack(alignment: .trailing, spacing: 10) {
          ForEach(store.toasts) { t in
            if t.session.isEmpty {
              NoticeCard(store: store, t: t).transition(.edge)
            } else if let s = store.sessions[t.session] {
              ToastCard(store: store, t: t, s: s).transition(.edge)
            }
          }
        }
        .padding(.top, 10).padding(.trailing, 12)
      }
    }
    .onPreferenceChange(HitKey.self) { store.hitRects = $0 }
    .environment(\.colorScheme, .dark)
    .foregroundStyle(.white)
  }
}

