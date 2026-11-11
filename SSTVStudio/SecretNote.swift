import Foundation
import CryptoKit
import UIKit

/// Secret Note — file-only hidden messages (v1.0.5).
///
/// WHY THE SECRET LIVES IN THE FILE, NOT IN THE PICTURE
/// -----------------------------------------------------
/// Pixel-LSB steganography does NOT survive SSTV encoding, let alone a
/// speaker-to-mic acoustic path: the encoder quantises every pixel to a
/// tone frequency and the decoder rebuilds the picture from those tones,
/// so the low bits are destroyed on the first hop. Any app that claims
/// to hide a secret in the SSTV tones is lying. So the secret lives in
/// the FILE instead: it is embedded as a trailer chunk in the generated
/// WAV file (and in the Gallery PNG file on disk). A WAV shared as a
/// file can be unlocked in the Decode tab; a picture decoded live off
/// the radio cannot carry the note — the UI says so plainly.
///
/// CRYPTO SCHEME (documented, no security by obscurity)
/// ----------------------------------------------------
///   Key:      PBKDF2-HMAC-SHA256, 100,000 iterations, random 16-byte
///             salt, 32-byte key, derived from the user's passphrase.
///             (Implemented here with CryptoKit HMAC<SHA256>; CryptoKit
///             has no PBKDF2 of its own.)
///   Cipher:   AES-256-GCM (CryptoKit AES.GCM), random 12-byte nonce.
///   Envelope: JSON {"v":1,"salt":base64,"data":base64} where "data" is
///             the AES.GCM.SealedBox combined form
///             (nonce || ciphertext || 16-byte tag).
///   Trailer:  "SSTVNOTE" (8 ASCII bytes) + UInt32 little-endian
///             envelope length + envelope JSON bytes, appended to the
///             file. In a WAV it is wrapped in a RIFF chunk "SSTV" so
///             the file stays well-formed; in a PNG it trails the IEND
///             chunk, which decoders ignore.
///
/// LEGAL NOTE — READ THIS
/// ----------------------
/// FCC Part 97 prohibits transmitting messages encoded to obscure their
/// meaning over amateur radio. Secret Note and Codebook are FILE /
/// IN-PERSON ONLY: share the WAV/PNG file itself, never play a
/// secret-carrying WAV into a radio mic. The Math Puzzle mode is the
/// only one of the three that is legal on air, because nothing is
/// hidden — the picture IS the message.
enum SecretNote {
    static let maxNoteLength = 200
    static let magic = "SSTVNOTE" // 8 ASCII bytes marking a secret trailer
    static let fileOnlyWarning =
        "File only — do NOT transmit over amateur radio."

    // MARK: - Envelope (encrypt / decrypt)

    private struct Envelope: Codable {
        let v: Int
        let salt: String // base64, 16 bytes
        let data: String // base64, AES.GCM.SealedBox combined form
    }

    /// Encrypt a note under a passphrase. Returns the envelope JSON bytes.
    static func encrypt(note: String, passphrase: String) -> Data? {
        guard !note.isEmpty, note.count <= maxNoteLength, !passphrase.isEmpty else { return nil }
        let salt = randomBytes(count: 16)
        let key = pbkdf2(password: Data(passphrase.utf8), salt: salt, iterations: 100_000, keyLength: 32)
        let symKey = SymmetricKey(data: key)
        guard let plain = note.data(using: .utf8),
              let sealed = try? AES.GCM.seal(plain, using: symKey) else { return nil }
        let env = Envelope(v: 1, salt: salt.base64EncodedString(),
                           data: sealed.combined!.base64EncodedString())
        return try? JSONEncoder().encode(env)
    }

