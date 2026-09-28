import WebKit
import SwiftUI

extension WKWebView {
    // `context` is sized in output pixels; the web view's layer is laid out in preview points.
    // `scale` (== backing scale factor) blows the layer up to fill the context 1:1. When
    // `transparent`, the context is cleared to zero alpha (in pixel space, before the scale
    // transform) so pages with a transparent background produce a transparent Syphon frame.
    func getFrame(
        context: CGContext, texture: MTLTexture, region: MTLRegion, scale: CGFloat, transparent: Bool
    ) {

        context.interpolationQuality = CGInterpolationQuality.none
        layer!.isOpaque = !transparent

        if transparent {
            context.clear(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        }

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