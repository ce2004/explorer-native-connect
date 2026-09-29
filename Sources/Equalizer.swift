import AVFoundation
import MediaToolbox
import Observation

// A 10-band equalizer on everything the player plays, through an MTAudioProcessingTap on each AVPlayerItem.
//
// The settings live on the main thread (Equalizer). They're published to the render thread through EQParams, a block
// of doubles written and read with atomic 64-bit stores and loads: no locks, no allocation on the audio thread.
// Each tap owns an EQEngine: transposed direct form II biquads in Double, state per channel, gains that glide over
// 20 ms so a change never clicks, and a true bypass (the samples aren't touched) when the EQ is off or flat.

// MARK: - Parameters shared with the audio thread

/// [0] on (1) or off (0), [1] headroom in dB (always <= 0), [2...11] band gains in dB.
final class EQParams: @unchecked Sendable {
    static let shared = EQParams()
    static let count = 2 + EQEngine.bandCount

    let storage: UnsafeMutablePointer<Double>

    init() {
        storage = .allocate(capacity: Self.count)
        storage.initialize(repeating: 0, count: Self.count)
    }

    deinit { storage.deallocate() }

    /// Headroom is automatic: the largest boost comes off the level first, so a boost can't clip.
    static func headroom(_ gains: [Double]) -> Double { -max(0, gains.max() ?? 0) }

    /// Main thread.
    func set(enabled: Bool, gains: [Double]) {
        for i in 0..<EQEngine.bandCount {
            ec_atomic_store_double(storage + 2 + i, i < gains.count ? gains[i] : 0)
        }
        ec_atomic_store_double(storage + 1, Self.headroom(gains))
        ec_atomic_store_double(storage, enabled ? 1 : 0)
    }

    /// Audio thread: copies the current values into `out` (EQParams.count doubles).
    @inline(__always)
    func load(into out: UnsafeMutablePointer<Double>) {
        for i in 0..<Self.count { out[i] = ec_atomic_load_double(storage + i) }
    }
}

// MARK: - DSP

final class EQEngine: @unchecked Sendable {
    static let frequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let bandCount = 10
    /// One octave apart; Q 2 keeps a neighbouring band's centre within about 1.5 dB of a full boost.
    static let peakQ = 2.0
    /// The shelves' corners sit between the end bands and their neighbours.
    static let lowShelfCorner = 50.0
    static let highShelfCorner = 10_000.0
    static let shelfSlope = 1.5
    static let glideSeconds = 0.02
    /// Coefficients are recomputed every this many frames while a gain glides.
    static let block = 32

    private let params: EQParams
    private let snapshot = UnsafeMutablePointer<Double>.allocate(capacity: EQParams.count)
    private let targetGain = UnsafeMutablePointer<Double>.allocate(capacity: bandCount)
    private let currentGain = UnsafeMutablePointer<Double>.allocate(capacity: bandCount)
    private let gainStep = UnsafeMutablePointer<Double>.allocate(capacity: bandCount)
    private let remaining = UnsafeMutablePointer<Int>.allocate(capacity: bandCount)
    private let active = UnsafeMutablePointer<Bool>.allocate(capacity: bandCount)
    /// b0, b1, b2, a1, a2 per band, normalised by a0.
    private let coef = UnsafeMutablePointer<Double>.allocate(capacity: bandCount * 5)
    /// s1, s2 per band per channel.
    private var state: UnsafeMutablePointer<Double>?
    private var channels = 0
    private var sampleRate = 0.0
    private var interleaved = false
    private var supported = false
    private var level = 1.0
    private var levelTarget = 1.0
    private var levelStep = 0.0
    private var levelRemaining = 0

    init(params: EQParams = .shared) {
        self.params = params
        snapshot.initialize(repeating: 0, count: EQParams.count)
        targetGain.initialize(repeating: 0, count: Self.bandCount)
        currentGain.initialize(repeating: 0, count: Self.bandCount)
        gainStep.initialize(repeating: 0, count: Self.bandCount)
        remaining.initialize(repeating: 0, count: Self.bandCount)
        active.initialize(repeating: false, count: Self.bandCount)
        coef.initialize(repeating: 0, count: Self.bandCount * 5)
    }

    deinit {
        snapshot.deallocate()
        targetGain.deallocate()
        currentGain.deallocate()
        gainStep.deallocate()
        remaining.deallocate()
        active.deallocate()
        coef.deallocate()
        state?.deallocate()
    }

