import CoreGraphics
import Foundation

// Output pixel dimensions the Syphon server publishes. The preview (web view + window) is sized
// separately, in points, by dividing these by the screen's backing scale factor.
public enum OutputResolution: String, CaseIterable, Codable, Sendable {
  case hd720
  case hd1080

  public var pixelSize: CGSize {
    switch self {
    case .hd720: CGSize(width: 1280, height: 720)
    case .hd1080: CGSize(width: 1920, height: 1080)
    }
  }

  public var label: String {
    switch self {
    case .hd720: "720p"
    case .hd1080: "1080p"
    }
  }
}

// A validated custom output pixel size (decision 6). The only way to build a valid one is the
// failable initializer, which enforces the bounds. `Codable` is synthesized directly on the two
// `Int` properties (bypassing the failable initializer) so an out-of-bounds size in stored JSON
// still decodes — `sanitizeOutputConfigs` is what turns it back into `nil`, rather than the whole
// `[OutputConfig]` array failing to decode.
public struct PixelSize: Codable, Hashable, Sendable {
  public static let widthRange = 16...3840
  public static let heightRange = 16...2160

  public let width: Int
  public let height: Int

  private init(uncheckedWidth: Int, uncheckedHeight: Int) {
    width = uncheckedWidth
    height = uncheckedHeight
  }

  public init?(width: Int, height: Int) {
    guard PixelSize.widthRange.contains(width), PixelSize.heightRange.contains(height) else {
      return nil
    }
    self.init(uncheckedWidth: width, uncheckedHeight: height)
  }

  public var cgSize: CGSize { CGSize(width: width, height: height) }
}

public let defaultOutputURL = "https://www.google.com"

// Hard cap on the number of outputs (phase 2 decision 2). Not derived from measurement of what's
// actually fast — see the spike table in docs/multi-output-spec.md for the supported mixes.
public let maxOutputs = 4

// Names that OSC scoped addresses (phase 4) reserve for command words, so they can never collide
// with an output name. Enforced now (phase 2) so an output can't be renamed into one later.
public let reservedOutputNames = ["url", "bookmark", "refresh", "enable"]

// Per-profile (appDefaults) key for the outputs model. The app's `saveOutputs` writes under this
// key directly, so it stays public; the other migration-only keys below are core-internal.
public let outputsKey = "outputs"

private let outputsMigrationVersionKey = "outputsMigrationVersion"
private let legacyOutputIDKey = "legacyOutputID"

// Pre-multi-output per-profile keys. Read once by migration and kept for rollback, never written.
private let legacySyphonNameKey = "syphonName"
private let legacyOutputResolutionKey = "outputResolution"
private let legacyTransparentBackgroundKey = "transparentBackground"

// Persisted settings of one output. The whole array is stored as one JSON string under `outputs`.
public struct OutputConfig: Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var url: String
  public var resolution: OutputResolution
  // Custom W×H (decision 6). Declared `Optional` so the synthesized `Codable` conformance
  // encodes it with `encodeIfPresent` (omitted entirely when nil — phase 1 JSON for preset-only
  // outputs stays byte-identical) and decodes it with `decodeIfPresent` (missing key on old JSON
  // decodes to nil, not a decode failure). An out-of-bounds size still decodes successfully here
  // (see `PixelSize`'s comment) — `sanitizeOutputConfigs` is what drops it.
  public var customSize: PixelSize?
  public var transparentBackground: Bool
  public var captureWithoutClients: Bool
  // The bookmark this output was last opened from (`Output.open(bookmark:)`), or nil if its URL
  // was set some other way (`navigate(to:)`, OSC `/url`, a fresh default). `Optional` for the same
  // reason as `customSize`: omitted entirely when nil so phase 1/2 JSON stays byte-identical, and
  // missing on old JSON decodes to nil rather than failing.
  public var bookmarkID: Int64?
  // Whether the output's server/capture/page are live (phase 4 decision). Custom `Codable` below
  // (not synthesized) so absent on old JSON decodes to `true` and it's encoded only when `false` —
  // phase 1/2/3 JSON for an enabled output stays byte-identical.
  public var enabled: Bool

  public init(
    id: UUID, name: String, url: String, resolution: OutputResolution,
    customSize: PixelSize? = nil, transparentBackground: Bool, captureWithoutClients: Bool,
    bookmarkID: Int64? = nil, enabled: Bool = true
  ) {
    self.id = id
    self.name = name
    self.url = url
    self.resolution = resolution
    self.customSize = customSize
    self.transparentBackground = transparentBackground
    self.captureWithoutClients = captureWithoutClients
    self.bookmarkID = bookmarkID
    self.enabled = enabled
  }

  // `name` has no default here (unlike the app's pre-move version): the old default called
  // `defaultSyphonName()`, which reads the app's `--profile` and can't live in core. The app
  // always passes a name explicitly (see `defaultOutputBaseName()`).
  public static func makeDefault(id: UUID = UUID(), name: String) -> OutputConfig {
    OutputConfig(
      id: id, name: name, url: defaultOutputURL, resolution: .hd720, transparentBackground: false,
      captureWithoutClients: true, bookmarkID: nil, enabled: true)
  }
}

