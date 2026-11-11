import Foundation
import AVFoundation

/// WAV / audio file helpers. The SSTV engine works with raw float32 samples;
/// these helpers turn those samples into a playable .wav file, and turn an
/// audio file (WAV, MP3, AAC, …) back into float32 samples.
enum WAVUtils {

    /// Write mono float32 samples as a 16-bit PCM .wav file in the temp
    /// directory. Returns the file URL, or nil on failure.
    static func writeWAV(samples: Data, sampleRate: Double, fileName: String) -> URL? {
        let count = samples.count / 4
        guard count > 0 else { return nil }
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBytes { samples.copyBytes(to: $0) }
        var pcm = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let v = max(-1.0, min(1.0, floats[i]))
            pcm[i] = Int16(v * 32767)
        }
        var data = Data()
        func appendBytes(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
        func append32(_ v: UInt32) {
            var x = v.littleEndian
            data.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) })
        }
        func append16(_ v: UInt16) {
            var x = v.littleEndian
            data.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) })
        }
        let dataSize = UInt32(count * 2)
        appendBytes([0x52, 0x49, 0x46, 0x46]) // "RIFF"
        append32(36 + dataSize)
        appendBytes([0x57, 0x41, 0x56, 0x45]) // "WAVE"
        appendBytes([0x66, 0x6D, 0x74, 0x20]) // "fmt "
        append32(16)
        append16(1) // PCM
        append16(1) // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate) * 2) // byte rate
        append16(2) // block align
        append16(16) // bits per sample
        appendBytes([0x64, 0x61, 0x74, 0x61]) // "data"
        append32(dataSize)
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
        do {
            try data.write(to: url)
            return url
        } catch {
            print("WAV write failed: \(error)")
            return nil
        }
    }

    /// Read an audio file (WAV, MP3, AAC, …) into mono float32 samples at
    /// the file's native sample rate. Returns the raw sample bytes and the
    /// sample rate, or nil on failure.
    static func readAudio(url: URL) -> (samples: Data, sampleRate: Double)? {
        do {
            let file = try AVAudioFile(forReading: url)
            let sr = file.fileFormat.sampleRate
            guard let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sr,
                channels: 1, interleaved: false) else { return nil }
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: outFormat, frameCapacity: frameCount) else { return nil }
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let ch = buffer.floatChannelData?[0] else { return nil }
            var mono = [Float](repeating: 0, count: frames)
            for i in 0..<frames { mono[i] = ch[i] }
            let data = mono.withUnsafeBytes { Data($0) }
            return (data, sr)
        } catch {
            print("Audio read failed: \(error)")
            return nil
        }
    }
}
