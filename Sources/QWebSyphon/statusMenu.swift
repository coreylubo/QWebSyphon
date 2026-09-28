import AppKit
import QWebSyphonCore

// Status bar item + menu, owned by AppDelegate for the app's lifetime. Icon composition is
// adapted from tcb-gross-prophets-osc-monitor/mac/Prompter/main.swift's `AppController.statusImage`:
// a template SF Symbol tinted to the menu bar's current foreground colour, composited with a small
// filled circle for the status colour, then marked non-template so the dot survives (a template
// image would otherwise get flattened to one colour). The per-row "only the bullet is coloured"
// treatment below is adapted from the same file's `rebuildMonitorMenuItems`.
@available(macOS 14, *)
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
  private let model: AppModel
  private let oscController: OSCController
  private let showWindow: (UUID?) -> Void
  private let showSettingsAction: () -> Void

  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let menu = NSMenu()
  private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  // Marks where the per-output rows go (inserted just before it); itself never removed.
  private let rowsEndMarker = NSMenuItem.separator()

  private var outputItems: [NSMenuItem] = []
  private var timer: Timer?

  init(
    model: AppModel, oscController: OSCController,
    showWindow: @escaping (UUID?) -> Void, showSettings: @escaping () -> Void
  ) {
    self.model = model
    self.oscController = oscController
    self.showWindow = showWindow
    self.showSettingsAction = showSettings
    super.init()

    statusItem.button?.imagePosition = .imageOnly
    menu.delegate = self
    statusItem.menu = menu

    statusLine.isEnabled = false
    menu.addItem(statusLine)
    menu.addItem(.separator())
    menu.addItem(rowsEndMarker)

    let showWindowItem = NSMenuItem(
      title: "Show Window", action: #selector(showWindowTapped), keyEquivalent: "")
    showWindowItem.target = self
    menu.addItem(showWindowItem)

    let settingsItem = NSMenuItem(
      title: "Settings…", action: #selector(showSettingsTapped), keyEquivalent: "")
    settingsItem.target = self
    menu.addItem(settingsItem)

    menu.addItem(.separator())

    let quitItem = NSMenuItem(
      title: "Quit SyphonWeb", action: #selector(quitTapped), keyEquivalent: "")
    quitItem.target = self
    menu.addItem(quitItem)

    refreshIcon()

    // Same weak-self/invalidate-if-gone pattern as OutputStats' timer (statusBar.swift): the run
    // loop owns the timer, not `self`.
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }
      Task { @MainActor in self.refreshIcon() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  // Menu rows can go stale between polls (an output added/removed, fps ticking) with no cost to
  // anyone since nobody's looking; only rebuild them when the menu is actually about to be shown.
  func menuWillOpen(_ menu: NSMenu) {
    refreshIcon()
    rebuildOutputRows()
  }

  private func refreshIcon() {
    let color = Self.nsColor(for: overallLevel())
    statusItem.button?.image = Self.statusImage(color: color)
    let summary = statusSummaryText()
    statusItem.button?.toolTip = summary
    statusLine.title = summary
  }

  private func rebuildOutputRows() {
    for item in outputItems { menu.removeItem(item) }
    outputItems = []
    guard let insertionIndex = menu.items.firstIndex(of: rowsEndMarker) else { return }

    let bookmarks = Bookmark.getAll()
    for (offset, output) in model.outputs.enumerated() {
      let item = makeRow(for: output, bookmarks: bookmarks)
      menu.insertItem(item, at: insertionIndex + offset)
      outputItems.append(item)
    }
  }

  private func makeRow(for output: Output, bookmarks: [Bookmark]) -> NSMenuItem {
    let level = outputStatusLevel(
      OutputHealth(loading: output.loading, failed: output.loadError != nil, fps: output.stats.fps))
    let fpsText = output.loading ? "— fps" : "\(output.stats.fps) fps"
    let clientsText = (output.frameServer?.hasClients ?? false) ? "clients" : "no clients"
    let sourceText = bookmarkOrHostLabel(for: output, bookmarks: bookmarks)
    let text = "●  \(output.name) — \(fpsText) · \(clientsText) · \(sourceText)"

    let item = NSMenuItem(title: "", action: #selector(rowTapped(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = output.id

    // Only the bullet carries the colour; coloured text on the translucent menu is hard to read
    // (same call as Prompter's rebuildMonitorMenuItems).
    let attributed = NSMutableAttributedString(
      string: text,
      attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.menuFont(ofSize: 0)])
    attributed.addAttribute(
      .foregroundColor, value: Self.nsColor(for: level), range: NSRange(location: 0, length: 1))
    item.attributedTitle = attributed
    return item
  }

  // The bookmark this output was last opened from, if it still resolves; else the URL's host (or
  // the whole URL for a host-less address like a `file://` URL).
  private func bookmarkOrHostLabel(for output: Output, bookmarks: [Bookmark]) -> String {
    if let id = output.bookmarkID, let bookmark = bookmarks.first(where: { $0.id == id }) {
      return bookmark.name
    }
    return output.url.host ?? output.url.absoluteString
  }

  // "[<profile> · ]N outputs · M with clients · OSC <port>" (or the OSC status text when it isn't
  // bound to a port yet, e.g. "Failed to bind…").
  private func statusSummaryText() -> String {
    let profilePrefix = profileName.map { "\($0) · " } ?? ""
    let n = model.outputs.count
    let withClients = model.outputs.filter { $0.frameServer?.hasClients ?? false }.count
    let oscText = oscController.port.map { "OSC \($0)" } ?? oscController.status
    return "\(profilePrefix)\(n) outputs · \(withClients) with clients · \(oscText)"
  }

  private func overallLevel() -> StatusLevel {
    let healths = model.outputs.map {
      OutputHealth(loading: $0.loading, failed: $0.loadError != nil, fps: $0.stats.fps)
    }
    return statusLevel(outputs: healths, oscListening: oscController.port != nil)
  }

  private static func nsColor(for level: StatusLevel) -> NSColor {
    switch level {
    case .ok: return .systemGreen
    case .warning: return .systemOrange
    case .error: return .systemRed
    }
  }

  // `rectangle.on.rectangle` tinted to the menu bar foreground, with a small filled circle at the
  // bottom-trailing corner for the status colour. See the type comment for the composition
  // technique (adapted from Prompter's `statusImage`); the dot placement itself is this icon's own
  // corner-badge position, not ported from that file's flood-fill measurement (which was specific
  // to `display.2`).
  private static func statusImage(color: NSColor) -> NSImage {
    let height: CGFloat = 18
    guard
      let symbol = NSImage(
        systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "SyphonWeb")
    else {
      return NSImage(size: NSSize(width: height, height: height))
    }
    symbol.isTemplate = true
    let aspect = symbol.size.height > 0 ? symbol.size.width / symbol.size.height : 1
    let size = NSSize(width: (height * aspect).rounded(), height: height)

    let image = NSImage(size: size, flipped: false) { rect in
      // Tint the template glyph with the menu bar's foreground colour: fill with it, then keep
      // only the pixels the glyph itself covers (.destinationIn).
      NSColor.labelColor.set()
      rect.fill()
      symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)

      let dotDiameter = rect.height * 0.4
      let dotRect = NSRect(
        x: rect.width - dotDiameter * 0.8,
        y: -dotDiameter * 0.1,
        width: dotDiameter,
        height: dotDiameter
      )
      color.setFill()
      NSBezierPath(ovalIn: dotRect).fill()
      return true
    }
    image.isTemplate = false
    return image
  }

  @objc private func rowTapped(_ sender: NSMenuItem) {
    showWindow(sender.representedObject as? UUID)
  }

  @objc private func showWindowTapped() {
    showWindow(nil)
  }

  @objc private func showSettingsTapped() {
    showSettingsAction()
  }

  @objc private func quitTapped() {
    NSApp.terminate(nil)
  }
}
