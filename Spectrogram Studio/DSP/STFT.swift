import Accelerate
import Foundation

/// The time–frequency grid every view and the filter mask share.
///
/// Frame `t` is centred on sample `t * hop` (the signal is treated as zero outside its bounds),
/// so frame times line up with sample times and the first frame sits at 0 s.
struct STFTGrid: Equatable, Sendable {
    let sampleRate: Double
    let fftSize: Int
    let hop: Int
    let sampleCount: Int

    var bins: Int { fftSize / 2 + 1 }
    var frameCount: Int { sampleCount / hop + 1 }
    var duration: Double { Double(sampleCount) / sampleRate }
    var nyquist: Double { sampleRate / 2 }

    func time(ofFrame t: Int) -> Double { Double(t * hop) / sampleRate }
    /// Fractional frame index at `seconds`.
    func frame(at seconds: Double) -> Double { seconds * sampleRate / Double(hop) }
    func hz(ofBin k: Int) -> Double { Double(k) * sampleRate / Double(fftSize) }
    /// Fractional bin index for `hz`.
    func bin(at hz: Double) -> Double { hz * Double(fftSize) / sampleRate }

    /// Samples covered by the windows of `frames`.
    func samples(coveredBy frames: Range<Int>) -> Range<Int> {
        guard !frames.isEmpty else { return 0..<0 }
        let lo = max(0, frames.lowerBound * hop - fftSize / 2)
        let hi = min(sampleCount, (frames.upperBound - 1) * hop + fftSize / 2)
        return lo..<max(lo, hi)
    }

    /// Frames whose window overlaps any sample in `samples`.
    func frames(touching samples: Range<Int>) -> Range<Int> {
        guard !samples.isEmpty else { return 0..<0 }
        let half = fftSize / 2
        // t*hop - half < upper  &&  t*hop + half > lower
        let lo = max(0, Int(floor(Double(samples.lowerBound - half) / Double(hop))) + 1)
        let hi = min(frameCount, Int(ceil(Double(samples.upperBound + half) / Double(hop))))
        return lo..<max(lo, hi)
    }

    /// Copies the (zero-padded) samples of frame `t` into `dest` (fftSize long), multiplied by `window`.
    func readFrame(_ t: Int, from source: UnsafeBufferPointer<Float>, window: UnsafePointer<Float>, into dest: UnsafeMutablePointer<Float>) {
        let start = t * hop - fftSize / 2
        let lo = max(0, -start), hi = min(fftSize, source.count - start)
        if lo > 0 { dest.update(repeating: 0, count: lo) }
        if hi < fftSize { (dest + max(hi, 0)).update(repeating: 0, count: fftSize - max(hi, 0)) }
        if hi > lo { vDSP_vmul(source.baseAddress! + start + lo, 1, window + lo, 1, dest + lo, 1, vDSP_Length(hi - lo)) }
    }
}

/// Inverse STFT with the painted mask applied: weighted overlap-add (WOLA) resynthesis.
///
/// y = Σ_t w·IFFT(G_t · FFT(w·x_t)) / Σ_t w²  — with G = 1 everywhere this reproduces the input exactly,
/// which is what the "unity mask" test checks.
enum Resynthesizer {
    /// Recomputes `output` over the samples influenced by `frames` (the whole file when `frames` is nil).
    /// Returns the sample range that changed. Checks `isCancelled` between chunks and stops early if set.
    @discardableResult
    static func render(source: [Float], grid: STFTGrid, window: [Float], mask: MaskRaster,
                       frames: Range<Int>? = nil, into output: inout [Float],
                       isCancelled: () -> Bool = { false }) -> Range<Int> {
        precondition(output.count == source.count)
        let region = frames.map { grid.samples(coveredBy: $0.clamped(to: 0..<grid.frameCount)) } ?? (0..<grid.sampleCount)
        guard !region.isEmpty else { return region }
        let contributing = grid.frames(touching: region)
        let n = grid.fftSize, bins = grid.bins
        var acc = [Float](repeating: 0, count: region.count)
        var norm = [Float](repeating: 0, count: region.count)
        let fft = RealFFT(size: n)
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: bins), im = [Float](repeating: 0, count: bins)
        var gains = [Float](repeating: 1, count: bins)
        let w2 = window.map { $0 * $0 }

        source.withUnsafeBufferPointer { src in
            window.withUnsafeBufferPointer { win in
                for t in contributing {
                    if t % 256 == 0, isCancelled() { return }
                    grid.readFrame(t, from: src, window: win.baseAddress!, into: &frame)
                    if mask.row(t, into: &gains) {
                        fft.forward(frame, &re, &im)
                        vDSP_vmul(re, 1, gains, 1, &re, 1, vDSP_Length(bins))
                        vDSP_vmul(im, 1, gains, 1, &im, 1, vDSP_Length(bins))
                        fft.inverse(re, im, &frame)
                    }
                    // Synthesis window, then overlap-add into the region.
                    let start = t * grid.hop - n / 2
                    let lo = max(0, region.lowerBound - start), hi = min(n, region.upperBound - start)
                    guard hi > lo else { continue }
                    for i in lo..<hi {
                        let j = start + i - region.lowerBound
                        acc[j] += frame[i] * win[i]
                        norm[j] += w2[i]
                    }
                }
            }
        }
        if isCancelled() { return 0..<0 }
        for j in 0..<region.count {
            output[region.lowerBound + j] = norm[j] > 1e-8 ? acc[j] / norm[j] : source[region.lowerBound + j]
        }
        return region
    }
}