    /// Not on the render thread: the tap's prepare callback (and the tests). Handles any rate and channel count;
    /// only 32-bit float audio is processed, anything else passes through untouched.
    func prepare(sampleRate: Double, channels: Int, interleaved: Bool, float32: Bool) {
        state?.deallocate()
        self.sampleRate = sampleRate
        self.channels = max(0, channels)
        self.interleaved = interleaved
        supported = float32 && sampleRate > 0 && channels > 0
        let n = Self.bandCount * max(1, channels) * 2
        let s = UnsafeMutablePointer<Double>.allocate(capacity: n)
        s.initialize(repeating: 0, count: n)
        state = s
        // Start where the settings are now, without a glide: nothing has played through this tap yet.
        params.load(into: snapshot)
        let on = snapshot[0] != 0
        for b in 0..<Self.bandCount {
            let g = on ? snapshot[2 + b] : 0
            targetGain[b] = g
            currentGain[b] = g
            remaining[b] = 0
            active[b] = g != 0
            computeCoefficients(b)
        }
        levelTarget = on ? pow(10, snapshot[1] / 20) : 1
        level = levelTarget
        levelRemaining = 0
    }

    /// Zeroes the filters' memory (a new stream after a seek), without touching the gains.
    func resetState() {
        guard let state else { return }
        state.update(repeating: 0, count: Self.bandCount * max(1, channels) * 2)
    }

    /// True when the EQ passes audio through untouched.
    var isBypassed: Bool {
        guard levelRemaining == 0, level == 1 else { return false }
        for b in 0..<Self.bandCount where active[b] { return false }
        return true
    }

