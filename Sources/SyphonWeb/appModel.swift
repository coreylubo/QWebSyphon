import Foundation
import CoreGraphics
import Metal

let defaultOutputURL = "https://puppy.surf"

// Hard cap on the number of outputs (phase 2 decision 2). Not derived from measurement of what's
// actually fast — see the spike table in docs/multi-output-spec.md for the supported mixes.
let maxOutputs = 4

// Names that OSC scoped addresses (phase 4) reserve for command words, so they can never collide
// with an output name. Enforced now (phase 2) so an output can't be renamed into one later.
let reservedOutputNames = ["url", "bookmark", "refresh"]

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
  // Custom W×H (decision 6). Declared `Optional` so the synthesized `Codable` conformance
  // encodes it with `encodeIfPresent` (omitted entirely when nil — phase 1 JSON for preset-only
  // outputs stays byte-identical) and decodes it with `decodeIfPresent` (missing key on old JSON
  // decodes to nil, not a decode failure). An out-of-bounds size still decodes successfully here
  // (see `PixelSize`'s comment) — `sanitizeOutputConfigs` is what drops it.
  var customSize: PixelSize?
  var transparentBackground: Bool
  var captureWithoutClients: Bool

  static func makeDefault(id: UUID = UUID(), name: String = defaultSyphonName()) -> OutputConfig {
    OutputConfig(
      id: id, name: name, url: defaultOutputURL, resolution: .hd720, transparentBackground: false,
      captureWithoutClients: true)
  }
}

// Pure check for a rename/add/duplicate: trimmed, non-empty, unique case-insensitively among
// `existing` (the OTHER outputs' names — the caller excludes the output being renamed), and not
// one of the reserved command words. Returns an error message, or nil if `name` is valid as-is.
func validateOutputName(_ name: String, existing: [String]) -> String? {
  let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return "Name can't be empty" }
  if reservedOutputNames.contains(trimmed.lowercased()) {
    return "\"\(trimmed)\" is a reserved name"
  }
  if existing.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
    return "An output named \"\(trimmed)\" already exists"
  }
  return nil
}

// `base` if it doesn't collide (case-insensitively) with anything in `existing`, else
// "<base> 2", "<base> 3", ... until one doesn't.
func uniqueOutputName(base: String, existing: [String]) -> String {
  let existingLower = Set(existing.map { $0.lowercased() })
  guard existingLower.contains(base.lowercased()) else { return base }
  var suffix = 2
  while existingLower.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
  return "\(base) \(suffix)"
}

// Repairs a loaded/decoded `[OutputConfig]` so an `Output` can always be built from the result:
// truncates to `maxOutputs`, fixes blank/duplicate/reserved names, unparseable URLs, duplicate
// UUIDs, and out-of-bounds `customSize` (dropped, since decoding lets one through — see
// `PixelSize`). `repaired` is true iff anything above actually changed, telling the caller not to
// persist a repaired copy over whatever's actually stored.
func sanitizeOutputConfigs(
  _ configs: [OutputConfig], defaultName: String
) -> (configs: [OutputConfig], repaired: Bool) {
  var repaired = configs.count > maxOutputs
  var result = Array(configs.prefix(maxOutputs))

  var usedNames: [String] = []
  var usedIDs: Set<UUID> = []

  for i in result.indices {
    var config = result[i]

    if usedIDs.contains(config.id) {
      config.id = UUID()
      repaired = true
    }
    usedIDs.insert(config.id)

    let trimmedName = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidateName = trimmedName.isEmpty ? defaultName : trimmedName
    let finalName = uniqueOutputName(base: candidateName, existing: usedNames + reservedOutputNames)
    if finalName != config.name {
      config.name = finalName
      repaired = true
    }
    usedNames.append(finalName)

    let trimmedURL = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
    let finalURL = (!trimmedURL.isEmpty && URL(string: trimmedURL) != nil) ? trimmedURL : defaultOutputURL
    if finalURL != config.url {
      config.url = finalURL
      repaired = true
    }

    if let customSize = config.customSize,
      PixelSize(width: customSize.width, height: customSize.height) == nil
    {
      config.customSize = nil
      repaired = true
    }

    result[i] = config
  }

  return (result, repaired)
}

