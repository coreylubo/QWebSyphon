import AppKit
import Combine
import MetalKit
import SwiftOSC
import SwiftUI
import Syphon

// Copy pre-rename SyphonWeb settings (once) before AppKit or anything else reads defaults.
_ = appDefaults

// Stop app from napping
var activity: NSObjectProtocol?
activity = ProcessInfo().beginActivity(
  options: ProcessInfo.ActivityOptions.userInitiated, reason: "No Napping!")

// Init metal and SQLite. The Syphon server itself is created per-instance in
// AppDelegate once the final name is known (see Bug 1: creating it here with a placeholder
// name and renaming afterwards means QLab's initial Syphon announce carries the wrong name).
appLog("Creating Metal device...")
let metalDevice: MTLDevice = MTLCreateSystemDefaultDevice()!

appLog("Opening SQLite database connection...")
nonisolated(unsafe) let databaseConn = initDatabase()

// Whether the Dock icon should be shown, persisted per profile in `appDefaults` (absent = true).
// Read at launch to set the initial activation policy, and live-toggled from Settings' "App"
// section (`AppDelegate.setDockIconVisible`).
let showDockIconDefaultsKey = "showDockIcon"

func showDockIconEnabled(defaults: UserDefaults = appDefaults) -> Bool {
  defaults.object(forKey: showDockIconDefaultsKey) == nil ? true : defaults.bool(forKey: showDockIconDefaultsKey)
}

// AppKit Stuff
class WindowDelegate: NSObject, NSWindowDelegate {

  // With the Dock icon hidden, the app has no other way back on screen than the menu bar (no Dock
  // icon, no main menu), so closing the window just hides it — outputs and OSC keep running, and
  // "Show Window" in the status menu brings it back. With the Dock icon shown, unchanged: closing
  // quits (windowWillClose below).
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard !showDockIconEnabled() else { return true }
    sender.orderOut(nil)
    return false
  }

  func windowWillClose(_ notification: Notification) {
    NSApplication.shared.terminate(0)
  }
}

