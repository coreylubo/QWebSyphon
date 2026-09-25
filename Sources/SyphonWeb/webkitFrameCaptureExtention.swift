import WebKit
import SwiftUI

extension WKWebView {
    // `context` is sized in output pixels; the web view's layer is laid out in preview points.
    // `scale` (== backing scale factor) blows the layer up to fill the context 1:1.
    func getFrame(context: CGContext, texture: MTLTexture, region: MTLRegion, scale: CGFloat) {

        context.interpolationQuality = CGInterpolationQuality.none
        layer!.isOpaque = true

        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        layer!.render(in: context)
        context.restoreGState()

        let data: UnsafeMutableRawPointer? = context.data
        
        texture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: data!,
            bytesPerRow: context.bytesPerRow
        )
    }
}