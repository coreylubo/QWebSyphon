import AppKit
import Combine
import WebKit

// Never key or main: the host window must not take focus or appear in the UI.
private final class OutputHostWindow: NSWindow {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

// Hosts every output's web view in one invisible window (spec decision 5). Phase 0 findings: an
// alpha-0 borderless window keeps painting even when everything else is covered or the app is
// inactive, and web views stacked as siblings keep painting; hidden, offscreen and low-alpha
// hosting do not. The main window shows captured images (tiles), never a live web view.
@MainActor
final class OutputHost {
  private let model: AppModel
  private weak var mainWindow: NSWindow?
  private let window: OutputHostWindow
  private var controllers: [UUID: OutputWebViewController] = [:]
  private var outputsCancellable: AnyCancellable?
  private var observers: [NSObjectProtocol] = []

  init(model: AppModel, mainWindow: NSWindow) {
    self.model = model
    self.mainWindow = mainWindow

    window = OutputHostWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    window.level = .screenSaver
    window.isReleasedWhenClosed = false
    window.hasShadow = false
    layoutWindow()
    window.orderFrontRegardless()

    // @Published emits on willSet: use the array the sink receives, not `model.outputs`
    outputsCancellable = model.$outputs.sink { [weak self] outputs in self?.sync(outputs) }

    let center = NotificationCenter.default
    let followMain: (Notification) -> Void = { [weak self] _ in
      MainActor.assumeIsolated {
        self?.layoutWindow()
        self?.applyBackingScale()
      }
    }
    observers = [
      center.addObserver(
        forName: NSWindow.didChangeScreenNotification, object: mainWindow, queue: .main,
        using: followMain),
      center.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main,
        using: followMain),
      center.addObserver(
        forName: NSWindow.didChangeBackingPropertiesNotification, object: window, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.applyBackingScale() } },
    ]
  }

  // Creates controllers for new outputs and tears down those of removed outputs
  private func sync(_ outputs: [Output]) {
    let ids = Set(outputs.map(\.id))
    for (id, controller) in controllers where !ids.contains(id) {
      controller.tearDown()
      controllers[id] = nil
    }
    for output in outputs where controllers[output.id] == nil {
      output.backingScale = window.backingScaleFactor
      controllers[output.id] = OutputWebViewController(
        output: output, container: window.contentView!,
        onResize: { [weak self] in self?.layoutWindow() })
    }
    layoutWindow()
  }

  // Every output shares the host window, so they all get its backing scale. Each controller
  // re-provisions synchronously from its `backingScale` subscription (no-op if unchanged).
  private func applyBackingScale() {
    for output in model.outputs { output.backingScale = window.backingScaleFactor }
  }

  // Size = largest web view (all stacked at 0,0), placed at the bottom-left of the main window's
  // screen's visible frame, pulled down/left only as far as needed to stay on that screen.
  // ponytail: on a 1x screen a 1080p view is 1920x1080 pt, which covers the whole screen
  // (menu bar included) and a larger custom size extends past it. Spike 4a: fully offscreen
  // freezes; partially offscreen is untested. Upgrade: one host window per screen/scale.
  private func layoutWindow() {
    let size = controllers.values.reduce(CGSize(width: 1, height: 1)) {
      CGSize(width: max($0.width, $1.viewSize.width), height: max($0.height, $1.viewSize.height))
    }
    guard let screen = mainWindow?.screen ?? NSScreen.main else {
      window.setContentSize(size)
      return
    }
    let visible = screen.visibleFrame
    let full = screen.frame
    let origin = CGPoint(
      x: max(full.minX, min(visible.minX, full.maxX - size.width)),
      y: max(full.minY, min(visible.minY, full.maxY - size.height)))
    window.setFrame(CGRect(origin: origin, size: size), display: false)
  }
}

// Owns one output's WKWebView: creates it in the host window, is its navigation delegate
// (WKWebView holds the delegate weakly; the host retains this controller) and applies the
// output's URL, transparency, pixel size and backing scale to it.
@MainActor
final class OutputWebViewController: NSObject, WKNavigationDelegate {
  private let output: Output
  private let webView = WKWebView()
  private let onResize: () -> Void
  private var cancellables: Set<AnyCancellable> = []
  private var lastPixelSize: CGSize?
  private var lastBackingScale: CGFloat?

  var viewSize: CGSize { webView.frame.size }