@available(macOS 14, *)
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  let mainWindow: NSWindow = NSWindow()
  let mainWindowDelegate: WindowDelegate = WindowDelegate()

  // Retained so the Settings… menu item and OSC dispatch keep working for the app's lifetime.
  var model: AppModel!
  var oscController: OSCController!
  var settingsWindow: NSWindow?
  var outputHost: OutputHost?
  var statusMenuController: StatusMenuController!
  private var oscPortCancellable: AnyCancellable?

  func applicationDidFinishLaunching(_ notification: Notification) {

    // Loads (and on first launch migrates) the outputs and creates each output's Syphon server
    // with its final name.
    let model = AppModel()
    self.model = model
    self.oscController = OSCController(model: model)
    // @Published publishes on willSet (i.e. with the incoming value, before the stored property
    // is actually updated) — use the value the sink receives directly rather than re-reading
    // `oscController.port` inside the closure, which would still see the old value.
    oscPortCancellable = oscController.$port.sink { [weak self] port in
      self?.updateWindowTitle(port: port)
    }

    // Main Window: sidebar + a 2x2 grid of 400x225 tiles + status bar. Resizable; the tiles are
    // images, so nothing depends on its size.
    let mainSize = CGSize(width: 200 + 2 * 400, height: 2 * 225 + statusBarHeight)
    mainWindow.styleMask = [.closable, .titled, .miniaturizable, .resizable]
    mainWindow.setContentSize(mainSize)
    mainWindow.contentMinSize = CGSize(width: 700, height: 420)
    mainWindow.delegate = mainWindowDelegate

    let mainViewInst = MainView(model: model, oscController: oscController)
    let mainView: NSHostingView<MainView> = NSHostingView(rootView: mainViewInst)
    mainView.frame = CGRect(origin: .zero, size: mainSize)
    mainView.autoresizingMask = [.height, .width]
    mainWindow.contentView!.addSubview(mainView)
    mainWindow.center()
    mainWindow.makeKeyAndOrderFront(mainWindow)

    // Hosts every output's web view; created once the main window is on screen, since it follows
    // that window's screen (and takes its backing scale from there).
    outputHost = OutputHost(model: model, mainWindow: mainWindow)

    setupAppMenu()

    statusMenuController = StatusMenuController(
      model: model, oscController: oscController,
      showWindow: { [weak self] outputID in self?.showMainWindow(selecting: outputID) },
      showSettings: { [weak self] in self?.showSettings() }
    )

    model.startCapture()
    oscController.start(port: model.oscPort)

    // Accessory mode has no Dock icon and no main menu (⌘, / ⌘Q vanish); the status menu's
    // Settings…/Quit items are the only way back in that mode, and must work on their own.
    NSApp.setActivationPolicy(showDockIconEnabled() ? .regular : .accessory)
    NSApp.activate(ignoringOtherApps: true)
  }

  // Brings the main window to front and, if `outputID` is given (a status-menu row click),
  // selects that output first. Works the same whether the app is `.regular` or `.accessory`.
  func showMainWindow(selecting outputID: UUID? = nil) {
    if let outputID { model.selectedOutputID = outputID }
    mainWindow.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  // Settings' "App" section toggle. Persists, then applies live; switching to `.accessory` still
  // needs an explicit re-activate afterwards or the app can drop out of the foreground with the
  // main window behind other apps.
  func setDockIconVisible(_ visible: Bool) {
    appDefaults.set(visible, forKey: showDockIconDefaultsKey)
    NSApp.setActivationPolicy(visible ? .regular : .accessory)
    if !visible {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Stop every Syphon server explicitly so clients drop the sources cleanly on quit.
    for output in model.outputs { output.frameServer?.stop() }
  }

  // "QWebSyphon — left · OSC 9001" (profile + actual bound port), or "QWebSyphon · OSC 9000"
  // for the default profile. Reflects the OSC controller's actual bound port (which may differ
  // from the configured/requested port after a fallback), not just the configured one.
  private func updateWindowTitle(port: UInt16?) {
    let base = profileName.map { "QWebSyphon — \($0)" } ?? "QWebSyphon"
    guard let port else {
      mainWindow.title = base
      return
    }
    mainWindow.title = "\(base) · OSC \(port)"
  }

  private func setupAppMenu() {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()

    let aboutItem = NSMenuItem(
      title: "About QWebSyphon", action: #selector(showAbout), keyEquivalent: "")
    aboutItem.target = self
    appMenu.addItem(aboutItem)
    appMenu.addItem(NSMenuItem.separator())

    let settingsItem = NSMenuItem(
      title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
    settingsItem.target = self
    appMenu.addItem(settingsItem)
    appMenu.addItem(NSMenuItem.separator())

    appMenu.addItem(
      NSMenuItem(
        title: "Quit QWebSyphon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    )

    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    let editMenuItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(
      NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    editMenu.addItem(
      NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editMenu.addItem(
      NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    editMenu.addItem(
      NSMenuItem(
        title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    let viewMenuItem = NSMenuItem()
    let viewMenu = NSMenu(title: "View")
    let reloadItem = NSMenuItem(
      title: "Reload Page", action: #selector(reloadPage), keyEquivalent: "r")
    reloadItem.target = self
    viewMenu.addItem(reloadItem)
    viewMenuItem.submenu = viewMenu
    mainMenu.addItem(viewMenuItem)

    NSApp.mainMenu = mainMenu
  }

  @objc private func reloadPage() {
    model.selectedOutput.reload()
  }

  // Standard about panel with programmatic credits (replaces Credits.rtf, which only the bundled
  // app read — `swift run` never picked it up). Centered, small, label-colored so it holds up in
  // both appearances.
  @objc private func showAbout() {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    let baseAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraphStyle,
    ]

    func line(_ text: String, link: String? = nil) -> NSAttributedString {
      var attributes = baseAttributes
      if let link { attributes[.link] = URL(string: link)! }
      return NSAttributedString(string: text, attributes: attributes)
    }

    let credits = NSMutableAttributedString()
    for piece in [
      line("The Great Experience Company", link: "https://gr8x.co"),
      line("\n\n"),
      line("Based on SyphonWeb by Digit (@doawoo)"),
      line("\n"),
      line("github.com/doawoo/SyphonWeb", link: "https://github.com/doawoo/SyphonWeb"),
      line("\n"),
      line("puppy.surf", link: "https://puppy.surf"),
      line("\n\n"),
      line("Thanks to the "),
      line("Syphon", link: "https://syphon.github.io"),
      line(" project."),
    ] {
      credits.append(piece)
    }

    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "QWebSyphon", .credits: credits])
  }

  @objc private func showSettings() {
    if let settingsWindow {
      settingsWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let settingsViewInst = SettingsView(
      model: model, oscController: oscController,
      onDockIconChange: { [weak self] visible in self?.setDockIconVisible(visible) })
    let hostingView = NSHostingView(rootView: settingsViewInst)

    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 460, height: 520),
      styleMask: [.closable, .titled],
      backing: .buffered,
      defer: false
    )
    window.title = "Settings"
    window.contentView = hostingView
    window.isReleasedWhenClosed = false
    window.center()
    settingsWindow = window

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

// Start!
if #available(macOS 14, *) {
  let app: NSApplication = NSApplication.shared
  // Always dark: set before AppDelegate (and its main window) is created, so every window,
  // popover, menu and the About panel comes up dark from the start.
  app.appearance = NSAppearance(named: .darkAqua)
  let delegate: AppDelegate = AppDelegate()
  // Fallback on earlier versions
  app.delegate = delegate
  app.run()

} else {
  appLog("You cannot run this app on this version of macOS!")
}
