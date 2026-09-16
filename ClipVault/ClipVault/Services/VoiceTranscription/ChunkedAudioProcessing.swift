import Foundation

/// Pure PCM16 helpers for the chunked (non-realtime) transcription path.
///
/// The voice recorder produces 24 kHz mono signed-16-bit little-endian PCM.
/// Omni chat models want a WAV file — 16 kHz mono 16-bit is the recommended
/// shape — so every chunk is resampled and wrapped before it is posted.
/// Everything here is deterministic and free of I/O so it can be unit-tested.
enum PCM16Audio {

    /// Bytes per sample in the interchange format used throughout the voice path.
    static let bytesPerSample = MemoryLayout<Int16>.size

    /// Number of samples in `pcm16`.
    static func sampleCount(_ pcm16: Data) -> Int {
        pcm16.count / bytesPerSample
    }

    /// Duration of `pcm16` in seconds at `sampleRate`.
    static func duration(_ pcm16: Data, sampleRate: Int) -> TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(sampleCount(pcm16)) / TimeInterval(sampleRate)
    }

    /// Reads `pcm16` as an array of little-endian Int16 samples.
    static func samples(_ pcm16: Data) -> [Int16] {
        let count = sampleCount(pcm16)
        guard count > 0 else { return [] }
        return pcm16.withUnsafeBytes { raw -> [Int16] in
            var out = [Int16]()
            out.reserveCapacity(count)
            for index in 0..<count {
                let offset = index * bytesPerSample
                let low = UInt16(raw[offset])
                let high = UInt16(raw[offset + 1]) << 8
                out.append(Int16(bitPattern: high | low))
            }
            return out
        }
    }

    /// Packs Int16 samples back into little-endian bytes.
    static func data(from samples: [Int16]) -> Data {
        var out = Data(capacity: samples.count * bytesPerSample)
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            out.append(UInt8(bits & 0xFF))
            out.append(UInt8(bits >> 8))
        }
        return out
    }

    /// Root-mean-square level of `pcm16`, normalized to 0...1.
    static func rms(_ pcm16: Data) -> Float {
        let count = sampleCount(pcm16)
        guard count > 0 else { return 0 }
        var sum = 0.0
        for sample in samples(pcm16) {
            let normalized = Double(sample) / Double(Int16.max)
            sum += normalized * normalized
        }
        return Float((sum / Double(count)).squareRoot())
    }

    /// Linearly resamples mono PCM16 from `sourceRate` to `targetRate`.
    ///
    /// Linear interpolation is adequate for speech at a 3:2 downsample ratio
    /// (24 kHz → 16 kHz) and avoids pulling in an AVAudioConverter, which
    /// would make the chunker untestable off the audio thread.
    static func resample(_ pcm16: Data, from sourceRate: Int, to targetRate: Int) -> Data {
        guard sourceRate > 0, targetRate > 0, sourceRate != targetRate else { return pcm16 }
        let input = samples(pcm16)
        guard input.count > 1 else { return pcm16 }

        let ratio = Double(sourceRate) / Double(targetRate)
        let outputCount = Int((Double(input.count) / ratio).rounded(.down))
        guard outputCount > 0 else { return Data() }

        var output = [Int16]()
        output.reserveCapacity(outputCount)
        for index in 0..<outputCount {
            let position = Double(index) * ratio
            let lowIndex = Int(position)
            let highIndex = min(lowIndex + 1, input.count - 1)
            let fraction = position - Double(lowIndex)
            let interpolated = Double(input[lowIndex]) * (1 - fraction) + Double(input[highIndex]) * fraction
            output.append(Int16(max(Double(Int16.min), min(Double(Int16.max), interpolated.rounded()))))
        }
        return data(from: output)
    }

    /// Wraps raw PCM16 in a canonical 44-byte RIFF/WAVE header.
    static func wav(pcm16: Data, sampleRate: Int, channels: Int = 1) -> Data {
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var out = Data()
        func appendASCII(_ text: String) {
            out.append(contentsOf: Array(text.utf8))
        }
        func appendUInt32(_ value: UInt32) {
            out.append(UInt8(value & 0xFF))
            out.append(UInt8((value >> 8) & 0xFF))
            out.append(UInt8((value >> 16) & 0xFF))
            out.append(UInt8((value >> 24) & 0xFF))
        }
        func appendUInt16(_ value: UInt16) {
            out.append(UInt8(value & 0xFF))
            out.append(UInt8((value >> 8) & 0xFF))
        }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + pcm16.count))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)                       // PCM fmt chunk size
        appendUInt16(1)                        // PCM format tag
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(UInt16(blockAlign))
        appendUInt16(UInt16(bitsPerSample))
        appendASCII("data")
        appendUInt32(UInt32(pcm16.count))
        out.append(pcm16)
        return out
    }
}

