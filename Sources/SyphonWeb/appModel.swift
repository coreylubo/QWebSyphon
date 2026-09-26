import Foundation
import Metal

let defaultOutputURL = "https://puppy.surf"

// Per-profile (appDefaults) keys for the outputs model
private let outputsKey = "outputs"
private let outputsMigrationVersionKey = "outputsMigrationVersion"
private let legacyOutputIDKey = "legacyOutputID"

// Pre-multi-output per-profile keys. Read once by migration and kept for rollback, never written.
private let legacySyphonNameKey = "syphonName"
private let legacyOutputResolutionKey = "outputResolution"
private let legacyTransparentBackgroundKey = "transparentBackground"

// Persisted settings of one output. The whole array is stored as one JSON string under `outputs`.
struct OutputConfig: Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var url: String
  var resolution: OutputResolution
  var transparentBackground: Bool
  var captureWithoutClients: Bool

  static func makeDefault(id: UUID = UUID(), name: String = defaultSyphonName()) -> OutputConfig {
    OutputConfig(
      id: id, name: name, url: defaultOutputURL, resolution: .hd720, transparentBackground: false,
      captureWithoutClients: true)
  }
}

func encodeOutputs(_ configs: [OutputConfig]) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  // Plain Codable struct with no floats: encoding can't fail
  return String(decoding: try! encoder.encode(configs), as: UTF8.self)
}

func decodeOutputs(_ raw: Any?) -> [OutputConfig]? {
  guard let string = raw as? String else { return nil }
  return try? JSONDecoder().decode([OutputConfig].self, from: Data(string.utf8))
}

struct OutputsLoad: Equatable {
  var configs: [OutputConfig]
  var legacyID: UUID?
  // Migration: the caller writes `configs`, reads them back, then sets `legacyOutputID` + marker
  var shouldWrite: Bool
  // False for in-memory fallbacks, so later saves don't overwrite what's stored
  var persist: Bool
  // Stored `outputs` is valid but `legacyOutputID`/marker are missing (a migration interrupted
  // after writing `outputs`): the caller writes only those two, leaving `outputs` untouched
  var shouldCompleteMarker = false
}

// Decides what to load from a profile's defaults. Reads only; writing is `loadOutputs`' job.
// - Stored `outputs` that decodes (even `[]`) is used as-is, marker or not: never overwritten.
// - Stored `outputs` that doesn't decode, or no `outputs` once the marker is set: one default
//   output in memory, nothing written (kept for inspection/rollback).
// - No `outputs` and no marker: build output #1 (the legacy output) from the legacy keys.
func migrateOutputs(
  defaults: UserDefaults, defaultName: String = defaultSyphonName(), newID: UUID = UUID()
) -> OutputsLoad {
  let storedLegacyID = defaults.string(forKey: legacyOutputIDKey).flatMap(UUID.init(uuidString:))
  let stored = defaults.object(forKey: outputsKey)

  if let configs = decodeOutputs(stored) {
    // A single stored output with no legacy id can only be the migrated output #1: recover its id
    // so unscoped OSC keeps working. With several outputs there is no safe guess; leave it nil.
    if storedLegacyID == nil, configs.count == 1 {
      return OutputsLoad(
        configs: configs, legacyID: configs[0].id, shouldWrite: false, persist: true,
        shouldCompleteMarker: true)
    }
    return OutputsLoad(configs: configs, legacyID: storedLegacyID, shouldWrite: false, persist: true)
  }

  if stored != nil || defaults.object(forKey: outputsMigrationVersionKey) != nil {
    appLog(
      stored != nil
        ? "Stored `outputs` is not valid; using one default output in memory (not saved)"
        : "`outputs` missing after migration; using one default output in memory (not saved)")
    return OutputsLoad(
      configs: [.makeDefault(id: newID, name: defaultName)], legacyID: newID, shouldWrite: false,
      persist: false)
  }

  let savedName = defaults.string(forKey: legacySyphonNameKey)?.trimmingCharacters(
    in: .whitespacesAndNewlines)
  var config = OutputConfig.makeDefault(id: newID, name: defaultName)
  if let savedName, !savedName.isEmpty { config.name = savedName }
  config.resolution =
    defaults.string(forKey: legacyOutputResolutionKey).flatMap(OutputResolution.init(rawValue:))
    ?? .hd720
  config.transparentBackground = defaults.bool(forKey: legacyTransparentBackgroundKey)
  return OutputsLoad(configs: [config], legacyID: newID, shouldWrite: true, persist: true)
}

