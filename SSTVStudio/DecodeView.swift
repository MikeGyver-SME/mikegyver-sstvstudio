import SwiftUI
import UniformTypeIdentifiers

struct DecodeView: View {
    @State private var showImporter = false
    @State private var status = "Choose a WAV file and the app will decode the picture in it."
    @State private var decoded: DecodedSSTVImage?
    @State private var modeHint = "auto"
    @State private var fileName = ""
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    // Secret Note found in the picked file (WAV trailer chunk).
    @State private var secretEnvelope: Data?
    @State private var secretPassphrase = ""
    @State private var secretNote: String?
    @State private var secretMessage = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Decode a WAV").font(.largeTitle).bold()
                Text("Pick a recording of an SSTV pass — from the ISS, a WebSDR, or a radio — and the picture comes out here.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                Button("Choose WAV File") { showImporter = true }
                    .buttonStyle(.borderedProminent)
                Picker("Mode", selection: $modeHint) {
                    Text("Auto").tag("auto")
                    Text("Robot 36").tag("Robot 36")
                    Text("Robot 72").tag("Robot 72")
                }.pickerStyle(.segmented)
                if !fileName.isEmpty {
                    Text(fileName).font(.caption).foregroundColor(.secondary)
                }
                Text(status)
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                if let img = decoded {
                    Image(uiImage: img.uiImage)
                        .resizable().scaledToFit().cornerRadius(8)
                    Text("\(img.mode) · \(img.syncCount) sync pulses · VIS \(img.visCode ?? -1)")
                        .font(.caption).foregroundColor(.secondary)
                    HStack {
                        Button("Save to Photos") { saveToPhotos(img.uiImage) }
                        Button("Share") {
                            shareItems = [img.uiImage]
                            showShare = true
                        }
                    }.buttonStyle(.bordered)
                }
                // Secret Note in this file, if the sender embedded one.
                // A live radio decode cannot carry a note — only a file can.
                if secretEnvelope != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("🔒 This file has a secret note")
                            .font(.headline)
                        if let note = secretNote {
                            Text(note)
                                .font(.body)
                                .padding(8)
                                .background(Color.gray.opacity(0.12))
                                .cornerRadius(8)
                        } else {
                            SecureField("Passphrase", text: $secretPassphrase)
                                .textFieldStyle(.roundedBorder)
                            Button("Unlock Note") { unlockSecret() }
                                .buttonStyle(.borderedProminent)
                            if !secretMessage.isEmpty {
                                Text(secretMessage)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(10)
                }
            }.padding()
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.wav, .audio],
            allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                decodeFile(url: url)
            case .failure(let error):
                status = "Could not pick the file: \(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
    }

    func decodeFile(url: URL) {
        fileName = url.lastPathComponent
        status = "Reading \(fileName)…"
        secretEnvelope = nil
        secretNote = nil
        secretPassphrase = ""
        secretMessage = ""
        guard url.startAccessingSecurityScopedResource() else {
            status = "Could not access that file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        // A secret note lives in the file's trailer chunk, not in the tones.
        if let env = SecretNote.extractEnvelope(fromFile: url) {
            secretEnvelope = env
        }
        guard let audio = WAVUtils.readAudio(url: url) else {
            status = "Could not read that audio file."
            return
        }
        status = "Decoding…"
        SSTVEngine.shared.decode(
            samples: audio.samples, sampleRate: audio.sampleRate, modeHint: modeHint) { image in
            if let image = image {
                decoded = image
                status = "Picture decoded — \(image.mode), \(image.syncCount) sync pulses. Auto-saved to Gallery and Photos."
                GalleryStore.shared.save(
                    image: image.uiImage, mode: image.mode,
                    source: "Decode", frequency: nil)
            } else {
                decoded = nil
                status = "No SSTV picture found in that file."
            }
        }
    }

    func unlockSecret() {
        guard let envelope = secretEnvelope else { return }
        guard !secretPassphrase.isEmpty else {
            secretMessage = "Enter the passphrase."
            return
        }
        if let note = SecretNote.decrypt(envelopeData: envelope, passphrase: secretPassphrase) {
            secretNote = note
            secretMessage = ""
        } else {
            secretNote = nil
            secretMessage = "Wrong passphrase."
        }
    }

    func saveToPhotos(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        status = "Saved to Photos."
    }
}
