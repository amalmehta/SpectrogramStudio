import Accelerate
import Foundation

/// Everything that changes how audio is analysed. Built from preferences (see `Prefs`).
struct AnalysisSettings: Equatable, Sendable {
    var fftSize = 2048
    var window = WindowKind.hann
    var melBands = 40
    var mfccCount = 13
    var pitchMinHz = 60.0
    var pitchMaxHz = 1000.0
    var pitchThreshold = 0.15

    /// 75% overlap: enough for clean resynthesis with every window offered, and it keeps the
    /// time resolution fine enough for painting.
    var hop: Int { fftSize / 4 }

    func grid(sampleRate: Double, sampleCount: Int) -> STFTGrid {
        STFTGrid(sampleRate: sampleRate, fftSize: fftSize, hop: hop, sampleCount: sampleCount)
    }
}

/// The STFT, MFCC and pitch track of one signal, all on the same frame grid.
struct Analysis: Sendable {
    let grid: STFTGrid
    let settings: AnalysisSettings
    /// Level per (frame, bin), frame-major, quantised to a byte over `dbRange`.
    var levels: [UInt8]
    /// MFCCs per frame, frame-major, `settings.mfccCount` each.
    var mfcc: [Float]
    /// Fundamental frequency per frame in Hz (0 = unvoiced) and its confidence.
    var pitchHz: [Float]
    var pitchConfidence: [Float]

    static let dbRange: ClosedRange<Float> = -120...24
    static func quantise(_ db: Float) -> UInt8 {
        UInt8(max(0, min(255, ((db - dbRange.lowerBound) / (dbRange.upperBound - dbRange.lowerBound) * 255).rounded())))
    }
    static let levelTable: [Float] = (0..<256).map {
        dbRange.lowerBound + Float($0) / 255 * (dbRange.upperBound - dbRange.lowerBound)
    }

    func db(frame t: Int, bin k: Int) -> Float { Self.levelTable[Int(levels[t * grid.bins + k])] }
    func mfcc(frame t: Int) -> ArraySlice<Float> { mfcc[(t * settings.mfccCount)..<((t + 1) * settings.mfccCount)] }

    init(grid: STFTGrid, settings: AnalysisSettings) {
        self.grid = grid
        self.settings = settings
        levels = .init(repeating: 0, count: grid.frameCount * grid.bins)
        mfcc = .init(repeating: 0, count: grid.frameCount * settings.mfccCount)
        pitchHz = .init(repeating: 0, count: grid.frameCount)
        pitchConfidence = pitchHz
    }
}

enum Analyzer {
    /// Analyses a whole signal. Returns nil if cancelled.
    static func analyze(_ samples: [Float], sampleRate: Double, settings: AnalysisSettings,
                        isCancelled: @escaping @Sendable () -> Bool = { false }) -> Analysis? {
        var result = Analysis(grid: settings.grid(sampleRate: sampleRate, sampleCount: samples.count), settings: settings)
        guard update(&result, samples: samples, frames: 0..<result.grid.frameCount, isCancelled: isCancelled) else { return nil }
        return result
    }

    /// Recomputes `frames` of `analysis` from `samples` (same length as the analysis was made for).
    /// Runs chunks in parallel; returns false if cancelled part-way.
    @discardableResult
    static func update(_ analysis: inout Analysis, samples: [Float], frames: Range<Int>,
                       isCancelled: @escaping @Sendable () -> Bool = { false }) -> Bool {
        let grid = analysis.grid, settings = analysis.settings
        let frames = frames.clamped(to: 0..<grid.frameCount)
        guard !frames.isEmpty else { return true }
        let window = settings.window.make(grid.fftSize)
        // Amplitude normalisation so a full-scale sine reads 0 dB.
        let ampScale = 2 / window.reduce(0, +)
        let mel = MFCC(bands: settings.melBands, coefficients: settings.mfccCount, fftSize: grid.fftSize, sampleRate: grid.sampleRate)
        let chunk = 512
        let chunks = (frames.count + chunk - 1) / chunk
        var cancelled = false
        let lock = NSLock()

        samples.withUnsafeBufferPointer { src in
        window.withUnsafeBufferPointer { win in
        analysis.levels.withUnsafeMutableBufferPointer { levels in
        analysis.mfcc.withUnsafeMutableBufferPointer { mfccOut in
        analysis.pitchHz.withUnsafeMutableBufferPointer { pitchOut in
        analysis.pitchConfidence.withUnsafeMutableBufferPointer { confOut in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                if isCancelled() { lock.withLock { cancelled = true }; return }
                let lo = frames.lowerBound + c * chunk, hi = min(frames.upperBound, lo + chunk)
                let fft = RealFFT(size: grid.fftSize)
                let yin = PitchTracker(sampleRate: grid.sampleRate, minHz: settings.pitchMinHz,
                                       maxHz: settings.pitchMaxHz, threshold: settings.pitchThreshold)
                var frame = [Float](repeating: 0, count: grid.fftSize)
                var re = [Float](repeating: 0, count: grid.bins), im = re, power = re
                var scratch = [Float](repeating: 0, count: settings.melBands)
                for t in lo..<hi {
                    grid.readFrame(t, from: src, window: win.baseAddress!, into: &frame)
                    fft.forward(frame, &re, &im)
                    let base = t * grid.bins
                    for k in 0..<grid.bins {
                        let p = (re[k] * re[k] + im[k] * im[k]) * ampScale * ampScale
                        power[k] = p
                        levels[base + k] = Analysis.quantise(10 * log10f(p + 1e-14))
                    }
                    power.withUnsafeBufferPointer { p in
                        mel.compute(power: p.baseAddress!, scratch: &scratch, into: mfccOut.baseAddress! + t * settings.mfccCount)
                    }
                    let (hz, conf) = yin.estimate(src, start: t * grid.hop - yin.windowSize / 2)
                    pitchOut[t] = hz
                    confOut[t] = conf
                }
            }
        }}}}}}
        return !cancelled
    }
}
