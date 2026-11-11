import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Codebook tab — the Windtalkers-style game (v1.0.5).
///
/// Chosen as its own tab (not a section in Make): the book is a thing
/// in its own right — encode, decode and manage all live here, and a
/// fifth tab still fits the tab bar. The warning is at the top of every
/// section: a codebook obscures meaning, so it is FILE / IN-PERSON
/// ONLY. Never play a codebook WAV into a radio mic.
struct CodebookView: View {
    @ObservedObject private var store = CodebookStore.shared
    @State private var section = 0 // 0 Send, 1 Read, 2 Book
    @State private var status = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Codebook").font(.largeTitle).bold()
                Text("File / in-person only — do NOT transmit over amateur radio.")
                    .font(.subheadline).bold()
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                Text("Words become pictures. Only someone with the same book can turn them back into words.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                Picker("Section", selection: $section) {
                    Text("Send").tag(0)
                    Text("Read").tag(1)
                    Text("Book").tag(2)
                }.pickerStyle(.segmented)
                if section == 0 {
                    CodebookSendView(status: $status)
                } else if section == 1 {
                    CodebookReadView(status: $status)
                } else {
                    CodebookManageView(status: $status)
                }
                if !status.isEmpty {
                    Text(status)
                        .multilineTextAlignment(.center)
                        .font(.subheadline)
                }
            }.padding()
        }
    }
}

// MARK: - Send: phrase -> collage -> SSTV WAV

struct CodebookSendView: View {
    @Binding var status: String
    @State private var phrase = ""
    @State private var collage: UIImage?
    @State private var collageEntries: [CodebookEntry] = []
    @State private var wavURL: URL?
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    var body: some View {
        VStack(spacing: 14) {
            TextField("Type a phrase, e.g. hello friend", text: $phrase)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Text("Up to \(CodebookStore.maxWords) words. Words not in the book become ? tiles.")
                .font(.caption).foregroundColor(.secondary)
            Button("Build Collage") {
                let made = CodebookStore.shared.collage(for: phrase)
                collage = made.image
                collageEntries = made.entries
                wavURL = nil
                status = made.entries.isEmpty
                    ? "Type a phrase first."
                    : "Collage ready — \(made.entries.count) tiles."
            }
            .buttonStyle(.borderedProminent)
            .disabled(phrase.trimmingCharacters(in: .whitespaces).isEmpty)
            if let collage = collage {
                Image(uiImage: collage)
                    .resizable().scaledToFit().cornerRadius(8)
                Text(collageEntries.map { $0.word }.joined(separator: " "))
                    .font(.caption).foregroundColor(.secondary)
                Button("Make the WAV") { makeWAV() }
                    .buttonStyle(.borderedProminent)
            }
            if let wavURL = wavURL {
                HStack {
                    Button("Share WAV") {
                        shareItems = [wavURL]
                        showShare = true
                    }
                    Button("Save Collage") {
                        if let collage = collage {
                            GalleryStore.shared.save(
                                image: collage, mode: "Robot 36",
                                source: "Codebook", frequency: nil)
                            status = "Collage saved to Gallery."
                        }
                    }
                }.buttonStyle(.bordered)
            }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
    }

    func makeWAV() {
        guard let collage = collage,
              let rgba = ImageUtils.rgba320x240(from: collage, fit: .stretch) else {
            status = "Could not build the collage."
            return
        }
        status = "Making the WAV…"
        SSTVEngine.shared.encode(
            rgba: rgba, width: 320, height: 240, mode: "Robot 36", sampleRate: 44100) { data in
            guard let data = data,
                  let url = WAVUtils.writeWAV(
                    samples: data, sampleRate: 44100, fileName: "sstv-codebook.wav") else {
                status = "Could not make the WAV."
                return
            }
            wavURL = url
            status = "Codebook WAV ready — share the FILE, do not play it into a radio."
        }
    }
}

// MARK: - Read: look at the collage, tap matching entries in order

struct CodebookReadView: View {
    @ObservedObject private var store = CodebookStore.shared
    @Binding var status: String
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPicker = false
    @State private var collage: UIImage?
    @State private var words: [String] = []

