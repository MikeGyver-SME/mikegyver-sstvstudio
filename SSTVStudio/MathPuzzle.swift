import Foundation
import UIKit

/// Math Puzzle mode — the one secret-family feature that IS legal on air
/// (v1.0.5). Nothing is hidden here: the picture IS the message, in
/// plain sight. A formula or a puzzle is rendered large and
/// high-contrast as a 320x240 SSTV image, and the recipient reads it
/// and solves it. No encryption, no codebook, no hidden data.
enum MathPuzzle {
    static let presets = [
        "E=mc^2",
        "A = pi*r^2",
        "a^2 + b^2 = c^2",
        "v = d/t",
        "F = ma",
        "3x + 7 = 22",
    ]

    struct Puzzle {
        let question: String // rendered on the image
        let answer: String // shown only to the sender
    }

    /// Render any formula / puzzle text large, high-contrast and centred
    /// as a 320x240 image. Supports ^2/^3 superscripts, pi, * and sqrt
    /// as plain-text shorthands, converted to proper symbols.
    static func render(_ text: String) -> UIImage {
        let pretty = prettify(text)
        let size = CGSize(width: 320, height: 240)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            // Shrink the font until the text fits the frame.
            var fontSize: CGFloat = 52
            var attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: fontSize),
                .foregroundColor: UIColor.white
            ]
            var s = NSAttributedString(string: pretty, attributes: attrs)
            var rect = s.boundingRect(
                with: CGSize(width: 300, height: 220),
                options: [.usesLineFragmentOrigin], context: nil)
            while (rect.width > 300 || rect.height > 220) && fontSize > 18 {
                fontSize -= 4
                attrs[.font] = UIFont.boldSystemFont(ofSize: fontSize)
                s = NSAttributedString(string: pretty, attributes: attrs)
                rect = s.boundingRect(
                    with: CGSize(width: 300, height: 220),
                    options: [.usesLineFragmentOrigin], context: nil)
            }
            // Word-wrap by hand: draw centred, line by line, so long
            // formulas stack instead of running off the frame.
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            var drawAttrs = attrs
            drawAttrs[.paragraphStyle] = paragraph
            let full = NSAttributedString(string: pretty, attributes: drawAttrs)
            let drawRect = CGRect(x: 10, y: (240 - rect.height) / 2, width: 300, height: rect.height)
            full.draw(in: drawRect)
        }
    }

    /// Plain-text shorthands to proper symbols. Only the common ones —
    /// this is a display helper, not a typesetter.
    static func prettify(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "pi", with: "\u{03C0}")
        t = t.replacingOccurrences(of: "sqrt", with: "\u{221A}")
        t = t.replacingOccurrences(of: "*", with: "\u{00D7}")
        // ^2 / ^3 superscripts (and ^n for single digits).
        let sup: [Character: String] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "-": "⁻", "x": "ˣ", "n": "ⁿ"
        ]
        var out = ""
        let chars = Array(t)
        var i = 0
        while i < chars.count {
            if chars[i] == "^", i + 1 < chars.count, let s = sup[chars[i + 1]] {
                out += s
                i += 2
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    /// Generate a random puzzle. The sender sees the answer; the
    /// recipient only sees the question image.
    static func randomPuzzle() -> Puzzle {
        switch Int.random(in: 0..<4) {
        case 0:
            let a = Int.random(in: 3...12), b = Int.random(in: 3...12)
            return Puzzle(question: "\(a) x \(b) = ?", answer: "\(a * b)")
        case 1:
            let a = Int.random(in: 11...99), b = Int.random(in: 3...20)
            return Puzzle(question: "\(a) - \(b) = ?", answer: "\(a - b)")
        case 2:
            // One-step algebra: ax + b = c, solve for x.
            let a = Int.random(in: 2...9)
            let x = Int.random(in: 2...12)
            let b = Int.random(in: 1...20)
            return Puzzle(question: "\(a)x + \(b) = \(a * x + b)\n x = ?", answer: "\(x)")
        default:
            // Area of a circle, r given, answer to the nearest whole number.
            let r = Int.random(in: 2...9)
            let area = Int((Double.pi * Double(r * r)).rounded())
            return Puzzle(question: "r = \(r)\n A = pi x r^2 = ?", answer: "about \(area)")
        }
    }
}
