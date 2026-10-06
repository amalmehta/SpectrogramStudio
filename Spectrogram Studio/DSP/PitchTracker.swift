import Accelerate
import Foundation

/// YIN fundamental-frequency estimator (de Cheveigné & Kawahara, 2002), with the difference
/// function computed through an FFT cross-correlation so each frame costs O(W log W).
///
/// Not thread-safe: one instance per thread.
final class PitchTracker {
    let sampleRate: Double
    let windowSize: Int          // W: analysis frame; lags go up to W/2
    let minHz: Double, maxHz: Double
    let threshold: Float
    static let silenceRMS: Float = powf(10, -55 / 20)

    private let fft: RealFFT
    private var a: [Float], b: [Float]
    private var aRe: [Float], aIm: [Float], bRe: [Float], bIm: [Float]
    private var r: [Float], cum: [Float], d: [Float]

    init(sampleRate: Double, minHz: Double, maxHz: Double, threshold: Double) {
        self.sampleRate = sampleRate
        self.minHz = max(20, minHz)
        self.maxHz = max(self.minHz * 2, min(maxHz, sampleRate / 4))
        self.threshold = Float(threshold)
        // Need W/2 > sampleRate / minHz (the longest period).
        var w = 512
        while w / 2 <= Int(ceil(sampleRate / self.minHz)) + 2 { w *= 2 }
        windowSize = w
        fft = RealFFT(size: 2 * w)
        let bins = w + 1
        a = .init(repeating: 0, count: 2 * w); b = .init(repeating: 0, count: 2 * w)
        aRe = .init(repeating: 0, count: bins); aIm = aRe; bRe = aRe; bIm = aRe
        r = .init(repeating: 0, count: 2 * w)
        cum = .init(repeating: 0, count: w + 1)
        d = .init(repeating: 0, count: w / 2)
    }

    /// Pitch of the W samples starting at `start` in `samples` (zero outside the buffer).
    /// Returns (hz, confidence 0...1); hz is 0 for unvoiced or silent frames.
    func estimate(_ samples: UnsafeBufferPointer<Float>, start: Int) -> (hz: Float, confidence: Float) {
        let w = windowSize, half = w / 2
        // b = the whole frame, a = its first half; both zero-padded to 2W.
        for i in 0..<w {
            let j = start + i
            b[i] = (j >= 0 && j < samples.count) ? samples[j] : 0
        }
        var ss: Float = 0
        vDSP_svesq(b, 1, &ss, vDSP_Length(w))
        if (ss / Float(w)).squareRoot() < Self.silenceRMS { return (0, 0) }
        for i in 0..<half { a[i] = b[i] }
        for i in half..<(2 * w) { a[i] = 0 }
        for i in w..<(2 * w) { b[i] = 0 }

        // r[τ] = Σ_j a[j]·b[j+τ]  =  IFFT(conj(A)·B)
        fft.forward(a, &aRe, &aIm)
        fft.forward(b, &bRe, &bIm)
        for k in 0...w {
            let re = aRe[k] * bRe[k] + aIm[k] * bIm[k]
            let im = aRe[k] * bIm[k] - aIm[k] * bRe[k]
            aRe[k] = re; aIm[k] = im
        }
        fft.inverse(aRe, aIm, &r)

        cum[0] = 0
        for i in 0..<w { cum[i + 1] = cum[i] + b[i] * b[i] }
        let e0 = cum[half]
        // Difference function and its cumulative-mean-normalised form, d'(τ).
        var running: Float = 0
        d[0] = 1
        for tau in 1..<half {
            let diff = max(0, e0 + (cum[tau + half] - cum[tau]) - 2 * r[tau])
            running += diff
            d[tau] = running > 0 ? diff * Float(tau) / running : 1
        }

        let tauMin = max(2, Int(floor(sampleRate / maxHz)))
        let tauMax = min(half - 2, Int(ceil(sampleRate / minHz)))
        guard tauMin < tauMax else { return (0, 0) }
        var best = -1
        var tau = tauMin
        while tau <= tauMax {
            if d[tau] < threshold {
                while tau + 1 <= tauMax && d[tau + 1] < d[tau] { tau += 1 }
                best = tau
                break
            }
            tau += 1
        }
        guard best > 0 else { return (0, 0) }
        // Parabolic interpolation around the dip.
        let s0 = d[best - 1], s1 = d[best], s2 = d[best + 1]
        let denom = s0 - 2 * s1 + s2
        let shift = abs(denom) > 1e-12 ? 0.5 * (s0 - s2) / denom : 0
        let period = Float(best) + max(-1, min(1, shift))
        return (Float(sampleRate) / period, max(0, min(1, 1 - s1)))
    }
}
