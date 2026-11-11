import Foundation
import UIKit

/// Fit a photo into the 320x240 frame the SSTV encoder expects, and hand
/// back the raw RGBA pixels (R, G, B, A in that order).
enum ImageUtils {
    enum Fit: String, CaseIterable {
        case contain = "Contain"
        case cover = "Cover"
        case stretch = "Stretch"
    }

    static let targetWidth = 320
    static let targetHeight = 240

    static func rgba320x240(from image: UIImage, fit: Fit) -> Data? {
        let size = CGSize(width: targetWidth, height: targetHeight)
        // First pass: render the photo into a correctly-oriented 320x240
        // image, honouring the chosen fit.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let iw = image.size.width, ih = image.size.height
            guard iw > 0, ih > 0 else { return }
            var rect = CGRect(origin: .zero, size: size)
            switch fit {
            case .stretch:
                rect = CGRect(origin: .zero, size: size)
            case .contain:
                let s = min(size.width / iw, size.height / ih)
                rect = CGRect(
                    x: (size.width - iw * s) / 2, y: (size.height - ih * s) / 2,
                    width: iw * s, height: ih * s)
            case .cover:
                let s = max(size.width / iw, size.height / ih)
                rect = CGRect(
                    x: (size.width - iw * s) / 2, y: (size.height - ih * s) / 2,
                    width: iw * s, height: ih * s)
            }
            image.draw(in: rect)
        }
        // Second pass: read the rendered image's RGBA pixels.
        guard let cg = rendered.cgImage else { return nil }
        guard let ctx = CGContext(
            data: nil, width: targetWidth, height: targetHeight,
            bitsPerComponent: 8, bytesPerRow: targetWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        guard let data = ctx.data else { return nil }
        return Data(bytes: data, count: targetWidth * targetHeight * 4)
    }
}