/// Chooses where to cut a buffered chunk so a word isn't sliced in half.
///
/// The chunker cuts roughly every `chunkedTranscriptionWindowSeconds`, then
/// slides the cut to the quietest 50 ms frame inside the trailing search
/// window. Speech has natural inter-word dips, so the quietest frame is very
/// likely to be a pause.
struct SilenceSplitFinder {

    /// How far back from the nominal cut point to look for a pause.
    var searchWindowSeconds: Double = 1.5
    /// Analysis frame length. 50 ms is short enough to land inside a word gap
    /// and long enough for the RMS to be stable.
    var frameSeconds: Double = 0.05

    init(searchWindowSeconds: Double = 1.5, frameSeconds: Double = 0.05) {
        self.searchWindowSeconds = searchWindowSeconds
        self.frameSeconds = frameSeconds
    }

    /// Returns the byte offset at which `pcm16` should be cut.
    ///
    /// The offset is always sample-aligned and never zero for a non-empty
    /// buffer — if no quieter frame exists, the whole buffer is taken.
    func splitOffset(in pcm16: Data, sampleRate: Int) -> Int {
        let totalSamples = PCM16Audio.sampleCount(pcm16)
        guard totalSamples > 0, sampleRate > 0 else { return 0 }

        let frameSamples = max(1, Int(Double(sampleRate) * frameSeconds))
        let windowSamples = min(totalSamples, Int(Double(sampleRate) * searchWindowSeconds))
        guard windowSamples > frameSamples else {
            return totalSamples * PCM16Audio.bytesPerSample
        }

        let samples = PCM16Audio.samples(pcm16)
        let searchStart = totalSamples - windowSamples
        var bestEnergy = Double.greatestFiniteMagnitude
        var bestSample = totalSamples

        var frameStart = searchStart
        while frameStart + frameSamples <= totalSamples {
            var sum = 0.0
            for index in frameStart..<(frameStart + frameSamples) {
                let normalized = Double(samples[index]) / Double(Int16.max)
                sum += normalized * normalized
            }
            let energy = sum / Double(frameSamples)
            if energy < bestEnergy {
                bestEnergy = energy
                // Cut in the middle of the quietest frame.
                bestSample = frameStart + frameSamples / 2
            }
            frameStart += frameSamples
        }

        return max(frameSamples, bestSample) * PCM16Audio.bytesPerSample
    }
}

/// Releases transcription results in submission order.
///
/// Up to two chunk requests are in flight per source; the second can finish
/// first, so completions are parked until every earlier chunk has landed.
struct OrderedSegmentEmitter {

    private var nextSequence = 0
    private var nextToRelease = 0
    private var pending: [Int: String] = [:]

    init() {}

    /// Reserves the next sequence number for a chunk about to be sent.
    mutating func reserve() -> Int {
        defer { nextSequence += 1 }
        return nextSequence
    }

    /// Records a finished chunk and returns every result that is now
    /// releasable, in order. Empty results still advance the sequence.
    mutating func complete(sequence: Int, text: String) -> [String] {
        pending[sequence] = text
        var released: [String] = []
        while let next = pending.removeValue(forKey: nextToRelease) {
            nextToRelease += 1
            if !next.isEmpty { released.append(next) }
        }
        return released
    }

    /// True when every reserved chunk has been released.
    var isDrained: Bool { nextToRelease == nextSequence }
}
