import Foundation
import JavaScriptCore
import UIKit

/// A decoded SSTV picture, ready to display, save, or share.
struct DecodedSSTVImage {
    let mode: String
    let width: Int
    let height: Int
    let visCode: Int?
    let syncCount: Int
    let syncRmsMs: Double
    let uiImage: UIImage
}

/// The SSTV engine: the same DSP core that powers the SSTV Studio web app,
/// running inside JavaScriptCore. Swift hands it base64 strings and gets
/// base64 strings back — no browser APIs involved.
final class SSTVEngine {
    static let shared = SSTVEngine()

    /// All JavaScriptCore work happens on this one serial queue, because
    /// JSContext is not thread-safe.
    private let jsQueue = DispatchQueue(label: "com.mikegyver.sstvstudio.js")
    private var context: JSContext?

    private init() {}

    /// Must be called on jsQueue.
    private func ensureContext() -> JSContext? {
        if let c = context { return c }
        let c = JSContext()
        c?.exceptionHandler = { _, exception in
            print("SSTV JS error: \(exception?.toString() ?? "unknown")")
        }
        guard let url = Bundle.main.url(forResource: "sstv-core", withExtension: "js"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            print("SSTV: sstv-core.js not found in bundle")
            return nil
        }
        c?.evaluateScript(src)
        context = c
        return c
    }

    /// Encode 320x240 RGBA pixels into SSTV audio (float32 samples at
    /// `sampleRate`). Calls `completion` on the main thread with the raw
    /// float32 sample bytes, or nil on failure.
    func encode(rgba: Data, width: Int, height: Int, mode: String,
                sampleRate: Double, completion: @escaping (Data?) -> Void) {
        let b64 = rgba.base64EncodedString()
        jsQueue.async { [weak self] in
            guard let self = self, let ctx = self.ensureContext() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let result = ctx.objectForKeyedSubscript("iosEncode")?
                .call(withArguments: [b64, width, height, mode, sampleRate])
            let data = result?.toString().flatMap { Data(base64Encoded: $0) }
            DispatchQueue.main.async { completion(data) }
        }
    }

    /// Decode float32 audio samples (at `sampleRate`) into a picture.
    /// `modeHint` is "auto", "Robot 36", or "Robot 72".
    /// Calls `completion` on the main thread with the image, or nil if no
    /// picture was found.
    func decode(samples: Data, sampleRate: Double, modeHint: String,
                completion: @escaping (DecodedSSTVImage?) -> Void) {
        let b64 = samples.base64EncodedString()
        jsQueue.async { [weak self] in
            guard let self = self, let ctx = self.ensureContext() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let result = ctx.objectForKeyedSubscript("iosDecode")?
                .call(withArguments: [b64, sampleRate, modeHint])
            let decoded = SSTVEngine.parseDecodeResult(result?.toString())
            DispatchQueue.main.async { completion(decoded) }
        }
    }

    private static func parseDecodeResult(_ json: String?) -> DecodedSSTVImage? {
        guard let json = json,
              let jsonData = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let ok = obj["ok"] as? Bool, ok,
              let mode = obj["mode"] as? String,
              let width = obj["width"] as? Int,
              let height = obj["height"] as? Int,
              let rgbaB64 = obj["rgbaB64"] as? String,
              let rgba = Data(base64Encoded: rgbaB64),
              let image = image(fromRGBA: rgba, width: width, height: height) else {
            return nil
        }
        return DecodedSSTVImage(
            mode: mode, width: width, height: height,
            visCode: obj["visCode"] as? Int,
            syncCount: obj["syncCount"] as? Int ?? 0,
            syncRmsMs: obj["syncRmsMs"] as? Double ?? 0,
            uiImage: image)
    }

    /// Build a UIImage from RGBA bytes (R, G, B, A in that order).
    static func image(fromRGBA rgba: Data, width: Int, height: Int) -> UIImage? {
        guard rgba.count == width * height * 4 else { return nil }
        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue)
        guard let cg = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
