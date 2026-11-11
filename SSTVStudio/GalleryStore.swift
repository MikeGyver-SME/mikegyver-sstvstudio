import Foundation
import UIKit

/// One decoded picture kept in the on-device gallery.
struct SSTVGalleryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let mode: String
    let source: String // "Listen", "Make", or "Decode"
    let frequency: String? // e.g. "437.550 MHz" for live Listen decodes
    let fileName: String // PNG file inside Documents/Gallery/

    var displayDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

/// The gallery store: every decoded picture is auto-saved here the moment
/// it decodes, so a picture survives the app closing, the screen locking,
/// or the user forgetting to tap Save.
///
/// Storage layout, inside the app's Documents folder:
///   Gallery/<uuid>.png   — the picture itself
///   Gallery/gallery.json — the metadata record (one JSON array of items)
/// A copy is also written to the Photos library, as before.
final class GalleryStore: ObservableObject {
    static let shared = GalleryStore()

    @Published private(set) var items: [SSTVGalleryItem] = []

    private let galleryDir: URL
    private let indexURL: URL
    private let queue = DispatchQueue(label: "com.mikegyver.sstvstudio.gallery")

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        galleryDir = docs.appendingPathComponent("Gallery", isDirectory: true)
        indexURL = galleryDir.appendingPathComponent("gallery.json", isDirectory: false)
        try? FileManager.default.createDirectory(at: galleryDir, withIntermediateDirectories: true)
        load()
    }

    /// Auto-save a decoded picture. Safe to call from any thread; the
    /// published list is updated on the main thread. Returns the item, or
    /// nil if the image could not be written.
    /// If `secretEnvelope` is given, the envelope is appended as a
    /// trailer to the Gallery PNG file on disk (decoders ignore trailing
    /// data). The Photos-library copy is re-encoded by iOS and loses
    /// the trailer — the Gallery file is the record.
    @discardableResult
    func save(image: UIImage, mode: String, source: String, frequency: String?,
              secretEnvelope: Data? = nil) -> SSTVGalleryItem? {
        guard var png = image.pngData() else { return nil }
        if let envelope = secretEnvelope {
            png = SecretNote.pngWithSecret(png, envelope: envelope)
        }
        let id = UUID()
        let item = SSTVGalleryItem(
            id: id, date: Date(), mode: mode, source: source,
            frequency: frequency, fileName: "\(id.uuidString).png")
        let url = galleryDir.appendingPathComponent(item.fileName)
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try png.write(to: url, options: .atomic)
            } catch {
                print("Gallery: PNG write failed: \(error)")
                return
            }
            var updated = self.items
            updated.insert(item, at: 0)
            self.persist(updated)
            DispatchQueue.main.async { self.items = updated }
        }
        // Also save a copy to the Photos library (the old manual behaviour,
        // now automatic). Fire-and-forget; the gallery copy is the record.
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        return item
    }

    /// The UIImage for an item, or nil if its file is missing.
    func image(for item: SSTVGalleryItem) -> UIImage? {
        UIImage(contentsOfFile: galleryDir.appendingPathComponent(item.fileName).path)
    }

    /// The file URL for an item (for sharing).
    func url(for item: SSTVGalleryItem) -> URL {
        galleryDir.appendingPathComponent(item.fileName)
    }

    func delete(_ item: SSTVGalleryItem) {
        try? FileManager.default.removeItem(at: url(for: item))
        var updated = items
        updated.removeAll { $0.id == item.id }
        persist(updated)
        items = updated
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([SSTVGalleryItem].self, from: data) else {
            items = []
            return
        }
        // Drop index entries whose PNG is gone (e.g. deleted via Files).
        items = decoded.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func persist(_ items: [SSTVGalleryItem]) {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("Gallery: index write failed: \(error)")
        }
    }
}
