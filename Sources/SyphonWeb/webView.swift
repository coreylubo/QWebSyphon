import MetalKit
import SwiftUI
import Syphon
import WebKit

// Output pixel dimensions the Syphon server publishes. The preview (web view + window) is sized
// separately, in points, by dividing these by the screen's backing scale factor.
enum OutputResolution: String, CaseIterable {
  case hd720
  case hd1080

  var pixelSize: CGSize {
    switch self {
    case .hd720: CGSize(width: 1280, height: 720)
    case .hd1080: CGSize(width: 1920, height: 1080)
    }
  }

  var label: String {
    switch self {
    case .hd720: "720p"
    case .hd1080: "1080p"
    }
  }
}

private let outputResolutionDefaultsKey = "outputResolution"
// Not private: OSCController (oscServer.swift) checks this key to decide whether a port was
// explicitly saved before falling back to the next free port.
let oscPortDefaultsKey = "oscPort"
private let transparentBackgroundDefaultsKey = "transparentBackground"
private let syphonNameDefaultsKey = "syphonName"

// Default Syphon server name: "SyphonWeb", or "SyphonWeb <profile>" when running under a profile.
func defaultSyphonName() -> String {
  guard let profileName else { return "SyphonWeb" }
  return "SyphonWeb \(profileName)"
}

// Valid OSC listen ports (avoids the well-known/privileged range below 1024).
let validOSCPortRange: ClosedRange<Int> = 1024...65535

// @unchecked: mutated only from the main actor (SwiftUI @Published + navigate(to:) both require it)
class WebViewState: ObservableObject, @unchecked Sendable {
  @Published var url: URL = URL(string: "https://puppy.surf")!
  @Published var loading: Bool = false
  @Published var currentUrl: URL?

  // Output resolution, persisted across launches. Preview (web view + window) size is derived
  // from this and `backingScale`, not stored separately.
  @Published var resolution: OutputResolution = {
    if let saved = appDefaults.string(forKey: outputResolutionDefaultsKey),
      let resolution = OutputResolution(rawValue: saved)
    {
      return resolution
    }
    return .hd720
  }() {
    didSet { appDefaults.set(resolution.rawValue, forKey: outputResolutionDefaultsKey) }
  }

  // Syphon server name, persisted across launches. The initial server is created with this name
  // directly (AppDelegate). On later change, the server is stopped and replaced rather than
  // renamed in place: Syphon clients (e.g. QLab) only read the name from a server's initial
  // announce, so renaming in place leaves stale/duplicate names client-side. Old clients see the
  // source disappear; a new source with the new name appears.
  @Published var syphonName: String = {
    let saved = appDefaults.string(forKey: syphonNameDefaultsKey)?.trimmingCharacters(
      in: .whitespacesAndNewlines)
    return saved?.isEmpty == false ? saved! : defaultSyphonName()
  }() {
    didSet {
      appDefaults.set(syphonName, forKey: syphonNameDefaultsKey)
      // Synchronous, no `await` in between: captureFrame (main actor, 60Hz timer) never
      // observes frameServer in a stopped-but-not-yet-replaced state.
      frameServer?.stop()
      frameServer = SyphonMetalServer(name: syphonName, device: metalDevice)
    }
  }

  // Screen's backing scale factor (1x/2x). Set once the window is actually on screen (the
  // pre-display value is unreliable) and kept current via didChangeBackingPropertiesNotification.
  @Published var backingScale: CGFloat = 2.0

  // OSC listen port, persisted across launches. Changing this does not itself restart the OSC
  // server; the Settings view calls OSCController.start(port:) and status reflects the result.
  @Published var oscPort: UInt16 = {
    let saved = appDefaults.integer(forKey: oscPortDefaultsKey)
    return validOSCPortRange.contains(saved) ? UInt16(saved) : defaultOSCPort
  }() {
    didSet { appDefaults.set(Int(oscPort), forKey: oscPortDefaultsKey) }
  }

