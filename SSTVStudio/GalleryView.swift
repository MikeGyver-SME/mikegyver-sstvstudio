import SwiftUI

/// The Gallery tab: every picture the app has decoded, newest first.
/// Pictures land here automatically the moment they decode — no tap-Save
/// step — and survive app close and screen lock.
struct GalleryView: View {
    @ObservedObject private var store = GalleryStore.shared
    @State private var selected: SSTVGalleryItem?

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No pictures yet")
                            .font(.headline)
                        Text("Decoded pictures appear here automatically — from Live Listen, Make, and Decode.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(store.items) { item in
                                Button { selected = item } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let ui = store.image(for: item) {
                                            Image(uiImage: ui)
                                                .resizable()
                                                .scaledToFit()
                                                .cornerRadius(6)
                                        } else {
                                            Rectangle()
                                                .fill(Color.gray.opacity(0.25))
                                                .aspectRatio(4 / 3, contentMode: .fit)
                                                .cornerRadius(6)
                                        }
                                        Text(item.mode)
                                            .font(.caption).bold()
                                            .lineLimit(1)
                                        Text(item.displayDate)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .navigationTitle("Gallery")
            .sheet(item: $selected) { item in
                GalleryDetailView(item: item, onDelete: {
                    store.delete(item)
                    selected = nil
                })
            }
        }
    }
}

/// Full view of one gallery picture, with Share / Save / Delete.
struct GalleryDetailView: View {
    let item: SSTVGalleryItem
    let onDelete: () -> Void

    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var savedMessage = ""
    // Secret Note embedded in this Gallery PNG file (Make decode-back
    // only — the Photos copy loses the trailer when iOS re-encodes it).
    @State private var secretEnvelope: Data?
    @State private var secretPassphrase = ""
    @State private var secretNote: String?
    @State private var secretMessage = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let ui = GalleryStore.shared.image(for: item) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(8)
                }
                VStack(spacing: 4) {
                    Text(item.mode).font(.headline)
                    Text(item.displayDate).foregroundColor(.secondary)
                    Text("Source: \(item.source)" + (item.frequency.map { " · \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Button("Share") {
                        shareItems = [GalleryStore.shared.url(for: item)]
                        showShare = true
                    }
                    Button("Save to Photos") {
                        if let ui = GalleryStore.shared.image(for: item) {
                            UIImageWriteToSavedPhotosAlbum(ui, nil, nil, nil)
                            savedMessage = "Saved to Photos."
                        }
                    }
                    Button("Delete", role: .destructive) { onDelete() }
                }
                .buttonStyle(.bordered)
                if !savedMessage.isEmpty {
                    Text(savedMessage).font(.caption).foregroundColor(.secondary)
                }
                if secretEnvelope != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("🔒 This picture has a secret note")
                            .font(.headline)
                        if let note = secretNote {
                            Text(note).font(.body)
                        } else {
                            SecureField("Passphrase", text: $secretPassphrase)
                                .textFieldStyle(.roundedBorder)
                            Button("Unlock Note") {
                                guard let env = secretEnvelope else { return }
                                if secretPassphrase.isEmpty {
                                    secretMessage = "Enter the passphrase."
                                } else if let note = SecretNote.decrypt(envelopeData: env, passphrase: secretPassphrase) {
                                    secretNote = note
                                    secretMessage = ""
                                } else {
                                    secretMessage = "Wrong passphrase."
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            if !secretMessage.isEmpty {
                                Text(secretMessage).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(10)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
        .onAppear {
            // The Gallery PNG may carry a secret trailer (Make decode-back).
            secretEnvelope = SecretNote.extractEnvelope(
                fromFile: GalleryStore.shared.url(for: item))
        }
    }
}
