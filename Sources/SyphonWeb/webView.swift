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

// @unchecked: mutated only from the main actor (SwiftUI @Published + navigate(to:) both require it)
class WebViewState: ObservableObject, @unchecked Sendable {
  @Published var url: URL = URL(string: "https://puppy.surf")!
  @Published var loading: Bool = false
  @Published var currentUrl: URL?

  // Output resolution, persisted across launches. Preview (web view + window) size is derived
  // from this and `backingScale`, not stored separately.
  @Published var resolution: OutputResolution = {
    if let saved = UserDefaults.standard.string(forKey: outputResolutionDefaultsKey),
      let resolution = OutputResolution(rawValue: saved)
    {
      return resolution
    }
    return .hd720
  }() {
    didSet { UserDefaults.standard.set(resolution.rawValue, forKey: outputResolutionDefaultsKey) }
  }

  // Screen's backing scale factor (1x/2x). Set once the window is actually on screen (the
  // pre-display value is unreliable) and kept current via didChangeBackingPropertiesNotification.
  @Published var backingScale: CGFloat = 2.0

  // Preview size in points: output pixels / backing scale, so the web view's CSS layout width
  // equals the output pixel width once `pageZoom` is applied.
  var previewSize: CGSize {
    let pixels = resolution.pixelSize
    return CGSize(width: pixels.width / backingScale, height: pixels.height / backingScale)
  }

  // Normalizes a string (prepends https:// when no scheme) and navigates the web view to it
  @MainActor
  func navigate(to urlString: String) {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    if var urlToNavigate = URL(string: trimmed) {
      if urlToNavigate.scheme == nil {
        if let httpsURL = URL(string: "https://" + trimmed) {
          urlToNavigate = httpsURL
        }
      }

      url = urlToNavigate
    }
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
    commandQueue = server.device.makeCommandQueue()
    layer = CAMetalLayer()
    layer?.device = server.device
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

    texture = server.device.makeTexture(descriptor: textureDescriptor)
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

struct WebView: NSViewRepresentable {
  let webView: WKWebView = WKWebView()

  @ObservedObject var state: WebViewState

  func makeNSView(context: Context) -> WKWebView {
    webView.navigationDelegate = context.coordinator
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
        scale: state.backingScale)
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

    // Re-provision the texture/context/region and re-zoom the page whenever the output
    // resolution or the screen's backing scale changes. Runs synchronously (no awaits), on the
    // main actor, so a capture tick never observes a mismatched texture/context.
    let pixelSize = state.resolution.pixelSize
    let coordinator = context.coordinator
    guard pixelSize != coordinator.lastPixelSize || state.backingScale != coordinator.lastBackingScale
    else {
      return
    }

    state.initMetal(pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
    nsView.pageZoom = 1 / state.backingScale
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