  // When true, the web view and Syphon output are transparent instead of opaque white. Requires
  // the page itself to set a transparent background (e.g. `body { background: transparent }`);
  // output alpha is premultiplied.
  @Published var transparentBackground: Bool = appDefaults.bool(
    forKey: transparentBackgroundDefaultsKey
  ) {
    didSet {
      appDefaults.set(transparentBackground, forKey: transparentBackgroundDefaultsKey)
    }
  }

  // Preview size in points: output pixels / backing scale, so the web view's CSS layout width
  // equals the output pixel width once `setLayoutScale` is applied.
  var previewSize: CGSize {
    let pixels = resolution.pixelSize
    return CGSize(width: pixels.width / backingScale, height: pixels.height / backingScale)
  }

  // The live web view, set in WebView.makeNSView
  weak var webView: WKWebView?

  // Trims and prepends https:// when no scheme. Shared so bookmark URLs compare equal to `url`.
  static func normalizedURL(_ string: String) -> URL? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parsed = URL(string: trimmed) else { return nil }
    if parsed.scheme == nil, let httpsURL = URL(string: "https://" + trimmed) {
      return httpsURL
    }
    return parsed
  }

  // Normalizes a string and navigates the web view to it
  @MainActor
  func navigate(to urlString: String) {
    if let urlToNavigate = WebViewState.normalizedURL(urlString) {
      url = urlToNavigate
    }
  }

  @MainActor
  func reload() {
    NSLog("Reloading page")
    webView?.reload()
  }

  // Metal Related Objects
  var texture: MTLTexture?
  var frameServer: SyphonMetalServer?
  var commandQueue: MTLCommandQueue?
  var layer: CAMetalLayer?
  var graphicsContext: CGContext?
  var region: MTLRegion?

  // (Re)creates the texture, context and region at an exact output pixel size. Called
  // synchronously (no awaits) so a 60 Hz capture tick never sees a mismatched texture/context.
  @MainActor
  func initMetal(pixelWidth: Int, pixelHeight: Int) {
    commandQueue = metalDevice.makeCommandQueue()
    layer = CAMetalLayer()
    layer?.device = metalDevice
    layer?.pixelFormat = .rgba8Unorm
    layer?.maximumDrawableCount = 2
    layer?.drawableSize = CGSize(width: pixelWidth, height: pixelHeight)

    let textureDescriptor: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: pixelWidth,
      height: pixelHeight,
      mipmapped: false
    )
    textureDescriptor.usage.insert(MTLTextureUsage.shaderRead)
    textureDescriptor.usage.insert(MTLTextureUsage.shaderWrite)

    texture = metalDevice.makeTexture(descriptor: textureDescriptor)
    graphicsContext = CGContext(
      data: nil,
      width: texture!.width,
      height: texture!.height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    region = MTLRegionMake2D(0, 0, texture!.width, texture!.height)
  }
}

extension WKWebView {
  // Lays the page out at (frame / scale) CSS px and draws it shrunk by `scale`, so a preview sized
  // output px / backing scale gets a CSS viewport of exactly the output pixel size, rasterized at
  // 1 device px per CSS px.
  //
  // Prefers the private `_viewScale` + `_layoutMode` SPI (what Safari's Responsive Design Mode
  // uses): `pageZoom` gets box sizes right but WebKit also multiplies viewport-unit *font sizes*
  // by the zoom, so `font-size: 10vw` renders at half size. Falls back to `pageZoom` if the SPI
  // is ever removed.
  func setLayoutScale(_ scale: CGFloat) {
    guard responds(to: NSSelectorFromString("_setViewScale:")),
      responds(to: NSSelectorFromString("_setLayoutMode:"))
    else {
      pageZoom = scale
      return
    }
    pageZoom = 1
    // 2 == _WKLayoutModeDynamicSizeComputedFromViewScale: layout size = view size / _viewScale
    setValue(2, forKey: "layoutMode")
    setValue(scale, forKey: "viewScale")
  }
}

