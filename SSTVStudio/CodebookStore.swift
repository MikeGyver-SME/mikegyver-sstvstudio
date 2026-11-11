import Foundation
import UIKit

/// Codebook mode — the Windtalkers-style game (v1.0.5).
///
/// A codebook maps words to pictures (here: symbols — emoji — plus an
/// optional photo the user attaches on their own phone). To send a
/// phrase, the app lays the pictures out in order as a 320x240 collage
/// and makes an SSTV WAV from it. To read one, the person who knows the
/// book looks at the pictures and taps the matching entries in order;
/// the app turns them back into words. The human does the picture
/// matching, exactly like the code talkers did — the app only does the
/// translation, and it never tries to recognise a picture from pixels.
///
/// SHARING RULE — read this before relying on it:
/// The shared JSON file carries words, symbols and entry IDs. A photo
/// attached to an entry stays on THAT phone only (Photos images cannot
/// be packed into the JSON). So a codebook shared between two phones
/// works with its symbols; a photo entry works on the phone it was
/// made on, or in person, with both people looking at the same screen.
///
/// LEGAL NOTE: a codebook obscures meaning, so it is FILE / IN-PERSON
/// ONLY. Never play a codebook WAV into a radio mic — FCC Part 97
/// prohibits transmitting messages encoded to obscure their meaning
/// over amateur radio.
struct CodebookEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var word: String
    var symbol: String // emoji / symbol shown on the tile
    var hasPhoto: Bool // a local photo replaces the symbol on this phone

    init(id: UUID = UUID(), word: String, symbol: String, hasPhoto: Bool = false) {
        self.id = id
        self.word = word
        self.symbol = symbol
        self.hasPhoto = hasPhoto
    }
}

struct CodebookFile: Codable {
    let format: String // "sstv-codebook"
    let version: Int
    let entries: [CodebookEntry]
}

/// The codebook store: one JSON file + one photo per entry, in the app's
/// Documents folder. A starter book of 20 entries is created on first run.
final class CodebookStore: ObservableObject {
    static let shared = CodebookStore()

    @Published private(set) var entries: [CodebookEntry] = []

    private let dir: URL
    private let indexURL: URL
    private let photosDir: URL

    static let starter: [(word: String, symbol: String)] = [
        ("hello", "👋"), ("yes", "✅"), ("no", "❌"), ("help", "🆘"),
        ("thanks", "🙏"), ("friend", "🤝"), ("family", "👨‍👩‍👦"),
        ("radio", "📻"), ("space", "🚀"), ("moon", "🌙"),
        ("star", "⭐"), ("sun", "☀️"), ("turkey", "🦃"),
        ("colin", "🧒"), ("love", "❤️"), ("happy", "😀"),
        ("good", "👍"), ("morning", "🌅"), ("night", "🌃"),
        ("secret", "🤫"),
    ]

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        dir = docs.appendingPathComponent("Codebook", isDirectory: true)
        indexURL = dir.appendingPathComponent("codebook.json", isDirectory: false)
        photosDir = dir.appendingPathComponent("Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        load()
    }

    func entry(forWord word: String) -> CodebookEntry? {
        entries.first { $0.word.lowercased() == word.lowercased() }
    }

    func entry(forID id: UUID) -> CodebookEntry? {
        entries.first { $0.id == id }
    }

    func photo(for entry: CodebookEntry) -> UIImage? {
        guard entry.hasPhoto else { return nil }
        return UIImage(contentsOfFile: photosDir.appendingPathComponent("\(entry.id.uuidString).png").path)
    }

    func setPhoto(_ image: UIImage, for entry: CodebookEntry) {
        guard let png = image.pngData() else { return }
        let url = photosDir.appendingPathComponent("\(entry.id.uuidString).png")
        try? png.write(to: url, options: .atomic)
        update(entry, hasPhoto: true)
    }

    func clearPhoto(for entry: CodebookEntry) {
        try? FileManager.default.removeItem(at: photosDir.appendingPathComponent("\(entry.id.uuidString).png"))
        update(entry, hasPhoto: false)
    }

