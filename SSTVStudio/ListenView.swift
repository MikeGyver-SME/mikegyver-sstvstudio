import SwiftUI
import AVFoundation

/// Owns the microphone, the rolling audio buffer, and the periodic decode.
/// The tap callback only captures and stores audio — all decoding happens on
/// a background queue, so the real-time audio thread is never blocked.
final class MicListener: ObservableObject {
    @Published var level: Float = 0
    @Published var status: String = "Tap Listen, then hold the phone near a speaker or radio."
    @Published var decoded: DecodedSSTVImage?
    @Published var isListening = false
    var keepListening = false

    private var engine: AVAudioEngine?
    private var inputRate: Double = 48000
    private var buffer: [Float] = [] // mono, at inputRate
    private let bufferLock = NSLock()
    private var timer: Timer?
    private var decoding = false

    private let listenRate: Double = 8000
    private let windowSeconds: Double = 45
    private let minSeconds: Double = 40
    private let maxBufferSeconds: Double = 75

    func start() {
        stop()
        bufferLock.lock(); buffer.removeAll(); bufferLock.unlock()
        decoded = nil
        decoding = false
        // Keep the screen awake while listening. Without this, auto-lock
        // suspends mic capture mid-picture (the app has no background
        // audio mode unless Info.plist adds one) and the decode comes out
        // half-done: good audio at the top, noise at the bottom.
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
        } catch {
            status = "Mic setup failed: \(error.localizedDescription)"
            return
        }
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        inputRate = inFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] avBuffer, _ in
            self?.handleTap(buffer: avBuffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            status = "Audio engine failed: \(error.localizedDescription)"
            return
        }
        isListening = true
        status = "Listening…"
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.decodeWindow()
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        isListening = false
        DispatchQueue.main.async { [weak self] in
            self?.level = 0
            // Listening is over — the screen may sleep again.
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func handleTap(buffer avBuffer: AVAudioPCMBuffer) {
        let frames = Int(avBuffer.frameLength)
        guard frames > 0, let channels = avBuffer.floatChannelData else { return }
        let chCount = Int(avBuffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for c in 0..<chCount {
            let ch = channels[c]
            for i in 0..<frames { mono[i] += ch[i] / Float(chCount) }
        }
        var sum: Float = 0
        for v in mono { sum += v * v }
        let rms = sqrt(sum / Float(frames))
        let lvl = min(1, rms * 4)
        DispatchQueue.main.async { [weak self] in self?.level = lvl }
        bufferLock.lock()
        buffer.append(contentsOf: mono)
        let maxSamples = Int(maxBufferSeconds * inputRate)
        if buffer.count > maxSamples { buffer.removeFirst(buffer.count - maxSamples) }
        bufferLock.unlock()
    }

    private func decodeWindow() {
        guard isListening, !decoding else { return }
        bufferLock.lock()
        let needed = Int(minSeconds * inputRate)
        guard buffer.count >= needed else { bufferLock.unlock(); return }
        let window = Int(windowSeconds * inputRate)
        let slice = Array(buffer.suffix(window))
        bufferLock.unlock()
        decoding = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let down = MicListener.resampleTo8k(slice, fromRate: self.inputRate)
            let data = down.withUnsafeBytes { Data($0) }
            SSTVEngine.shared.decode(samples: data, sampleRate: self.listenRate, modeHint: "auto") { [weak self] image in
                guard let self = self else { return }
                self.decoding = false
                guard let image = image else { return }
                DispatchQueue.main.async {
                    self.decoded = image
                    self.status = "Picture received — \(image.mode), \(image.syncCount) sync pulses."
                    if self.keepListening {
                        self.bufferLock.lock(); self.buffer.removeAll(); self.bufferLock.unlock()
                    } else {
                        self.stop()
                    }
                }
            }
        }
    }

    /// Downsample to 8 kHz: a short boxcar low-pass (anti-alias), then
    /// linear interpolation to the new rate. Good enough for SSTV tones,
    /// which live between 1200 and 2300 Hz.
    static func resampleTo8k(_ samples: [Float], fromRate: Double) -> [Float] {
        guard fromRate > 8000, !samples.isEmpty else { return samples }
        let ratio = fromRate / 8000.0
        let win = max(1, Int(ratio.rounded()))
        var filtered = [Float](repeating: 0, count: samples.count)
        var acc: Float = 0
        for i in 0..<samples.count {
            acc += samples[i]
            if i >= win { acc -= samples[i - win] }
            filtered[i] = acc / Float(min(i + 1, win))
        }
        let outCount = Int(Double(samples.count) / ratio)
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let pos = Double(i) * ratio
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let a = filtered[min(idx, filtered.count - 1)]
            let b = filtered[min(idx + 1, filtered.count - 1)]
            out[i] = a + (b - a) * frac
        }
        return out
    }
}

struct ListenView: View {
    @StateObject private var listener = MicListener()
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Live Listen").font(.largeTitle).bold()
                Text("Point the phone at a speaker or a radio playing SSTV. The app listens, and when it hears a full picture it shows it here.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                VStack {
                    Text("Mic level").font(.caption)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.gray.opacity(0.25))
                            RoundedRectangle(cornerRadius: 6)
                                .fill(listener.level > 0.5 ? Color.green : Color.blue)
                                .frame(width: geo.size.width * CGFloat(min(max(listener.level, 0), 1)))
                        }
                    }.frame(height: 14)
                }
                Button(action: toggleListen) {
                    Text(listener.isListening ? "Stop Listening" : "Start Listening")
                        .font(.headline).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding()
                        .background(listener.isListening ? Color.red : Color.blue)
                        .cornerRadius(12)
                }
                Toggle("Keep listening after a picture", isOn: $listener.keepListening)
                Text(listener.status)
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                if let img = listener.decoded {
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
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
    }

    func toggleListen() {
        if listener.isListening {
            listener.stop()
            return
        }
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            listener.start()
        case .denied:
            listener.status = "Microphone access is off. Turn it on in Settings > SSTV Studio > Microphone."
        case .undetermined:
            session.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted { listener.start() }
                    else { listener.status = "Microphone access is needed to listen." }
                }
            }
        @unknown default:
            listener.start()
        }
    }

    func saveToPhotos(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        listener.status = "Saved to Photos."
    }
}