    /// Render thread. `frames` of 32-bit float audio, planar (one buffer per channel) or interleaved.
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        readTargets()
        guard supported, frames > 0, isBypassed == false, let state else { return }
        var start = 0
        while start < frames {
            let n = min(Self.block, frames - start)
            glideCoefficients()
            let levelStart = level
            let levelFrames = min(n, levelRemaining)
            if interleaved {
                guard buffers.count >= 1, let raw = buffers[0].mData else { return }
                let data = raw.assumingMemoryBound(to: Float.self)
                for ch in 0..<channels {
                    run(data + start * channels + ch, stride: channels, count: n, channel: ch, state: state,
                        levelStart: levelStart, levelFrames: levelFrames)
                }
            } else {
                for ch in 0..<min(channels, buffers.count) {
                    guard let raw = buffers[ch].mData else { continue }
                    run(raw.assumingMemoryBound(to: Float.self) + start, stride: 1, count: n, channel: ch, state: state,
                        levelStart: levelStart, levelFrames: levelFrames)
                }
            }
            if levelFrames > 0 {
                levelRemaining -= levelFrames
                level = levelRemaining == 0 ? levelTarget : levelStart + levelStep * Double(levelFrames)
            }
            retireSettledBands(state)
            start += n
        }
    }

    /// Reads the settings and starts a glide for anything that changed.
    @inline(__always)
    private func readTargets() {
        params.load(into: snapshot)
        let on = snapshot[0] != 0
        let rampBlocks = max(1, Int((Self.glideSeconds * max(sampleRate, 1) / Double(Self.block)).rounded()))
        for b in 0..<Self.bandCount {
            let g = on ? snapshot[2 + b] : 0
            if g != targetGain[b] {
                targetGain[b] = g
                gainStep[b] = (g - currentGain[b]) / Double(rampBlocks)
                remaining[b] = rampBlocks
                active[b] = true
            }
        }
        let lt = on ? pow(10, snapshot[1] / 20) : 1
        if lt != levelTarget {
            levelTarget = lt
            let frames = rampBlocks * Self.block
            levelStep = (lt - level) / Double(frames)
            levelRemaining = frames
        }
    }

    @inline(__always)
    private func glideCoefficients() {
        for b in 0..<Self.bandCount where remaining[b] > 0 {
            remaining[b] -= 1
            currentGain[b] = remaining[b] == 0 ? targetGain[b] : currentGain[b] + gainStep[b]
            computeCoefficients(b)
        }
    }

    /// A band back at 0 dB keeps running until its filter has rung down, then drops out.
    @inline(__always)
    private func retireSettledBands(_ state: UnsafeMutablePointer<Double>) {
        for b in 0..<Self.bandCount where active[b] && remaining[b] == 0 && currentGain[b] == 0 {
            var quiet = true
            for ch in 0..<channels {
                let s = state + (b * channels + ch) * 2
                if abs(s[0]) > 1e-12 || abs(s[1]) > 1e-12 {
                    quiet = false
                    break
                }
            }
            if quiet {
                active[b] = false
                for ch in 0..<channels {
                    let s = state + (b * channels + ch) * 2
                    s[0] = 0
                    s[1] = 0
                }
            }
        }
    }

    @inline(__always)
    private func run(_ p: UnsafeMutablePointer<Float>, stride: Int, count: Int, channel: Int, state: UnsafeMutablePointer<Double>,
                     levelStart: Double, levelFrames: Int) {
        for k in 0..<count {
            let g = k < levelFrames ? levelStart + levelStep * Double(k + 1) : (levelFrames > 0 ? levelTarget : levelStart)
            var x = Double(p[k * stride]) * g
            for b in 0..<Self.bandCount where active[b] {
                let c = coef + b * 5
                let s = state + (b * channels + channel) * 2
                let y = c[0] * x + s[0]
                s[0] = c[1] * x - c[3] * y + s[1]
                s[1] = c[2] * x - c[4] * y
                x = y
            }
            p[k * stride] = Float(x)
        }
    }

    /// RBJ audio-EQ-cookbook biquads: a low shelf, eight peaks and a high shelf. A band at or past Nyquist for this
    /// rate (8 kHz audio has no 4 kHz and up) is left flat.
    private func computeCoefficients(_ b: Int) {
        let c = coef + b * 5
        let fs = sampleRate
        let f0 = b == 0 ? Self.lowShelfCorner : b == Self.bandCount - 1 ? Self.highShelfCorner : Self.frequencies[b]
        let (bq, aq) = Self.design(band: b, f0: f0, fs: fs, db: currentGain[b])
        c[0] = bq.0 / aq.0
        c[1] = bq.1 / aq.0
        c[2] = bq.2 / aq.0
        c[3] = aq.1 / aq.0
        c[4] = aq.2 / aq.0
    }

    static func design(band b: Int, f0: Double, fs: Double, db: Double) -> ((Double, Double, Double), (Double, Double, Double)) {
        // At 0 dB these formulas give b == a exactly: unity, with the same poles, so a band gliding to 0 rings down smoothly.
        guard fs > 0, f0 < fs * 0.45 else { return ((1, 0, 0), (1, 0, 0)) }
        let a = pow(10, db / 40)
        let w = 2 * Double.pi * f0 / fs
        let cw = cos(w), sw = sin(w)
        if b == 0 || b == bandCount - 1 {
            let alpha = sw / 2 * sqrt((a + 1 / a) * (1 / shelfSlope - 1) + 2)
            let r = 2 * sqrt(a) * alpha
            if b == 0 {
                return ((a * ((a + 1) - (a - 1) * cw + r), 2 * a * ((a - 1) - (a + 1) * cw), a * ((a + 1) - (a - 1) * cw - r)),
                        ((a + 1) + (a - 1) * cw + r, -2 * ((a - 1) + (a + 1) * cw), (a + 1) + (a - 1) * cw - r))
            }
            return ((a * ((a + 1) + (a - 1) * cw + r), -2 * a * ((a - 1) + (a + 1) * cw), a * ((a + 1) + (a - 1) * cw - r)),
                    ((a + 1) - (a - 1) * cw + r, 2 * ((a - 1) - (a + 1) * cw), (a + 1) - (a - 1) * cw - r))
        }
        let alpha = sw / (2 * peakQ)
        return ((1 + alpha * a, -2 * cw, 1 - alpha * a), (1 + alpha / a, -2 * cw, 1 - alpha / a))
    }
}

// MARK: - The tap

enum EQTap {
    /// What the tap's storage points at: the engine for this one item.
    final class Context {
        let engine = EQEngine()
    }

    /// Buffers the taps have filtered (not bypassed), so tests can see the EQ really runs inside AVPlayer.
    /// Written only on the render thread; a racy read from a test is fine.
    nonisolated(unsafe) static var filteredBuffers = 0

