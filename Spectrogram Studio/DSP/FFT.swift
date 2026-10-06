import Accelerate

/// A real-input FFT of a fixed power-of-two size, wrapping vDSP's packed split-complex format.
///
/// Spectra are `bins = n/2 + 1` long and stored as separate real and imaginary arrays (not packed),
/// so callers never deal with vDSP's "DC in realp[0], Nyquist in imagp[0]" layout or its scale factors:
/// `forward` returns the plain DFT and `inverse(forward(x)) == x`.
///
/// Not thread-safe: each thread needs its own instance (they hold scratch buffers).
final class RealFFT {
    let n: Int
    var bins: Int { n / 2 + 1 }
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var re: [Float]
    private var im: [Float]

    init(size: Int) {
        precondition(size >= 4 && size & (size - 1) == 0, "FFT size must be a power of two")
        n = size
        log2n = vDSP_Length(size.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        re = [Float](repeating: 0, count: size / 2)
        im = [Float](repeating: 0, count: size / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// DFT of `input` (exactly `n` samples) into `outRe`/`outIm` (each `bins` long).
    func forward(_ input: UnsafePointer<Float>, _ outRe: UnsafeMutablePointer<Float>, _ outIm: UnsafeMutablePointer<Float>) {
        let half = n / 2
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                input.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // vDSP's forward real FFT is scaled by 2; undo that while unpacking.
                outRe[0] = rp[0] * 0.5; outIm[0] = 0
                outRe[half] = ip[0] * 0.5; outIm[half] = 0
                for k in 1..<half {
                    outRe[k] = rp[k] * 0.5
                    outIm[k] = ip[k] * 0.5
                }
            }
        }
    }

    /// Inverse DFT of a `bins`-long half spectrum into `n` real samples.
    func inverse(_ inRe: UnsafePointer<Float>, _ inIm: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>) {
        let half = n / 2
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                rp[0] = inRe[0]; ip[0] = inRe[half]
                for k in 1..<half { rp[k] = inRe[k]; ip[k] = inIm[k] }
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                output.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                    vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                }
                // Inverse is unscaled and the packed input carries the factor 2 we removed: divide by n.
                var scale = 1 / Float(n)
                vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(n))
            }
        }
    }
}

enum WindowKind: String, CaseIterable, Identifiable, Codable {
    case hann = "Hann", hamming = "Hamming", blackman = "Blackman"
    var id: String { rawValue }

    /// Periodic window (the right choice for overlap-add resynthesis).
    func make(_ n: Int) -> [Float] {
        (0..<n).map { i in
            let x = 2 * Float.pi * Float(i) / Float(n)
            switch self {
            case .hann: return 0.5 - 0.5 * cos(x)
            case .hamming: return 0.54 - 0.46 * cos(x)
            case .blackman: return 0.42 - 0.5 * cos(x) + 0.08 * cos(2 * x)
            }
        }
    }
}