struct WebView: NSViewRepresentable {
  let webView: WKWebView = WKWebView()

  @ObservedObject var state: WebViewState

  func makeNSView(context: Context) -> WKWebView {
    webView.navigationDelegate = context.coordinator
    state.webView = webView
    webView.load(URLRequest(url: state.url))

    Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
      Task { @MainActor in
        captureFrame()
      }
    }

    return webView
  }

  func printTimeElapsedWhenRunningCode(title: String, operation: () -> Void) {
    let startTime = CFAbsoluteTimeGetCurrent()
    operation()
    let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
    print("Time elapsed for \(title): \(timeElapsed) s.")
  }

  func captureFrame() {
    if state.texture != nil && state.graphicsContext != nil && !state.loading {
      let commandBuffer: (any MTLCommandBuffer)? = state.commandQueue?.makeCommandBuffer()

      webView.getFrame(
        context: state.graphicsContext!, texture: state.texture!, region: state.region!,
        scale: state.backingScale, transparent: state.transparentBackground)
      state.frameServer?.publishFrameTexture(
        state.texture!, on: commandBuffer!,
        imageRegion: NSRect(x: 0, y: 0, width: state.texture!.width, height: state.texture!.height),
        flipped: false)
      commandBuffer?.commit()
    }
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    // Only reload if the URL has changed, save the new URL in state
    if state.url.absoluteString != state.currentUrl?.absoluteString {
      nsView.load(URLRequest(url: state.url))
      state.currentUrl = state.url
    }

    // Apply background transparency to the live view (never `self.webView`, which may not be the
    // instance actually on screen). `drawsBackground` is undocumented KVC on WKWebView; guarded so
    // an unrecognized key never crashes.
    let coordinator = context.coordinator
    if state.transparentBackground != coordinator.lastTransparentBackground {
      if nsView.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
        nsView.setValue(!state.transparentBackground, forKey: "drawsBackground")
      }
      coordinator.lastTransparentBackground = state.transparentBackground
    }

    // Re-provision the texture/context/region and re-zoom the page whenever the output
    // resolution or the screen's backing scale changes. Runs synchronously (no awaits), on the
    // main actor, so a capture tick never observes a mismatched texture/context.
    let pixelSize = state.resolution.pixelSize
    guard pixelSize != coordinator.lastPixelSize || state.backingScale != coordinator.lastBackingScale
    else {
      return
    }

    state.initMetal(pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
    nsView.setLayoutScale(1 / state.backingScale)
    resizeWindow(nsView: nsView)
    coordinator.lastPixelSize = pixelSize
    coordinator.lastBackingScale = state.backingScale
  }

  // Resizes the window's content area to the new preview size + sidebar, keeping the top-left
  // corner in place.
  func resizeWindow(nsView: WKWebView) {
    guard let window = nsView.window else { return }
    let preview = state.previewSize
    let newContentSize = CGSize(width: preview.width + 200, height: preview.height)
    let contentRect = window.contentRect(forFrameRect: window.frame)

    var frame = window.frame
    frame.size.width += newContentSize.width - contentRect.width
    frame.size.height += newContentSize.height - contentRect.height
    frame.origin.y -= newContentSize.height - contentRect.height
    window.setFrame(frame, display: true)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  class Coordinator: NSObject, WKNavigationDelegate {
    var parent: WebView
    var lastPixelSize: CGSize?
    var lastBackingScale: CGFloat?
    var lastTransparentBackground: Bool = false

    init(_ parent: WebView) {
      self.parent = parent
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
      parent.state.loading = true
      NSLog("Loading URL: \(parent.state.url)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      parent.state.loading = webView.isLoading
      NSLog("Done loading URL: \(parent.state.url)")
    }

    func webView(
      _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
      parent.state.loading = webView.isLoading
      NSLog("Failed loading URL: \(parent.state.url) error: \(error)")
    }

    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      parent.state.loading = webView.isLoading
      NSLog("Failed provisional loading URL: \(parent.state.url) error: \(error)")
    }
  }
}
