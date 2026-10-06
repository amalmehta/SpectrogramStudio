import Foundation

/// How frequency maps onto the vertical axis. Used by the spectrogram display and by painted
/// filter strokes (a stroke remembers the scale it was painted on so its soft edge keeps its shape).
enum FrequencyScale: String, CaseIterable, Identifiable, Codable {
    case linear = "Linear", log = "Log", mel = "Mel"
    var id: String { rawValue }

    static let logFloor: Double = 20   // Hz at the bottom of the log axis

    /// Axis coordinate (arbitrary units, increasing with frequency) for `hz`.
    func warp(_ hz: Double) -> Double {
        switch self {
        case .linear: return hz
        case .log: return log2(max(hz, Self.logFloor))
        case .mel: return Self.hzToMel(hz)
        }
    }

    func unwarp(_ y: Double) -> Double {
        switch self {
        case .linear: return y
        case .log: return pow(2, y)
        case .mel: return Self.melToHz(y)
        }
    }

    /// Normalised position 0 (bottom) ... 1 (top) of `hz` on an axis spanning `minHz...maxHz`.
    func position(of hz: Double, minHz: Double, maxHz: Double) -> Double {
        let lo = warp(minHz), hi = warp(maxHz)
        return (warp(hz) - lo) / (hi - lo)
    }

    func frequency(at position: Double, minHz: Double, maxHz: Double) -> Double {
        let lo = warp(minHz), hi = warp(maxHz)
        return unwarp(lo + position * (hi - lo))
    }

    /// Lowest frequency the axis shows.
    func minHz() -> Double { self == .log ? Self.logFloor : 0 }

    static func hzToMel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
    static func melToHz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }
}

/// Musical note name for a frequency, e.g. 440 → ("A4", 0 cents).
enum NoteName {
    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    static func describe(_ hz: Double) -> (name: String, cents: Int) {
        guard hz > 0 else { return ("–", 0) }
        let midi = 69 + 12 * log2(hz / 440)
        let nearest = Int(midi.rounded())
        let cents = Int(((midi - Double(nearest)) * 100).rounded())
        let octave = nearest / 12 - 1
        return (names[((nearest % 12) + 12) % 12] + "\(octave)", cents)
    }
}
