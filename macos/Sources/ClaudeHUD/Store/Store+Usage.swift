import AppKit
import SwiftUI

extension Store {
  // MARK: usage

  func refreshUsage() {
    let mod = (try? limitsURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    if let mod, mod != limitsMod, let d = try? Data(contentsOf: limitsURL),
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
      limitsMod = mod
      func lim(_ k: String, _ label: String) -> Limit? {
        guard let o = j[k] as? [String: Any], let p = o["used_percentage"] as? Double else { return nil }
        let r = Date(timeIntervalSince1970: o["resets_at"] as? Double ?? 0)
        if r < Date() { return Limit(pct: 0, resets: r) }
        // Forecast: burn rate over the last hour of samples → time until 100%.
        var arr = (samples[k] ?? []).filter { Date().timeIntervalSince($0.t) < 3600 && $0.p <= p }
        arr.append((Date(), p))
        samples[k] = arr
        // Pace: recent samples when they span 5+ min, else the average since the window opened.
        let start = r.addingTimeInterval(k == "five_hour" ? -5 * 3600 : -7 * 86400)
        var rate: Double?
        if let first = arr.first, p > first.p, Date().timeIntervalSince(first.t) >= 300 {
          rate = (p - first.p) / Date().timeIntervalSince(first.t)
        } else if p > 0, Date().timeIntervalSince(start) > 600 {
          rate = p / Date().timeIntervalSince(start)
        }
        var eta: TimeInterval?
        if let rate, rate > 0, (100 - p) / rate < r.timeIntervalSinceNow { eta = (100 - p) / rate }
        for th in [80.0, 95.0] where p >= th && warned.insert("\(k)\(th)\(r.timeIntervalSince1970)").inserted {
          notice("\(label) usage at \(Int(p))%", eta.map { "At this pace you hit the limit in ~\(span($0))" } ?? "Resets in \(span(r.timeIntervalSinceNow))")
        }
        return Limit(pct: p, resets: r, out: eta.map { Date().addingTimeInterval($0) }, paced: rate != nil)
      }
      let (f, w) = (lim("five_hour", "5-hour"), lim("seven_day", "Weekly"))
      if let f {
        let local = todayTokens
        if let prev = lastPace, f.resets == prev.resets {
          if f.pct - prev.p >= 0.5, local - prev.local < 20_000 {
            elsewhere += f.pct - prev.p
            if elsewhere >= 3, warned.insert("elsewhere\(f.resets.timeIntervalSince1970)").inserted {
              notice("Claude is being used elsewhere", "+\(Int(elsewhere))% of your 5-hour window came from claude.ai, a phone or another computer while this Mac was idle")
            }
          }
        } else if lastPace != nil {
          elsewhere = 0  // new window
        }
        lastPace = (f.pct, local, f.resets)
      }
      if f != fiveHour { fiveHour = f }
      if w != week { week = w }
      onLimits?()
    }
    let meeting = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier?.lowercased().contains("cpthost") == true }
    if meeting != inMeeting { inMeeting = meeting }
    queue.async { [counter] in
      let u = counter.scan()
      DispatchQueue.main.async {
        if u != self.usage { self.usage = u }
        self.readRegistry()
        self.updateBurn()
        self.remindIdle()
        self.syncDevices()
      }
    }
  }

  /// 5-hour / weekly usage from the endpoint `/usage` uses, signed in with Claude Code's own login
  /// (read via /usr/bin/security, which already has Keychain access). Saved in the statusline's format.
  func fetchLimits() {
    queue.async {
      let p = Process(), out = Pipe()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
      p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
      p.standardOutput = out
      p.standardError = FileHandle.nullDevice
      guard (try? p.run()) != nil else { return }
      let data = out.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = (j["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String else { return }
      self.fetchRemote(token)
      var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
      URLSession.shared.dataTask(with: req) { d, r, _ in
        guard (r as? HTTPURLResponse)?.statusCode == 200, let d,
              let u = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        var limits: [String: Any] = [:]
        for k in ["five_hour", "seven_day"] {
          guard let o = u[k] as? [String: Any], let pct = o["utilization"] as? Double, let r = o["resets_at"] as? String,
                let date = ISO8601DateFormatter().date(from: r.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
          else { continue }
          limits[k] = ["used_percentage": pct, "resets_at": date.timeIntervalSince1970]
        }
        if !limits.isEmpty, let out = try? JSONSerialization.data(withJSONObject: limits) {
          try? out.write(to: limitsURL, options: .atomic)
        }
      }.resume()
    }
  }

  /// Claude Code sessions on the account that run elsewhere (remote control, claude.ai/code), active in the last 2 days.
  func fetchRemote(_ token: String) {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/code/sessions")!, timeoutInterval: 10)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    URLSession.shared.dataTask(with: req) { d, r, _ in
      guard (r as? HTTPURLResponse)?.statusCode == 200, let d,
            let rows = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["data"] as? [[String: Any]] else { return }
      let iso = ISO8601DateFormatter()
      iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let list: [Remote] = rows.compactMap { x in
        guard let id = x["id"] as? String, x["status"] as? String == "active",
              let last = (x["last_event_at"] as? String).flatMap(iso.date(from:)), Date().timeIntervalSince(last) < 2 * 86400
        else { return nil }
        let meta = x["external_metadata"] as? [String: Any] ?? [:]
        let branches = (meta["current_branches"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
        return Remote(id: id, title: x["title"] as? String ?? "Session",
                      connected: x["connection_status"] as? String == "connected",
                      working: x["worker_status"] as? String == "running" || x["worker_status"] as? String == "busy",
                      model: (meta["model"] as? String ?? "").replacingOccurrences(of: "claude-", with: ""),
                      branch: branches?.first.map { "\(($0.key as NSString).lastPathComponent) · \($0.value)" } ?? "", last: last)
      }
      DispatchQueue.main.async { if list != self.remote { self.remote = list } }
    }.resume()
  }

}
