import Foundation

// Menu bar status level (statusMenu.swift, app side): drives the composed status-item icon's top
// ("in") dot colour and, per output, the menu row's bullet colour. `clientsLevel` drives the
// bottom ("out") dot.
public enum StatusLevel: Sendable {
  case ok
  case warning
  case error
}

// Just enough of one output's live state to classify it: whether its page is still loading,
// whether it failed to load, and its current fps. No `hasClients` — `outputStatusLevel` and
// `statusLevel` don't use client presence; `clientsLevel` covers that separately.
public struct OutputHealth: Sendable {
  public var loading: Bool
  public var failed: Bool
  public var fps: Int
  // A disabled output has no server/page to be healthy or unhealthy about; `statusLevel` ignores
  // it entirely rather than counting it as ok, warning or error.
  public var enabled: Bool

  public init(loading: Bool, failed: Bool, fps: Int, enabled: Bool = true) {
    self.loading = loading
    self.failed = failed
    self.fps = fps
    self.enabled = enabled
  }
}

// One output's level: error if it failed to load; warning if it's still loading, or loaded with
// fps under 55 (matches `OutputStatusStyle.fpsColor`'s threshold, statusBar.swift); ok otherwise.
public func outputStatusLevel(_ health: OutputHealth) -> StatusLevel {
  if health.failed { return .error }
  if health.loading { return .warning }
  if health.fps < 55 { return .warning }
  return .ok
}

// Overall level: error if any ENABLED output failed or OSC isn't listening (control is down);
// else warning if any enabled output is loading or degraded; else ok. Disabled outputs never
// affect the level either way. Error takes precedence over warning even when a different output
// would only warrant a warning.
public func statusLevel(outputs: [OutputHealth], oscListening: Bool) -> StatusLevel {
  let relevant = outputs.filter(\.enabled)
  if !oscListening || relevant.contains(where: \.failed) { return .error }
  if relevant.contains(where: { outputStatusLevel($0) == .warning }) { return .warning }
  return .ok
}

// Far-end ("out") level for the menu bar's bottom dot: whether Syphon clients are receiving the
// enabled outputs. ok when every enabled output has a client; warning when only some do; nil (no
// colour, shown grey) when none do or nothing is enabled — no clients is not a fault.
public func clientsLevel(enabledOutputsWithClients: [Bool]) -> StatusLevel? {
  let withClients = enabledOutputsWithClients.filter { $0 }.count
  if withClients == 0 { return nil }
  return withClients == enabledOutputsWithClients.count ? .ok : .warning
}

// Tooltip text for the top ("in") dot. Mirrors `statusLevel`'s precedence so the text never
// contradicts the dot colour: OSC down, then failed (error), then loading, then slow (warning).
// Each output is counted once, under its highest-precedence condition.
public func inStatusText(outputs: [OutputHealth], oscListening: Bool) -> String {
  if !oscListening { return "OSC not listening" }
  let enabled = outputs.filter(\.enabled)
  let m = enabled.count
  let failed = enabled.filter(\.failed).count
  if failed > 0 { return "\(failed) of \(m) \(m == 1 ? "page" : "pages") failed to load" }
  let loading = enabled.filter(\.loading).count
  if loading > 0 { return "\(loading) of \(m) \(m == 1 ? "page" : "pages") loading" }
  let slow = enabled.filter { $0.fps < 55 }.count
  if slow > 0 { return "\(slow) of \(m) \(m == 1 ? "output" : "outputs") under 55 fps" }
  return m == 0 ? "OSC listening, no outputs enabled" : "OSC listening, pages loaded"
}

// Tooltip text for the bottom ("out") dot; mirrors `clientsLevel`.
public func outStatusText(enabledOutputsWithClients: [Bool]) -> String {
  let m = enabledOutputsWithClients.count
  let n = enabledOutputsWithClients.filter { $0 }.count
  if m == 0 { return "No outputs enabled" }
  if n == 0 { return "No Syphon clients" }
  if m == 1 { return "Output has Syphon clients" }
  return n == m ? "All \(m) outputs have Syphon clients" : "\(n) of \(m) outputs have Syphon clients"
}
