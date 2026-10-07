import Foundation

/// "15:42" today, "Sat 14:00" later.
public func clock(_ d: Date) -> String {
  let f = DateFormatter()
  f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE HH:mm"
  return f.string(from: d)
}

public func money(_ d: Double) -> String {
  d >= 100 ? String(format: "$%.0f", d) : String(format: "$%.2f", d)
}

/// API list price per million tokens (input, output, cache read). Cache writes cost 1.25× input (5 min) / 2× (1 h).
public func price(_ model: String) -> (i: Double, o: Double, r: Double) {
  if model.contains("fable") || model.contains("mythos") { return (10, 50, 0.25) }
  if model.contains("opus-5-5") { return (4, 20, 0.2) }
  if model.contains("opus-4-1") || model.contains("opus-4-2025") { return (15, 75, 1.5) }
  if model.contains("opus") { return (5, 25, 0.5) }
  if model.contains("sonnet-5") { return (2, 10, 0.2) }
  if model.contains("sonnet") { return (3, 15, 0.3) }
  if model.contains("haiku") { return (1, 5, 0.1) }
  return (5, 25, 0.5)
}

public func fmt(_ n: Int) -> String {
  n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.0fk", Double(n) / 1e3) : "\(n)"
}

public func span(_ s: TimeInterval) -> String {
  let s = max(0, Int(s)), h = s / 3600, m = s % 3600 / 60
  return h >= 24 ? "\(h / 24)d \(h % 24)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
}