    var body: some View {
        VStack(spacing: 14) {
            Text("Pick the collage picture, then tap the matching entries below, in the order they appear in the collage.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button("Choose Collage Picture") { showPicker = true }
                .buttonStyle(.borderedProminent)
            if let collage = collage {
                Image(uiImage: collage)
                    .resizable().scaledToFit().cornerRadius(8)
            }
            if !words.isEmpty {
                Text(words.joined(separator: " "))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(8)
                HStack {
                    Button("Clear") { words.removeAll() }
                    Button("Copy") {
                        UIPasteboard.general.string = words.joined(separator: " ")
                        status = "Copied."
                    }
                }.buttonStyle(.bordered)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                ForEach(store.entries) { entry in
                    Button {
                        words.append(entry.word)
                    } label: {
                        VStack(spacing: 2) {
                            if let photo = store.photo(for: entry) {
                                Image(uiImage: photo)
                                    .resizable().scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipped().cornerRadius(8)
                            } else {
                                Text(entry.symbol).font(.system(size: 32))
                            }
                            Text(entry.word)
                                .font(.caption2).lineLimit(1)
                        }
                        .frame(width: 64, height: 76)
                        .background(Color.gray.opacity(0.12))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item = item else { return }
            item.loadTransferable(type: Data.self) { result in
                if case .success(let data) = result,
                   let data = data, let ui = UIImage(data: data) {
                    DispatchQueue.main.async {
                        collage = ui
                        words.removeAll()
                        status = "Collage loaded — tap the entries in order."
                    }
                }
            }
        }
    }
}

// MARK: - Book: entries, photos, share / import

struct CodebookManageView: View {
    @ObservedObject private var store = CodebookStore.shared
    @Binding var status: String
    @State private var newWord = ""
    @State private var newSymbol = ""
    @State private var photoEntry: CodebookEntry?
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showImporter = false
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    var body: some View {
        VStack(spacing: 14) {
            Text("\(store.entries.count) entries. Symbols travel with a shared book; photos stay on this phone only.")
                .font(.caption).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                TextField("word", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                TextField("symbol", text: $newSymbol)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Button("Add") {
                    store.add(word: newWord, symbol: newSymbol)
                    newWord = ""
                    newSymbol = ""
                    status = "Entry added."
                }
                .buttonStyle(.bordered)
                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(store.entries) { entry in
                HStack {
                    if let photo = store.photo(for: entry) {
                        Image(uiImage: photo)
                            .resizable().scaledToFill()
                            .frame(width: 36, height: 36)
                            .clipped().cornerRadius(6)
                    } else {
                        Text(entry.symbol).font(.title2).frame(width: 36)
                    }
                    Text(entry.word).font(.headline)
                    Spacer()
                    Button("Photo") {
                        photoEntry = entry
                        showPhotoPicker = true
                    }.buttonStyle(.bordered)
                    if entry.hasPhoto {
                        Button("Clear") { store.clearPhoto(for: entry) }
                            .buttonStyle(.bordered)
                    }
                    Button("Delete", role: .destructive) {
                        store.delete(entry)
                    }.buttonStyle(.bordered)
                }
            }
            HStack {
                Button("Share Book") {
                    if let url = store.exportURL() {
                        shareItems = [url]
                        showShare = true
                    } else {
                        status = "Could not export the book."
                    }
                }
                Button("Import Book") { showImporter = true }
                Button("Reset") {
                    store.resetToStarter()
                    status = "Starter book restored."
                }
            }.buttonStyle(.bordered)
            Text("Sharing sends a JSON file (words + symbols). The other phone imports it here.")
                .font(.caption).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item = item, let entry = photoEntry else { return }
            item.loadTransferable(type: Data.self) { result in
                if case .success(let data) = result,
                   let data = data, let ui = UIImage(data: data) {
                    DispatchQueue.main.async {
                        store.setPhoto(ui, for: entry)
                        status = "Photo set for \(entry.word)."
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                guard url.startAccessingSecurityScopedResource() else {
                    status = "Could not access that file."
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }
                if let count = store.importFile(url) {
                    status = "Imported \(count) entries."
                } else {
                    status = "That file is not a SSTV codebook."
                }
            case .failure(let error):
                status = "Could not pick the file: \(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
    }
}
