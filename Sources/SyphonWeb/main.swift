import AppKit
import MetalKit
import SwiftOSC
import SwiftUI
import Syphon

// Stop app from napping
var activity: NSObjectProtocol?
activity = ProcessInfo().beginActivity(
  options: ProcessInfo.ActivityOptions.userInitiated, reason: "No Napping!")

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
  var oscServer: OSCUDPServer?

  func applicationDidFinishLaunching(_ notification: Notification) {

    // Create state object (default resolution, guessed backing scale until the window is shown)
    let state: WebViewState = WebViewState()
    state.frameServer = server

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

    oscServer = startOSCServer(state: state)

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

    appMenu.addItem(
      NSMenuItem(
        title: "Quit SyphonWeb", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    )

    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    NSApp.mainMenu = mainMenu
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
