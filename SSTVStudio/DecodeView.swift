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
        guard url.startAccessingSecurityScopedResource() else {
            status = "Could not access that file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let audio = WAVUtils.readAudio(url: url) else {
            status = "Could not read that audio file."
            return
        }
        status = "Decoding…"
        SSTVEngine.shared.decode(
            samples: audio.samples, sampleRate: audio.sampleRate, modeHint: modeHint) { image in
            if let image = image {
                decoded = image
                status = "Picture decoded — \(image.mode), \(image.syncCount) sync pulses."
            } else {
                decoded = nil
                status = "No SSTV picture found in that file."
            }
        }
    }

    func saveToPhotos(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        status = "Saved to Photos."
    }
}
