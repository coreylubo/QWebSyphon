import Foundation
import os
import SwiftOSC
import QWebSyphonCore

let defaultOSCPort: UInt16 = 9000
private let bookmarkAddressPrefix = "/syphon/bookmark/"

// Extracts an integral value from an OSC argument. Accepts Int32/Int64 directly, and Float32/
// Double only when integral and in range (TouchOSC sends floats for what are logically ints).
func integralOSCValue(_ value: any OSCValue) -> Int? {
  switch value {
  case let v as Int32:
    return Int(v)
  case let v as Int64:
    return Int(v)
  case let v as Float32:
    return Int(exactly: v)
  case let v as Double:
    return Int(exactly: v)
  default:
    return nil
  }
}

// `/syphon/bookmark <name-or-position>`: a string label/name matches `Bookmark.find(label:)`
// first, then falls back to a case-insensitive name match; an int/float selects by 1-based
// sidebar position.
@available(macOS 14, *)
@MainActor
func handleBookmarkMessage(name: String?, position: Int?, state: Output) {
  if let name, let byLabel = Bookmark.find(label: name) {
    state.open(bookmark: byLabel)
    return
  }

  let all = Bookmark.getAll()
  let entries = all.map {
    OSCBookmarkEntry(id: $0.id, name: $0.name, url: $0.url, favorite: $0.favorite)
  }

  guard let match = resolveBookmark(name: name, position: position, in: entries),
    let bookmark = all.first(where: { $0.id == match.id })
  else {
    appLog("OSC: /syphon/bookmark no match for \(name ?? position.map(String.init) ?? "<none>")")
    return
  }

  state.open(bookmark: bookmark)
}

// `/syphon/bookmark/<label>`: looks up the bookmark by its exact OSC label.
@available(macOS 14, *)
@MainActor
func handleBookmarkLabelMessage(label: String, state: Output) {
  guard let bookmark = Bookmark.find(label: label) else {
    appLog("OSC: \(bookmarkAddressPrefix)\(label) no match")
    return
  }
  state.open(bookmark: bookmark)
}

// Resolves an `OSCOutputScope` to a live output. Touches `model.outputs`/`legacyOutput`, so this
// must run on the main actor.
@available(macOS 14, *)
@MainActor
private func resolvedOutput(for scope: OSCOutputScope, model: AppModel) -> Output? {
  switch scope {
  case .legacy:
    return model.legacyOutput
  case .named(let ref):
    let list = model.outputs.map { (id: $0.id, name: $0.name) }
    guard let id = resolveOutput(ref, outputs: list) else { return nil }
    return model.outputs.first { $0.id == id }
  }
}

// Parses one incoming OSC message and hops to the main actor for anything that touches an
// output. Runs on the OSC server's receive queue (not the main actor), so values are extracted
// here as plain Sendable data before crossing over.
@available(macOS 14, *)
func dispatchOSCMessage(_ message: OSCMessage, controller: OSCController) {
  let address = message.addressPattern.stringValue
  let values = message.values

  // Recorded for recognized AND unrecognized addresses — this is a "did anything arrive"
  // indicator for the status bar, not a log of handled commands. Written straight from the
  // receive thread; the controller's 1 s tick publishes it.
  controller.recordOSC(address: address)

  guard let route = parseOSCRoute(address) else {
    appLog("OSC: ignoring unhandled address \(address)")
    return
  }

  let model = controller.model
  // Resolution against `model.outputs`/`legacyOutput` happens on the main actor, inside the Task.
  func withOutput(_ scope: OSCOutputScope, _ body: @escaping @MainActor (Output) -> Void) {
    Task { @MainActor in
      guard let output = resolvedOutput(for: scope, model: model) else {
        appLog("OSC: no output for \(address), ignoring")
        return
      }
      body(output)
    }
  }

  switch route {
  case .url(let scope):
    guard let urlString = values.first as? String else {
      appLog("OSC: \(address) requires a string argument, ignoring")
      return
    }
    withOutput(scope) { $0.navigate(to: urlString) }

  case .bookmark(let scope):
    guard let first = values.first else {
      appLog("OSC: \(address) requires an argument, ignoring")
      return
    }
    if let name = first as? String {
      withOutput(scope) { handleBookmarkMessage(name: name, position: nil, state: $0) }
    } else if let position = integralOSCValue(first) {
      withOutput(scope) { handleBookmarkMessage(name: nil, position: position, state: $0) }
    } else {
      appLog("OSC: \(address) argument must be a string or an integral number, ignoring")
    }

  case .bookmarkLabel(let scope, let label):
    withOutput(scope) { handleBookmarkLabelMessage(label: label, state: $0) }

  case .refresh(let scope):
    withOutput(scope) { $0.reload() }
  }
}

// One documented OSC address for the "OSC Commands" reference list (Settings, cluster 3).
struct OSCCommandInfo: Identifiable {
  let id: String
  let args: String
  let description: String
}

