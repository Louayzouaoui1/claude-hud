import AppKit
import SwiftUI
import HUDCore

// MARK: - Drawer

struct SessionCard: View {
  @ObservedObject var store: Store
  let s: Session
  let index: Int
  let selected: Bool
  @State private var hover = false
  @State private var shown = false
  @State private var confirmEnd = false

  var body: some View {
    let u = store.usage(s)
    let replying = store.replyTarget == s.id
    let lit = hover || selected
    let heavy = store.heavy(s)
    let burn = store.burn[s.id] ?? 0
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 10) {
        StatusDot(phase: s.phase)
        VStack(alignment: .leading, spacing: 2) {
          Text(s.name).font(.system(size: 13.5, weight: .semibold, design: .rounded)).lineLimit(1)
          HStack(spacing: 5) {
            Text(s.phase.label).foregroundStyle(s.phase.color)
            Text("·")
            TimelineView(.everyMinute) { _ in Text(s.since.timeIntervalSinceNow > -60 ? "just now" : span(-s.since.timeIntervalSinceNow)) }
          }
          .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.45))
        }
        Spacer(minLength: 6)
        VStack(alignment: .trailing, spacing: 3) {
          Text(fmt(u.tokens)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
            .help("\(fmt(u.tokens)) tokens · \(money(u.cost)) at API prices (\(money(u.todayCost)) today)")
          ContextRing(tokens: u.context)
          if burn >= 50_000 {
            Text("+\(fmt(burn))/10m").font(.system(size: 9, weight: .semibold, design: .monospaced))
              .foregroundStyle(heavy != nil ? red : .white.opacity(0.35))
              .help("Tokens used in the last 10 minutes")
          }
        }
      }
      if let from = store.predecessor(of: s.id) {
        Label("continues \(from.name)", systemImage: "arrow.turn.down.right")
          .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(Color(red: 0.75, green: 0.65, blue: 1))
      }
      if !s.agents.isEmpty {
        HStack(spacing: 6) {
          Image(systemName: "person.2.wave.2.fill").font(.system(size: 9.5)).foregroundStyle(Theme.aurora.colors[0])
          Text("\(s.agents.count) agent\(s.agents.count == 1 ? "" : "s") · \(Set(s.agents.values).sorted().joined(separator: ", "))")
            .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
        }
      }
      if let heavy {
        VStack(alignment: .leading, spacing: 7) {
          HStack(spacing: 6) {
            Image(systemName: "flame.fill").foregroundStyle(red)
            Text(heavy).foregroundStyle(red)
          }
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          HStack(spacing: 6) {
            Pill(title: "Compact", icon: "arrow.down.right.and.arrow.up.left", tint: red) { store.jump(s, prompt: "/compact") }
              .help("Open the tab with /compact ready to send")
            Pill(title: "Fresh session", icon: "arrow.triangle.branch", tint: red, primary: true) { store.handoff(s) }
              .help("New tab in this workspace, seeded with a handoff note from this one")
          }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(red.opacity(0.08)))
      }
      if s.phase == .working, !s.activity.isEmpty {
        HStack(spacing: 6) {
          Rectangle().fill(Phase.working.color.opacity(0.7)).frame(width: 2, height: 12)
          Text(s.activity).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
            .lineLimit(1).truncationMode(.middle)
        }
        .transition(.opacity)
      }
      if let r = s.request {
        RequestBlock(store: store, s: s, r: r)
      } else if s.phase == .done, !u.lastText.isEmpty {
        Text(u.lastText).font(.system(size: 11.5, design: .rounded)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
      }
      if (lit || replying) && s.request == nil {
        HStack(spacing: 6) {
          Pill(title: "Open", icon: "arrow.up.right", key: selected ? "↩" : nil) { store.jump(s) }
          if s.phase != .ended {
            Pill(title: "Reply", icon: "arrowshape.turn.up.left.fill", tint: Phase.done.color, key: selected ? "R" : nil) {
              withAnimation(Store.spring) { store.replyTarget = replying ? nil : s.id }
            }
          }
          Spacer()
          if s.phase != .ended {
            Pill(title: confirmEnd ? "End session?" : "End", icon: "power", tint: red) {
              if confirmEnd { store.end(s) } else {
                withAnimation(.easeOut(duration: 0.15)) { confirmEnd = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { confirmEnd = false } }
              }
            }
          }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
      if replying { ReplyField(store: store, s: s).transition(.opacity.combined(with: .scale(scale: 0.97))) }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(lit ? 0.075 : 0.04)))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
      .strokeBorder(heavy != nil && s.phase != .permission ? red.opacity(0.55)
                    : s.phase.color.opacity(s.phase == .permission ? 0.5 : selected ? 0.45 : hover ? 0.22 : 0.07)))
    .contentShape(RoundedRectangle(cornerRadius: 16))
    .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    .onTapGesture { store.jump(s) }
    .help(s.cwd)
    .offset(x: shown ? 0 : 36).opacity(shown ? 1 : 0)
    .onAppear { withAnimation(Store.spring.delay(0.05 + Double(index) * 0.045)) { shown = true } }
  }
}