// Capture order for one tick: `ids` rotated to start at `startID` (the first output the previous
// tick didn't reach), or `ids` as-is if `startID` is nil or no longer present (removed output).
func captureOrder(ids: [UUID], startID: UUID?) -> [UUID] {
  guard let startID, let start = ids.firstIndex(of: startID) else { return ids }
  return Array(ids[start...] + ids[..<start])
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
  private var tileTimer: Timer?
  // First output the last tick didn't reach before the deadline; nil when every output was captured
  private var nextCaptureID: UUID?
  // Spike budget rule: past ~12 ms of capture per tick, the pages' own rAF and WebKit commits starve
  private let captureDeadline: TimeInterval = 0.012

  init(defaults: UserDefaults = appDefaults) {
    self.defaults = defaults
    let savedPort = defaults.integer(forKey: oscPortDefaultsKey)
    oscPort = validOSCPortRange.contains(savedPort) ? UInt16(savedPort) : defaultOSCPort

    let load = loadOutputs(defaults: defaults)
    var configs = load.configs
    var persist = load.persist
    if configs.isEmpty {
      appLog("`outputs` is empty; using one default output in memory (not saved)")
      configs = [.makeDefault(name: defaultSyphonName())]
      persist = false
    }
    let sanitized = sanitizeOutputConfigs(configs, defaultName: defaultSyphonName())
    configs = sanitized.configs
    if sanitized.repaired {
      appLog("Loaded `outputs` needed repair (cap/name/url/size/id); not saved this session")
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

  // Adds a new output with a default config (720p, default URL) and a unique default-based name
  // ("SyphonWeb", "SyphonWeb 2", …). Nil at `maxOutputs`.
  @discardableResult
  func addOutput() -> Output? {
    guard outputs.count < maxOutputs else { return nil }
    let name = uniqueOutputName(
      base: defaultSyphonName(), existing: outputs.map(\.name) + reservedOutputNames)
    let output = Output(config: .makeDefault(name: name))
    output.onConfigChange = { [weak self] in self?.saveOutputs() }
    outputs.append(output)
    saveOutputs()
    return output
  }

  // Copies url/resolution/customSize/transparent/captureWithoutClients from `id`'s output into a
  // new one named "<name> copy" (made unique). Nil if `id` doesn't exist or at `maxOutputs`.
  @discardableResult
  func duplicateOutput(_ id: UUID) -> Output? {
    guard outputs.count < maxOutputs, let source = outputs.first(where: { $0.id == id }) else {
      return nil
    }
    var config = source.config
    config.id = UUID()
    config.name = uniqueOutputName(
      base: "\(source.name) copy", existing: outputs.map(\.name) + reservedOutputNames)
    let output = Output(config: config)
    output.onConfigChange = { [weak self] in self?.saveOutputs() }
    outputs.append(output)
    saveOutputs()
    return output
  }

  // Refuses to remove the last output. Stops the removed output's Syphon server; selection moves
  // to the neighbour at the same index (clamped) if the removed output was selected.
  // `legacyOutputID` is untouched (a `let`): unscoped OSC then logs "no legacy output" rather than
  // silently retargeting.
  func removeOutput(_ id: UUID) {
    guard outputs.count > 1, let index = outputs.firstIndex(where: { $0.id == id }) else { return }
    outputs[index].frameServer?.stop()
    outputs.remove(at: index)
    if selectedOutputID == id {
      selectedOutputID = outputs[min(index, outputs.count - 1)].id
    }
    saveOutputs()
  }

  // Validates `newName` against the OTHER outputs, then trims and assigns it (which recreates the
  // output's Syphon server via `Output.name`'s `didSet`). Returns an error message, or nil on
  // success. This is the only path that should rename an output; assigning `Output.name` directly
  // skips validation.
  @discardableResult
  func renameOutput(_ id: UUID, to newName: String) -> String? {
    guard let output = outputs.first(where: { $0.id == id }) else { return "Output not found" }
    let others = outputs.filter { $0.id != id }.map(\.name)
    if let error = validateOutputName(newName, existing: others) { return error }
    output.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    saveOutputs()
    return nil
  }

  // One 60 Hz driver for all outputs, in `.common` mode so capture keeps running during menu
  // tracking and window drags (the old per-view timer ran in the default mode and paused). Plus a
  // 15 Hz tile refresh for the main window's previews.
  func startCapture() {
    guard captureTimer == nil else { return }
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.captureOutputs() }
    }
    RunLoop.main.add(timer, forMode: .common)
    captureTimer = timer

    let tiles = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshTiles() }
    }
    RunLoop.main.add(tiles, forMode: .common)
    tileTimer = tiles
  }

  // Round robin with a deadline: starts at the output the last tick didn't reach and stops
  // before the next capture once the deadline has passed, so one heavy output can't starve the
  // rest. The first capture always runs, even if it alone exceeds the deadline.
  private func captureOutputs() {
    let start = ProcessInfo.processInfo.systemUptime
    let order = captureOrder(ids: outputs.map(\.id), startID: nextCaptureID)
    nextCaptureID = nil
    for (i, id) in order.enumerated() {
      if i > 0, ProcessInfo.processInfo.systemUptime - start >= captureDeadline {
        nextCaptureID = id
        return
      }
      outputs.first { $0.id == id }?.captureFrame(commandQueue: commandQueue)
    }
  }

  private func refreshTiles() {
    for output in outputs where output.tileDirty {
      output.tileDirty = false
      output.previewImage = output.graphicsContext.flatMap(makeTileImage)
    }
  }
}