// Runs `migrateOutputs` and performs the migration write: `outputs`, read back and compared, and
// only then `legacyOutputID` + `outputsMigrationVersion = 1`. A failed read-back leaves the
// marker unset so the next launch retries. `write` is injectable for the self-check.
func loadOutputs(
  defaults: UserDefaults, defaultName: String = defaultSyphonName(),
  write: ((String) -> Void)? = nil
) -> OutputsLoad {
  let load = migrateOutputs(defaults: defaults, defaultName: defaultName)
  if load.shouldCompleteMarker, let legacyID = load.legacyID {
    defaults.set(legacyID.uuidString, forKey: legacyOutputIDKey)
    defaults.set(1, forKey: outputsMigrationVersionKey)
    appLog("Completed interrupted `outputs` migration, legacy output \(legacyID)")
    return load
  }
  guard load.shouldWrite, let legacyID = load.legacyID else { return load }

  appLog("Migrating legacy settings to `outputs`: \(load.configs)")
  (write ?? { defaults.set($0, forKey: outputsKey) })(encodeOutputs(load.configs))
  guard decodeOutputs(defaults.object(forKey: outputsKey)) == load.configs else {
    appLog("`outputs` read-back failed; migration marker not set, will retry next launch")
    return load
  }
  defaults.set(legacyID.uuidString, forKey: legacyOutputIDKey)
  defaults.set(1, forKey: outputsMigrationVersionKey)
  appLog("Migrated to `outputs` (version 1), legacy output \(legacyID)")
  return load
}

// App-wide state: the outputs, selection, the shared Metal command queue, the OSC port and the
// single capture driver.
@MainActor
final class AppModel: ObservableObject {
  // Phase 1: exactly one output
  @Published private(set) var outputs: [Output]
  @Published var selectedOutputID: UUID
  // Target of the legacy (unscoped) OSC addresses. Never retargeted to another output.
  let legacyOutputID: UUID?
  let commandQueue: MTLCommandQueue = metalDevice.makeCommandQueue()!

  // OSC listen port, app-wide, persisted as its own key. Changing this does not itself restart
  // the OSC server; the Settings view calls OSCController.start(port:).
  @Published var oscPort: UInt16 {
    didSet { defaults.set(Int(oscPort), forKey: oscPortDefaultsKey) }
  }

  private let defaults: UserDefaults
  private let persistOutputs: Bool
  private var captureTimer: Timer?

  init(defaults: UserDefaults = appDefaults) {
    self.defaults = defaults
    let savedPort = defaults.integer(forKey: oscPortDefaultsKey)
    oscPort = validOSCPortRange.contains(savedPort) ? UInt16(savedPort) : defaultOSCPort

    let load = loadOutputs(defaults: defaults)
    var configs = load.configs
    var persist = load.persist
    if configs.isEmpty {
      appLog("`outputs` is empty; using one default output in memory (not saved)")
      configs = [.makeDefault()]
      persist = false
    } else if configs.count > 1 {
      // ponytail: phase 1 runs one output; saving would drop the rest, so don't
      appLog("`outputs` has \(configs.count) outputs; this version runs one (not saved)")
      configs = [configs.first { $0.id == load.legacyID } ?? configs[0]]
      persist = false
    }
    if !persist { appLog("Output settings changes will not be saved this session") }

    persistOutputs = persist
    legacyOutputID = load.legacyID
    let outputs = configs.map { Output(config: $0) }
    self.outputs = outputs
    selectedOutputID = outputs[0].id
    for output in outputs {
      output.onConfigChange = { [weak self] in self?.saveOutputs() }
    }
  }

  var selectedOutput: Output { outputs.first { $0.id == selectedOutputID } ?? outputs[0] }

  var legacyOutput: Output? {
    guard let legacyOutputID else { return nil }
    return outputs.first { $0.id == legacyOutputID }
  }

  // Writes the whole array in one value, so outputs never persist half-updated
  func saveOutputs() {
    guard persistOutputs else { return }
    defaults.set(encodeOutputs(outputs.map(\.config)), forKey: outputsKey)
  }

  // One 60 Hz driver for all outputs, in `.common` mode so capture keeps running during menu
  // tracking and window drags (the old per-view timer ran in the default mode and paused).
  func startCapture() {
    guard captureTimer == nil else { return }
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.captureOutputs() }
    }
    RunLoop.main.add(timer, forMode: .common)
    captureTimer = timer
  }

  private func captureOutputs() {
    for output in outputs {
      output.captureFrame(commandQueue: commandQueue)
    }
  }
}