struct LimitBar: View {
  let title: String
  let limit: Limit?
  @AppStorage("theme") private var theme = "aurora"
  var body: some View {
    let pct = min(100, limit?.pct ?? 0)
    let colors: [Color] = pct > 85 ? [Color(red: 1, green: 0.4, blue: 0.5), Color(red: 1, green: 0.25, blue: 0.4)]
      : pct > 60 ? [Color(red: 1, green: 0.8, blue: 0.35), Phase.permission.color]
      : (Theme(rawValue: theme) ?? .aurora).colors
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(1.4).foregroundStyle(.white.opacity(0.45))
        Spacer()
        Text(limit.map { "\(Int($0.pct.rounded()))%" } ?? "—").font(.system(size: 13, weight: .semibold, design: .monospaced))
      }
      GeometryReader { g in
        ZStack(alignment: .leading) {
          Capsule().fill(.white.opacity(0.07))
          Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
            .frame(width: max(5, g.size.width * pct / 100))
            .shadow(color: colors[1].opacity(0.6), radius: 5)
        }
      }
      .frame(height: 5)
      Group {
        Text(limit.map { "resets in \(span($0.resets.timeIntervalSinceNow)) · \(clock($0.resets))" } ?? "waiting for data")
          .foregroundStyle(.white.opacity(0.4))
        if let l = limit, let out = l.out {
          Text("out ≈ \(clock(out)) at this pace").foregroundStyle(Phase.permission.color.opacity(0.9))
        } else if let l = limit, l.paced {
          Text("lasts until reset at this pace").foregroundStyle(Phase.done.color.opacity(0.7))
        }
      }
      .font(.system(size: 9.5, weight: .medium, design: .rounded))
    }
  }
}

struct WorkspaceHeader: View {
  @ObservedObject var store: Store
  let cwd: String
  let sessions: [Session]
  @State private var hover = false
  var body: some View {
    let tokens = sessions.reduce(0) { $0 + store.usage($1).tokens }
    let cost = sessions.reduce(0.0) { $0 + store.usage($1).todayCost }
    let folded = store.collapsed.contains(cwd)
    HStack(spacing: 6) {
      Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.4))
        .rotationEffect(.degrees(folded ? 0 : 90))
      Text((cwd as NSString).lastPathComponent.uppercased())
        .font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(1.3).foregroundStyle(.white.opacity(0.55))
        .lineLimit(1).fixedSize()
      if folded {
        HStack(spacing: 3) { ForEach(sessions) { Circle().fill($0.phase.color).frame(width: 5, height: 5) } }
      } else {
        Text("\(sessions.count)").font(.system(size: 9.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
      }
      Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
      if hover {
        Button { store.launch(cwd) } label: {
          Image(systemName: "plus").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white.opacity(0.7))
            .frame(width: 16, height: 16).background(Circle().fill(.white.opacity(0.1)))
        }
        .buttonStyle(Press()).help("New session in \((cwd as NSString).lastPathComponent)")
      }
      Text("\(money(cost)) · \(fmt(tokens))").font(.system(size: 9.5, weight: .semibold, design: .monospaced))
        .foregroundStyle(sessions.contains { store.heavy($0) != nil } ? red : .white.opacity(0.4))
        .help("Today at API prices · tokens across these sessions")
    }
    .padding(.horizontal, 4).padding(.vertical, 2)
    .contentShape(Rectangle())
    .onTapGesture { store.toggleCollapse(cwd) }
    .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    .help(cwd)
  }
}

