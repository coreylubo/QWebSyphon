import CoreGraphics
import Foundation

// Width cap for tile images, in pixels: tiles are ~260 pt wide, 2x
public let tileImageMaxWidth = 640

// Capture order for one tick: `ids` rotated to start at `startID` (the first output the previous
// tick didn't reach), or `ids` as-is if `startID` is nil or no longer present (removed output).
public func captureOrder(ids: [UUID], startID: UUID?) -> [UUID] {
  guard let startID, let start = ids.firstIndex(of: startID) else { return ids }
  return Array(ids[start...] + ids[..<start])
}

// Pure matcher for "which bookmarks are live in which outputs" (the sidebar's globe icon).
// Per output: `bookmarkID` wins outright if set (even if that id no longer appears in
// `bookmarks` — the caller just won't find a row to mark); otherwise the FIRST bookmark in
// `bookmarks` order whose normalized URL equals the output's `url` is used. Either way, at most
// one bookmark is ever live per output. `bookmarks` must already be in sidebar order (favorites
// first, then the rest, each in `Bookmark.getAll()` order) for the "first match" rule to line up
// with what the UI shows. Output lists in the result are in `outputs` order.
public func liveBookmarkIDs(
  outputs: [(id: UUID, url: URL, bookmarkID: Int64?)],
  bookmarks: [(id: Int64, url: String)]
) -> [Int64: [UUID]] {
  var result: [Int64: [UUID]] = [:]
  for output in outputs {
    let liveID =
      output.bookmarkID ?? bookmarks.first { normalizedURL($0.url) == output.url }?.id
    if let liveID {
      result[liveID, default: []].append(output.id)
    }
  }
  return result
}

// Small upright copy of a capture-layout buffer for a tile. The buffer is bottom-up (row 0 is the
// page's bottom, as Syphon expects), so it is drawn flipped, and capped at `tileImageMaxWidth`.
// The app passes the GPU-downscaled readback of the published texture (`Output.refreshTile`),
// which is already at most that wide.
public func makeTileImage(_ context: CGContext) -> CGImage? {
  guard let snapshot = context.makeImage() else { return nil }
  let width = min(context.width, tileImageMaxWidth)
  let height = max(1, context.height * width / context.width)
  guard
    let tile = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return nil }
  tile.interpolationQuality = .none
  tile.translateBy(x: 0, y: CGFloat(height))
  tile.scaleBy(x: 1, y: -1)
  tile.draw(snapshot, in: CGRect(x: 0, y: 0, width: width, height: height))
  return tile.makeImage()
}
