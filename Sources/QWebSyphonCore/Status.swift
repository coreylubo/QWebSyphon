import Foundation

// Menu bar status level (statusMenu.swift, app side): drives the composed status-item icon's dot
// colour and, per output, the menu row's bullet colour.
public enum StatusLevel: Sendable {
  case ok
  case warning
  case error
}

// Just enough of one output's live state to classify it: whether its page is still loading,
// whether it failed to load, and its current fps. No `hasClients` — the level rules below don't
// use client presence.
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
