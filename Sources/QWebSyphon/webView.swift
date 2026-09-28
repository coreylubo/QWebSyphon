import Combine
import MetalKit
import Syphon
import QWebSyphonCore
import WebKit

// Not private: OSCController (oscServer.swift) checks this key to decide whether a port was
// explicitly saved before falling back to the next free port.
let oscPortDefaultsKey = "oscPort"

// Default Syphon server name: "SyphonWeb", or "SyphonWeb <profile>" when running under a profile.
func defaultSyphonName() -> String {
  guard let profileName else { return "SyphonWeb" }
  return "SyphonWeb \(profileName)"
}

// Valid OSC listen ports (avoids the well-known/privileged range below 1024).
let validOSCPortRange: ClosedRange<Int> = 1024...65535

// One Syphon output: its web page, Syphon server, capture buffers and stats. Persisted settings
// (see `config`) are saved by AppModel as one JSON value whenever one of them changes.
@MainActor
final class Output: ObservableObject, Identifiable {
  let id: UUID

  // Syphon server name. The server is created with this name directly (init). On later change,
  // the server is stopped and replaced rather than renamed in place: Syphon clients (e.g. QLab)
  // only read the name from a server's initial announce, so renaming in place leaves
  // stale/duplicate names client-side. Old clients see the source disappear; a new source with
  // the new name appears.
  // UI should rename through `AppModel.renameOutput`, which validates against the other outputs'
  // names before assigning here; assigning directly skips that validation.
  @Published var name: String {
    didSet {
      // Recreating the server makes clients drop and re-find the source; skip if unchanged
      guard name != oldValue else { return }
      // Synchronous, no `await` in between: captureFrame (main actor, 60Hz timer) never
      // observes frameServer in a stopped-but-not-yet-replaced state.
      frameServer?.stop()
      frameServer = SyphonMetalServer(name: name, device: metalDevice)
      onConfigChange?()
    }
  }
  @Published var url: URL { didSet { onConfigChange?() } }
  @Published var loading: Bool = false
  @Published var currentUrl: URL?
  // Set on didFail/didFailProvisionalNavigation, cleared on didStartProvisionalNavigation. Shown
  // in the status bar's page-state indicator.
  @Published var loadError: String?

  // Output resolution preset. Effective pixel size is `customSize ?? resolution.pixelSize` (see
  // `pixelSize` below). Kept even when `customSize` is set, as the rollback fallback if the app
  // downgrades and stops understanding `customSize`.
  @Published var resolution: OutputResolution { didSet { onConfigChange?() } }

  // Custom W×H (decision 6). When set, overrides `resolution` for the effective pixel size; use
  // `setCustomSize` rather than assigning directly so `resolution` tracks the nearest preset.
  @Published var customSize: PixelSize? { didSet { onConfigChange?() } }

  // Tile preview image, refreshed at ~15 Hz by AppModel from the last captured frame. Only UI
  // subscribes to it. Downscaled and upright (`makeTileImage`).
  @Published var previewImage: CGImage?
  // Set by captureFrame, cleared by AppModel's tile refresh: a new frame since the last tile
  var tileDirty = false

  // When true, the web view and Syphon output are transparent instead of opaque white. Requires
  // the page itself to set a transparent background (e.g. `body { background: transparent }`);
  // output alpha is premultiplied.
  @Published var transparentBackground: Bool { didSet { onConfigChange?() } }

  // When false, capture is skipped while the Syphon server has no clients. No UI yet.
  @Published var captureWithoutClients: Bool { didSet { onConfigChange?() } }

  // The bookmark this output was last opened from, or nil if its URL came from somewhere else
  // (`navigate(to:)`, a fresh default, OSC `/url`). Set only by `open(bookmark:)`; cleared by
  // `navigate(to:)`. Reconciled by `AppModel.reconcileBookmarkIDs` when bookmarks change (delete,
  // URL edit) so a stale id never outlives what it pointed to. Used by `liveBookmarkIDs` for the
  // sidebar's live-bookmark matching.
  @Published var bookmarkID: Int64? { didSet { onConfigChange?() } }

  // Backing scale factor (1x/2x) of the window hosting this output's web view (OutputHost's
  // window, which keeps it current as the host follows the main window between screens).
  @Published var backingScale: CGFloat = 2.0

  let stats: OutputStats
  // Set by AppModel to persist the outputs after a config change
  var onConfigChange: (() -> Void)?