// Legacy forms + scoped forms + one concrete example per output (by name, or by index for a
// grandfathered non-slug name). Touches `Output.name`, so main-actor only.
@available(macOS 14, *)
@MainActor
func oscCommandReference(outputs: [Output]) -> [OSCCommandInfo] {
  var commands: [OSCCommandInfo] = [
    OSCCommandInfo(
      id: "/syphon/url", args: "string",
      description: "Load a URL in the legacy output (https:// added if no scheme is given)."),
    OSCCommandInfo(
      id: "/syphon/bookmark", args: "string or int",
      description:
        "Load a bookmark by OSC label or name (string), or by 1-based sidebar position (int/float), in the legacy output."
    ),
    OSCCommandInfo(
      id: "/syphon/bookmark/<label>", args: "none",
      description: "Load the bookmark with this OSC label, in the legacy output."),
    OSCCommandInfo(
      id: "/syphon/refresh", args: "none", description: "Reload the current page in the legacy output."
    ),
    OSCCommandInfo(
      id: "/syphon/<output>/url", args: "string",
      description: "Load a URL in <output> (name, case-insensitive, or 1-based index)."),
    OSCCommandInfo(
      id: "/syphon/<output>/bookmark", args: "string or int",
      description: "Load a bookmark by label, name, or 1-based sidebar position, in <output>."),
    OSCCommandInfo(
      id: "/syphon/<output>/bookmark/<label>", args: "none",
      description: "Load the bookmark with this OSC label, in <output>."),
    OSCCommandInfo(
      id: "/syphon/<output>/refresh", args: "none", description: "Reload the current page in <output>."
    ),
  ]
  for (index, output) in outputs.enumerated() {
    let ref = isOSCAddressableName(output.name) ? output.name : String(index + 1)
    commands.append(
      OSCCommandInfo(
        id: "/syphon/\(ref)/url", args: "string",
        description: "Example: load a URL in \"\(output.name)\"."))
  }
  return commands
}

// Creates and starts a server in one step so bind failures propagate to the caller instead of
// being swallowed.
@available(macOS 14, *)
private func makeStartedOSCServer(port: UInt16, controller: OSCController) throws -> OSCUDPServer {
  let server = OSCUDPServer(
    port: port,
    receiveHandler: .messages { message, _, _, _ in
      dispatchOSCMessage(message, controller: controller)
    }
  )
  try server.start()
  return server
}

// How many ports above the requested one to try when it's not explicitly saved (see `start`).
private let oscPortFallbackRange = 1...20

// Owns the live OSC server and swaps it out when the listen port changes. Bind failures are
// reflected in `status`, not fatal, so the app keeps running without (or with the old) OSC control.
@available(macOS 14, *)
@MainActor
final class OSCController: ObservableObject {
  @Published private(set) var status: String = "Not started"
  // Actual bound port (may differ from the requested one after a fallback). @Published so the
  // window title can track it.
  @Published private(set) var port: UInt16?

  // Last OSC message seen (any address), for the status bar. Published at most once per second.
  @Published private(set) var lastOSCAddress: String?
  @Published private(set) var lastOSCDate: Date?

  let model: AppModel
  private var server: OSCUDPServer?
  private var activityTimer: Timer?

  // Latest OSC activity, written from the OSC receive thread without hopping to the main actor
  // (a high-rate sender would otherwise queue a main-actor task per packet).
  private nonisolated let pendingOSC = OSAllocatedUnfairLock<(address: String, date: Date)?>(
    initialState: nil)

  nonisolated func recordOSC(address: String) {
    pendingOSC.withLock { $0 = (address, Date()) }
  }

  init(model: AppModel) {
    self.model = model
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.publishActivity() }
    }
    RunLoop.main.add(timer, forMode: .common)
    activityTimer = timer
  }

  private func publishActivity() {
    if let osc = pendingOSC.withLock({ $0 }), osc.date != lastOSCDate {
      lastOSCAddress = osc.address
      lastOSCDate = osc.date
    }
  }

  // Tries `port` first. If this profile has no explicitly saved `oscPort` default (a fresh
  // profile defaulting to 9000, say) and `port` fails to bind, tries the next ports up to
  // `oscPortFallbackRange` above it and uses the first that binds, without persisting the
  // fallback. A port the user explicitly saved keeps the old behavior: fail with an error status,
  // no fallback.
  // `explicit` (a port the user just chose in Settings) disables the fallback. Returns whether
  // `port` itself is now bound.
  @discardableResult
  func start(port: UInt16, explicit: Bool = false) -> Bool {
    // Rebinding the port we already hold would fail with "address in use"
    if server != nil && self.port == port { return true }

    let explicitlySaved = explicit || appDefaults.object(forKey: oscPortDefaultsKey) != nil
    var candidates = [port]
    if !explicitlySaved {
      candidates += oscPortFallbackRange.compactMap { offset -> UInt16? in
        let candidate = Int(port) + offset
        return candidate <= Int(UInt16.max) ? UInt16(candidate) : nil
      }
    }

    var lastError: Error?
    for candidate in candidates {
      do {
        let newServer = try makeStartedOSCServer(port: candidate, controller: self)
        server?.stop()
        server = newServer
        self.port = candidate
        status =
          candidate == port
          ? "Listening on UDP \(candidate)"
          : "Listening on UDP \(candidate) (port \(port) was in use)"
        appLog("OSC server listening on UDP port \(candidate)")
        return candidate == port
      } catch {
        lastError = error
      }
    }
    status = "Failed to bind UDP \(port): \(lastError!)"
    appLog("OSC server failed to start on UDP port \(port): \(lastError!)")
    return false
  }
}

