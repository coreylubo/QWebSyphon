import Combine
import Foundation
import os
import SwiftUI

// Fixed height of the status bar shown directly below the web view preview. Window sizing
// (main.swift's initial size, webView.swift's resizeWindow) must include this.
let statusBarHeight: CGFloat = 24

// Aggregated, low-frequency stats for the status bar: output fps, Syphon client presence, and the
// last OSC message seen. Updated at most once per second by a single Timer, so the 60 Hz capture
// path (WebView.captureFrame) and the OSC receive path never trigger a SwiftUI re-render directly
// — only the status bar observes this object.
@MainActor
final class OutputStats: ObservableObject {
  @Published private(set) var fps: Int = 0
  @Published private(set) var hasClients: Bool = false
  @Published private(set) var lastOSCAddress: String?
  @Published private(set) var lastOSCDate: Date?

  // Latest OSC activity, written from the OSC receive thread without hopping to the main actor
  // (a high-rate sender would otherwise queue a main-actor task per packet).
  private nonisolated let pendingOSC = OSAllocatedUnfairLock<(address: String, date: Date)?>(
    initialState: nil)

  nonisolated func recordOSC(address: String) {
    pendingOSC.withLock { $0 = (address, Date()) }
  }

  // Plain (non-published) per-frame counter. Incremented once per published frame in
  // WebView.captureFrame; read and reset by the 1 s tick below.
  var frameCount: Int = 0

  private weak var state: WebViewState?
  private var timer: Timer?

  init(state: WebViewState) {
    self.state = state
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func tick() {
    fps = frameCount
    frameCount = 0
    hasClients = state?.frameServer?.hasClients ?? false
    if let osc = pendingOSC.withLock({ $0 }), osc.date != lastOSCDate {
      lastOSCAddress = osc.address
      lastOSCDate = osc.date
    }
  }
}

// Truncates a string for inline display, keeping the full text available via `.help`.
private func truncated(_ text: String, limit: Int = 40) -> String {
  text.count > limit ? String(text.prefix(limit)) + "…" : text
}

// A thin status bar below the web view preview: Syphon client presence, output fps, page load
// state, and OSC listen status + last message. Full preview width.
@available(macOS 14, *)
struct StatusBar: View {
  @ObservedObject var state: WebViewState
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
        .fill(stats.hasClients ? Color.green : Color.gray)
        .frame(width: 6, height: 6)
      Text(stats.hasClients ? "Connected" : "No clients")
    }
  }

  // "— fps" while loading, since capture pauses (see WebView.captureFrame); amber below 55 fps
  // once a page is loaded.
  private var fpsLabel: some View {
    Group {
      if state.loading {
        Text("— fps").foregroundStyle(.secondary)
      } else {
        Text("\(stats.fps) fps")
          .foregroundStyle(stats.fps < 55 ? Color.orange : Color.primary)
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
      if let address = stats.lastOSCAddress, let date = stats.lastOSCDate {
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
