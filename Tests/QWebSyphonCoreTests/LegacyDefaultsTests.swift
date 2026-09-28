import Foundation
import Testing

@testable import QWebSyphonCore

// Path-named suite = a plist at that path, nothing in ~/Library/Preferences.
private func withSuite(_ body: (UserDefaults) -> Void) {
  let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(
    "QWebSyphonCoreTests.\(UUID().uuidString)")
  let defaults = UserDefaults(suiteName: path)!
  body(defaults)
  defaults.removePersistentDomain(forName: path)
  try? FileManager.default.removeItem(atPath: path + ".plist")
}

@Suite struct LegacyDefaultsTests {
  @Test func domainOrder() {
    #expect(legacyDefaultsDomains(profile: "p2", isBundled: true) == ["SyphonWeb.profile.p2"])
    #expect(legacyDefaultsDomains(profile: "p2", isBundled: false) == ["SyphonWeb.profile.p2"])
    #expect(
      legacyDefaultsDomains(profile: nil, isBundled: true) == ["surf.puppy.SyphonWeb", "SyphonWeb"])
    #expect(
      legacyDefaultsDomains(profile: nil, isBundled: false) == ["SyphonWeb", "surf.puppy.SyphonWeb"])
  }

  @Test func mergeNeverOverwritesOrCopiesMarker() {
    let toCopy = legacyDefaultsToCopy(
      old: ["a": 1, "b": "old", legacyDefaultsMarkerKey: "x"], new: ["b": "new"])
    #expect(Set(toCopy.keys) == ["a"])
    #expect(toCopy["a"] as? Int == 1)
  }

  @Test func mergesAllDomainsOnceEarlierWinsWithoutTouchingThem() {
    withSuite { defaults in
      defaults.set("keep", forKey: "oscPort")
      var old: [String: [String: Any]] = [
        "empty": [:],
        "src": ["oscPort": 9001, "outputs": "[{}]", "showDockIcon": false],
        "later": ["other": 1, "outputs": "later"],
      ]
      let snapshot = old["src"]! as NSDictionary
      let source = migrateLegacyDefaults(
        into: defaults, legacyDomains: ["missing", "empty", "src", "later"], read: { old[$0] })
      #expect(source == "src,later")
      #expect(defaults.string(forKey: "oscPort") == "keep")
      #expect(defaults.string(forKey: "outputs") == "[{}]")
      #expect(defaults.object(forKey: "showDockIcon") as? Bool == false)
      #expect(defaults.integer(forKey: "other") == 1, "later domains fill keys the earlier lacked")
      #expect(defaults.string(forKey: legacyDefaultsMarkerKey) == "src,later")
      #expect(old["src"]! as NSDictionary == snapshot)

      // Marker set: a second run copies nothing, even if the old domain changed.
      old["src"]!["outputs"] = "changed"
      defaults.removeObject(forKey: "outputs")
      #expect(migrateLegacyDefaults(into: defaults, legacyDomains: ["src"], read: { old[$0] }) == nil)
      #expect(defaults.object(forKey: "outputs") == nil)
    }
  }

  @Test func noOldDataStillSetsMarker() {
    withSuite { defaults in
      #expect(migrateLegacyDefaults(into: defaults, legacyDomains: ["none"], read: { _ in nil }) == "")
      #expect(defaults.string(forKey: legacyDefaultsMarkerKey) == "")
    }
  }
}
