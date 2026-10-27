import Accelerate
import CoreAudio

/// Turns a stream of audio into a few band levels between 0 and 1, lowest band first, for the
/// equalizer bars. Bands are spaced evenly in pitch from 60 Hz to 12 kHz, and each follows its own
/// recent peak so the treble moves too, within reach of the loudest band. Not thread-safe: the tap
/// uses it from its IO queue only.
final class SpectrumAnalyzer {
    struct Output {
        let bands: [Float]
        /// The tap has heard nothing but silence for a while: the player is between tracks, paused,
        /// or macOS is withholding the sound.
        let isSilent: Bool
    }

    private static let log2n: vDSP_Length = 10
    private static let size = 1 << 10
    /// How far below its peak a band can go before its bar bottoms out, in dB.
    private static let range: Float = 30
    /// How far a band's own peak may sit below the loudest band's.
    private static let headroom: Float = 24
    private static let floor: Float = -75

    private let setup: FFTSetup
    private let window: [Float]
    private let bins: [Range<Int>]
    private let publishInterval: Int
    private let silenceLimit: Int
    private let peakFall: Float
    private var history: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var power: [Float]
    private var mono: [Float]
    private var decibels: [Float]
    private var peaks: [Float]
    private var levels: [Float]
    private var sinceLastPublish = 0
    private var silentSamples = 0

    init(sampleRate: Double, bands: Int) {
        let size = Self.size, half = size / 2
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        let binWidth = sampleRate / Double(size)
        let low = 60.0, high = min(12_000, sampleRate / 2 * 0.9)
        bins = (0..<bands).map { band in
            let from = low * pow(high / low, Double(band) / Double(bands))
            let to = low * pow(high / low, Double(band + 1) / Double(bands))
            let first = max(1, Int((from / binWidth).rounded()))
            let last = min(half - 1, max(first + 1, Int((to / binWidth).rounded())))
            return first..<last
        }
        // About 30 updates a second.
        publishInterval = max(256, Int(sampleRate / 30))
        silenceLimit = Int(sampleRate * 1.5)
        // Peaks sink about 6 dB a second.
        peakFall = 6 / 30
        history = [Float](repeating: 0, count: size)
        windowed = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: half)
        imaginary = [Float](repeating: 0, count: half)
        power = [Float](repeating: 0, count: half)
        mono = [Float](repeating: 0, count: 4096)
        decibels = [Float](repeating: Self.floor, count: bands)
        peaks = [Float](repeating: Self.floor, count: bands)
        levels = [Float](repeating: 0, count: bands)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Takes one IO cycle of 32-bit float audio, interleaved or not. Returns new levels about 30 times a second.
    func process(_ input: UnsafePointer<AudioBufferList>) -> Output? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels > 0 else { return nil }
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        guard frames > 0 else { return nil }
        if mono.count < frames { mono = [Float](repeating: 0, count: frames) }

        // Mix every channel of every buffer down to one.
        var channels = 0
        var loudest: Float = 0
        mono.withUnsafeMutableBufferPointer { mono in
            let out = mono.baseAddress!
            vDSP_vclr(out, 1, vDSP_Length(frames))
            for buffer in buffers {
                let count = Int(buffer.mNumberChannels)
                guard count > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let available = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * count))
                for channel in 0..<count {
                    vDSP_vadd(data + channel, vDSP_Stride(count), out, 1, out, 1, vDSP_Length(available))
                }
                channels += count
            }
            if channels > 1 {
                var scale = 1 / Float(channels)
                vDSP_vsmul(out, 1, &scale, out, 1, vDSP_Length(frames))
            }
            vDSP_maxmgv(out, 1, &loudest, vDSP_Length(frames))
        }
        guard channels > 0 else { return nil }
        silentSamples = loudest < 1e-5 ? silentSamples + frames : 0
        append(frames)

        sinceLastPublish += frames
        guard sinceLastPublish >= publishInterval else { return nil }
        sinceLastPublish = 0
        if silentSamples >= silenceLimit {
            for band in levels.indices { levels[band] *= 0.6 }
            return Output(bands: levels, isSilent: true)
        }
        analyze()
        return Output(bands: levels, isSilent: false)
    }

    /// Slides the newest `frames` mixed samples into the history.
    private func append(_ frames: Int) {
        let size = Self.size
        history.withUnsafeMutableBufferPointer { history in
            mono.withUnsafeBufferPointer { mono in
                let stride = MemoryLayout<Float>.stride
                if frames >= size {
                    memcpy(history.baseAddress!, mono.baseAddress! + (frames - size), size * stride)
                } else {
                    memmove(history.baseAddress!, history.baseAddress! + frames, (size - frames) * stride)
                    memcpy(history.baseAddress! + (size - frames), mono.baseAddress!, frames * stride)
                }
            }
        }
    }

    private func analyze() {
        let size = Self.size, half = size / 2
        vDSP_vmul(history, 1, window, 1, &windowed, 1, vDSP_Length(size))
        real.withUnsafeMutableBufferPointer { realPart in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPart in
                var split = DSPSplitComplex(realp: realPart.baseAddress!, imagp: imaginaryPart.baseAddress!)
                windowed.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { pairs in
                        vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                // The first slot packs the DC and Nyquist terms, which no band uses.
                split.realp[0] = 0
                split.imagp[0] = 0
                power.withUnsafeMutableBufferPointer { power in
                    vDSP_zvmags(&split, 1, power.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        // Band power in dB relative to a full-scale sine, give or take the window.
        let scale = 20 * log10f(Float(size))
        power.withUnsafeBufferPointer { power in
            for (band, range) in bins.enumerated() {
                var sum: Float = 0
                vDSP_sve(power.baseAddress! + range.lowerBound, 1, &sum, vDSP_Length(range.count))
                decibels[band] = max(Self.floor, 10 * log10f(sum + 1e-20) - scale)
            }
        }
        for band in peaks.indices {
            peaks[band] = max(decibels[band], peaks[band] - peakFall, Self.floor)
        }
        let loudestPeak = peaks.max() ?? Self.floor
        for band in levels.indices {
            let reference = max(peaks[band], loudestPeak - Self.headroom)
            // A band at the floor stays at the bottom, however quiet everything is.
            let bottom = max(Self.floor, reference - Self.range)
            let target = reference > bottom + 1 ? min(1, max(0, (decibels[band] - bottom) / (reference - bottom))) : 0
            // Rise quickly, fall gently.
            levels[band] += (target - levels[band]) * (target > levels[band] ? 0.6 : 0.22)
        }
    }
}