  // Trusts `config`: it must already be sanitized (`sanitizeOutputConfigs`), so name and URL are
  // assigned as-is rather than re-normalized here.
  init(config: OutputConfig) {
    id = config.id
    name = config.name
    url = URL(string: config.url)!
    resolution = config.resolution
    customSize = config.customSize
    transparentBackground = config.transparentBackground
    captureWithoutClients = config.captureWithoutClients
    bookmarkID = config.bookmarkID
    stats = OutputStats()
    stats.output = self
    // Created with the final name up front (not renamed afterwards): QLab and other clients only
    // read the name from the initial Syphon announce, so a later rename leaves them showing stale
    // or duplicate source names.
    frameServer = SyphonMetalServer(name: name, device: metalDevice)
  }

  var config: OutputConfig {
    OutputConfig(
      id: id, name: name, url: url.absoluteString, resolution: resolution, customSize: customSize,
      transparentBackground: transparentBackground, captureWithoutClients: captureWithoutClients,
      bookmarkID: bookmarkID)
  }

  // Effective output pixel size: the custom size if set, else the preset's.
  var pixelSize: CGSize { customSize?.cgSize ?? resolution.pixelSize }

  // Sets a validated custom size and rolls `resolution` to the nearest preset by pixel area, so
  // a build that stops understanding `customSize` (rollback) still shows a sane preset size.
  func setCustomSize(_ size: PixelSize) {
    let area = size.width * size.height
    resolution =
      OutputResolution.allCases.min {
        let areaA = Int($0.pixelSize.width * $0.pixelSize.height)
        let areaB = Int($1.pixelSize.width * $1.pixelSize.height)
        return abs(areaA - area) < abs(areaB - area)
      } ?? .hd720
    customSize = size
  }

  // Preview size in points: output pixels / backing scale, so the web view's CSS layout width
  // equals the output pixel width once `setLayoutScale` is applied.
  var previewSize: CGSize {
    let pixels = pixelSize
    return CGSize(width: pixels.width / backingScale, height: pixels.height / backingScale)
  }

  // The live web view, owned by this output's OutputWebViewController (outputHost.swift)
  weak var webView: WKWebView?

  // Trims and adds http(s):// when there is no scheme. Shared so bookmark URLs compare equal to
  // `url`. Forwards to core's free function; module-qualified to avoid shadowing the name.
  nonisolated static func normalizedURL(_ string: String) -> URL? {
    QWebSyphonCore.normalizedURL(string)
  }

  // Normalizes a string and navigates the web view to it. For non-bookmark URLs only — clears
  // `bookmarkID`. Bookmark-originated opens use `open(bookmark:)` instead, so the live-bookmark
  // matching in the sidebar keeps working.
  func navigate(to urlString: String) {
    if let urlToNavigate = Output.normalizedURL(urlString) {
      url = urlToNavigate
      bookmarkID = nil
    }
  }

  // Navigates to a bookmark's URL and records which bookmark it came from (`bookmarkID`), so the
  // sidebar's live-bookmark matching (`liveBookmarkIDs`) can find it even after a later rename.
  @available(macOS 14, *)
  func open(bookmark: Bookmark) {
    guard let urlToNavigate = Output.normalizedURL(bookmark.url) else { return }
    url = urlToNavigate
    bookmarkID = bookmark.id
  }

  func reload() {
    appLog("Reloading page")
    webView?.reload()
  }

  // Metal Related Objects
  var texture: MTLTexture?
  var frameServer: SyphonMetalServer?
  var graphicsContext: CGContext?
  var region: MTLRegion?

  // (Re)creates the texture, context and region at an exact output pixel size. Called
  // synchronously (no awaits) so a 60 Hz capture tick never sees a mismatched texture/context.
  func initMetal(pixelWidth: Int, pixelHeight: Int) {
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

  // Captures the web view into the texture and publishes it. Called by AppModel's capture
  // driver; skipped while the page is loading, before initMetal, and (if
  // `captureWithoutClients` is off) while no Syphon client is connected.
  func captureFrame(commandQueue: MTLCommandQueue) {
    guard !loading, let webView, let texture, let graphicsContext, let region else { return }
    if !captureWithoutClients && frameServer?.hasClients != true { return }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

    webView.getFrame(
      context: graphicsContext, texture: texture, region: region, scale: backingScale,
      transparent: transparentBackground)
    frameServer?.publishFrameTexture(
      texture, on: commandBuffer,
      imageRegion: NSRect(x: 0, y: 0, width: texture.width, height: texture.height),
      flipped: false)
    commandBuffer.commit()
    stats.frameCount += 1
    tileDirty = true
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
