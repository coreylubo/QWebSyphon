import Foundation
import Testing

@testable import SyphonWebCore

// Ported from the app's `checkOSCRoutes` self-check (pre-move `oscServer.swift`).
@Suite struct OSCRoutesTests {

  @Test func legacyForms() {
    #expect(parseOSCRoute("/syphon/url") == .url(.legacy))
    #expect(parseOSCRoute("/syphon/bookmark") == .bookmark(.legacy))
    #expect(parseOSCRoute("/syphon/refresh") == .refresh(.legacy))
    #expect(
      parseOSCRoute("/syphon/bookmark/lower-third") == .bookmarkLabel(.legacy, label: "lower-third"))
  }

  @Test func scopedFormsByNameAndIndex() {
    #expect(parseOSCRoute("/syphon/Main/url") == .url(.named("Main")))
    #expect(parseOSCRoute("/syphon/Main/bookmark") == .bookmark(.named("Main")))
    #expect(parseOSCRoute("/syphon/Main/refresh") == .refresh(.named("Main")))
    #expect(
      parseOSCRoute("/syphon/Main/bookmark/lower-third")
        == .bookmarkLabel(.named("Main"), label: "lower-third"))
    #expect(parseOSCRoute("/syphon/2/url") == .url(.named("2")))
  }

  @Test func bookmarkAmbiguityResolvesToLegacyLabel() {
    // ["syphon", "bookmark", x] is always the legacy label form (an output can never be named
    // "bookmark" — reserved).
    #expect(parseOSCRoute("/syphon/bookmark/x") == .bookmarkLabel(.legacy, label: "x"))
  }

  @Test func rejectedAddresses() {
    // extra/empty/trailing segments, no leading slash, unknown command words, wrong prefix
    #expect(parseOSCRoute("/syphon//url") == nil, "empty output segment")
    #expect(parseOSCRoute("/syphon/url/") == nil, "trailing slash")
    #expect(parseOSCRoute("/syphon/bookmark/") == nil, "empty trailing label")
    #expect(parseOSCRoute("/syphon/Main/url/extra") == nil, "too many segments")
    #expect(parseOSCRoute("/syphon") == nil, "too few segments")
    #expect(parseOSCRoute("syphon/url") == nil, "no leading slash")
    #expect(parseOSCRoute("/syphon/nonsense") == nil, "unknown legacy command")
    #expect(parseOSCRoute("/syphon/Main/nonsense") == nil, "unknown scoped command")
    #expect(parseOSCRoute("/other/url") == nil, "wrong prefix")
  }

  @Test func resolveOutputByIndexAndName() {
    // 1-based index, 0/negative/out-of-range -> nil, case-insensitive name match, unknown name ->
    // nil, grandfathered (non-slug) name reachable only by index.
    let outputs: [(id: UUID, name: String)] = [
      (UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, "Main"),
      (UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, "Overlay"),
      (UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, "SyphonWeb left"),
    ]
    #expect(resolveOutput("1", outputs: outputs) == outputs[0].id)
    #expect(resolveOutput("2", outputs: outputs) == outputs[1].id)
    #expect(resolveOutput("0", outputs: outputs) == nil, "index 0")
    #expect(resolveOutput("-1", outputs: outputs) == nil, "negative index")
    #expect(resolveOutput("4", outputs: outputs) == nil, "out of range")
    #expect(resolveOutput("main", outputs: outputs) == outputs[0].id, "case-insensitive")
    #expect(resolveOutput("OVERLAY", outputs: outputs) == outputs[1].id, "case-insensitive")
    #expect(resolveOutput("nope", outputs: outputs) == nil, "unknown name")
    #expect(
      resolveOutput("SyphonWeb left", outputs: outputs) == nil,
      "grandfathered (non-slug) name not matched by name")
    #expect(
      resolveOutput("3", outputs: outputs) == outputs[2].id,
      "grandfathered name reachable by index")
    #expect(resolveOutput("", outputs: outputs) == nil, "empty ref")
  }
}
