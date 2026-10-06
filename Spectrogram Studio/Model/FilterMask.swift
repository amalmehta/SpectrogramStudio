import Foundation

/// One dab of the brush: a point on the spectrogram in physical units.
struct BrushStamp: Codable, Equatable, Sendable {
    var time: Double   // seconds
    var hz: Double
}

/// A painted filter stroke. Stored in physical units (seconds, Hz) rather than pixels or STFT bins,
/// so strokes survive zooming, changing the FFT size or switching the frequency axis.
struct FilterStroke: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var gainDB: Double          // negative = cut, positive = boost
    var radiusSeconds: Double   // half-width of the brush in time
    var radiusAxis: Double      // half-height of the brush in `scale`'s warped units
    var hardness: Double        // 0 = all soft edge, 1 = hard edge
    var scale: FrequencyScale   // axis the stroke was painted on (defines the brush's shape in Hz)
    var stamps: [BrushStamp]

    /// Brush weight (0...1) at normalised distance `d` from a stamp's centre.
    func falloff(_ d: Double) -> Double {
        if d >= 1 { return 0 }
        if d <= hardness { return 1 }
        let u = (d - hardness) / (1 - hardness)
        return 0.5 * (1 + cos(Double.pi * u))
    }
}

/// The painted strokes plus undo/redo history. Clearing is an undoable edit too.
struct FilterMask: Equatable {
    private(set) var strokes: [FilterStroke] = []
    private var undoStack: [[FilterStroke]] = []
    private var redoStack: [[FilterStroke]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isEmpty: Bool { strokes.isEmpty }

    mutating func add(_ stroke: FilterStroke) { commit(strokes + [stroke]) }
    mutating func clear() { if !strokes.isEmpty { commit([]) } }

    /// Undo the last edit; returns the strokes that changed (added or removed), to know what to re-render.
    mutating func undo() -> [FilterStroke] {
        guard let previous = undoStack.popLast() else { return [] }
        redoStack.append(strokes)
        defer { strokes = previous }
        return Self.difference(strokes, previous)
    }

    mutating func redo() -> [FilterStroke] {
        guard let next = redoStack.popLast() else { return [] }
        undoStack.append(strokes)
        defer { strokes = next }
        return Self.difference(strokes, next)
    }

    private mutating func commit(_ new: [FilterStroke]) {
        undoStack.append(strokes)
        redoStack.removeAll()
        strokes = new
    }

    private static func difference(_ a: [FilterStroke], _ b: [FilterStroke]) -> [FilterStroke] {
        let ia = Set(a.map(\.id)), ib = Set(b.map(\.id))
        return a.filter { !ib.contains($0.id) } + b.filter { !ia.contains($0.id) }
    }
}

/// The strokes rasterised onto an STFT grid: one gain per (frame, bin), in half-dB steps stored as Int8.
///
/// Int8 keeps memory at one byte per cell (a 3-minute file at the default settings is ~16 MB);
/// the range is −64 dB (effectively silence) to +24 dB.
struct MaskRaster {
    let grid: STFTGrid
    private(set) var values: [Int8] = []   // frame-major; empty until something is painted
    private(set) var activeFrames = IndexSet()

    static let minHalfDB = -128, maxHalfDB = 48
    /// Linear gain for each possible stored value, indexed by `Int(value) + 128`.
    static let gainTable: [Float] = (0..<256).map { powf(10, Float($0 - 128) * 0.5 / 20) }

    init(grid: STFTGrid) { self.grid = grid }

    init(grid: STFTGrid, strokes: [FilterStroke]) {
        self.grid = grid
        for s in strokes { add(s) }
    }

    var isEmpty: Bool { activeFrames.isEmpty }

    func gainDB(frame t: Int, bin k: Int) -> Float {
        guard !values.isEmpty, t >= 0, t < grid.frameCount, k >= 0, k < grid.bins else { return 0 }
        return Float(values[t * grid.bins + k]) * 0.5
    }

