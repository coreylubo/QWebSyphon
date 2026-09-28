import Foundation
import Testing

@testable import QWebSyphonCore

@Suite struct OSCReferenceTests {

  @Test func addressableNameUsesNameNonAddressableUsesIndex() {
    let reference = buildOSCReference(
      outputs: [(name: "Main", index: 1), (name: "SyphonWeb left", index: 2)],
      labelledBookmarks: [],
      legacyOutputName: nil)

    #expect(reference.groups.map(\.id) == ["Main", "2"])
    #expect(reference.groups[0].rows.map(\.id).contains("/syphon/Main/url"))
    #expect(reference.groups[1].rows.map(\.id).contains("/syphon/2/url"))
  }

  @Test func labelledBookmarkRowsRepeatPerOutput() {
    let reference = buildOSCReference(
      outputs: [(name: "Main", index: 1), (name: "Overlay", index: 2)],
      labelledBookmarks: [(label: "lower-third", name: "Lower Third")],
      legacyOutputName: nil)

    #expect(reference.groups.count == 2)
    for group in reference.groups {
      let bookmarkRow = group.rows.first { $0.id == "/syphon/\(group.id)/bookmark/lower-third" }
      #expect(bookmarkRow != nil)
      #expect(bookmarkRow?.description == "Load \"Lower Third\".")
    }
  }

  @Test func footnotePresentOnlyWithLegacyOutput() {
    let withLegacy = buildOSCReference(
      outputs: [(name: "Main", index: 1)], labelledBookmarks: [], legacyOutputName: "Main")
    #expect(withLegacy.footnote != nil)
    #expect(withLegacy.footnote?.description.contains("Main") == true)

    let withoutLegacy = buildOSCReference(
      outputs: [(name: "Main", index: 1)], labelledBookmarks: [], legacyOutputName: nil)
    #expect(withoutLegacy.footnote == nil)
  }
}