  init(output: Output, container: NSView, onResize: @escaping () -> Void) {
    self.output = output
    self.onResize = onResize
    super.init()

    webView.navigationDelegate = self
    container.addSubview(webView)  // frame origin (0,0): all outputs stacked
    output.webView = webView

    // @Published emits on willSet, before the property is stored: every sink uses the values it
    // receives and never re-reads the output's properties. Size first, so the first load already
    // lays out at the output size.
    // CombineLatest caches each publisher's latest value, so every emission carries the new value
    // of whichever property changed plus the current values of the others.
    Publishers.CombineLatest3(output.$resolution, output.$customSize, output.$backingScale)
      .sink { [weak self] resolution, customSize, scale in
        // Same rule as `Output.pixelSize`, from the incoming values
        self?.applySize(pixelSize: customSize?.cgSize ?? resolution.pixelSize, scale: scale)
      }
      .store(in: &cancellables)

    output.$transparentBackground
      .removeDuplicates()
      .sink { [weak self] transparent in
        guard let webView = self?.webView else { return }
        // `drawsBackground` is undocumented KVC on WKWebView; guarded so an unrecognized key never
        // crashes.
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
          webView.setValue(!transparent, forKey: "drawsBackground")
        }
      }
      .store(in: &cancellables)

    output.$url
      .sink { [weak self] url in self?.load(url, enabled: output.enabled) }
      .store(in: &cancellables)

    // Skips the initial value: `load(_:)`'s `enabled` guard already covers the launch-disabled
    // case, and disabling/enabling itself only matters on a later change.
    output.$enabled
      .dropFirst()
      .sink { [weak self] enabled in self?.setEnabled(enabled) }
      .store(in: &cancellables)
  }

  // The single place anything loads a URL into this output's web view — navigation (URL,
  // bookmark, drag/drop, OSC `/url`/`/bookmark`), reload, and enabling all funnel through here (or
  // through `setEnabled` below), so disabled-ness only has to be enforced once. `enabled` is taken
  // as a parameter rather than read from `output.enabled`: `@Published` emits on willSet, so a
  // call made from the `$enabled` sink itself (`setEnabled`, below) would otherwise still see the
  // OLD value at this point — the same hazard as `OutputHost.sync`'s comment about `model.outputs`.
  private func load(_ url: URL, enabled: Bool) {
    guard enabled else { return }
    guard url.absoluteString != output.currentUrl?.absoluteString else { return }
    webView.load(URLRequest(url: url))
    output.currentUrl = url
  }

  // Disable: unloads the page (about:blank) without touching `output.url`/`bookmarkID`, so
  // reconcile/live-bookmark matching and the saved URL are unaffected, and resets `currentUrl` so
  // `load(_:)`'s "unchanged" guard doesn't skip the reload below on re-enable. Enable: reloads
  // `output.url` through the same `load(_:)`.
  private func setEnabled(_ enabled: Bool) {
    if enabled {
      load(output.url, enabled: true)
    } else {
      webView.stopLoading()
      webView.load(URLRequest(url: URL(string: "about:blank")!))
      output.currentUrl = nil
    }
  }

  // Re-provisions the texture/context/region and re-lays out the page at a new output size or
  // backing scale. Synchronous (no awaits) on the main actor, so a capture tick never observes a
  // mismatched texture/context.
  private func applySize(pixelSize: CGSize, scale: CGFloat) {
    guard pixelSize != lastPixelSize || scale != lastBackingScale else { return }
    lastPixelSize = pixelSize
    lastBackingScale = scale

    output.initMetal(pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
    let size = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
    webView.setFrameSize(size)
    webView.setLayoutScale(1 / scale)
    onResize()
    nudgeViewport(size: size)
  }

  // Spike surprise 3: vw/vh stay 0 after the layout SPI is set until the view is resized. The
  // nudge has to run on a later runloop turn than `setLayoutScale`: in the same turn vw stays 0
  // (measured). Skipped if another size change superseded this one meanwhile.
  private func nudgeViewport(size: CGSize) {
    DispatchQueue.main.async { [webView] in
      guard webView.frame.size == size else { return }
      webView.setFrameSize(CGSize(width: size.width + 1, height: size.height + 1))
      webView.setFrameSize(size)
    }
  }

  // Remove order: subscriptions, loading, view, then the output's reference to it. The host drops
  // this controller afterwards; AppModel.removeOutput stops the Syphon server.
  func tearDown() {
    cancellables.removeAll()
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.removeFromSuperview()
    output.webView = nil
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    output.loading = true
    output.loadError = nil
    appLog("Loading URL: \(output.url)")
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    output.loading = webView.isLoading
    appLog("Done loading URL: \(output.url)")
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    output.loading = webView.isLoading
    output.loadError = error.localizedDescription
    appLog("Failed loading URL: \(output.url) error: \(error)")
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    output.loading = webView.isLoading
    output.loadError = error.localizedDescription
    appLog("Failed provisional loading URL: \(output.url) error: \(error)")
  }

  // A cross-site navigation swaps WebKit's WebContent process; the new process starts with the
  // layout-mode-2 viewport unset, so vw/vh resolve to 0 until the view is resized. Nudge on every
  // commit, not just on size changes, so this covers the process-swap case too.
  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    nudgeViewport(size: webView.frame.size)
  }
}
