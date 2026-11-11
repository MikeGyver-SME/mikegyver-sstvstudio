import SwiftUI
import PhotosUI
import AVFoundation

/// Make tab (v1.0.5): photo, formula, or puzzle — plus an optional
/// Secret Note, file-only.
///
/// Send types:
///   Photo   — the original Make: pick a photo, make the WAV.
///   Formula — type a formula, it is rendered large as the picture.
///             Legal on air: nothing is hidden, the picture IS the message.
///   Puzzle  — a generated puzzle (or your own question), same rendering.
/// Secret Note is a separate toggle that works with any of the three:
/// it encrypts a short note and embeds it in the WAV file. FILE ONLY —
/// do NOT transmit a secret-carrying WAV over amateur radio (FCC Part 97).
struct MakeView: View {
    enum SendType: String, CaseIterable {
        case photo = "Photo"
        case formula = "Formula"
        case puzzle = "Puzzle"
    }

    @State private var sendType = SendType.photo
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

    // Formula / puzzle
    @State private var formulaText = "E=mc^2"
    @State private var puzzle: MathPuzzle.Puzzle?
    @State private var puzzleQuestion = ""

    // Secret Note (file only)
    @State private var secretOn = false
    @State private var secretPassphrase = ""
    @State private var secretNote = ""
    @State private var secretEnvelope: Data?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Make SSTV Sound").font(.largeTitle).bold()
                Text("Pick a photo, a formula, or a puzzle — make the WAV, play it to a radio mic, or decode it back here to check it.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                Picker("What to send", selection: $sendType) {
                    ForEach(SendType.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }.pickerStyle(.segmented)
                .onChange(of: sendType) { _, _ in
                    wavURL = nil; samples = nil; decodedBack = nil; secretEnvelope = nil
                    status = sendType == .photo
                        ? "Choose a photo to turn it into SSTV sound."
                        : "Type it below, then tap Make the WAV."
                }

                if sendType == .photo {
                    if let photo = photo {
                        Image(uiImage: photo)
                            .resizable().scaledToFit().frame(maxHeight: 220).cornerRadius(8)
                    }
                    Button("Choose Photo") { showPicker = true }
                        .buttonStyle(.borderedProminent)
                } else if sendType == .formula {
                    TextField("Formula, e.g. E=mc^2", text: $formulaText)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(MathPuzzle.presets, id: \.self) { preset in
                                Button(preset) { formulaText = preset }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    Text("Rendered large as the picture. Legal on air — nothing is hidden.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    if puzzleQuestion.isEmpty {
                        Button("New Puzzle") { newPuzzle() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Text(MathPuzzle.prettify(puzzleQuestion))
                            .font(.title2).bold()
                            .multilineTextAlignment(.center)
                        if let puzzle = puzzle {
                            Text("Answer (sender only): \(puzzle.answer)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Button("New Puzzle") { newPuzzle() }
                            .buttonStyle(.bordered)
                    }
                    Text("The recipient sees only the question and solves it.")
                        .font(.caption).foregroundColor(.secondary)
                }

                Picker("Mode", selection: $mode) {
                    Text("Robot 36").tag("Robot 36")
                    Text("Robot 72").tag("Robot 72")
                }.pickerStyle(.segmented)
                if sendType == .photo {
                    Picker("Fit", selection: $fit) {
                        ForEach(ImageUtils.Fit.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }.pickerStyle(.segmented)
                }

                // MARK: Secret Note (file only)
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Secret Note (file only)", isOn: $secretOn)
                    if secretOn {
                        Text("File only — do NOT transmit over amateur radio.")
                            .font(.subheadline).bold().foregroundColor(.red)
                        Text("The note is encrypted and hidden in the WAV file itself, not in the picture tones. A live radio decode cannot carry it — only someone with the file and the passphrase can read it.")
                            .font(.caption).foregroundColor(.secondary)
                        SecureField("Passphrase", text: $secretPassphrase)
                            .textFieldStyle(.roundedBorder)
                        TextField("Secret note (max \(SecretNote.maxNoteLength) chars)", text: $secretNote, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3)
                            .onChange(of: secretNote) { _, v in
                                if v.count > SecretNote.maxNoteLength {
                                    secretNote = String(v.prefix(SecretNote.maxNoteLength))
                                }
                            }
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.12))
                .cornerRadius(10)

                Button("Make the WAV") { makeWAV() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canMake)
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

    var canMake: Bool {
        switch sendType {
        case .photo: return photo != nil
        case .formula: return !formulaText.trimmingCharacters(in: .whitespaces).isEmpty
        case .puzzle: return !puzzleQuestion.isEmpty
        }
    }

    func newPuzzle() {
        puzzle = MathPuzzle.randomPuzzle()
        puzzleQuestion = puzzle?.question ?? ""
    }

    /// The 320x240 source image for the chosen send type.
    func sourceImage() -> UIImage? {
        switch sendType {
        case .photo:
            return photo
        case .formula:
            return MathPuzzle.render(formulaText)
        case .puzzle:
            return MathPuzzle.render(puzzleQuestion)
        }
    }

    func makeWAV() {
        // Encrypt the secret note first (if on) — a bad passphrase or an
        // empty note blocks the build with a clear message, not a silent WAV.
        secretEnvelope = nil
        if secretOn {
            guard !secretPassphrase.isEmpty else {
                status = "Secret Note is on — enter a passphrase first."
                return
            }
            guard !secretNote.trimmingCharacters(in: .whitespaces).isEmpty else {
                status = "Secret Note is on — type a note first."
                return
            }
            guard let env = SecretNote.encrypt(note: secretNote, passphrase: secretPassphrase) else {
                status = "Could not encrypt the note."
                return
            }
            secretEnvelope = env
        }
        guard var image = sourceImage() else {
            status = "Nothing to send yet."
            return
        }
        if secretOn { image = SecretNote.withLockBadge(image) }
        guard let rgba = ImageUtils.rgba320x240(from: image, fit: sendType == .photo ? fit : .stretch) else {
            status = "Could not read that image."
            return
        }
        status = "Making the WAV…"
        SSTVEngine.shared.encode(
            rgba: rgba, width: 320, height: 240, mode: mode, sampleRate: 44100) { data in
            guard let data = data,
                  let url = WAVUtils.writeWAV(
                    samples: data, sampleRate: 44100,
                    fileName: "sstv-\(mode.lowercased().replacingOccurrences(of: " ", with: "")).wav",
                    secretEnvelope: secretEnvelope) else {
                status = "Could not make the WAV."
                return
            }
            samples = data
            wavURL = url
            decodedBack = nil
            let seconds = Int(Double(data.count / 4) / 44100)
            if secretOn {
                status = "\(mode) WAV ready — \(seconds) seconds, with a secret note inside. Share the FILE. Do NOT play it into a radio."
            } else {
                status = "\(mode) WAV ready — \(seconds) seconds. Play it to a radio mic, or decode it back here."
            }
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
                status = "Decoded back cleanly — \(image.mode). Auto-saved to Gallery and Photos."
                GalleryStore.shared.save(
                    image: image.uiImage, mode: image.mode,
                    source: "Make", frequency: nil,
                    secretEnvelope: secretEnvelope)
            } else {
                status = "Decode-back found nothing."
            }
        }
    }
}
