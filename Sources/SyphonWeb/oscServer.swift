import Foundation
import SwiftOSC

let oscPort: UInt16 = 9000

// A bookmark's name/url/favorite flag, stripped of the SQLite-backed `Bookmark` class so the
// dispatch logic below can be tested without a database.
struct OSCBookmarkEntry {
  let name: String
  let url: String
  let favorite: Bool
}

// Resolves an OSC `/bookmark` argument to a URL. `name` matches case-insensitively (trimmed).
// `position` is a 1-based index into sidebar display order: favorites first, then non-favorites,
// each preserving `bookmarks` order (matches MainView's two sections). Returns nil on no match.
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

@available(macOS 14, *)
@MainActor
func handleBookmarkMessage(name: String?, position: Int?, state: WebViewState) {
  let entries = Bookmark.getAll().map {
    OSCBookmarkEntry(name: $0.name, url: $0.url, favorite: $0.favorite)
  }

  guard let url = resolveBookmarkURL(name: name, position: position, in: entries) else {
    NSLog("OSC: /bookmark no match for \(name ?? position.map(String.init) ?? "<none>")")
    return
  }

  state.navigate(to: url)
}

// Starts a UDP OSC server on `oscPort` and dispatches `/url` and `/bookmark` messages to `state`.
// Bind failures are logged, not fatal, so the app keeps running without OSC control.
@available(macOS 14, *)
func startOSCServer(state: WebViewState) -> OSCUDPServer {
  let server = OSCUDPServer(
    port: oscPort,
    receiveHandler: .messages { message, _, _, _ in
      let address = message.addressPattern.stringValue
      let values = message.values

      switch address {
      case "/url":
        guard let urlString = values.first as? String else {
          NSLog("OSC: /url requires a string argument, ignoring")
          return
        }
        Task { @MainActor in
          state.navigate(to: urlString)
        }

      case "/bookmark":
        guard let first = values.first else {
          NSLog("OSC: /bookmark requires an argument, ignoring")
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
          NSLog("OSC: /bookmark argument must be a string or an integral number, ignoring")
        }

      default:
        NSLog("OSC: ignoring unhandled address \(address)")
      }
    }
  )

  do {
    try server.start()
    NSLog("OSC server listening on UDP port \(oscPort)")
  } catch {
    NSLog("OSC server failed to start on UDP port \(oscPort): \(error)")
  }

  return server
}
