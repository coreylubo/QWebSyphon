import CoreGraphics
import Foundation
import Testing

@testable import SyphonWebCore

// Ported from the app's `checkOutputsModel` self-check (pre-move `appModel.swift`).
@Suite struct OutputsModelTests {

  @Test func validateOutputNameRules() {
    // empty, whitespace, duplicate (case-insensitive), reserved, valid
    #expect(validateOutputName("", existing: []) != nil)
    #expect(validateOutputName("   ", existing: []) != nil)
    #expect(validateOutputName("Main", existing: ["main"]) != nil)
    #expect(validateOutputName("URL", existing: []) != nil)
    #expect(validateOutputName("bookmark", existing: []) != nil)
    #expect(validateOutputName("Refresh", existing: []) != nil)
    #expect(validateOutputName("  Toast  ", existing: ["Main"]) == nil)
    // slug rule (chars, all-digits, max 64)
    #expect(validateOutputName("My Output", existing: []) != nil, "space not allowed")
    #expect(validateOutputName("123", existing: []) != nil, "all-digits not allowed")
    #expect(
      validateOutputName(String(repeating: "a", count: 65), existing: []) != nil, "over 64 chars")
    #expect(
      validateOutputName(String(repeating: "a", count: 64), existing: []) == nil, "64 chars is ok")
    #expect(validateOutputName("My-Output_1", existing: []) == nil)
  }

  @Test func isOSCAddressableNameRules() {
    // the slug rule alone, no reserved/uniqueness check
    #expect(isOSCAddressableName("Main"))
    #expect(isOSCAddressableName("a1"))
    #expect(!isOSCAddressableName(""))
    #expect(!isOSCAddressableName("SyphonWeb left"), "space")
    #expect(!isOSCAddressableName("123"), "all digits")
    #expect(!isOSCAddressableName(String(repeating: "a", count: 65)), "over 64 chars")
    #expect(isOSCAddressableName(String(repeating: "a", count: 64)))
    // doesn't reject reserved words or check uniqueness (separate concerns)
    #expect(isOSCAddressableName("url"))
  }

  // The app's default base name is slugForOutputName(defaultSyphonName()), i.e. "SyphonWeb" or
  // "SyphonWeb <profile>": it must always be OSC-addressable.
  @Test(arguments: [nil, "left", "Main Stage", "café", "123", "a/b"])
  func defaultBaseNameIsAddressable(profile: String?) {
    let name = profile.map { "SyphonWeb \($0)" } ?? "SyphonWeb"
    #expect(isOSCAddressableName(slugForOutputName(name)))
  }

  @Test func slugForOutputNameRules() {
    #expect(slugForOutputName("SyphonWeb left") == "SyphonWeb-left")
    #expect(slugForOutputName("a/b c") == "a-b-c")
  }

  @Test func uniqueOutputNameSuffixing() {
    // "-N" suffix (not " N"), so a unique/default name is always slug-shaped
    #expect(uniqueOutputName(base: "SyphonWeb", existing: []) == "SyphonWeb")
    #expect(uniqueOutputName(base: "SyphonWeb", existing: ["SyphonWeb"]) == "SyphonWeb-2")
    #expect(
      uniqueOutputName(base: "SyphonWeb", existing: ["SyphonWeb", "SyphonWeb-2"]) == "SyphonWeb-3")
    #expect(uniqueOutputName(base: "SyphonWeb", existing: ["syphonweb"]) == "SyphonWeb-2")
  }

  @Test func sanitizeGrandfathersNonSlugNames() {
    // A unique non-slug name (e.g. legacy "SyphonWeb left") loads as-is, not treated as needing
    // repair — sanitize only touches blank/duplicate/reserved names, never the slug rule.
    let grandfathered = [OutputConfig.makeDefault(name: "SyphonWeb left")]
    let keptAsIs = sanitizeOutputConfigs(grandfathered, defaultName: "Default")
    #expect(!keptAsIs.repaired && keptAsIs.configs[0].name == "SyphonWeb left")
    // ...but duplicates of a grandfathered name are still deduped like any other name
    let dupNonSlug = [
      OutputConfig.makeDefault(name: "SyphonWeb left"), OutputConfig.makeDefault(name: "SyphonWeb left"),
    ]
    let dedupedNonSlug = sanitizeOutputConfigs(dupNonSlug, defaultName: "Default")
    #expect(dedupedNonSlug.repaired && Set(dedupedNonSlug.configs.map(\.name)).count == 2)
  }

  @Test func outputConfigJSONShape() {
    // preset-only omits `customSize`/`bookmarkID` (phase 1/2 shape, byte-identical)
    let preset = OutputConfig.makeDefault(name: "Preset")
    let presetJSON = encodeOutputs([preset])
    #expect(!presetJSON.contains("customSize") && !presetJSON.contains("bookmarkID"))
    #expect(decodeOutputs(presetJSON) == [preset])

    // customSize round-trips
    var custom = preset
    custom.customSize = PixelSize(width: 960, height: 1080)
    let customJSON = encodeOutputs([custom])
    #expect(customJSON.contains("customSize"))
    #expect(decodeOutputs(customJSON) == [custom])

    // bookmarkID round-trips, omitted when nil
    var withBookmark = preset
    withBookmark.bookmarkID = 42
    let withBookmarkJSON = encodeOutputs([withBookmark])
    #expect(withBookmarkJSON.contains("bookmarkID"))
    #expect(decodeOutputs(withBookmarkJSON) == [withBookmark])
  }

  @Test func liveBookmarkIDsMatching() {
    // explicit bookmarkID wins outright (even pointing at a deleted bookmark); nil bookmarkID
    // falls back to the FIRST bookmark (in order) whose URL matches
    let (o1, o2, o3) = (UUID(), UUID(), UUID())
    let urlA = normalizedURL("https://a.example")!
    let urlB = normalizedURL("https://b.example")!
    let live = liveBookmarkIDs(
      outputs: [
        (id: o1, url: urlA, bookmarkID: 1),
        (id: o2, url: urlA, bookmarkID: nil),
        (id: o3, url: urlB, bookmarkID: 99),
      ],
      bookmarks: [(id: 1, url: "https://a.example"), (id: 2, url: "https://a.example")])
    #expect(live[1] == [o1, o2], "bookmarkID match and URL-fallback match both key id 1")
    #expect(live[99] == [o3], "bookmarkID keys the result even with no matching bookmark row")
    #expect(live[2] == nil, "second duplicate-URL bookmark never wins the fallback")
  }

  @Test func outOfBoundsCustomSizeDecodesButIsSanitizedAway() {
    let badJSON = """
      [{"id":"\(UUID().uuidString)","name":"Bad","url":"\(defaultOutputURL)",\
      "resolution":"hd720","customSize":{"width":99999,"height":5000},\
      "transparentBackground":false,"captureWithoutClients":true}]
      """
    guard let badConfigs = decodeOutputs(badJSON) else {
      Issue.record("out-of-bounds customSize should decode, not fail the array")
      return
    }
    #expect(badConfigs[0].customSize?.width == 99999)
    let sanitizedBad = sanitizeOutputConfigs(badConfigs, defaultName: "Default")
    #expect(sanitizedBad.repaired && sanitizedBad.configs[0].customSize == nil)
  }

  @Test func sanitizeTruncatesToMaxOutputs() {
    let five = (1...5).map { OutputConfig.makeDefault(name: "Out \($0)") }
    let capped = sanitizeOutputConfigs(five, defaultName: "Default")
    #expect(capped.configs.count == maxOutputs && capped.repaired)
  }

  @Test func sanitizeDedupesNamesCaseInsensitively() {
    let dupNames = [OutputConfig.makeDefault(name: "Dup"), OutputConfig.makeDefault(name: "dup")]
    let dedupedNames = sanitizeOutputConfigs(dupNames, defaultName: "Default")
    #expect(dedupedNames.repaired && Set(dedupedNames.configs.map(\.name)).count == 2)
  }

  @Test func sanitizeGivesDuplicateUUIDsFreshIDs() {
    let sharedID = UUID()
    let dupIDs = [
      OutputConfig.makeDefault(id: sharedID, name: "A"),
      OutputConfig.makeDefault(id: sharedID, name: "B"),
    ]
    let dedupedIDs = sanitizeOutputConfigs(dupIDs, defaultName: "Default")
    #expect(dedupedIDs.repaired && Set(dedupedIDs.configs.map(\.id)).count == 2)
  }

  @Test func sanitizeReplacesUnparseableOrBlankURL() {
    var badURL = OutputConfig.makeDefault(name: "BadURL")
    badURL.url = ""
    let fixedURL = sanitizeOutputConfigs([badURL], defaultName: "Default")
    #expect(fixedURL.repaired && fixedURL.configs[0].url == defaultOutputURL)
  }

  @Test func sanitizePassesCleanInputThroughUnchanged() {
    let clean = [OutputConfig.makeDefault(name: "Clean1"), OutputConfig.makeDefault(name: "Clean2")]
    let cleaned = sanitizeOutputConfigs(clean, defaultName: "Default")
    #expect(!cleaned.repaired && cleaned.configs == clean)
  }

  @Test func captureOrderRotation() {
    // no/unknown start (e.g. the cursor's output was removed) -> as-is; rotation
    let (a, b, c) = (UUID(), UUID(), UUID())
    #expect(captureOrder(ids: [a, b, c], startID: nil) == [a, b, c])
    #expect(captureOrder(ids: [a, b, c], startID: a) == [a, b, c])
    #expect(captureOrder(ids: [a, b, c], startID: c) == [c, a, b])
    #expect(captureOrder(ids: [a, b, c], startID: b) == [b, c, a])
    #expect(captureOrder(ids: [a, c], startID: b) == [a, c])
    #expect(captureOrder(ids: [], startID: a) == [])
  }

  @Test func makeTileImageFlipsAndCapsWidth() {
    // capture buffer row 0 is the page's bottom, so the tile's first row must be the buffer's
    // last row (red here), and the size is capped at tileImageMaxWidth
    let capture = CGContext(
      data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let pixels = capture.data!.assumingMemoryBound(to: UInt8.self)
    for (i, byte) in [0, 0, 255, 255, 0, 0, 255, 255, 255, 0, 0, 255, 255, 0, 0, 255].enumerated() {
      pixels[i] = UInt8(byte)  // memory row 0 blue (page bottom), row 1 red (page top)
    }
    let tile = makeTileImage(capture)!
    let tileBytes = CFDataGetBytePtr(tile.dataProvider!.data)!
    #expect(tileBytes[0] == 255 && tileBytes[2] == 0, "tile image is upside down")

    let wide = CGContext(
      data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let wideTile = makeTileImage(wide)!
    #expect(wideTile.width == tileImageMaxWidth && wideTile.height == 360)
  }
}
