import Foundation

/// Mel-frequency cepstral coefficients from a power spectrum:
/// triangular mel filterbank → log energy → DCT-II (orthonormal) → first `coefficients` values.
struct MFCC {
    let bands: Int
    let coefficients: Int
    /// For each band, the first bin it covers and the triangle weights from there.
    private let filters: [(start: Int, weights: [Float])]
    private let dct: [Float]   // coefficients × bands

    init(bands: Int, coefficients: Int, fftSize: Int, sampleRate: Double, minHz: Double = 20, maxHz: Double? = nil) {
        self.bands = bands
        self.coefficients = min(coefficients, bands)
        let bins = fftSize / 2 + 1
        let top = min(maxHz ?? sampleRate / 2, sampleRate / 2)
        let melLo = FrequencyScale.hzToMel(minHz), melHi = FrequencyScale.hzToMel(top)
        // bands + 2 equally spaced mel points → band edges, as fractional bins.
        let edges = (0..<(bands + 2)).map { i -> Double in
            let hz = FrequencyScale.melToHz(melLo + (melHi - melLo) * Double(i) / Double(bands + 1))
            return hz * Double(fftSize) / sampleRate
        }
        filters = (0..<bands).map { m in
            let lo = edges[m], mid = edges[m + 1], hi = edges[m + 2]
            let start = max(0, Int(ceil(lo))), end = min(bins - 1, Int(floor(hi)))
            guard start <= end else { return (min(start, bins - 1), [1]) }   // narrower than a bin
            let weights = (start...end).map { k -> Float in
                let x = Double(k)
                let w = x <= mid ? (x - lo) / max(mid - lo, 1e-9) : (hi - x) / max(hi - mid, 1e-9)
                return Float(max(0, w))
            }
            return (start, weights)
        }
        let c = self.coefficients
        dct = (0..<(c * bands)).map { idx in
            let i = idx / bands, j = idx % bands
            let s = i == 0 ? (1 / Double(bands)).squareRoot() : (2 / Double(bands)).squareRoot()
            return Float(s * cos(Double.pi * Double(i) * (Double(j) + 0.5) / Double(bands)))
        }
    }

    /// Mel band log energies from `power` (bins long) into `melLog` (bands long).
    func melLogEnergies(power: UnsafePointer<Float>, into melLog: inout [Float]) {
        for (m, f) in filters.enumerated() {
            var e: Float = 0
            for (i, w) in f.weights.enumerated() { e += w * power[f.start + i] }
            melLog[m] = logf(e + 1e-10)
        }
    }

    /// Coefficients from `power` into `out` (coefficients long). `scratch` must be bands long.
    func compute(power: UnsafePointer<Float>, scratch: inout [Float], into out: UnsafeMutablePointer<Float>) {
        melLogEnergies(power: power, into: &scratch)
        for i in 0..<coefficients {
            var s: Float = 0
            for j in 0..<bands { s += dct[i * bands + j] * scratch[j] }
            out[i] = s
        }
    }
}