struct Drawer: View {
  @ObservedObject var store: Store
  @AppStorage("theme") private var theme = "aurora"
  @AppStorage("groupByWorkspace") private var groupByWorkspace = true
  @AppStorage("idleMinutes") private var idleMinutes = 10.0
  @AppStorage("firstPrompt") private var firstPrompt = ""
  @AppStorage("autoEndOld") private var autoEndOld = true
  @AppStorage("autoSend") private var autoSend = true
  @State private var axTrusted = AXIsProcessTrusted()
  @AppStorage("syncDevices") private var syncDevices = true
  var body: some View {
    let list = store.filtered
    let vis = store.visible
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center, spacing: 8) {
        StatusDot(phase: store.urgent ?? .ready)
        Text("CLAUDE").font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(3).foregroundStyle(.white.opacity(0.75))
        Text("\(list.filter { $0.phase != .ended }.count) live")
          .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.4))
        Menu {
          Section("New session in…") {
            ForEach(store.recent, id: \.self) { c in Button((c as NSString).lastPathComponent) { store.launch(c) } }
          }
        } label: {
          Image(systemName: "plus").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white.opacity(0.5))
            .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.06)))
        }
        .menuStyle(.button).buttonStyle(Press()).menuIndicator(.hidden).fixedSize()
        .help("New session")
        Button { SettingsWindow.show(store) } label: {
          Image(systemName: "gearshape.fill").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.35))
            .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.04)))
        }
        .buttonStyle(Press())
        .help("Settings")
        Button { store.dnd.toggle() } label: {
          Image(systemName: store.quiet ? "moon.fill" : "moon")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(store.quiet ? Color(red: 0.7, green: 0.6, blue: 1) : .white.opacity(0.35))
            .frame(width: 22, height: 22)
            .background(Circle().fill(.white.opacity(store.quiet ? 0.1 : 0.04)))
        }
        .buttonStyle(Press())
        .help(store.inMeeting ? "Quiet: you're in a Zoom meeting" : store.dnd ? "Do not disturb is on" : "Do not disturb")
        Spacer()
        VStack(alignment: .trailing, spacing: 1) {
          Text(money(store.todayCost)).font(.system(size: 16, weight: .semibold, design: .monospaced))
            .contentTransition(.numericText())
            .help("Today's usage priced at API rates (your plan isn't billed this way)")
          Text("\(fmt(store.todayTokens)) tokens today").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.4))
        }
      }
      .contextMenu {
        Button("Settings…") { SettingsWindow.show(store) }
        Button("Quit Claude HUD") { NSApp.terminate(nil) }
      }

      HStack(spacing: 16) {
        LimitBar(title: "5-HOUR", limit: store.fiveHour)
        LimitBar(title: "WEEKLY", limit: store.week)
      }

      if !store.devices.isEmpty || !store.remote.isEmpty || store.elsewhere > 0 { DevicesStrip(store: store) }
      if !store.tips.isEmpty { TipsStrip(store: store) }

      Rectangle().fill(LinearGradient(colors: [.clear, .white.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing))
        .frame(height: 1)

      if store.pinned || !store.query.isEmpty { SearchField(store: store) }

      if list.isEmpty {
        VStack(spacing: 6) {
          Image(systemName: store.query.isEmpty ? "sparkles" : "magnifyingglass").font(.system(size: 18)).foregroundStyle(.white.opacity(0.3))
          Text(store.query.isEmpty ? "No sessions yet" : "No session matches “\(store.query)”")
            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
      } else {
        let grouped = groupByWorkspace && store.query.isEmpty && Set(list.map(\.cwd)).count > 1
        let folders = list.map(\.cwd).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let cards = VStack(spacing: 8) {
          if grouped {
            ForEach(folders, id: \.self) { c in
              let group = list.filter { $0.cwd == c }
              WorkspaceHeader(store: store, cwd: c, sessions: group).padding(.top, c == folders.first ? 0 : 6)
              if !store.collapsed.contains(c) {
                ForEach(group) { s in card(s, vis) }
              }
            }
          } else {
            ForEach(list) { s in card(s, vis) }
          }
        }
        ViewThatFits(in: .vertical) {
          cards
          ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) { cards }
              .defaultScrollAnchor(.top)
              .onChange(of: store.selected) { _, i in
                if vis.indices.contains(i) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(vis[i].id, anchor: .center) } }
              }
          }
        }
      }
      if store.pinned {
        Text("↑↓  ↩ open  A allow  D deny  R reply  / search")
          .font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
          .frame(maxWidth: .infinity)
      }
    }
    .padding(16)
    .frame(width: 340)
    .glass(24, tint: store.urgent == .permission ? Phase.permission.color : (Theme(rawValue: theme) ?? .aurora).colors[1])
    .hitArea()
  }

  @ViewBuilder func card(_ s: Session, _ vis: [Session]) -> some View {
    if store.retired[s.id] != nil {
      RetiredCard(store: store, s: s)
    } else {
      let i = vis.firstIndex { $0.id == s.id } ?? 0
      SessionCard(store: store, s: s, index: i, selected: store.pinned && vis.indices.contains(store.selected) && vis[store.selected].id == s.id)
    }
  }
}