    /// Decrypt an envelope under a passphrase. Returns nil on a wrong
    /// passphrase, a corrupt envelope, or any other failure — callers
    /// must report that as "Wrong passphrase", never show partial text.
    static func decrypt(envelopeData: Data, passphrase: String) -> String? {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: envelopeData),
              env.v == 1,
              let salt = Data(base64Encoded: env.salt),
              let combined = Data(base64Encoded: env.data),
              let sealed = try? AES.GCM.SealedBox(combined: combined),
              !passphrase.isEmpty else { return nil }
        let key = pbkdf2(password: Data(passphrase.utf8), salt: salt, iterations: 100_000, keyLength: 32)
        guard let plain = try? AES.GCM.open(sealed, using: SymmetricKey(data: key)),
              let note = String(data: plain, encoding: .utf8) else { return nil }
        return note
    }

    /// PBKDF2-HMAC-SHA256, implemented on CryptoKit HMAC. Standard
    /// construction: T_i = U_1 ^ U_2 ^ ... ^ U_c, U_1 = HMAC(pw, salt||INT(i)).
    static func pbkdf2(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let hLen = 32 // SHA-256 output
        let blocks = (keyLength + hLen - 1) / hLen
        var out = Data()
        let pwKey = SymmetricKey(data: password)
        for block in 1...blocks {
            var blockIndex = UInt32(block).bigEndian
            var u = Data(salt)
            u.append(contentsOf: withUnsafeBytes(of: &blockIndex) { Array($0) })
            var macData = Data(HMAC<SHA256>.authenticationCode(for: u, using: pwKey))
            var t = macData
            if iterations > 1 {
                for _ in 1..<iterations {
                    macData = Data(HMAC<SHA256>.authenticationCode(for: macData, using: pwKey))
                    for i in 0..<hLen { t[i] ^= macData[i] }
                }
            }
            out.append(t)
        }
        return out.prefix(keyLength)
    }

    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    // MARK: - Trailer (embed / extract)

    /// Build the trailer bytes for an envelope: magic + length + envelope.
    static func trailer(for envelope: Data) -> Data {
        var t = Data(magic.utf8)
        var len = UInt32(envelope.count).littleEndian
        t.append(contentsOf: withUnsafeBytes(of: &len) { Array($0) })
        t.append(envelope)
        return t
    }

    /// Find a secret envelope in any file's raw bytes (WAV or PNG).
    /// Scans for the magic; the 8-byte magic plus the GCM tag make a
    /// false positive from random audio data negligible.
    static func extractEnvelope(from data: Data) -> Data? {
        let magicBytes = [UInt8](magic.utf8)
        guard data.count > magicBytes.count + 4 else { return nil }
        // Search from the end backwards: the trailer is always last.
        var i = data.count - magicBytes.count - 4
        while i >= 0 {
            if data[i] == magicBytes[0] && Array(data[i..<(i + magicBytes.count)]) == magicBytes {
                let lenStart = i + magicBytes.count
                // Little-endian UInt32, read byte by byte (no unaligned load).
                let len = UInt32(data[lenStart])
                    | (UInt32(data[lenStart + 1]) << 8)
                    | (UInt32(data[lenStart + 2]) << 16)
                    | (UInt32(data[lenStart + 3]) << 24)
                let envStart = lenStart + 4
                guard len > 0, envStart + Int(len) <= data.count else { return nil }
                return Data(data[envStart..<(envStart + Int(len))])
            }
            i -= 1
        }
        return nil
    }

    static func extractEnvelope(fromFile url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return extractEnvelope(from: data)
    }

    /// Append a secret trailer to PNG bytes (after IEND; decoders ignore
    /// trailing data). The Photos-library copy is re-encoded by iOS and
    /// loses the trailer — the Gallery file on disk is the record.
    static func pngWithSecret(_ png: Data, envelope: Data) -> Data {
        var out = png
        out.append(trailer(for: envelope))
        return out
    }

    /// Draw a small lock badge in the bottom-right corner of a 320x240
    /// image, so the recipient can see a note is present. The badge is
    /// visible in the picture itself — it marks the note's presence, it
    /// is not the note.
    static func withLockBadge(_ image: UIImage) -> UIImage {
        let size = CGSize(width: 320, height: 240)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
            let badge = CGRect(x: size.width - 34, y: size.height - 34, width: 28, height: 28)
            UIColor.black.withAlphaComponent(0.65).setFill()
            UIBezierPath(ovalIn: badge).fill()
            let lock = "\u{1F512}"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 17),
                .foregroundColor: UIColor.white
            ]
            let s = NSAttributedString(string: lock, attributes: attrs)
            let r = s.boundingRect(with: badge.size, options: [], context: nil)
            s.draw(at: CGPoint(
                x: badge.midX - r.width / 2, y: badge.midY - r.height / 2))
        }
    }
}
