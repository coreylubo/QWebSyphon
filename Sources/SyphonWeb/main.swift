import AppKit
import MetalKit
import SwiftOSC
import SwiftUI
import Syphon

// Stop app from napping
var activity: NSObjectProtocol?
activity = ProcessInfo().beginActivity(
  options: ProcessInfo.ActivityOptions.userInitiated, reason: "No Napping!")

#if DEBUG
  checkBookmarkLabelValidation()
#endif

// Init metal, syphon and SQLite
NSLog("Creating Metal device and Syphon server...")
let metalDevice: MTLDevice = MTLCreateSystemDefaultDevice()!
let server: SyphonMetalServer = SyphonMetalServer.init(name: "SyphonWeb", device: metalDevice)

NSLog("Opening SQLite database connection...")
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
  var state: WebViewState!
  var oscController: OSCController!
  var settingsWindow: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {

    // Create state object (default resolution, guessed backing scale until the window is shown)
    let state: WebViewState = WebViewState()
    state.frameServer = server
    self.state = state
    self.oscController = OSCController(state: state)

    // Main Window, sized from the guessed backing scale; corrected below once on screen
    let initialPreview = state.previewSize
    let mainSize: CGSize = CGSize(
      width: initialPreview.width + 200, height: initialPreview.height)
    mainWindow.setContentSize(mainSize)
    mainWindow.styleMask = [.closable, .titled]
    mainWindow.delegate = mainWindowDelegate
    mainWindow.title = "SyphonWeb"

    let mainViewInst = MainView(state: state)
    let mainView: NSHostingView<MainView> = NSHostingView(rootView: mainViewInst)
    mainView.frame = CGRect(origin: .zero, size: mainSize)
    mainView.autoresizingMask = [.height, .width]
    mainWindow.contentView!.addSubview(mainView)
    mainWindow.center()
    mainWindow.makeKeyAndOrderFront(mainWindow)

    // The pre-display backing scale is unreliable; read the real value now that the window is on
    // screen, and keep it current when the window moves between 1x/2x screens.
    state.backingScale = mainWindow.backingScaleFactor
    let window = mainWindow
    NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeBackingPropertiesNotification, object: window, queue: .main
    ) { _ in
      Task { @MainActor in
        state.backingScale = window.backingScaleFactor
      }
    }

    setupAppMenu()

    oscController.start(port: state.oscPort)

    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
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
    state.reload()
  }

  @objc private func showSettings() {
    if let settingsWindow {
      settingsWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let settingsViewInst = SettingsView(state: state, oscController: oscController)
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
  NSLog("You cannot run this app on this version of macOS!")
}
