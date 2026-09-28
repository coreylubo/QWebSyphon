import Foundation
import Testing

@testable import SyphonWebCore

// A suite named by absolute path is a plist at that path, so nothing lands in
// ~/Library/Preferences (cfprefsd leaves an empty plist there even after
// removePersistentDomain). Mirrors the app's old `#if DEBUG` self-check helper.
private func withSuite(_ body: (UserDefaults) -> Void) {
  let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(
    "SyphonWebCoreTests.\(UUID().uuidString)")
  let defaults = UserDefaults(suiteName: path)!
  body(defaults)
  defaults.removePersistentDomain(forName: path)
  try? FileManager.default.removeItem(atPath: path + ".plist")
}

// Ported from the app's `checkOutputsMigration` self-check (pre-move `appModel.swift`). Keys are
// literal strings matching the core module's private constants (`outputsKey` is the one exception
// that's public, since the app's `saveOutputs` writes it directly).
private let outputsKeyLiteral = "outputs"
private let outputsMigrationVersionKeyLiteral = "outputsMigrationVersion"
private let legacyOutputIDKeyLiteral = "legacyOutputID"
private let legacySyphonNameKeyLiteral = "syphonName"
private let legacyOutputResolutionKeyLiteral = "outputResolution"
private let legacyTransparentBackgroundKeyLiteral = "transparentBackground"

@Suite struct OutputsMigrationTests {

  @Test func legacyKeysMigrateAndPersist() {
    withSuite { d in
      d.set("  Mig Name ", forKey: legacySyphonNameKeyLiteral)
      d.set("hd1080", forKey: legacyOutputResolutionKeyLiteral)
      d.set(true, forKey: legacyTransparentBackgroundKeyLiteral)
      let load = loadOutputs(defaults: d, defaultName: "Default")
      #expect(load.configs.count == 1 && load.shouldWrite && load.persist)
      let c = load.configs[0]
      #expect(
        c.name == "Mig Name" && c.resolution == .hd1080 && c.transparentBackground
          && c.captureWithoutClients && c.url == defaultOutputURL && load.legacyID == c.id)
      #expect(decodeOutputs(d.object(forKey: outputsKeyLiteral)) == load.configs)
      #expect(d.integer(forKey: outputsMigrationVersionKeyLiteral) == 1)
      #expect(d.string(forKey: legacyOutputIDKeyLiteral) == c.id.uuidString)
      #expect(d.string(forKey: legacySyphonNameKeyLiteral) == "  Mig Name ")
      // Second launch: no re-migration, same output and legacy ID
      let again = migrateOutputs(defaults: d, defaultName: "Default")
      #expect(!again.shouldWrite && again.configs == load.configs && again.legacyID == c.id)
    }
  }

  @Test func blankOrInvalidLegacyKeysFallBackToDefaults() {
    withSuite { d in
      d.set("   ", forKey: legacySyphonNameKeyLiteral)
      d.set("bogus", forKey: legacyOutputResolutionKeyLiteral)
      let c = migrateOutputs(defaults: d, defaultName: "Default").configs[0]
      #expect(c.name == "Default" && c.resolution == .hd720 && !c.transparentBackground)
    }
  }

  @Test func existingValidEmptyAndCorruptStoredOutputs() {
    // Existing valid array, empty array, corrupt JSON: `outputs` untouched. A single stored
    // output with no legacy id (interrupted migration) gets its id + marker completed; the
    // others get no marker.
    let kept = OutputConfig.makeDefault(name: "Kept")
    let existing = encodeOutputs([kept])
    for (stored, expectCount, expectPersist) in [(existing, 1, true), ("[]", 0, true), ("{nope", 1, false)] {
      withSuite { d in
        d.set(stored, forKey: outputsKeyLiteral)
        let load = loadOutputs(defaults: d, defaultName: "Default")
        #expect(!load.shouldWrite && load.configs.count == expectCount && load.persist == expectPersist)
        #expect(d.string(forKey: outputsKeyLiteral) == stored)
        if stored == existing {
          #expect(load.configs[0].name == "Kept" && load.legacyID == kept.id)
          #expect(d.string(forKey: legacyOutputIDKeyLiteral) == kept.id.uuidString)
          #expect(d.integer(forKey: outputsMigrationVersionKeyLiteral) == 1)
          let again = loadOutputs(defaults: d, defaultName: "Default")
          #expect(!again.shouldCompleteMarker && again.legacyID == kept.id)
        } else {
          #expect(d.object(forKey: outputsMigrationVersionKeyLiteral) == nil)
          #expect(d.object(forKey: legacyOutputIDKeyLiteral) == nil)
        }
      }
    }
  }

  @Test func severalStoredOutputsWithNoLegacyIDMakeNoGuess() {
    withSuite { d in
      let two = encodeOutputs([.makeDefault(name: "A"), .makeDefault(name: "B")])
      d.set(two, forKey: outputsKeyLiteral)
      let load = loadOutputs(defaults: d, defaultName: "Default")
      #expect(load.legacyID == nil && !load.shouldCompleteMarker)
      #expect(d.string(forKey: outputsKeyLiteral) == two)
      #expect(d.object(forKey: legacyOutputIDKeyLiteral) == nil)
    }
  }

  @Test func markerSetButOutputsGoneFallsBackInMemory() {
    withSuite { d in
      d.set(1, forKey: outputsMigrationVersionKeyLiteral)
      let load = loadOutputs(defaults: d, defaultName: "Default")
      #expect(!load.shouldWrite && !load.persist && load.configs.count == 1)
      #expect(d.object(forKey: outputsKeyLiteral) == nil)
    }
  }

  @Test func failedWriteLeavesMarkerAndLegacyIDUnset() {
    withSuite { d in
      let load = loadOutputs(defaults: d, defaultName: "Default", write: { _ in })
      #expect(load.shouldWrite)
      #expect(d.object(forKey: outputsMigrationVersionKeyLiteral) == nil)
      #expect(d.object(forKey: legacyOutputIDKeyLiteral) == nil)
    }
  }

  @Test func loadingTwoStoredOutputsKeepsBoth() {
    // No phase 1 "keep one" truncation
    withSuite { d in
      let two = encodeOutputs([.makeDefault(name: "One"), .makeDefault(name: "Two")])
      d.set(two, forKey: outputsKeyLiteral)
      let load = loadOutputs(defaults: d, defaultName: "Default")
      #expect(load.persist && load.configs.count == 2)
      let sanitizedTwo = sanitizeOutputConfigs(load.configs, defaultName: "Default")
      #expect(!sanitizedTwo.repaired && sanitizedTwo.configs.count == 2)
    }
  }
}
