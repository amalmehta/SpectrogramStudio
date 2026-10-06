import CoreGraphics
import Foundation

/// Perceptually uniform colour maps (polynomial fits to matplotlib's, by Matt Zucker) plus grayscale.
enum ColorMap: String, CaseIterable, Identifiable {
    case magma = "Magma", inferno = "Inferno", viridis = "Viridis", grayscale = "Grayscale"
    var id: String { rawValue }

    private var coefficients: [[Double]] {
        switch self {
        case .magma: return [[-0.002136485053939582, -0.000749655052795221, -0.005386127855323933],
                             [0.2516605407371642, 0.6775232436837668, 2.494026599312351],
                             [8.353717279216625, -3.577719514958484, 0.3144679030132573],
                             [-27.66873308576866, 14.26473078096533, -13.64921318813922],
                             [52.17613981234068, -27.94360607168351, 12.94416944238394],
                             [-50.76852536473588, 29.04658282127291, 4.23415299384598],
                             [18.65570506591883, -11.48977351997711, -5.601961508734096]]
        case .inferno: return [[0.0002189403691192265, 0.001651004631001012, -0.01948089843709184],
                               [0.1065134194856116, 0.5639564367884091, 3.932712388889277],
                               [11.60249308247187, -3.972853965665698, -15.9423941062914],
                               [-41.70399613139459, 17.43639888205313, 44.35414519872813],
                               [77.162935699427, -33.40235894210092, -81.80730925738993],
                               [-71.31942824499214, 32.62606426397723, 73.20951985803202],
                               [25.13112622477341, -12.24266895238567, -23.07032500287172]]
        case .viridis: return [[0.2777273272234177, 0.005407344544966578, 0.3340998053353061],
                               [0.1050930431085774, 1.404613529898575, 1.384590162594685],
                               [-0.3308618287255563, 0.214847559468213, 0.09509516302823659],
                               [-4.634230498983486, -5.799100973351585, -19.33244095627987],
                               [6.228269936347081, 14.17993336680509, 56.69055260068105],
                               [4.776384997670288, -13.74514537774601, -65.35303263337234],
                               [-5.435455855934631, 4.645852612178535, 26.3124352495832]]
        case .grayscale: return []
        }
    }

    func rgb(_ t: Double) -> (Double, Double, Double) {
        let t = max(0, min(1, t))
        if self == .grayscale { return (t, t, t) }
        var r = 0.0, g = 0.0, b = 0.0, p = 1.0
        for c in coefficients { r += c[0] * p; g += c[1] * p; b += c[2] * p; p *= t }
        return (max(0, min(1, r)), max(0, min(1, g)), max(0, min(1, b)))
    }

    /// 256 opaque RGBA pixels (little-endian ABGR as UInt32), index 0 = low.
    var lut: [UInt32] {
        (0..<256).map { i in
            let (r, g, b) = rgb(Double(i) / 255)
            return pixel(r, g, b, 1)
        }
    }
}