/// A session that was handed off to a fresh one: clearly retired, one tap to close it.
struct RetiredCard: View {
  @ObservedObject var store: Store
  let s: Session
  @State private var hover = false
  var body: some View {
    let next = store.successor(of: s.id)
    let violet = Color(red: 0.75, green: 0.65, blue: 1)
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "archivebox.fill").font(.system(size: 11)).foregroundStyle(violet.opacity(0.8)).frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(s.name).font(.system(size: 13, weight: .semibold, design: .rounded)).strikethrough(color: .white.opacity(0.4))
            .foregroundStyle(.white.opacity(0.55)).lineLimit(1)
          Text(next.map { "Handed off → \($0.name)" } ?? "Handed off · waiting for the new session")
            .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(violet)
        }
        Spacer()
        Text(fmt(store.usage(s).tokens)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.35))
      }
      if hover {
        HStack(spacing: 6) {
          if let next { Pill(title: "Go to new", icon: "arrow.up.right", tint: violet) { store.jump(next) } }
          Pill(title: "Undo", icon: "arrow.uturn.backward") { store.undoHandoff(s) }
          Spacer()
          if s.phase != .ended { Pill(title: "Close old", icon: "power", tint: red, primary: true) { store.end(s) } }
        }
        .transition(.opacity)
      }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(violet.opacity(hover ? 0.08 : 0.04)))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(violet.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    .contentShape(RoundedRectangle(cornerRadius: 16))
    .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    .help("This session was continued in a fresh one — you don't need it anymore")
  }
}

struct SearchField: View {
  @ObservedObject var store: Store
  @FocusState private var focused: Bool
  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
      TextField("Search sessions  ( / )", text: $store.query)
        .textFieldStyle(.plain).font(.system(size: 12, design: .rounded))
        .focused($focused)
        .onSubmit { if let s = store.visible.first { store.jump(s) } }
        .onExitCommand { store.query = ""; focused = false }
      if !store.query.isEmpty {
        Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.35)) }
          .buttonStyle(.plain).accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 7)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.35)))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(focused ? 0.25 : 0.06)))
    .onChange(of: store.focusSearch) { _, v in if v { hudPanel?.makeKey(); focused = true; store.focusSearch = false } }
    .onChange(of: focused) { _, v in store.searching = v }
  }
}