#if DEBUG
  // Runs at launch in debug builds; traps if outputs migration regresses. Each case uses its own
  // throwaway suite, removed afterwards.
  func checkOutputsMigration() {
    // A suite named by absolute path is a plist at that path, so nothing lands in
    // ~/Library/Preferences (cfprefsd leaves an empty plist there even after
    // removePersistentDomain).
    func withSuite(_ body: (UserDefaults) -> Void) {
      let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(
        "SyphonWeb.selfcheck.\(UUID().uuidString)")
      let defaults = UserDefaults(suiteName: path)!
      body(defaults)
      defaults.removePersistentDomain(forName: path)
      try? FileManager.default.removeItem(atPath: path + ".plist")
    }

    // Legacy keys -> one output, written, read back, marker + legacy ID set, legacy keys kept
    withSuite { d in
      d.set("  Mig Name ", forKey: legacySyphonNameKey)
      d.set("hd1080", forKey: legacyOutputResolutionKey)
      d.set(true, forKey: legacyTransparentBackgroundKey)
      let load = loadOutputs(defaults: d, defaultName: "Default")
      precondition(load.configs.count == 1 && load.shouldWrite && load.persist)
      let c = load.configs[0]
      precondition(
        c.name == "Mig Name" && c.resolution == .hd1080 && c.transparentBackground
          && c.captureWithoutClients && c.url == defaultOutputURL && load.legacyID == c.id)
      precondition(decodeOutputs(d.object(forKey: outputsKey)) == load.configs)
      precondition(d.integer(forKey: outputsMigrationVersionKey) == 1)
      precondition(d.string(forKey: legacyOutputIDKey) == c.id.uuidString)
      precondition(d.string(forKey: legacySyphonNameKey) == "  Mig Name ")
      // Second launch: no re-migration, same output and legacy ID
      let again = migrateOutputs(defaults: d, defaultName: "Default")
      precondition(!again.shouldWrite && again.configs == load.configs && again.legacyID == c.id)
    }

    // No/blank/invalid legacy keys -> defaults
    withSuite { d in
      d.set("   ", forKey: legacySyphonNameKey)
      d.set("bogus", forKey: legacyOutputResolutionKey)
      let c = migrateOutputs(defaults: d, defaultName: "Default").configs[0]
      precondition(c.name == "Default" && c.resolution == .hd720 && !c.transparentBackground)
    }

    // Existing valid array, empty array, corrupt JSON: `outputs` untouched. A single stored
    // output with no legacy id (interrupted migration) gets its id + marker completed; the
    // others get no marker.
    let kept = OutputConfig.makeDefault(name: "Kept")
    let existing = encodeOutputs([kept])
    for (stored, expectCount, expectPersist) in [(existing, 1, true), ("[]", 0, true), ("{nope", 1, false)] {
      withSuite { d in
        d.set(stored, forKey: outputsKey)
        let load = loadOutputs(defaults: d, defaultName: "Default")
        precondition(!load.shouldWrite && load.configs.count == expectCount && load.persist == expectPersist)
        precondition(d.string(forKey: outputsKey) == stored)
        if stored == existing {
          precondition(load.configs[0].name == "Kept" && load.legacyID == kept.id)
          precondition(d.string(forKey: legacyOutputIDKey) == kept.id.uuidString)
          precondition(d.integer(forKey: outputsMigrationVersionKey) == 1)
          let again = loadOutputs(defaults: d, defaultName: "Default")
          precondition(!again.shouldCompleteMarker && again.legacyID == kept.id)
        } else {
          precondition(d.object(forKey: outputsMigrationVersionKey) == nil)
          precondition(d.object(forKey: legacyOutputIDKey) == nil)
        }
      }
    }

    // Several stored outputs with no legacy id: no guess, nothing written
    withSuite { d in
      let two = encodeOutputs([.makeDefault(name: "A"), .makeDefault(name: "B")])
      d.set(two, forKey: outputsKey)
      let load = loadOutputs(defaults: d, defaultName: "Default")
      precondition(load.legacyID == nil && !load.shouldCompleteMarker)
      precondition(d.string(forKey: outputsKey) == two)
      precondition(d.object(forKey: legacyOutputIDKey) == nil)
    }

    // Marker set but `outputs` gone: in-memory fallback, nothing written
    withSuite { d in
      d.set(1, forKey: outputsMigrationVersionKey)
      let load = loadOutputs(defaults: d, defaultName: "Default")
      precondition(!load.shouldWrite && !load.persist && load.configs.count == 1)
      precondition(d.object(forKey: outputsKey) == nil)
    }

    // Failed write: marker and legacy ID stay unset
    withSuite { d in
      let load = loadOutputs(defaults: d, defaultName: "Default", write: { _ in })
      precondition(load.shouldWrite)
      precondition(d.object(forKey: outputsMigrationVersionKey) == nil)
      precondition(d.object(forKey: legacyOutputIDKey) == nil)
    }

    appLog("Outputs migration self-check passed")
  }
#endif