// Width cap for tile images, in pixels: tiles are ~260 pt wide, 2x
let tileImageMaxWidth = 640

// Small upright copy of a capture context for a tile. The capture buffer is bottom-up (row 0 is
// the page's bottom, as Syphon expects), so it is drawn flipped. Downscaled rather than kept as a
// full-size `makeImage()`: a full-size image alive at the next capture makes that capture copy
// the whole buffer (copy-on-write) and SwiftUI upload it; 1080p + 720p dropped from 60 to 45 fps.
// The snapshot here is released before the next capture, so it never copies.
func makeTileImage(_ context: CGContext) -> CGImage? {
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

#if DEBUG
  // A suite named by absolute path is a plist at that path, so nothing lands in
  // ~/Library/Preferences (cfprefsd leaves an empty plist there even after
  // removePersistentDomain). Shared by both self-checks below.
  private func withSuite(_ body: (UserDefaults) -> Void) {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(
      "SyphonWeb.selfcheck.\(UUID().uuidString)")
    let defaults = UserDefaults(suiteName: path)!
    body(defaults)
    defaults.removePersistentDomain(forName: path)
    try? FileManager.default.removeItem(atPath: path + ".plist")
  }

  // Runs at launch in debug builds; traps if outputs migration regresses. Each case uses its own
  // throwaway suite, removed afterwards.
  func checkOutputsMigration() {
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

  // Runs at launch in debug builds; traps if the phase 2 model (naming, sanitize, custom size
  // JSON shape) regresses. Pure logic only — no `Output`/`AppModel` construction, which would
  // create real Syphon servers.
  func checkOutputsModel() {
    // validateOutputName: empty, whitespace, duplicate (case-insensitive), reserved, valid
    precondition(validateOutputName("", existing: []) != nil)
    precondition(validateOutputName("   ", existing: []) != nil)
    precondition(validateOutputName("Main", existing: ["main"]) != nil)
    precondition(validateOutputName("URL", existing: []) != nil)
    precondition(validateOutputName("bookmark", existing: []) != nil)
    precondition(validateOutputName("Refresh", existing: []) != nil)
    precondition(validateOutputName("  Toast  ", existing: ["Main"]) == nil)

    // uniqueOutputName
    precondition(uniqueOutputName(base: "SyphonWeb", existing: []) == "SyphonWeb")
    precondition(uniqueOutputName(base: "SyphonWeb", existing: ["SyphonWeb"]) == "SyphonWeb 2")
    precondition(
      uniqueOutputName(base: "SyphonWeb", existing: ["SyphonWeb", "SyphonWeb 2"]) == "SyphonWeb 3")
    precondition(uniqueOutputName(base: "SyphonWeb", existing: ["syphonweb"]) == "SyphonWeb 2")

    // OutputConfig JSON: preset-only omits `customSize` (phase 1 shape, byte-identical)
    let preset = OutputConfig.makeDefault(name: "Preset")
    let presetJSON = encodeOutputs([preset])
    precondition(!presetJSON.contains("customSize"))
    precondition(decodeOutputs(presetJSON) == [preset])

    // customSize round-trips
    var custom = preset
    custom.customSize = PixelSize(width: 960, height: 1080)
    let customJSON = encodeOutputs([custom])
    precondition(customJSON.contains("customSize"))
    precondition(decodeOutputs(customJSON) == [custom])

    // Out-of-bounds customSize decodes (doesn't fail the whole array) and sanitize drops it
    let badJSON = """
      [{"id":"\(UUID().uuidString)","name":"Bad","url":"\(defaultOutputURL)",\
      "resolution":"hd720","customSize":{"width":99999,"height":5000},\
      "transparentBackground":false,"captureWithoutClients":true}]
      """
    guard let badConfigs = decodeOutputs(badJSON) else {
      preconditionFailure("out-of-bounds customSize should decode, not fail the array")
    }
    precondition(badConfigs[0].customSize?.width == 99999)
    let sanitizedBad = sanitizeOutputConfigs(badConfigs, defaultName: "Default")
    precondition(sanitizedBad.repaired && sanitizedBad.configs[0].customSize == nil)

    // sanitize: truncates to maxOutputs and marks repaired
    let five = (1...5).map { OutputConfig.makeDefault(name: "Out \($0)") }
    let capped = sanitizeOutputConfigs(five, defaultName: "Default")
    precondition(capped.configs.count == maxOutputs && capped.repaired)

    // sanitize: duplicate names made unique (case-insensitive)
    let dupNames = [OutputConfig.makeDefault(name: "Dup"), OutputConfig.makeDefault(name: "dup")]
    let dedupedNames = sanitizeOutputConfigs(dupNames, defaultName: "Default")
    precondition(dedupedNames.repaired && Set(dedupedNames.configs.map(\.name)).count == 2)

    // sanitize: duplicate UUIDs given fresh ids
    let sharedID = UUID()
    let dupIDs = [
      OutputConfig.makeDefault(id: sharedID, name: "A"),
      OutputConfig.makeDefault(id: sharedID, name: "B"),
    ]
    let dedupedIDs = sanitizeOutputConfigs(dupIDs, defaultName: "Default")
    precondition(dedupedIDs.repaired && Set(dedupedIDs.configs.map(\.id)).count == 2)

    // sanitize: unparseable/blank URL replaced with the default
    var badURL = OutputConfig.makeDefault(name: "BadURL")
    badURL.url = ""
    let fixedURL = sanitizeOutputConfigs([badURL], defaultName: "Default")
    precondition(fixedURL.repaired && fixedURL.configs[0].url == defaultOutputURL)

    // sanitize: clean input passes through unchanged, not repaired
    let clean = [OutputConfig.makeDefault(name: "Clean1"), OutputConfig.makeDefault(name: "Clean2")]
    let cleaned = sanitizeOutputConfigs(clean, defaultName: "Default")
    precondition(!cleaned.repaired && cleaned.configs == clean)

    // Loading a suite with 2 stored outputs keeps both (no phase 1 "keep one" truncation)
    withSuite { d in
      let two = encodeOutputs([.makeDefault(name: "One"), .makeDefault(name: "Two")])
      d.set(two, forKey: outputsKey)
      let load = loadOutputs(defaults: d, defaultName: "Default")
      precondition(load.persist && load.configs.count == 2)
      let sanitizedTwo = sanitizeOutputConfigs(load.configs, defaultName: "Default")
      precondition(!sanitizedTwo.repaired && sanitizedTwo.configs.count == 2)
    }

    // captureOrder: no/unknown start (e.g. the cursor's output was removed) -> as-is; rotation
    let (a, b, c) = (UUID(), UUID(), UUID())
    precondition(captureOrder(ids: [a, b, c], startID: nil) == [a, b, c])
    precondition(captureOrder(ids: [a, b, c], startID: a) == [a, b, c])
    precondition(captureOrder(ids: [a, b, c], startID: c) == [c, a, b])
    precondition(captureOrder(ids: [a, b, c], startID: b) == [b, c, a])
    precondition(captureOrder(ids: [a, c], startID: b) == [a, c])
    precondition(captureOrder(ids: [], startID: a) == [])

    // makeTileImage: capture buffer row 0 is the page's bottom, so the tile's first row must be
    // the buffer's last row (red here), and the size is capped at tileImageMaxWidth
    let capture = CGContext(
      data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let pixels = capture.data!.assumingMemoryBound(to: UInt8.self)
    for (i, byte) in [0, 0, 255, 255, 0, 0, 255, 255, 255, 0, 0, 255, 255, 0, 0, 255].enumerated() {
      pixels[i] = UInt8(byte)  // memory row 0 blue (page bottom), row 1 red (page top)
    }
    let tile = makeTileImage(capture)!
    let tileBytes = CFDataGetBytePtr(tile.dataProvider!.data)!
    precondition(tileBytes[0] == 255 && tileBytes[2] == 0, "tile image is upside down")
    let wide = CGContext(
      data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let wideTile = makeTileImage(wide)!
    precondition(wideTile.width == tileImageMaxWidth && wideTile.height == 360)

    appLog("Outputs model self-check passed")
  }
#endif
