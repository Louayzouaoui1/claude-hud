import AppKit
import SwiftUI
import HUDCore

// MARK: - Pieces shared by cards and toasts

struct RequestBlock: View {
  @ObservedObject var store: Store
  let s: Session
  let r: Request
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 6) {
        Image(systemName: "lock.shield.fill").foregroundStyle(Phase.permission.color)
        Text(r.tool).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
      }
      .font(.system(size: 11))
      Text(r.detail)
        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.78))
        .lineLimit(5).textSelection(.enabled)
        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.black.opacity(0.4)))
      HStack(spacing: 6) {
        Pill(title: "Allow", icon: "checkmark", tint: Phase.permission.color, primary: true) { store.answer(s, .allow) }
        if let always = r.always {
          Pill(title: "Always", icon: "checkmark.seal", tint: Phase.permission.color) { store.answer(s, .always) }
            .help("Allow and don't ask again: \(always)")
        }
        Pill(title: "Deny", icon: "xmark", tint: red) { store.answer(s, .deny) }
        Spacer(minLength: 0)
        let app = hostApp(s.pid)?.localizedName ?? editor.name
        Pill(title: app, icon: "arrow.up.right") { store.answer(s, .cursor) }
          .help("Answer in \(app) instead")
      }
      if let always = r.always {
        Text("Always = don't ask again for \(always)").font(.system(size: 9.5, design: .monospaced))
          .foregroundStyle(.white.opacity(0.35)).lineLimit(1).truncationMode(.middle)
      }
    }
  }
}

struct ReplyField: View {
  @ObservedObject var store: Store
  let s: Session
  @State private var draft = ""
  @FocusState private var focused: Bool
  var body: some View {
    HStack(spacing: 8) {
      TextField("Reply to \(s.name)…", text: $draft)
        .textFieldStyle(.plain).font(.system(size: 12.5, design: .rounded))
        .focused($focused)
        .onSubmit { store.jump(s, prompt: draft) }
        .onExitCommand { withAnimation(Store.spring) { store.replyTarget = nil } }
      Image(systemName: "return").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(draft.isEmpty ? 0.25 : 0.7))
    }
    .padding(.horizontal, 11).padding(.vertical, 9)
    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.black.opacity(0.45)))
    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Phase.done.color.opacity(focused ? 0.55 : 0.15)))
    .onAppear {
      hudPanel?.makeKey()
      DispatchQueue.main.async { focused = true }
    }
  }
}

