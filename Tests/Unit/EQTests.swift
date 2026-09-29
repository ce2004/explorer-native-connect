import AVFoundation
import XCTest
@testable import ExplorerConnect

/// Real audio through the real DSP: sines in, levels measured with Goertzel.
final class EQTests: XCTestCase {
    private let fs = 48_000.0

    private func gains(_ band: Int, _ db: Double) -> [Double] {
        var g = Array(repeating: 0.0, count: EQEngine.bandCount)
        g[band] = db
        return g
    }

    private func engine(_ params: EQParams, rate: Double? = nil, channels: Int = 1, interleaved: Bool = false) -> EQEngine {
        let e = EQEngine(params: params)
        e.prepare(sampleRate: rate ?? fs, channels: channels, interleaved: interleaved, float32: true)
        return e
    }

    private func sine(_ freq: Double, seconds: Double, amplitude: Float = 0.25, rate: Double? = nil) -> [Float] {
        let r = rate ?? fs
        return (0..<Int(seconds * r)).map { amplitude * Float(sin(2 * Double.pi * freq * Double($0) / r)) }
    }

    /// Runs mono audio through the engine in 512-frame buffers, as the tap would; `before(startFrame)` runs before
    /// each buffer (to change settings mid-stream).
    private func run(_ e: EQEngine, _ input: [Float], chunk: Int = 512, before: ((Int) -> Void)? = nil) -> [Float] {
        var out = input
        let abl = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(abl.unsafeMutablePointer) }
        out.withUnsafeMutableBufferPointer { buf in
            var start = 0
            while start < buf.count {
                let n = min(chunk, buf.count - start)
                before?(start)
                abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: UnsafeMutableRawPointer(buf.baseAddress! + start))
                e.process(abl, frames: n)
                start += n
            }
        }
        return out
    }

    /// Amplitude of `freq` over a whole number of its cycles at the end of `x`.
    private func level(_ x: [Float], _ freq: Double, lastSeconds: Double = 0.4, rate: Double? = nil) -> Double {
        let r = rate ?? fs
        let cycles = max(1, (lastSeconds * freq).rounded(.down))
        let n = min(x.count, Int((cycles * r / freq).rounded()))
        guard n > 0 else { return 0 }
        let slice = x[(x.count - n)...]
        let w = 2 * Double.pi * freq / r
        let coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for v in slice {
            let s0 = Double(v) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return 2 * sqrt(max(0, power)) / Double(n)
    }

    private func db(_ ratio: Double) -> Double { 20 * log10(ratio) }

    func testEachBandBoostsItsOwnFrequencyAndLeavesTheOthers() {
        let params = EQParams()
        let f = EQEngine.frequencies
        for b in 0..<EQEngine.bandCount {
            params.set(enabled: true, gains: gains(b, 12))
            let headroom = EQParams.headroom(gains(b, 12))
            XCTAssertEqual(headroom, -12)
            for (j, freq) in f.enumerated() {
                let input = sine(freq, seconds: 0.7)
                let output = run(engine(params), input)
                // Relative to the automatic headroom, which lowers everything by the largest boost.
                let change = db(level(output, freq) / level(input, freq)) - headroom
                if j == b {
                    XCTAssertEqual(change, 12, accuracy: b == 0 || b == 9 ? 1.0 : 0.3, "band \(f[b]) at its own centre")
                } else if abs(j - b) == 1 {
                    XCTAssertLessThan(abs(change), 3.0, "band \(f[b]) at neighbour \(freq): \(change)")
                } else {
                    XCTAssertLessThan(abs(change), 0.8, "band \(f[b]) at \(freq): \(change)")
                }
            }
        }
    }

    func testShelvesReachFullGainAtTheEndBands() {
        let params = EQParams()
        params.set(enabled: true, gains: gains(0, -12))
        let low = sine(31, seconds: 1.0)
        XCTAssertLessThan(db(level(run(engine(params), low), 31) / level(low, 31)), -11, "31 Hz low shelf")
        let below = sine(20, seconds: 1.0)
        XCTAssertLessThan(db(level(run(engine(params), below), 20) / level(below, 20)), -11.3, "the shelf holds below 31 Hz")
        params.set(enabled: true, gains: gains(9, -12))
        let high = sine(16_000, seconds: 0.5)
        XCTAssertLessThan(db(level(run(engine(params), high), 16_000) / level(high, 16_000)), -11, "16 kHz high shelf")
    }

    func testOffAndFlatAreBitForBitIdentical() {
        let params = EQParams()
        let input = (0..<48_000).map { _ in Float.random(in: -1...1) }

        params.set(enabled: true, gains: Array(repeating: 0, count: 10))
        XCTAssertEqual(run(engine(params), input), input, "flat touches nothing")

        params.set(enabled: false, gains: [12, -12, 6, 3, 0, -4, 5, 12, -12, 8])
        XCTAssertEqual(run(engine(params), input), input, "off touches nothing")

        // Boosted, then back to flat: once the glide and the filters' ringing are over, it's a true bypass again.
        params.set(enabled: true, gains: gains(5, 6))
        let e = engine(params)
        let processed = run(e, input)
        XCTAssertNotEqual(processed, input)
        params.set(enabled: true, gains: Array(repeating: 0, count: 10))
        _ = run(e, input)
        XCTAssertTrue(e.isBypassed)
        XCTAssertEqual(run(e, input), input, "back to flat is a true bypass")

        // Switched off while boosted: the same.
        params.set(enabled: true, gains: gains(2, 9))
        _ = run(e, input)
        params.set(enabled: false, gains: gains(2, 9))
        _ = run(e, input)
        XCTAssertEqual(run(e, input), input, "switched off is a true bypass")
    }

    /// Largest sample-to-sample step: a click shows up as a step bigger than the sine itself ever makes.
    private func maxStep(_ x: [Float]) -> Float {
        var m: Float = 0
        for i in 1..<x.count { m = max(m, abs(x[i] - x[i - 1])) }
        return m
    }

    /// Peak level of each 1 ms stretch.
    private func envelope(_ x: [Float]) -> [Float] {
        stride(from: 0, to: x.count - 48, by: 48).map { i in x[i..<i + 48].map(abs).max() ?? 0 }
    }

    func testGainChangesGlideWithoutAClick() {
        let params = EQParams()
        params.set(enabled: true, gains: Array(repeating: 0, count: 10))
        let input = sine(1000, seconds: 0.3, amplitude: 0.5)
        let changeAt = 4800 // 100 ms, on a buffer boundary like a change from the screen would land
        let e = engine(params)
        let out = run(e, input, chunk: 480) { start in
            if start == changeAt { params.set(enabled: true, gains: self.gains(5, -12)) }
        }
        XCTAssertLessThanOrEqual(maxStep(out), maxStep(input) * 1.02, "no step bigger than the sine's own")
        let env = envelope(out)
        let t0 = changeAt / 48
        XCTAssertGreaterThan(env[t0 + 3], 0.5 * pow(10, -9.0 / 20), "not a jump: 3 ms in, it's still on its way down")
        XCTAssertEqual(Double(env[t0 + 45]), 0.5 * pow(10, -12.0 / 20), accuracy: 0.5 * pow(10, -12.0 / 20) * 0.08, "there within about 20 ms")
        for i in (t0 + 1)..<(t0 + 30) {
            // A 12 dB glide over 20 ms is at most about 1 dB per millisecond (with a little ringing).
            XCTAssertLessThan(abs(db(Double(env[i]) / Double(env[i - 1]))), 1.6, "smooth at \(i - t0) ms")
        }

        // The automatic headroom glides too: boosting 8 kHz lowers 1 kHz by 12 dB, smoothly.
        let p2 = EQParams()
        p2.set(enabled: true, gains: Array(repeating: 0, count: 10))
        let e2 = engine(p2)
        let out2 = run(e2, input, chunk: 480) { start in
            if start == changeAt { p2.set(enabled: true, gains: self.gains(8, 12)) }
        }
        XCTAssertLessThanOrEqual(maxStep(out2), maxStep(input) * 1.02)
        let env2 = envelope(out2)
        XCTAssertGreaterThan(env2[t0 + 3], 0.5 * pow(10, -9.0 / 20))
        XCTAssertEqual(Double(env2[t0 + 45]), 0.5 * pow(10, -12.0 / 20), accuracy: 0.5 * pow(10, -12.0 / 20) * 0.1)
    }

    func testAnyRateAndChannelCount() {
        let params = EQParams()
        var g = Array(repeating: 0.0, count: 10)
        g[5] = 6
        g[9] = 12 // above Nyquist at 8 kHz: left flat, but it still sets the headroom
        params.set(enabled: true, gains: g)
        let rate = 8000.0
        let mono = sine(1000, seconds: 0.6, rate: rate)
        // Interleaved stereo at 8 kHz.
        var stereo = [Float](repeating: 0, count: mono.count * 2)
        for i in mono.indices { stereo[2 * i] = mono[i]; stereo[2 * i + 1] = mono[i] * 0.5 }
        let e = EQEngine(params: params)
        e.prepare(sampleRate: rate, channels: 2, interleaved: true, float32: true)
        let abl = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(abl.unsafeMutablePointer) }
        stereo.withUnsafeMutableBufferPointer { buf in
            var frame = 0
            while frame < mono.count {
                let n = min(256, mono.count - frame)
                abl[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(n * 8), mData: UnsafeMutableRawPointer(buf.baseAddress! + frame * 2))
                e.process(abl, frames: n)
                frame += n
            }
        }
        XCTAssertFalse(stereo.contains { !$0.isFinite })
        let left = stride(from: 0, to: stereo.count, by: 2).map { stereo[$0] }
        let right = stride(from: 1, to: stereo.count, by: 2).map { stereo[$0] }
        XCTAssertEqual(db(level(left, 1000, rate: rate) / level(mono, 1000, rate: rate)), 6 - 12, accuracy: 0.4)
        XCTAssertEqual(db(level(right, 1000, rate: rate) / level(mono, 1000, rate: rate)), 6 - 12 - 6.02, accuracy: 0.4)

        // The same engine prepared again at another rate (the tap's prepare on a format change).
        e.prepare(sampleRate: 44_100, channels: 1, interleaved: false, float32: true)
        let cd = sine(1000, seconds: 0.5, rate: 44_100)
        let out = run(e, cd)
        XCTAssertEqual(db(level(out, 1000, rate: 44_100) / level(cd, 1000, rate: 44_100)), 6 - 12, accuracy: 0.4)
    }

    /// The tap is built for a real file's track (AVPlayer runs it; ServerTests plays through it).
    func testTapIsCreatedForARealTrack() async throws {
        let rate = 44_100.0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eq-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let samples = sine(1000, seconds: 0.2, rate: rate)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        pcm.frameLength = AVAudioFrameCount(samples.count)
        for i in samples.indices { pcm.floatChannelData![0][i] = samples[i] }
        try file.write(from: pcm)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let mix = try XCTUnwrap(EQTap.mix(for: track))
        XCTAssertNotNil(mix.inputParameters.first?.audioTapProcessor)
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
final class EqualizerModelTests: XCTestCase {
    func testSpeechAndRemembering() {
        XCTAssertEqual(Equalizer.bandName(2), "125 hertz")
        XCTAssertEqual(Equalizer.bandName(5), "1 kilohertz")
        XCTAssertEqual(Equalizer.bandName(9), "16 kilohertz")
        XCTAssertEqual(Equalizer.gainText(3), "plus 3 decibels")
        XCTAssertEqual(Equalizer.gainText(-1), "minus 1 decibel")
        XCTAssertEqual(Equalizer.gainText(0), "0 decibels")
        XCTAssertEqual(Equalizer.gainShortText(3), "+3 dB")

        let suite = "eq-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let params = EQParams()
        let eq = Equalizer(defaults: defaults, params: params)
        XCTAssertFalse(eq.enabled)
        XCTAssertTrue(eq.isFlat)
        var switched: [Bool] = []
        eq.onEnabledChange = { switched.append($0) }
        eq.setEnabled(true)
        eq.setGain(2, 20)
        XCTAssertEqual(eq.gains[2], 12, "clamped to +12")
        eq.adjust(2, by: -1)
        eq.adjust(7, by: -1)
        XCTAssertEqual(switched, [true])

        let again = Equalizer(defaults: defaults, params: EQParams())
        XCTAssertTrue(again.enabled, "on/off is remembered")
        XCTAssertEqual(again.gains[2], 11, "bands are remembered")
        XCTAssertEqual(again.gains[7], -1)

        let values = UnsafeMutablePointer<Double>.allocate(capacity: EQParams.count)
        defer { values.deallocate() }
        params.load(into: values)
        XCTAssertEqual(values[0], 1)
        XCTAssertEqual(values[1], -11, "headroom is the largest boost")
        XCTAssertEqual(values[2 + 2], 11)
        eq.resetAll()
        XCTAssertTrue(eq.isFlat)
        params.load(into: values)
        XCTAssertEqual(values[1], 0)
    }
}