extension OutputConfig: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, name, url, resolution, customSize, transparentBackground, captureWithoutClients,
      bookmarkID, enabled
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    url = try container.decode(String.self, forKey: .url)
    resolution = try container.decode(OutputResolution.self, forKey: .resolution)
    customSize = try container.decodeIfPresent(PixelSize.self, forKey: .customSize)
    transparentBackground = try container.decode(Bool.self, forKey: .transparentBackground)
    captureWithoutClients = try container.decode(Bool.self, forKey: .captureWithoutClients)
    bookmarkID = try container.decodeIfPresent(Int64.self, forKey: .bookmarkID)
    // Absent on JSON from before this field existed (phase 1/2/3): defaults to enabled.
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(url, forKey: .url)
    try container.encode(resolution, forKey: .resolution)
    try container.encodeIfPresent(customSize, forKey: .customSize)
    try container.encode(transparentBackground, forKey: .transparentBackground)
    try container.encode(captureWithoutClients, forKey: .captureWithoutClients)
    try container.encodeIfPresent(bookmarkID, forKey: .bookmarkID)
    // Written only when disabled, so an enabled output's JSON stays byte-identical to before this
    // field existed (phase 1/2/3).
    if !enabled { try container.encode(enabled, forKey: .enabled) }
  }
}

public func encodeOutputs(_ configs: [OutputConfig]) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  // Plain Codable struct with no floats: encoding can't fail
  return String(decoding: try! encoder.encode(configs), as: UTF8.self)
}

public func decodeOutputs(_ raw: Any?) -> [OutputConfig]? {
  guard let string = raw as? String else { return nil }
  return try? JSONDecoder().decode([OutputConfig].self, from: Data(string.utf8))
}

public struct OutputsLoad: Equatable {
  public var configs: [OutputConfig]
  public var legacyID: UUID?
  // Migration: the caller writes `configs`, reads them back, then sets `legacyOutputID` + marker
  public var shouldWrite: Bool
  // False for in-memory fallbacks, so later saves don't overwrite what's stored
  public var persist: Bool
  // Stored `outputs` is valid but `legacyOutputID`/marker are missing (a migration interrupted
  // after writing `outputs`): the caller writes only those two, leaving `outputs` untouched
  public var shouldCompleteMarker: Bool

  public init(
    configs: [OutputConfig], legacyID: UUID?, shouldWrite: Bool, persist: Bool,
    shouldCompleteMarker: Bool = false
  ) {
    self.configs = configs
    self.legacyID = legacyID
    self.shouldWrite = shouldWrite
    self.persist = persist
    self.shouldCompleteMarker = shouldCompleteMarker
  }
}

// Decides what to load from a profile's defaults. Reads only; writing is `loadOutputs`' job.
// - Stored `outputs` that decodes (even `[]`) is used as-is, marker or not: never overwritten.
// - Stored `outputs` that doesn't decode, or no `outputs` once the marker is set: one default
//   output in memory, nothing written (kept for inspection/rollback).
// - No `outputs` and no marker: build output #1 (the legacy output) from the legacy keys.
// `defaultName` has no default (unlike the app's pre-move version, which defaulted to
// `defaultOutputBaseName()` — app-only, reads the profile); the app always passes it explicitly.
// `log` defaults to a no-op so tests don't have to supply one; the app passes `appLog`.
public func migrateOutputs(
  defaults: UserDefaults, defaultName: String, newID: UUID = UUID(),
  log: (String) -> Void = { _ in }
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
    log(
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
// marker unset so the next launch retries. `write` is injectable for tests. See `migrateOutputs`
// for why `defaultName` has no default and `log` does.
public func loadOutputs(
  defaults: UserDefaults, defaultName: String, write: ((String) -> Void)? = nil,
  log: (String) -> Void = { _ in }
) -> OutputsLoad {
  let load = migrateOutputs(defaults: defaults, defaultName: defaultName, log: log)
  if load.shouldCompleteMarker, let legacyID = load.legacyID {
    defaults.set(legacyID.uuidString, forKey: legacyOutputIDKey)
    defaults.set(1, forKey: outputsMigrationVersionKey)
    log("Completed interrupted `outputs` migration, legacy output \(legacyID)")
    return load
  }
  guard load.shouldWrite, let legacyID = load.legacyID else { return load }

  log("Migrating legacy settings to `outputs`: \(load.configs)")
  (write ?? { defaults.set($0, forKey: outputsKey) })(encodeOutputs(load.configs))
  guard decodeOutputs(defaults.object(forKey: outputsKey)) == load.configs else {
    log("`outputs` read-back failed; migration marker not set, will retry next launch")
    return load
  }
  defaults.set(legacyID.uuidString, forKey: legacyOutputIDKey)
  defaults.set(1, forKey: outputsMigrationVersionKey)
  log("Migrated to `outputs` (version 1), legacy output \(legacyID)")
  return load
}

// Repairs a loaded/decoded `[OutputConfig]` so an `Output` can always be built from the result:
// truncates to `maxOutputs`, fixes blank/duplicate/reserved names, unparseable URLs, duplicate
// UUIDs, and out-of-bounds `customSize` (dropped, since decoding lets one through — see
// `PixelSize`). `repaired` is true iff anything above actually changed, telling the caller not to
// persist a repaired copy over whatever's actually stored.
public func sanitizeOutputConfigs(
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