@inline(__always) func pixel(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> UInt32 {
    // Premultiplied RGBA bytes in memory order R, G, B, A.
    UInt32(r * a * 255) | UInt32(g * a * 255) << 8 | UInt32(b * a * 255) << 16 | UInt32(a * 255) << 24
}

func makeImage(width: Int, height: Int, pixels: [UInt32]) -> CGImage? {
    let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

/// Maps a visible window of the timeline and frequency axis onto pixels.
struct TimelineMapping: Equatable {
    var start: Double, duration: Double
    var minHz: Double, maxHz: Double
    var scale: FrequencyScale

    func time(atColumn x: Double, width: Int) -> Double { start + x / Double(width) * duration }
    /// Row 0 is the top (highest frequency).
    func hz(atRow y: Double, height: Int) -> Double {
        scale.frequency(at: 1 - y / Double(height), minHz: minHz, maxHz: maxHz)
    }

    /// For each pixel column, the half-open frame span it covers (max-pooled when zoomed out).
    func columnFrames(width: Int, grid: STFTGrid) -> [(Int, Int)] {
        (0..<width).map { x in
            let f0 = grid.frame(at: time(atColumn: Double(x), width: width))
            let f1 = grid.frame(at: time(atColumn: Double(x + 1), width: width))
            let a = Int(f0.rounded()), b = max(a + 1, Int(f1.rounded()))
            return (a, b)
        }
    }

    /// For each pixel row, the bin span it covers.
    func rowBins(height: Int, grid: STFTGrid) -> [(Int, Int)] {
        (0..<height).map { y in
            let hi = grid.bin(at: hz(atRow: Double(y), height: height))
            let lo = grid.bin(at: hz(atRow: Double(y + 1), height: height))
            let a = max(0, min(grid.bins - 1, Int(lo.rounded())))
            let b = max(a + 1, min(grid.bins, Int(hi.rounded())))
            return (a, b)
        }
    }
}

enum SpectrogramRenderer {
    /// Spectrogram pixels for the visible window. Levels are max-pooled over the frames and bins each
    /// pixel covers, so zoomed-out views never hide a loud, short event.
    static func image(_ analysis: Analysis, mapping m: TimelineMapping, width: Int, height: Int,
                      floorDB: Float, ceilingDB: Float = 0, colorMap: ColorMap) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let grid = analysis.grid
        let lut = colorMap.lut
        // Byte level → colour, with the user's dB range applied once.
        let levelColor: [UInt32] = Analysis.levelTable.map { db in
            lut[Int(max(0, min(255, (db - floorDB) / (ceilingDB - floorDB) * 255)))]
        }
        let background = lut[0]
        let cols = m.columnFrames(width: width, grid: grid), rows = m.rowBins(height: height, grid: grid)
        var pixels = [UInt32](repeating: background, count: width * height)
        analysis.levels.withUnsafeBufferPointer { lv in
            pixels.withUnsafeMutableBufferPointer { px in
                DispatchQueue.concurrentPerform(iterations: width) { x in
                    let (f0, f1) = cols[x]
                    let lo = max(0, f0), hi = min(grid.frameCount, f1)
                    guard lo < hi else { return }
                    for y in 0..<height {
                        let (b0, b1) = rows[y]
                        var best: UInt8 = 0
                        for f in lo..<hi {
                            let base = f * grid.bins
                            for b in b0..<b1 where lv[base + b] > best { best = lv[base + b] }
                        }
                        px[y * width + x] = levelColor[Int(best)]
                    }
                }
            }
        }
        return makeImage(width: width, height: height, pixels: pixels)
    }

    /// Translucent overlay of the painted mask: blue where it cuts, amber where it boosts.
    static func maskImage(_ raster: MaskRaster, mapping m: TimelineMapping, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, !raster.isEmpty else { return nil }
        let grid = raster.grid
        let cols = m.columnFrames(width: width, grid: grid), rows = m.rowBins(height: height, grid: grid)
        // Stored half-dB value → overlay colour.
        let colors: [UInt32] = (0..<256).map { i in
            let db = Double(i - 128) * 0.5
            if db == 0 { return 0 }
            let a = min(0.6, abs(db) / 40 * 0.6 + 0.08)
            return db < 0 ? pixel(0.25, 0.65, 1.0, a) : pixel(1.0, 0.72, 0.2, a)
        }
        var pixels = [UInt32](repeating: 0, count: width * height)
        raster.values.withUnsafeBufferPointer { v in
            pixels.withUnsafeMutableBufferPointer { px in
                DispatchQueue.concurrentPerform(iterations: width) { x in
                    let f = (cols[x].0 + cols[x].1) / 2
                    guard f >= 0, f < grid.frameCount, raster.activeFrames.contains(f) else { return }
                    for y in 0..<height {
                        let b = (rows[y].0 + rows[y].1) / 2
                        px[y * width + x] = colors[Int(v[f * grid.bins + b]) + 128]
                    }
                }
            }
        }
        return makeImage(width: width, height: height, pixels: pixels)
    }

    /// MFCC heatmap: coefficient 1 at the bottom (coefficient 0, overall loudness, is left out).
    /// Each coefficient is standardised over the whole file so all rows use the full colour range.
    static func mfccImage(_ analysis: Analysis, start: Double, duration: Double, width: Int, colorMap: ColorMap) -> CGImage? {
        let n = analysis.settings.mfccCount, grid = analysis.grid
        guard width > 0, n > 1 else { return nil }
        let rows = n - 1
        var mean = [Double](repeating: 0, count: n), sd = mean
        let frames = grid.frameCount
        for t in 0..<frames { for i in 0..<n { mean[i] += Double(analysis.mfcc[t * n + i]) } }
        for i in 0..<n { mean[i] /= Double(frames) }
        for t in 0..<frames { for i in 0..<n { let d = Double(analysis.mfcc[t * n + i]) - mean[i]; sd[i] += d * d } }
        for i in 0..<n { sd[i] = max(1e-6, (sd[i] / Double(frames)).squareRoot()) }
        let lut = colorMap.lut
        var pixels = [UInt32](repeating: lut[0], count: width * rows)
        for x in 0..<width {
            let t = Int(grid.frame(at: start + (Double(x) + 0.5) / Double(width) * duration).rounded())
            guard t >= 0, t < frames else { continue }
            for r in 0..<rows {
                let i = r + 1
                let z = (Double(analysis.mfcc[t * n + i]) - mean[i]) / sd[i]
                pixels[(rows - 1 - r) * width + x] = lut[Int(max(0, min(255, (z + 2.5) / 5 * 255)))]
            }
        }
        return makeImage(width: width, height: rows, pixels: pixels)
    }
}
