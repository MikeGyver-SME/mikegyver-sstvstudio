import Foundation
import AVFoundation

/// Records the microphone stream for a whole listening session to a WAV
/// file, so a pass can be re-decoded later even if the live decode glitched.
///
/// Design notes:
/// - The recorder is fed the same mono tap buffers that feed the decoder.
/// - Audio is downsampled to 8 kHz mono, 16-bit PCM — the same rate the
///   decoder works at, and SSTV tones live between 1200 and 2300 Hz, so
///   nothing the decoder needs is lost. At 8 kHz a 10-minute pass is
///   about 9.6 MB.
/// - Downsampling is incremental (boxcar average driven by a phase
///   accumulator), and samples are written to disk as they arrive, so
///   memory stays flat no matter how long the session runs.
/// - The WAV header is written with placeholder sizes and patched on
///   finish(), so the file is a valid WAV even after a long session.
/// - Recording runs on the same audio session as listening, so it keeps
///   running in the background while UIBackgroundModes audio is set.
final class PassRecorder {
    static let outputSampleRate: Double = 8000

    private(set) var isRecording = false
    private(set) var fileName: String?
    private(set) var url: URL?

    private var fileHandle: FileHandle?
    private var inputRate: Double = 48000
    private var phase: Double = 0
    private var sum: Float = 0
    private var sumCount: Int = 0
    private var emittedSamples: Int = 0
    private let lock = NSLock()

    /// Start a new recording. The file is named with the session start
    /// time, e.g. sstv-pass-2026-11-14-1650.wav, in Documents/Recordings/.
    /// Returns the file URL, or nil on failure.
    func start(inputSampleRate: Double, startDate: Date = Date()) -> URL? {
        stopWithoutFinishing()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("PassRecorder: could not create Recordings dir: \(error)")
            return nil
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmm"
        let name = "sstv-pass-\(fmt.string(from: startDate)).wav"
        let fileURL = dir.appendingPathComponent(name)
        // 44-byte WAV header with placeholder sizes; patched in finish().
        var header = Data()
        func appendBytes(_ bytes: [UInt8]) { header.append(contentsOf: bytes) }
        func append32(_ v: UInt32) {
            var x = v.littleEndian
            header.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) })
        }
        func append16(_ v: UInt16) {
            var x = v.littleEndian
            header.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) })
        }
        appendBytes([0x52, 0x49, 0x46, 0x46]) // "RIFF"
        append32(0) // chunk size, patched in finish()
        appendBytes([0x57, 0x41, 0x56, 0x45]) // "WAVE"
        appendBytes([0x66, 0x6D, 0x74, 0x20]) // "fmt "
        append32(16)
        append16(1) // PCM
        append16(1) // mono
        append32(8000) // sample rate
        append32(16000) // byte rate
        append16(2) // block align
        append16(16) // bits per sample
        appendBytes([0x64, 0x61, 0x74, 0x61]) // "data"
        append32(0) // data size, patched in finish()
        assert(header.count == 44)
        do {
            try header.write(to: fileURL, options: .atomic)
            fileHandle = try FileHandle(forWritingTo: fileURL)
            try fileHandle?.seekToEnd()
        } catch {
            print("PassRecorder: could not open file: \(error)")
            return nil
        }
        inputRate = inputSampleRate
        phase = 0
        sum = 0
        sumCount = 0
        emittedSamples = 0
        fileName = name
        url = fileURL
        isRecording = true
        return fileURL
    }

    /// Feed mono tap samples (at the input sample rate). Cheap: a running
    /// average plus an occasional file write. Called from the audio tap.
    func append(_ mono: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording, let handle = fileHandle else { return }
        let step = PassRecorder.outputSampleRate / inputRate
        var pcm = [Int16]()
        pcm.reserveCapacity(mono.count / 4)
        for v in mono {
            sum += v
            sumCount += 1
            phase += step
            if phase >= 1 {
                phase -= 1
                let avg = sumCount > 0 ? sum / Float(sumCount) : 0
                sum = 0
                sumCount = 0
                let clamped = max(-1.0, min(1.0, avg))
                pcm.append(Int16(clamped * 32767))
                emittedSamples += 1
            }
        }
        if !pcm.isEmpty {
            let data = pcm.withUnsafeBytes { Data($0) }
            try? handle.write(data)
        }
    }

    /// Stop and finalise the file: patch the WAV header sizes and close.
    /// Returns the finished file URL, or nil if nothing was recorded.
    func finish() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording else { return url }
        isRecording = false
        guard let handle = fileHandle, let fileURL = url else { return nil }
        let dataSize = UInt32(emittedSamples * 2)
        do {
            try handle.seek(toOffset: 4)
            var chunk = (36 + dataSize).littleEndian
            try? handle.write(withUnsafeBytes(of: &chunk) { Data($0) })
            try handle.seek(toOffset: 40)
            var dsize = dataSize.littleEndian
            try? handle.write(withUnsafeBytes(of: &dsize) { Data($0) })
            try handle.close()
        } catch {
            print("PassRecorder: finish failed: \(error)")
        }
        fileHandle = nil
        return emittedSamples > 0 ? fileURL : nil
    }

    /// Length of audio recorded so far, in seconds (8 kHz output rate).
    var durationSeconds: Double {
        Double(emittedSamples) / PassRecorder.outputSampleRate
    }

    private func stopWithoutFinishing() {
        if isRecording {
            try? fileHandle?.close()
        }
        fileHandle = nil
        isRecording = false
    }
}