    /// An audio mix that runs `track` through a fresh EQ engine.
    static func mix(for track: AVAssetTrack) -> AVAudioMix? {
        let context = Context()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: Int32(kMTAudioProcessingTapCallbacksVersion_0),
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let context = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let f = format.pointee
                let float32 = f.mFormatID == kAudioFormatLinearPCM && (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && f.mBitsPerChannel == 32
                context.engine.prepare(sampleRate: f.mSampleRate, channels: Int(f.mChannelsPerFrame),
                                       interleaved: (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0, float32: float32)
            },
            unprepare: { _ in },
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
                guard status == noErr else { return }
                let context = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                if flagsOut.pointee & MTAudioProcessingTapFlags(kMTAudioProcessingTapFlag_StartOfStream) != 0 {
                    context.engine.resetState()
                }
                let engine = context.engine
                engine.process(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(framesOut.pointee))
                if !engine.isBypassed { EQTap.filteredBuffers &+= 1 }
            })
        var tap: MTAudioProcessingTap?
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                             MTAudioProcessingTapCreationFlags(kMTAudioProcessingTapCreationFlag_PreEffects), &tap)
        guard err == noErr, let tap else {
            Unmanaged<Context>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        let input = AVMutableAudioMixInputParameters(track: track)
        input.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [input]
        return mix
    }

    /// Puts the EQ on an item once its audio track is known. `stillWanted` is asked again at the end, in case the EQ
    /// was switched off meanwhile.
    @MainActor
    static func attach(to item: AVPlayerItem, stillWanted: @escaping @MainActor () -> Bool) {
        Task { @MainActor in
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first, stillWanted(),
                  item.audioMix == nil, let mix = mix(for: track) else { return }
            item.audioMix = mix
        }
    }
}

// MARK: - Settings

/// The EQ as the person sets it: ten bands and on or off. Remembered like any other setting.
@MainActor
@Observable
final class Equalizer {
    static let range = -12...12
    private(set) var enabled: Bool
    private(set) var gains: [Int]

    /// Told when the EQ is switched on or off, so the player adds or removes its taps.
    @ObservationIgnored var onEnabledChange: (@MainActor (Bool) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let params: EQParams
    static let enabledKey = "eqEnabled", gainsKey = "eqGains"

    init(defaults: UserDefaults = .standard, params: EQParams = .shared) {
        self.defaults = defaults
        self.params = params
        enabled = defaults.bool(forKey: Self.enabledKey)
        let saved = (defaults.array(forKey: Self.gainsKey) as? [Int]) ?? []
        gains = saved.count == EQEngine.bandCount ? saved.map { min(12, max(-12, $0)) } : Array(repeating: 0, count: EQEngine.bandCount)
        publish()
    }

    var isFlat: Bool { gains.allSatisfy { $0 == 0 } }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        publish()
        onEnabledChange?(on)
    }

    func setGain(_ band: Int, _ db: Int) {
        guard gains.indices.contains(band) else { return }
        let v = min(12, max(-12, db))
        guard v != gains[band] else { return }
        gains[band] = v
        save()
    }

    func adjust(_ band: Int, by delta: Int) {
        guard gains.indices.contains(band) else { return }
        setGain(band, gains[band] + delta)
    }

    func resetAll() {
        gains = Array(repeating: 0, count: EQEngine.bandCount)
        save()
    }

    private func save() {
        defaults.set(gains, forKey: Self.gainsKey)
        publish()
    }

    private func publish() {
        params.set(enabled: enabled, gains: gains.map(Double.init))
    }

    // What VoiceOver says.

    /// "125 hertz", "1 kilohertz".
    nonisolated static func bandName(_ band: Int) -> String {
        let f = Int(EQEngine.frequencies[band])
        return f >= 1000 ? "\(f / 1000) kilohertz" : "\(f) hertz"
    }

    /// "125 Hz", "1 kHz" on screen.
    nonisolated static func bandShortName(_ band: Int) -> String {
        let f = Int(EQEngine.frequencies[band])
        return f >= 1000 ? "\(f / 1000) kHz" : "\(f) Hz"
    }

    /// "plus 3 decibels", "minus 1 decibel", "0 decibels".
    nonisolated static func gainText(_ db: Int) -> String {
        let unit = abs(db) == 1 ? "decibel" : "decibels"
        if db > 0 { return "plus \(db) \(unit)" }
        if db < 0 { return "minus \(-db) \(unit)" }
        return "0 decibels"
    }

    /// "+3 dB" on screen.
    nonisolated static func gainShortText(_ db: Int) -> String { db > 0 ? "+\(db) dB" : "\(db) dB" }
}
