import Testing

@testable import SyphonWebCore

// Ported from the app's `checkBookmarkLabelValidation` self-check (pre-move `bookmark.swift`).
@Suite struct BookmarkLabelTests {

  static let existing: [(id: Int64, label: String?)] = [(1, "chuds"), (2, nil)]

  private static func check(_ raw: String, _ id: Int64?, _ label: String?, _ fails: Bool) {
    let result = validateBookmarkLabel(raw, existing: existing, excludingId: id)
    #expect(
      result.label == label && (result.error != nil) == fails,
      "label check failed for \"\(raw)\": \(result)")
  }

  @Test func labelValidationCases() {
    Self.check("", nil, nil, false)
    Self.check("  chuds ", 1, "chuds", false)
    Self.check("chuds", 1, "chuds", false)
    Self.check("chuds", nil, nil, true)
    Self.check("Chuds", 2, nil, true)
    Self.check("123", nil, nil, true)
    Self.check("a b", nil, nil, true)
    Self.check("a/b", nil, nil, true)
    Self.check("x-1_y", nil, "x-1_y", false)
    Self.check("é", nil, nil, true)
  }

  @Test func fieldValidationRequiresNameAndURL() {
    #expect(
      validateBookmarkFields(name: " ", url: "x", label: "", existing: [], excludingId: nil).error
        != nil)
    #expect(
      validateBookmarkFields(name: "n", url: "", label: "", existing: [], excludingId: nil).error
        != nil)
  }
}
