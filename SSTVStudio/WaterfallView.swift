import SwiftUI
import Foundation

/// Live spectrogram for the SSTV tone range, 1200-2300 Hz.
///
/// How it works: the mic tap feeds the latest audio into this model, which
/// every ~100 ms runs a Goertzel filter bank (48 bins, linear from 1200 to
/// 2300 Hz) over the last 1024 samples and appends one column to a
/// scrolling history. Goertzel is O(bins x samples) — about 50k multiply
/// operations per column, at 10 columns a second — so it costs almost
/// nothing next to the decoder, and the compute runs on a background
/// serial queue, never on the real-time audio thread.
///
/// The view renders the history with SwiftUI Canvas: time scrolls left,
/// frequency runs bottom (1200 Hz) to top (2300 Hz), bright = strong tone.
final class WaterfallModel: ObservableObject {
    static let binCount = 48
    static let lowFreq: Double = 1200
    static let highFreq: Double = 2300
    static let maxColumns = 120

    @Published private(set) var columns: [[Float]] = []

    private var ring: [Float] = []
    private let ringLock = NSLock()
    private let computeQueue = DispatchQueue(label: "com.mikegyver.sstvstudio.waterfall")
    private var lastCompute = Date.distantPast
    private var computing = false

    /// Feed mono tap samples (any sample rate). Throttled internally to
    /// about 10 columns per second.
    func feed(samples: [Float], sampleRate: Double) {
        ringLock.lock()
        ring.append(contentsOf: samples)
        let maxRing = 4096
        if ring.count > maxRing { ring.removeFirst(ring.count - maxRing) }
        let snapshot = ring
        ringLock.unlock()
        guard Date().timeIntervalSince(lastCompute) >= 0.1, !computing else { return }
        lastCompute = Date()
        computing = true
        computeQueue.async { [weak self] in
            guard let self = self else { return }
            let column = WaterfallModel.goertzelColumn(samples: snapshot, sampleRate: sampleRate)
            DispatchQueue.main.async {
                self.columns.append(column)
                if self.columns.count > WaterfallModel.maxColumns {
                    self.columns.removeFirst(self.columns.count - WaterfallModel.maxColumns)
                }
                self.computing = false
            }
        }
    }

    func clear() {
        ringLock.lock(); ring.removeAll(); ringLock.unlock()
        columns = []
    }

    /// One column of normalised bin levels (0...1) from the last 1024
    /// samples, using a Hann window and a Goertzel filter per bin.
    static func goertzelColumn(samples: [Float], sampleRate: Double) -> [Float] {
        let n = 1024
        guard samples.count >= 256, sampleRate > 0 else {
            return [Float](repeating: 0, count: binCount)
        }
        let take = Array(samples.suffix(n))
        let count = take.count
        // Hann window.
        var windowed = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let w = 0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(count - 1)))
            windowed[i] = take[i] * Float(w)
        }
        var levels = [Float](repeating: 0, count: binCount)
        for b in 0..<binCount {
            let freq = lowFreq + (highFreq - lowFreq) * Double(b) / Double(binCount - 1)
            let omega = 2 * Double.pi * freq / sampleRate
            let coeff = 2 * cos(omega)
            var sPrev: Double = 0
            var sPrev2: Double = 0
            for x in windowed {
                let s = Double(x) + coeff * sPrev - sPrev2
                sPrev2 = sPrev
                sPrev = s
            }
            let power = sPrev * sPrev + sPrev2 * sPrev2 - coeff * sPrev * sPrev2
            let magnitude = sqrt(max(power, 0)) / Double(count)
            // Map roughly -60 dB ... 0 dB to 0 ... 1.
            let db = 20 * log10(magnitude + 1e-6)
            let level = (db + 60) / 60
            levels[b] = Float(min(1, max(0, level)))
        }
        return levels
    }

    /// Frequency (Hz) of a bin index.
    static func frequency(forBin b: Int) -> Double {
        lowFreq + (highFreq - lowFreq) * Double(b) / Double(binCount - 1)
    }
}

/// The waterfall view: scrolling spectrogram plus frequency markers.
struct WaterfallView: View {
    @ObservedObject var model: WaterfallModel

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Waterfall 1200–2300 Hz").font(.caption).bold()
                Spacer()
                Text("bright = tone present").font(.caption2).foregroundColor(.secondary)
            }
            Canvas { context, size in
                // Background.
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                let cols = model.columns
                guard !cols.isEmpty else { return }
                let colWidth = size.width / CGFloat(WaterfallModel.maxColumns)
                let binHeight = size.height / CGFloat(WaterfallModel.binCount)
                for (ci, column) in cols.enumerated() {
                    // Newest column on the right.
                    let x = size.width - CGFloat(cols.count - ci) * colWidth
                    for (bi, level) in column.enumerated() {
                        let y = size.height - CGFloat(bi + 1) * binHeight
                        let rect = CGRect(x: x, y: y, width: colWidth + 0.5, height: binHeight + 0.5)
                        context.fill(Path(rect), with: .color(waterfallColor(level)))
                    }
                }
            }
            .frame(height: 120)
            .cornerRadius(8)
            HStack {
                ForEach([1200, 1500, 1900, 2300], id: \.self) { f in
                    Text("\(f) Hz").font(.caption2).foregroundColor(.secondary)
                    if f != 2300 { Spacer() }
                }
            }
        }
    }

    /// Black -> deep blue -> green -> yellow -> red, by level 0...1.
    private func waterfallColor(_ level: Float) -> Color {
        switch level {
        case ..<0.05: return .black
        case ..<0.3: return Color(red: 0, green: 0, blue: Double(level) * 2)
        case ..<0.55: return Color(red: 0, green: Double(level), blue: 0.4)
        case ..<0.8: return Color(red: Double(level), green: 0.9, blue: 0)
        default: return Color(red: 1, green: Double(1 - level) * 0.6, blue: 0)
        }
    }
}