    /// Fills `gains` with linear gains for frame `t`. Returns false (and leaves `gains` alone)
    /// when the frame is untouched, so callers can skip the FFT entirely.
    func row(_ t: Int, into gains: inout [Float]) -> Bool {
        guard activeFrames.contains(t) else { return false }
        let base = t * grid.bins
        values.withUnsafeBufferPointer { v in
            for k in 0..<grid.bins { gains[k] = Self.gainTable[Int(v[base + k]) + 128] }
        }
        return true
    }

    /// Frames a stroke can touch (used to limit re-rendering to the painted region).
    func frameRange(of stroke: FilterStroke) -> Range<Int> {
        guard let tMin = stroke.stamps.map(\.time).min(), let tMax = stroke.stamps.map(\.time).max() else { return 0..<0 }
        let lo = max(0, Int(floor(grid.frame(at: tMin - stroke.radiusSeconds))))
        let hi = min(grid.frameCount, Int(ceil(grid.frame(at: tMax + stroke.radiusSeconds))) + 1)
        return lo..<max(lo, hi)
    }

    /// Adds one stroke. Overlapping stamps within a stroke take the maximum weight (dragging back
    /// and forth doesn't deepen a cut); separate strokes add in dB.
    @discardableResult
    mutating func add(_ stroke: FilterStroke) -> Range<Int> {
        let frames = frameRange(of: stroke)
        guard !frames.isEmpty, stroke.gainDB != 0 else { return 0..<0 }
        let bins = grid.bins
        let scale = stroke.scale
        let binAxis = (0..<bins).map { scale.warp(grid.hz(ofBin: $0)) }

        // Per-stroke weight buffer over the stroke's frames × all bins.
        var weight = [Float](repeating: 0, count: frames.count * bins)
        var lowBin = bins, highBin = 0
        for stamp in stroke.stamps {
            let yc = scale.warp(stamp.hz)
            let hzLo = scale.unwarp(yc - stroke.radiusAxis), hzHi = scale.unwarp(yc + stroke.radiusAxis)
            let b0 = max(0, Int(floor(grid.bin(at: hzLo)))), b1 = min(bins - 1, Int(ceil(grid.bin(at: hzHi))))
            let f0 = max(frames.lowerBound, Int(floor(grid.frame(at: stamp.time - stroke.radiusSeconds))))
            let f1 = min(frames.upperBound - 1, Int(ceil(grid.frame(at: stamp.time + stroke.radiusSeconds))))
            guard b0 <= b1, f0 <= f1 else { continue }
            lowBin = min(lowBin, b0); highBin = max(highBin, b1)
            for f in f0...f1 {
                let dx = (grid.time(ofFrame: f) - stamp.time) / stroke.radiusSeconds
                if abs(dx) >= 1 { continue }
                let row = (f - frames.lowerBound) * bins
                for b in b0...b1 {
                    let dy = (binAxis[b] - yc) / stroke.radiusAxis
                    let w = Float(stroke.falloff((dx * dx + dy * dy).squareRoot()))
                    if w > weight[row + b] { weight[row + b] = w }
                }
            }
        }
        guard lowBin <= highBin else { return 0..<0 }

        if values.isEmpty { values = [Int8](repeating: 0, count: grid.frameCount * bins) }
        let gainHalf = Float(stroke.gainDB * 2)
        var touched = IndexSet()
        for f in frames {
            let row = (f - frames.lowerBound) * bins, base = f * bins
            var any = false
            for b in lowBin...highBin where weight[row + b] > 0 {
                let v = Int(values[base + b]) + Int((gainHalf * weight[row + b]).rounded())
                values[base + b] = Int8(min(Self.maxHalfDB, max(Self.minHalfDB, v)))
                any = true
            }
            if any { touched.insert(f) }
        }
        activeFrames.formUnion(touched)
        return frames
    }
}
