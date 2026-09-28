import Combine
import MetalKit
import MetalPerformanceShaders
import Syphon
import QWebSyphonCore
import WebKit

// Not private: OSCController (oscServer.swift) checks this key to decide whether a port was
// explicitly saved before falling back to the next free port.
let oscPortDefaultsKey = "oscPort"

// Default Syphon server name: "QWebSyphon", or "QWebSyphon <profile>" when running under a profile.
func defaultSyphonName() -> String {
  guard let profileName else { return "QWebSyphon" }
  return "QWebSyphon \(profileName)"
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
      // Disabled: no server to (re)create under the new name; `enabled`'s didSet creates one
      // (with the then-current name) on enable.
      frameServer = enabled ? SyphonMetalServer(name: name, device: metalDevice) : nil
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

  // Tile preview image, refreshed at ~15 Hz by AppModel (`refreshTile`) from a GPU readback of
  // the published texture. Only UI subscribes to it. Downscaled and upright (`makeTileImage`).
  @Published var previewImage: CGImage?
  // Set by captureFrame, cleared by `refreshTile` when it queues a readback: a new frame since the last tile
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

  // Off: stops and drops the Syphon server (the source disappears from clients) and unloads the
  // page (`OutputWebViewController`, subscribed to this, loads about:blank) to free CPU. On:
  // recreates the server under the current name and reloads `url`. `url`/`bookmarkID` are
  // untouched either way — see `navigate(to:)`/`open(bookmark:)`.
  @Published var enabled: Bool = true {
    didSet {
      guard enabled != oldValue else { return }
      if enabled {
        frameServer = SyphonMetalServer(name: name, device: metalDevice)
      } else {
        frameServer?.stop()
        frameServer = nil
        // So re-enabling shows the placeholder until a fresh frame, not the last one from before.
        previewImage = nil
        tileDirty = false
      }
      onConfigChange?()
    }
  }

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
    enabled = config.enabled
    stats = OutputStats()
    stats.output = self
    // Created with the final name up front (not renamed afterwards): QLab and other clients only
    // read the name from the initial Syphon announce, so a later rename leaves them showing stale
    // or duplicate source names. Disabled at launch: no server until enabled.
    frameServer = config.enabled ? SyphonMetalServer(name: name, device: metalDevice) : nil
  }

  var config: OutputConfig {
    OutputConfig(
      id: id, name: name, url: url.absoluteString, resolution: resolution, customSize: customSize,
      transparentBackground: transparentBackground, captureWithoutClients: captureWithoutClients,
      bookmarkID: bookmarkID, enabled: enabled)
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

  // No-ops while disabled: there's nothing loaded to reload.
  func reload() {
    guard enabled else { return }
    appLog("Reloading page")
    webView?.reload()
  }

  // Metal Related Objects
  var texture: MTLTexture?
  var frameServer: SyphonMetalServer?
  // CPU fallback only (`cpuCapture`): renderInContext target, uploaded into `texture`
  var graphicsContext: CGContext?
  var region: MTLRegion?
  // GPU path: composites the web view's layer tree straight into `texture`. Bound to one texture,
  // so recreated (lazily, by captureFrame) whenever initMetal replaces it.
  private var renderer: CARenderer?
  // Tile readback: `texture` downscaled on the GPU into `tileTexture`, blitted into `tileBuffer`
  // (wrapped by `tileContext`), turned into `previewImage` once `tileCommands` has completed.
  private var tileTexture: MTLTexture?
  private var tileBuffer: MTLBuffer?
  private var tileContext: CGContext?
  private var tileCommands: MTLCommandBuffer?

  // (Re)creates the texture, context and region at an exact output pixel size. Called
  // synchronously (no awaits) so a 60 Hz capture tick never sees a mismatched texture/context.
  func initMetal(pixelWidth: Int, pixelHeight: Int) {
    let textureDescriptor: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: pixelWidth,
      height: pixelHeight,
      mipmapped: false
    )
    textureDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]

    texture = metalDevice.makeTexture(descriptor: textureDescriptor)
    renderer = nil
    graphicsContext =
      cpuCapture
      ? CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) : nil

    region = MTLRegionMake2D(0, 0, pixelWidth, pixelHeight)

    let tileWidth = min(pixelWidth, tileImageMaxWidth)
    let tileHeight = max(1, pixelHeight * tileWidth / pixelWidth)
    let tileDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: tileWidth, height: tileHeight, mipmapped: false)
    tileDescriptor.usage = [.shaderRead, .shaderWrite]
    tileTexture = metalDevice.makeTexture(descriptor: tileDescriptor)
    tileBuffer = metalDevice.makeBuffer(length: tileWidth * tileHeight * 4, options: .storageModeShared)
    tileContext = tileBuffer.flatMap {
      CGContext(
        data: $0.contents(), width: tileWidth, height: tileHeight, bitsPerComponent: 8,
        bytesPerRow: tileWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    // A readback still in flight targets the old buffer: drop it rather than read it
    tileCommands = nil
  }

  // Captures the web view into the texture and publishes it. Called by AppModel's capture
  // driver; skipped while disabled (no server to publish to), while the page is loading, before
  // initMetal, and (if `captureWithoutClients` is off) while no Syphon client is connected.
  func captureFrame(commandQueue: MTLCommandQueue) {
    guard enabled, !loading, let webView, let layer = webView.layer, let texture, let region else {
      return
    }
    if !captureWithoutClients && frameServer?.hasClients != true { return }

    if let graphicsContext {
      webView.getFrame(
        context: graphicsContext, texture: texture, region: region, scale: backingScale,
        transparent: transparentBackground)
    } else {
      renderLayer(layer, into: texture, commandQueue: commandQueue)
    }

    guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
    frameServer?.publishFrameTexture(
      texture, on: commandBuffer,
      imageRegion: NSRect(x: 0, y: 0, width: texture.width, height: texture.height),
      flipped: false)
    commandBuffer.commit()
    stats.frameCount += 1
    tileDirty = true
  }

  // GPU capture: CARenderer composites the web view's (in-process, IOSurface-backed) layer tree
  // into `texture` on `commandQueue`, ahead of the publish on the same queue. The layer is laid
  // out in points, so it is scaled up by the backing scale (anchor is (0,0) for a view's layer);
  // reapplied every capture because AppKit resets it (e.g. on resize). The host window is alpha 0,
  // so the scaled layer is never seen there. Output orientation matches the CPU path's.
  private func renderLayer(_ layer: CALayer, into texture: MTLTexture, commandQueue: MTLCommandQueue) {
    let renderer =
      self.renderer
      ?? {
        let renderer = CARenderer(
          mtlTexture: texture,
          options: [kCARendererMetalCommandQueue as String: commandQueue])
        renderer.layer = layer
        renderer.bounds = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        self.renderer = renderer
        return renderer
      }()

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.isOpaque = !transparentBackground
    layer.transform = CATransform3DMakeScale(backingScale, backingScale, 1)
    CATransaction.commit()

    // CARenderer draws over the previous frame without clearing it: translucent areas would
    // accumulate towards opaque and moving content would smear
    if transparentBackground, let clear = commandQueue.makeCommandBuffer() {
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = texture
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
      pass.colorAttachments[0].storeAction = .store
      clear.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
      clear.commit()
    }

    renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
    renderer.addUpdate(renderer.bounds)
    renderer.render()
    renderer.endFrame()
  }

  // Called by AppModel's tile timer. Turns the previous readback into `previewImage` once the GPU
  // has finished it, then (if a new frame was captured) queues the next one: downscale + blit on
  // the capture queue, never waited on, so the capture tick never stalls.
  func refreshTile(commandQueue: MTLCommandQueue) {
    if let pending = tileCommands {
      guard pending.status == .completed else { return }
      tileCommands = nil
      previewImage = tileContext.flatMap(makeTileImage)
    }
    guard tileDirty, let texture, let tileTexture, let tileBuffer,
      let commandBuffer = commandQueue.makeCommandBuffer()
    else { return }
    tileDirty = false
    tileScaler.encode(
      commandBuffer: commandBuffer, sourceTexture: texture, destinationTexture: tileTexture)
    guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
    blit.copy(
      from: tileTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
      sourceSize: MTLSize(width: tileTexture.width, height: tileTexture.height, depth: 1),
      to: tileBuffer, destinationOffset: 0, destinationBytesPerRow: tileTexture.width * 4,
      destinationBytesPerImage: tileBuffer.length)
    blit.endEncoding()
    commandBuffer.commit()
    tileCommands = commandBuffer
  }
}

// `QWEBSYPHON_CPU_CAPTURE=1`: capture with the old renderInContext path (CPU, ~10-30 ms per
// frame on heavy pages) instead of CARenderer. Read once at launch.
let cpuCapture = appEnvironment("CPU_CAPTURE") == "1"

// Shared GPU downscaler for tile readback
@MainActor private let tileScaler = MPSImageBilinearScale(device: metalDevice)

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
