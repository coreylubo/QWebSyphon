import Combine
import Foundation
import os
import SwiftUI

// Fixed height of the status bar shown directly below the web view preview. Window sizing
// (main.swift's initial size, webView.swift's resizeWindow) must include this.
let statusBarHeight: CGFloat = 24

// Aggregated, low-frequency stats for one output: fps and Syphon client presence. Updated at
// most once per second by a single Timer, so the 60 Hz capture path (Output.captureFrame) never
// triggers a SwiftUI re-render directly — only the status bar observes this object.
@MainActor
final class OutputStats: ObservableObject {
  @Published private(set) var fps: Int = 0
  @Published private(set) var hasClients: Bool = false

  // Plain (non-published) per-frame counter. Incremented once per published frame in
  // Output.captureFrame; read and reset by the 1 s tick below.
  var frameCount: Int = 0

  weak var output: Output?
  private var timer: Timer?

  init() {
    // The run loop retains the timer, not `self`: stop it once a removed output's stats are freed
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }
      Task { @MainActor in self.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func tick() {
    fps = frameCount
    frameCount = 0
    hasClients = output?.frameServer?.hasClients ?? false
  }
}

// Truncates a string for inline display, keeping the full text available via `.help`.
private func truncated(_ text: String, limit: Int = 40) -> String {
  text.count > limit ? String(text.prefix(limit)) + "…" : text
}

// Client-dot and fps colors, shared with the output grid tiles (outputTiles.swift) so both places
// agree on what "healthy" looks like.
enum OutputStatusStyle {
  static func clientColor(hasClients: Bool) -> Color { hasClients ? .green : .gray }

  // Amber below 55 fps once a page is loaded; while loading, callers show "— fps" instead and
  // this color is unused, so any value is fine.
  static func fpsColor(fps: Int, loading: Bool) -> Color {
    loading ? .secondary : (fps < 55 ? .orange : .primary)
  }
}

// A thin status bar below the web view preview: Syphon client presence, output fps, page load
// state, and OSC listen status + last message. Full preview width.
@available(macOS 14, *)
struct StatusBar: View {
  @ObservedObject var state: Output
  @ObservedObject var stats: OutputStats
  @ObservedObject var oscController: OSCController

  var body: some View {
    HStack(spacing: 12) {
      clientsLabel
      fpsLabel
      pageStateLabel
      oscLabel
      Spacer()
    }
    .font(.caption)
    .monospacedDigit()
    .padding(.horizontal, 8)
    .frame(height: statusBarHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
  }

  private var clientsLabel: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(OutputStatusStyle.clientColor(hasClients: stats.hasClients))
        .frame(width: 6, height: 6)
      Text(stats.hasClients ? "Connected" : "No clients")
    }
  }

  // "— fps" while loading, since capture pauses (see Output.captureFrame); amber below 55 fps
  // once a page is loaded.
  private var fpsLabel: some View {
    Group {
      if state.loading {
        Text("— fps").foregroundStyle(.secondary)
      } else {
        Text("\(stats.fps) fps")
          .foregroundStyle(OutputStatusStyle.fpsColor(fps: stats.fps, loading: state.loading))
      }
    }
  }

  private var pageStateText: String {
    if state.loading { return "Loading…" }
    if let error = state.loadError { return "Failed: \(truncated(error, limit: 30))" }
    return "Loaded"
  }

  private var pageStateLabel: some View {
    Text(pageStateText)
      .help(state.loadError ?? pageStateText)
  }

  private var oscMainText: String {
    if let port = oscController.port { return "OSC \(port)" }
    return truncated(oscController.status)
  }

  private var oscLabel: some View {
    HStack(spacing: 4) {
      Text(oscMainText)
      if let address = oscController.lastOSCAddress, let date = oscController.lastOSCDate {
        Text("· \(address) \(relativeAge(date))")
          .foregroundStyle(.secondary)
      }
    }
    .help(oscController.status)
  }

  // Recomputed whenever `stats` changes (the 1 s tick updates `fps` every second regardless of
  // value), so this stays current without its own timer.
  private func relativeAge(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 2 { return "just now" }
    return "\(seconds)s ago"
  }
}