    func add(word: String, symbol: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !w.isEmpty, entry(forWord: w) == nil else { return }
        entries.append(CodebookEntry(word: w, symbol: symbol.isEmpty ? "❓" : symbol))
        persist()
    }

    func update(_ entry: CodebookEntry, hasPhoto: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].hasPhoto = hasPhoto
        persist()
    }

    func delete(_ entry: CodebookEntry) {
        clearPhoto(for: entry)
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func resetToStarter() {
        entries = Self.starter.map { CodebookEntry(word: $0.word, symbol: $0.symbol) }
        persist()
    }

    // MARK: - Share / import (JSON file only — photos stay on this phone)

    /// A shareable JSON file for the codebook (words + symbols + IDs).
    func exportURL() -> URL? {
        let file = CodebookFile(format: "sstv-codebook", version: 1, entries: entries)
        guard let data = try? JSONEncoder().encode(file) else { return nil }
        let url = dir.appendingPathComponent("codebook.json")
        // Write a share copy in the temp directory so the live file is untouched.
        let shareURL = FileManager.default.temporaryDirectory.appendingPathComponent("sstv-codebook.json")
        do {
            try data.write(to: shareURL, options: .atomic)
            return shareURL
        } catch {
            print("Codebook: export failed: \(error)")
            return nil
        }
    }

    /// Import a shared codebook JSON file. Replaces the current book.
    /// Returns the number of entries imported, or nil on failure.
    func importFile(_ url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CodebookFile.self, from: data),
              file.format == "sstv-codebook", !file.entries.isEmpty else { return nil }
        // Imported entries arrive without photos (photos are local only).
        entries = file.entries.map { CodebookEntry(id: $0.id, word: $0.word, symbol: $0.symbol, hasPhoto: false) }
        persist()
        return entries.count
    }

    // MARK: - Collage (320x240, 4 columns x 3 rows of 80x80 tiles)

    static let tileSize: CGFloat = 80
    static let columns = 4
    static let rows = 3
    static let maxWords = 12

    /// Render a collage image for a phrase. Words not in the book become
    /// "?" tiles. Returns the image and the entries in tile order.
    func collage(for phrase: String) -> (image: UIImage, entries: [CodebookEntry]) {
        let words = phrase
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(Self.maxWords)
        let tiles: [CodebookEntry] = words.map { word in
            entry(forWord: word) ?? CodebookEntry(word: word, symbol: "❓")
        }
        let size = CGSize(width: 320, height: 240)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            for (i, entry) in tiles.enumerated() {
                let col = i % Self.columns
                let row = i / Self.columns
                let rect = CGRect(
                    x: CGFloat(col) * Self.tileSize, y: CGFloat(row) * Self.tileSize,
                    width: Self.tileSize, height: Self.tileSize)
                if let photo = photo(for: entry) {
                    // Aspect-fill the tile, clipped to its square.
                    let s = max(rect.width / photo.size.width, rect.height / photo.size.height)
                    let w = photo.size.width * s, h = photo.size.height * s
                    let r = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
                    UIGraphicsGetCurrentContext()?.saveGState()
                    UIBezierPath(rect: rect).addClip()
                    photo.draw(in: r)
                    UIGraphicsGetCurrentContext()?.restoreGState()
                } else {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 44),
                        .foregroundColor: UIColor.white
                    ]
                    let s = NSAttributedString(string: entry.symbol, attributes: attrs)
                    let r = s.boundingRect(with: rect.size, options: [], context: nil)
                    s.draw(at: CGPoint(x: rect.midX - r.width / 2, y: rect.midY - r.height / 2))
                }
                UIColor.white.withAlphaComponent(0.25).setStroke()
                UIBezierPath(rect: rect).stroke()
            }
        }
        return (image, Array(tiles))
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: indexURL),
           let file = try? JSONDecoder().decode(CodebookFile.self, from: data),
           !file.entries.isEmpty {
            entries = file.entries
            return
        }
        entries = Self.starter.map { CodebookEntry(word: $0.word, symbol: $0.symbol) }
        persist()
    }

    private func persist() {
        let file = CodebookFile(format: "sstv-codebook", version: 1, entries: entries)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: indexURL, options: .atomic)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.objectWillChange.send()
        }
    }
}
