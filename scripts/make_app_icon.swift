// Generates the app icon: a black gradient tile with the menu bar icon on it (`macwindow` glyph,
// green status dot, clear ring around the dot), in the same proportions as `statusImage` in
// Sources/QWebSyphon/statusMenu.swift. Writes the .icns into the app skeleton, plus the layer
// PNGs of the Icon Composer document app_bundler/QWebSyphon.icon (its icon.json is
// hand-maintained; open it in Icon Composer to tweak glass/shadow). build_app.sh compiles the
// .icon with actool.
//
//   swift scripts/make_app_icon.swift
//
// Tile geometry follows Apple's macOS icon grid: 1024 px canvas, 824 px rounded-rect tile inset
// 100 px, corner radius 185 px, soft drop shadow.
import AppKit

let canvas: CGFloat = 1024
let tileInset: CGFloat = 100
let tileRadius: CGFloat = 185
let topColor = NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1)  // #333338
let bottomColor = NSColor(srgbRed: 0.03, green: 0.03, blue: 0.04, alpha: 1)  // #08080A
let glyphColor = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
let dotColor = NSColor.systemGreen.usingColorSpace(.sRGB)!

// Menu bar proportions (22 pt canvas): glyph 14.5 pt tall, dot 6.5 pt, ring gap 1.2 pt.
let glyphHeight: CGFloat = 400
let unit = glyphHeight / 14.5
let dotDiameter = 6.5 * unit
let ringGap = 1.2 * unit

// Glyph + dot geometry on the 1024 canvas (shared by the .icns tile render and the Icon Composer
// layer PNGs below — same default symbol configuration as the menu bar, pre-tinted via
// paletteColors so there's no destinationIn masking, which leaves a hairline at the edges of a
// fractional rect at large sizes).
let symbol = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)!
  .withSymbolConfiguration(.init(paletteColors: [glyphColor]))!
let aspect = symbol.size.width / symbol.size.height
let glyphWidth = glyphHeight * aspect
let overhang = dotDiameter / 2
// Centre the glyph+dot group on the tile.
let groupWidth = glyphWidth + overhang
let groupHeight = glyphHeight + overhang
let origin = NSPoint(x: (canvas - groupWidth) / 2, y: (canvas - groupHeight) / 2 + overhang)
let glyphRect = NSRect(origin: origin, size: NSSize(width: glyphWidth, height: glyphHeight))
let dotRect = NSRect(
  x: glyphRect.maxX - dotDiameter / 2, y: glyphRect.minY - dotDiameter / 2,
  width: dotDiameter, height: dotDiameter)

func render(size px: Int) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: canvas, height: canvas)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high

  let tileRect = NSRect(x: 0, y: 0, width: canvas, height: canvas).insetBy(dx: tileInset, dy: tileInset)
  let tile = NSBezierPath(roundedRect: tileRect, xRadius: tileRadius, yRadius: tileRadius)

  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
  shadow.shadowOffset = NSSize(width: 0, height: -10)
  shadow.shadowBlurRadius = 24
  shadow.set()
  bottomColor.setFill()
  tile.fill()
  NSGraphicsContext.restoreGraphicsState()

  NSGradient(starting: topColor, ending: bottomColor)!.draw(in: tile, angle: -90)

  // Glyph + dot, drawn into a layer image so the ring can be cut out of the glyph only.
  let mark = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
    symbol.draw(in: glyphRect)
    NSGraphicsContext.current?.compositingOperation = .destinationOut
    NSBezierPath(ovalIn: dotRect.insetBy(dx: -ringGap, dy: -ringGap)).fill()
    NSGraphicsContext.current?.compositingOperation = .sourceOver
    dotColor.setFill()
    NSBezierPath(ovalIn: dotRect).fill()
    return true
  }
  mark.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas))

  NSGraphicsContext.restoreGraphicsState()
  return rep
}

/// Icon Composer layers: the icon's canvas is the tile itself, so the tile rect is scaled up to
/// fill 1024 (the system draws the tile shape, gradient fill and shadow).
func composerPlacement(_ r: NSRect) -> NSRect {
  let k = canvas / (canvas - 2 * tileInset)
  return NSRect(x: (r.minX - tileInset) * k, y: (r.minY - tileInset) * k, width: r.width * k, height: r.height * k)
}

func bitmap(_ px: Int, _ draw: () -> Void) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: canvas, height: canvas)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high
  draw()
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

/// The glyph with the ring cut out of it, at composer-layer placement. Already palette-tinted (see
/// `symbol` above), so no destinationIn fill/mask step — that's what keeps it free of the faint
/// box under glass that a fill+mask on a fractional rect produces.
func drawGlyph(_ place: (NSRect) -> NSRect) {
  symbol.draw(in: place(glyphRect))
  NSGraphicsContext.current?.compositingOperation = .destinationOut
  NSBezierPath(ovalIn: place(dotRect.insetBy(dx: -ringGap, dy: -ringGap))).fill()
  NSGraphicsContext.current?.compositingOperation = .sourceOver
}

func drawDot(_ place: (NSRect) -> NSRect) {
  dotColor.setFill()
  NSBezierPath(ovalIn: place(dotRect)).fill()
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("QWebSyphon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    let png = render(size: base * scale).representation(using: .png, properties: [:])!
    try png.write(to: iconset.appendingPathComponent(name))
  }
}
try render(size: 1024).representation(using: .png, properties: [:])!
  .write(to: root.appendingPathComponent("docs/app-icon.png"))

let icns = root.appendingPathComponent("app_bundler/QWebSyphon.app.skeleton/Contents/Resources/QWebSyphon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(icns.path)" : "iconutil failed")

let assets = root.appendingPathComponent("app_bundler/QWebSyphon.icon/Assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try png(bitmap(Int(canvas)) { drawGlyph(composerPlacement) }).write(to: assets.appendingPathComponent("Glyph.png"))
try png(bitmap(Int(canvas)) { drawDot(composerPlacement) }).write(to: assets.appendingPathComponent("Dot.png"))
print("Wrote \(assets.path)")
