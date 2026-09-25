import Foundation
import SwiftOSC

let defaultOSCPort: UInt16 = 9000
private let bookmarkAddressPrefix = "/syphon/bookmark/"

// A bookmark's name/url/favorite flag, stripped of the SQLite-backed `Bookmark` class so the
// dispatch logic below can be tested without a database.
struct OSCBookmarkEntry {
  let name: String
  let url: String
  let favorite: Bool
}

// Resolves an OSC `/syphon/bookmark` argument to a URL. `name` matches case-insensitively
// (trimmed). `position` is a 1-based index into sidebar display order: favorites first, then
// non-favorites, each preserving `bookmarks` order (matches MainView's two sections). Returns nil
// on no match.
func resolveBookmarkURL(name: String?, position: Int?, in bookmarks: [OSCBookmarkEntry]) -> String? {
  if let name {
    let target = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return bookmarks.first {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target
    }?.url
  }

  if let position {
    let ordered = bookmarks.filter(\.favorite) + bookmarks.filter { !$0.favorite }
    guard ordered.indices.contains(position - 1) else { return nil }
    return ordered[position - 1].url
  }

  return nil
}

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
func handleBookmarkMessage(name: String?, position: Int?, state: WebViewState) {
  if let name, let byLabel = Bookmark.find(label: name) {
    state.navigate(to: byLabel.url)
    return
  }

  let entries = Bookmark.getAll().map {
    OSCBookmarkEntry(name: $0.name, url: $0.url, favorite: $0.favorite)
  }

  guard let url = resolveBookmarkURL(name: name, position: position, in: entries) else {
    NSLog("OSC: /syphon/bookmark no match for \(name ?? position.map(String.init) ?? "<none>")")
    return
  }

  state.navigate(to: url)
}

// `/syphon/bookmark/<label>`: looks up the bookmark by its exact OSC label.
@available(macOS 14, *)
@MainActor
func handleBookmarkLabelMessage(label: String, state: WebViewState) {
  guard let bookmark = Bookmark.find(label: label) else {
    NSLog("OSC: \(bookmarkAddressPrefix)\(label) no match")
    return
  }
  state.navigate(to: bookmark.url)
}

// Parses one incoming OSC message and hops to the main actor for anything that touches `state`.
// Runs on the OSC server's receive queue (not the main actor), so values are extracted here as
// plain Sendable data before crossing over.
@available(macOS 14, *)
func dispatchOSCMessage(_ message: OSCMessage, state: WebViewState, stats: OutputStats) {
  let address = message.addressPattern.stringValue
  let values = message.values

  // Recorded for recognized AND unrecognized addresses — this is a "did anything arrive"
  // indicator for the status bar, not a log of handled commands.
  Task { @MainActor in
    stats.lastOSCAddress = address
    stats.lastOSCDate = Date()
  }

  switch address {
  case "/syphon/url":
    guard let urlString = values.first as? String else {
      NSLog("OSC: /syphon/url requires a string argument, ignoring")
      return
    }
    Task { @MainActor in
      state.navigate(to: urlString)
    }

  case "/syphon/bookmark":
    guard let first = values.first else {
      NSLog("OSC: /syphon/bookmark requires an argument, ignoring")
      return
    }
    if let name = first as? String {
      Task { @MainActor in
        handleBookmarkMessage(name: name, position: nil, state: state)
      }
    } else if let position = integralOSCValue(first) {
      Task { @MainActor in
        handleBookmarkMessage(name: nil, position: position, state: state)
      }
    } else {
      NSLog("OSC: /syphon/bookmark argument must be a string or an integral number, ignoring")
    }

  case "/syphon/refresh":
    Task { @MainActor in
      state.reload()
    }

  default:
    if address.hasPrefix(bookmarkAddressPrefix) {
      let label = String(address.dropFirst(bookmarkAddressPrefix.count))
      Task { @MainActor in
        handleBookmarkLabelMessage(label: label, state: state)
      }
    } else {
      NSLog("OSC: ignoring unhandled address \(address)")
    }
  }
}

// Creates and starts a server in one step so bind failures propagate to the caller instead of
// being swallowed.
@available(macOS 14, *)
private func makeStartedOSCServer(
  port: UInt16, state: WebViewState, stats: OutputStats
) throws -> OSCUDPServer {
  let server = OSCUDPServer(
    port: port,
    receiveHandler: .messages { message, _, _, _ in
      dispatchOSCMessage(message, state: state, stats: stats)
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

  private let state: WebViewState
  private let stats: OutputStats
  private var server: OSCUDPServer?

  init(state: WebViewState, stats: OutputStats) {
    self.state = state
    self.stats = stats
  }

  // Tries `port` first. If this profile has no explicitly saved `oscPort` default (a fresh
  // profile defaulting to 9000, say) and `port` fails to bind, tries the next ports up to
  // `oscPortFallbackRange` above it and uses the first that binds, without persisting the
  // fallback. A port the user explicitly saved keeps the old behavior: fail with an error status,
  // no fallback.
  func start(port: UInt16) {
    // Rebinding the port we already hold would fail with "address in use"
    if server != nil && self.port == port { return }

    let explicitlySaved = appDefaults.object(forKey: oscPortDefaultsKey) != nil
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
        let newServer = try makeStartedOSCServer(port: candidate, state: state, stats: stats)
        server?.stop()
        server = newServer
        self.port = candidate
        status =
          candidate == port
          ? "Listening on UDP \(candidate)"
          : "Listening on UDP \(candidate) (port \(port) was in use)"
        NSLog("OSC server listening on UDP port \(candidate)")
        return
      } catch {
        lastError = error
      }
    }
    status = "Failed to bind UDP \(port): \(lastError!)"
    NSLog("OSC server failed to start on UDP port \(port): \(lastError!)")
  }
}
