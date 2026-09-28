import Foundation

// Which output an `OSCRoute` targets: the legacy (unscoped) output, or one named/indexed by a
// scoped address's `<output>` segment.
public enum OSCOutputScope: Equatable, Sendable {
  case legacy
  case named(String)
}

// A parsed, valid OSC address. Pure representation of "what to do to which output" — argument
// validation (is there a string/int argument, etc.) happens separately in the app's
// `dispatchOSCMessage`.
public enum OSCRoute: Equatable, Sendable {
  case url(OSCOutputScope)
  case bookmark(OSCOutputScope)
  case bookmarkLabel(OSCOutputScope, label: String)
  case refresh(OSCOutputScope)
}

// Parses an OSC address into a route. Splits on `/` keeping empty subsequences, so a leading `/`
// is required (segment 0 empty) and no other segment may be empty — this rejects `/syphon//url`
// and any trailing `/`. Segment counts are exact:
//   ["syphon", cmd]                    legacy url/bookmark/refresh
//   ["syphon", "bookmark", label]      legacy bookmark label (always this form: "bookmark" is a
//                                      reserved output name, so it can never be an `<output>`)
//   ["syphon", out, cmd]               scoped url/bookmark/refresh
//   ["syphon", out, "bookmark", label] scoped bookmark label
// Anything else (wrong prefix, wrong counts, unknown command word) returns nil.
public func parseOSCRoute(_ address: String) -> OSCRoute? {
  let segments = address.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
  guard segments.count >= 3, segments[0].isEmpty, segments[1] == "syphon" else { return nil }
  let rest = segments.dropFirst(2)
  guard rest.allSatisfy({ !$0.isEmpty }) else { return nil }
  let rest2 = Array(rest)

  switch rest2.count {
  case 1:
    switch rest2[0] {
    case "url": return .url(.legacy)
    case "bookmark": return .bookmark(.legacy)
    case "refresh": return .refresh(.legacy)
    default: return nil
    }
  case 2:
    if rest2[0] == "bookmark" { return .bookmarkLabel(.legacy, label: rest2[1]) }
    switch rest2[1] {
    case "url": return .url(.named(rest2[0]))
    case "bookmark": return .bookmark(.named(rest2[0]))
    case "refresh": return .refresh(.named(rest2[0]))
    default: return nil
    }
  case 3:
    guard rest2[1] == "bookmark" else { return nil }
    return .bookmarkLabel(.named(rest2[0]), label: rest2[2])
  default:
    return nil
  }
}

// Resolves a scoped address's `<output>` segment to an output id. An all-digit `ref` is a 1-based
// index into `outputs` (0 or out of range → nil). Otherwise, a case-insensitive match against
// names for which `isOSCAddressableName` is true — grandfathered (non-slug) names are excluded
// here, so they're only reachable by index.
public func resolveOutput(_ ref: String, outputs: [(id: UUID, name: String)]) -> UUID? {
  guard !ref.isEmpty else { return nil }
  if ref.allSatisfy(\.isNumber) {
    guard let index = Int(ref), index >= 1, index <= outputs.count else { return nil }
    return outputs[index - 1].id
  }
  let target = ref.lowercased()
  return outputs.first { isOSCAddressableName($0.name) && $0.name.lowercased() == target }?.id
}

// A bookmark's id/name/url/favorite flag, stripped of the SQLite-backed `Bookmark` class so the
// dispatch logic can be tested without a database. `id` lets the caller open the real `Bookmark`
// (for `Output.open(bookmark:)`) once a match is found.
public struct OSCBookmarkEntry: Sendable {
  public let id: Int64
  public let name: String
  public let url: String
  public let favorite: Bool

  public init(id: Int64, name: String, url: String, favorite: Bool) {
    self.id = id
    self.name = name
    self.url = url
    self.favorite = favorite
  }
}

// Resolves an OSC `/syphon/bookmark` argument to a bookmark entry. `name` matches
// case-insensitively (trimmed). `position` is a 1-based index into sidebar display order:
// favorites first, then non-favorites, each preserving `bookmarks` order (matches MainView's two
// sections). Returns nil on no match.
public func resolveBookmark(
  name: String?, position: Int?, in bookmarks: [OSCBookmarkEntry]
) -> OSCBookmarkEntry? {
  if let name {
    let target = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return bookmarks.first {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target
    }
  }

  if let position {
    let ordered = bookmarks.filter(\.favorite) + bookmarks.filter { !$0.favorite }
    // position > 0 first so Int.min can't overflow the subtraction
    guard position > 0, ordered.indices.contains(position - 1) else { return nil }
    return ordered[position - 1]
  }

  return nil
}
