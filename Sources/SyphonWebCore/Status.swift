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

  public init(loading: Bool, failed: Bool, fps: Int) {
    self.loading = loading
    self.failed = failed
    self.fps = fps
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

// Overall level: error if any output failed or OSC isn't listening (control is down); else
// warning if any output is loading or degraded; else ok. Error takes precedence over warning
// even when a different output would only warrant a warning.
public func statusLevel(outputs: [OutputHealth], oscListening: Bool) -> StatusLevel {
  if !oscListening || outputs.contains(where: \.failed) { return .error }
  if outputs.contains(where: { outputStatusLevel($0) == .warning }) { return .warning }
  return .ok
}
