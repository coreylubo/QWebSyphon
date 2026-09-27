import AppKit
import Combine
import MetalKit
import SwiftOSC
import SwiftUI
import Syphon

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

// AppKit Stuff
class WindowDelegate: NSObject, NSWindowDelegate {

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

    model.startCapture()
    oscController.start(port: model.oscPort)

    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Stop every Syphon server explicitly so clients drop the sources cleanly on quit.
    for output in model.outputs { output.frameServer?.stop() }
  }

  // "SyphonWeb — left · OSC 9001" (profile + actual bound port), or "SyphonWeb · OSC 9000"
  // for the default profile. Reflects the OSC controller's actual bound port (which may differ
  // from the configured/requested port after a fallback), not just the configured one.
  private func updateWindowTitle(port: UInt16?) {
    let base = profileName.map { "SyphonWeb — \($0)" } ?? "SyphonWeb"
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

    appMenu.addItem(
      NSMenuItem(
        title: "About SyphonWeb", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        keyEquivalent: ""))
    appMenu.addItem(NSMenuItem.separator())

    let settingsItem = NSMenuItem(
      title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
    settingsItem.target = self
    appMenu.addItem(settingsItem)
    appMenu.addItem(NSMenuItem.separator())

    appMenu.addItem(
      NSMenuItem(
        title: "Quit SyphonWeb", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

  @objc private func showSettings() {
    if let settingsWindow {
      settingsWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let settingsViewInst = SettingsView(model: model, oscController: oscController)
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
  let delegate: AppDelegate = AppDelegate()
  // Fallback on earlier versions
  app.delegate = delegate
  app.run()

} else {
  appLog("You cannot run this app on this version of macOS!")
}
