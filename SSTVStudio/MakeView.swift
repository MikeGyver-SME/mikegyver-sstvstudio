import SwiftUI
import PhotosUI
import AVFoundation

struct MakeView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPicker = false
    @State private var photo: UIImage?
    @State private var mode = "Robot 36"
    @State private var fit = ImageUtils.Fit.contain
    @State private var wavURL: URL?
    @State private var samples: Data?
    @State private var status = "Choose a photo to turn it into SSTV sound."
    @State private var decodedBack: DecodedSSTVImage?
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Make SSTV Sound").font(.largeTitle).bold()
                Text("Pick a photo, make the WAV, play it to a radio mic — or decode it back here to check it.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                if let photo = photo {
                    Image(uiImage: photo)
                        .resizable().scaledToFit().frame(maxHeight: 220).cornerRadius(8)
                }
                Button("Choose Photo") { showPicker = true }
                    .buttonStyle(.borderedProminent)
                Picker("Mode", selection: $mode) {
                    Text("Robot 36").tag("Robot 36")
                    Text("Robot 72").tag("Robot 72")
                }.pickerStyle(.segmented)
                Picker("Fit", selection: $fit) {
                    ForEach(ImageUtils.Fit.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }.pickerStyle(.segmented)
                Button("Make the WAV") { makeWAV() }
                    .buttonStyle(.borderedProminent)
                    .disabled(photo == nil)
                Text(status)
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                if let wavURL = wavURL {
                    HStack {
                        Button(isPlaying ? "Stop" : "Play") { togglePlay(url: wavURL) }
                        Button("Share WAV") {
                            shareItems = [wavURL]
                            showShare = true
                        }
                        Button("Decode it back") { decodeBack() }
                    }.buttonStyle(.bordered)
                }
                if let img = decodedBack {
                    Image(uiImage: img.uiImage)
                        .resizable().scaledToFit().cornerRadius(8)
                    Text("\(img.mode) · \(img.syncCount) sync pulses")
                        .font(.caption).foregroundColor(.secondary)
                }
            }.padding()
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item = item else { return }
            item.loadTransferable(type: Data.self) { result in
                if case .success(let data) = result,
                   let data = data, let ui = UIImage(data: data) {
                    DispatchQueue.main.async {
                        photo = ui
                        wavURL = nil
                        samples = nil
                        decodedBack = nil
                        status = "Photo ready. Tap Make the WAV."
                    }
                }
            }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
    }

    func makeWAV() {
        guard let photo = photo else { return }
        guard let rgba = ImageUtils.rgba320x240(from: photo, fit: fit) else {
            status = "Could not read that photo."
            return
        }
        status = "Making the WAV…"
        SSTVEngine.shared.encode(
            rgba: rgba, width: 320, height: 240, mode: mode, sampleRate: 44100) { data in
            guard let data = data,
                  let url = WAVUtils.writeWAV(
                    samples: data, sampleRate: 44100,
                    fileName: "sstv-\(mode.lowercased().replacingOccurrences(of: " ", with: "")).wav") else {
                status = "Could not make the WAV."
                return
            }
            samples = data
            wavURL = url
            decodedBack = nil
            let seconds = Int(Double(data.count / 4) / 44100)
            status = "\(mode) WAV ready — \(seconds) seconds. Play it to a radio mic, or decode it back here."
        }
    }

    func togglePlay(url: URL) {
        if isPlaying {
            player?.stop()
            isPlaying = false
            return
        }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
            isPlaying = true
            let dur = player?.duration ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + dur) { isPlaying = false }
        } catch {
            status = "Could not play: \(error.localizedDescription)"
        }
    }

    func decodeBack() {
        guard let samples = samples else { return }
        status = "Decoding it back…"
        SSTVEngine.shared.decode(samples: samples, sampleRate: 44100, modeHint: "auto") { image in
            if let image = image {
                decodedBack = image
                status = "Decoded back cleanly — \(image.mode)."
            } else {
                status = "Decode-back found nothing."
            }
        }
    }
}
