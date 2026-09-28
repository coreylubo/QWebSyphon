import Combine
import Foundation
import CoreGraphics
import Metal
import QWebSyphonCore

// Base name for newly added/default outputs: a slug of `defaultSyphonName()` (e.g. "QWebSyphon
// left" -> "QWebSyphon-left"), so `uniqueOutputName(base: defaultOutputBaseName(), ...)` always
// produces an OSC-addressable name. Stays in the app: `defaultSyphonName()` reads the profile.
func defaultOutputBaseName() -> String { slugForOutputName(defaultSyphonName()) }

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
  private var cancellables: Set<AnyCancellable> = []

  init(defaults: UserDefaults = appDefaults) {
    self.defaults = defaults
    let savedPort = defaults.integer(forKey: oscPortDefaultsKey)
    oscPort = validOSCPortRange.contains(savedPort) ? UInt16(savedPort) : defaultOSCPort

    let load = loadOutputs(defaults: defaults, defaultName: defaultOutputBaseName(), log: appLog)
    var configs = load.configs
    var persist = load.persist
    if configs.isEmpty {
      appLog("`outputs` is empty; using one default output in memory (not saved)")
      configs = [.makeDefault(name: defaultOutputBaseName())]
      persist = false
    }
    let sanitized = sanitizeOutputConfigs(configs, defaultName: defaultOutputBaseName())
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

    // Bookmarks require macOS 14 (`@Observable`); the app itself only runs on macOS 14+ (see
    // main.swift's `#available` gate), so this always runs in practice.
    if #available(macOS 14, *) {
      reconcileBookmarkIDs(Bookmark.getAll())
      bookmarksDidChangePublisher
        .sink { [weak self] _ in self?.reconcileBookmarkIDs(Bookmark.getAll()) }
        .store(in: &cancellables)
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
  // ("QWebSyphon", "QWebSyphon-2", …). Nil at `maxOutputs`.
  @discardableResult
  func addOutput() -> Output? {
    guard outputs.count < maxOutputs else { return nil }
    let name = uniqueOutputName(
      // Prefix leaves room for a "-N" suffix within the 64-character name limit
      base: String(defaultOutputBaseName().prefix(60)),
      existing: outputs.map(\.name) + reservedOutputNames)
    let output = Output(config: .makeDefault(name: name))
    output.onConfigChange = { [weak self] in self?.saveOutputs() }
    outputs.append(output)
    saveOutputs()
    return output
  }

  // Copies url/resolution/customSize/transparent/captureWithoutClients from `id`'s output into a
  // new one named "<name>-copy" (made unique). Nil if `id` doesn't exist or at `maxOutputs`.
  @discardableResult
  func duplicateOutput(_ id: UUID) -> Output? {
    guard outputs.count < maxOutputs, let source = outputs.first(where: { $0.id == id }) else {
      return nil
    }
    var config = source.config
    config.id = UUID()
    config.bookmarkID = nil
    config.name = uniqueOutputName(
      // Slugged (a grandfathered source name may have spaces) and trimmed so "-copy-N" fits in 64
      base: "\(slugForOutputName(source.name).prefix(54))-copy",
      existing: outputs.map(\.name) + reservedOutputNames)
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

  // Clears any output's `bookmarkID` whose bookmark is gone or whose URL no longer matches (the
  // bookmark was deleted, or its URL was edited elsewhere). Called at launch and on every
  // `bookmarksDidChangePublisher` event (delete, URL edit, another profile's changes) so a stale
  // `bookmarkID` never outlives what it pointed to.
  @available(macOS 14, *)
  func reconcileBookmarkIDs(_ bookmarks: [Bookmark]) {
    var changed = false
    for output in outputs {
      guard let bookmarkID = output.bookmarkID else { continue }
      let stillMatches = bookmarks.contains {
        $0.id == bookmarkID && Output.normalizedURL($0.url) == output.url
      }
      if !stillMatches {
        output.bookmarkID = nil
        changed = true
      }
    }
    if changed { saveOutputs() }
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