struct DevicesStrip: View {
  @ObservedObject var store: Store
  var body: some View {
    let folded = store.collapsed.contains("#devices")
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.4))
          .rotationEffect(.degrees(folded ? 0 : 90))
        Text("DEVICES").font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(1.4).foregroundStyle(.white.opacity(0.45))
        Text("\(store.devices.count + store.remote.count + (store.elsewhere > 0 ? 1 : 0))")
          .font(.system(size: 9.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
        Spacer()
        Text(money(store.devices.reduce(0) { $0 + $1.cost }) + " today").font(.system(size: 9.5, weight: .semibold, design: .monospaced))
          .foregroundStyle(.white.opacity(0.4))
      }
      .contentShape(Rectangle())
      .onTapGesture { store.toggleCollapse("#devices") }
      if !folded {
        ForEach(store.devices) { d in
          HStack(spacing: 8) {
            Image(systemName: "laptopcomputer").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Circle().fill(d.online ? Phase.done.color : Color(white: 0.4)).frame(width: 5, height: 5)
            Text(d.name + (d.mine ? "  · this Mac" : "")).font(.system(size: 11, weight: .medium, design: .rounded)).lineLimit(1)
            if d.live > 0 { Text("\(d.live) live").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.35)) }
            Spacer()
            Text("\(money(d.cost)) · \(fmt(d.tokens))").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
          }
          .help(d.online ? "Online" : "Last seen \(clock(d.updated))")
        }
        if store.elsewhere > 0 {
          HStack(spacing: 8) {
            Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(Phase.permission.color)
            Circle().fill(Phase.permission.color).frame(width: 5, height: 5)
            Text("Elsewhere · claude.ai, phone, other computers").font(.system(size: 11, weight: .medium, design: .rounded)).lineLimit(1)
            Spacer()
            Text("+\(Int(store.elsewhere.rounded()))% of 5h").font(.system(size: 10, weight: .semibold, design: .monospaced))
              .foregroundStyle(Phase.permission.color)
          }
          .help("Your account's 5-hour usage grew this much while this Mac wasn't using Claude")
        }
        ForEach(store.remote) { r in
          HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5))
            Circle().fill(r.working ? Phase.working.color : r.connected ? Phase.done.color : Color(white: 0.4)).frame(width: 5, height: 5)
            Text(r.title).font(.system(size: 11, weight: .medium, design: .rounded)).lineLimit(1)
            Spacer()
            Text(r.connected ? (r.working ? "working" : "connected") : "last \(clock(r.last))")
              .font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.4)).fixedSize()
          }
          .contentShape(Rectangle())
          .onTapGesture { NSWorkspace.shared.open(URL(string: "https://claude.ai/code/\(r.id)")!) }
          .help("Remote / cloud session · \(r.model)\(r.branch.isEmpty ? "" : " · " + r.branch) — click to open on claude.ai")
        }
      }
    }
  }
}

struct TipsStrip: View {
  @ObservedObject var store: Store
  var body: some View {
    let folded = store.collapsed.contains("#tips")
    let tips = store.tips
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.4))
          .rotationEffect(.degrees(folded ? 0 : 90))
        Text("SAVE TOKENS").font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(1.4).foregroundStyle(.white.opacity(0.45))
        Text("\(tips.count)").font(.system(size: 9.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
        Spacer()
      }
      .contentShape(Rectangle())
      .onTapGesture { store.toggleCollapse("#tips") }
      if !folded {
        ForEach(tips) { t in
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: t.icon).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Phase.done.color).frame(width: 14)
            VStack(alignment: .leading, spacing: 6) {
              Text(t.text).font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
              if let a = t.action {
                Pill(title: a.title, icon: "arrow.up.right", tint: Phase.done.color) { store.jump(a.session, prompt: a.prompt) }
              }
            }
            Spacer(minLength: 0)
            DismissButton { withAnimation(Store.spring) { _ = store.dismissedTips.insert(t.id) } }
          }
          .padding(9)
          .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Phase.done.color.opacity(0.06)))
        }
      }
    }
  }
}

