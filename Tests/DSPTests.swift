import AVFoundation
import XCTest
@testable import Spectrogram_Studio

func sine(_ hz: Double, seconds: Double, sampleRate: Double = 44_100, amplitude: Float = 0.5) -> [Float] {
    (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / sampleRate)) }
}

/// RMS of the part of `x` within `hz ± width` (measured by an FFT of the middle of the signal).
func bandLevelDB(_ x: [Float], hz: Double, sampleRate: Double = 44_100) -> Float {
    let n = 8192, start = x.count / 2 - n / 2
    let w = WindowKind.hann.make(n)
    let frame = (0..<n).map { x[start + $0] * w[$0] }
    let fft = RealFFT(size: n)
    var re = [Float](repeating: 0, count: n / 2 + 1), im = re
    fft.forward(frame, &re, &im)
    let k = Int((hz * Double(n) / sampleRate).rounded())
    var p: Float = 0
    for b in (k - 3)...(k + 3) { p += re[b] * re[b] + im[b] * im[b] }
    return 10 * log10f(p + 1e-20)
}

final class FFTTests: XCTestCase {
    func testRoundTripIsExact() {
        let fft = RealFFT(size: 1024)
        let x = (0..<1024).map { _ in Float.random(in: -1...1) }
        var re = [Float](repeating: 0, count: 513), im = re, y = [Float](repeating: 0, count: 1024)
        fft.forward(x, &re, &im)
        fft.inverse(re, im, &y)
        for i in 0..<1024 { XCTAssertEqual(x[i], y[i], accuracy: 1e-5) }
    }

    func testForwardIsPlainDFT() {
        // A cosine at bin 8 with amplitude 1 has |X[8]| = n/2.
        let n = 256
        let x = (0..<n).map { Float(cos(2 * .pi * 8 * Double($0) / Double(n))) }
        let fft = RealFFT(size: n)
        var re = [Float](repeating: 0, count: n / 2 + 1), im = re
        fft.forward(x, &re, &im)
        XCTAssertEqual(re[8], Float(n / 2), accuracy: 1e-3)
        XCTAssertEqual(re[0], 0, accuracy: 1e-3)
        XCTAssertEqual(re[7], 0, accuracy: 1e-3)
    }
}

final class ResynthesisTests: XCTestCase {
    func testUnityMaskReconstructsInput() {
        for window in WindowKind.allCases {
            let x = (0..<20_000).map { _ in Float.random(in: -1...1) }
            let grid = STFTGrid(sampleRate: 44_100, fftSize: 1024, hop: 256, sampleCount: x.count)
            // A boost and an identical cut cancel to 0 dB but mark the frames as painted,
            // so the FFT → gain → inverse FFT path really runs.
            let boost = FilterStroke(gainDB: 6, radiusSeconds: 0.1, radiusAxis: 1, hardness: 0.5, scale: .log,
                                     stamps: [BrushStamp(time: 0.2, hz: 1000)])
            var cut = boost; cut.id = UUID(); cut.gainDB = -6
            let raster = MaskRaster(grid: grid, strokes: [boost, cut])
            XCTAssertFalse(raster.isEmpty)
            var y = [Float](repeating: 0, count: x.count)
            Resynthesizer.render(source: x, grid: grid, window: window.make(1024), mask: raster, into: &y)
            for i in 0..<x.count { XCTAssertEqual(x[i], y[i], accuracy: 1e-4, "\(window) sample \(i)") ; if abs(x[i] - y[i]) > 1e-4 { break } }
        }
    }

    func testPaintedCutRemovesOnlyThatTone() {
        let sr = 44_100.0
        let a = sine(440, seconds: 2), b = sine(3000, seconds: 2)
        let x = zip(a, b).map { $0 + $1 }
        let grid = STFTGrid(sampleRate: sr, fftSize: 2048, hop: 512, sampleCount: x.count)
        // A long, hard-edged −40 dB stroke along 3 kHz for the whole file.
        let stamps = stride(from: 0.0, through: 2.0, by: 0.01).map { BrushStamp(time: $0, hz: 3000) }
        let stroke = FilterStroke(gainDB: -40, radiusSeconds: 0.05, radiusAxis: 0.3, hardness: 0.9, scale: .log, stamps: stamps)
        var mask = FilterMask(); mask.add(stroke)
        let raster = MaskRaster(grid: grid, strokes: mask.strokes)
        var y = x
        Resynthesizer.render(source: x, grid: grid, window: WindowKind.hann.make(2048), mask: raster, into: &y)
        let drop3k = bandLevelDB(x, hz: 3000) - bandLevelDB(y, hz: 3000)
        let drop440 = bandLevelDB(x, hz: 440) - bandLevelDB(y, hz: 440)
        XCTAssertEqual(drop3k, 40, accuracy: 3, "3 kHz should drop by about 40 dB")
        XCTAssertEqual(drop440, 0, accuracy: 0.5, "440 Hz should be untouched")
    }

    func testPartialRenderMatchesFullRender() {
        let x = (0..<60_000).map { _ in Float.random(in: -0.5...0.5) }
        let grid = STFTGrid(sampleRate: 44_100, fftSize: 1024, hop: 256, sampleCount: x.count)
        let first = FilterStroke(gainDB: -20, radiusSeconds: 0.05, radiusAxis: 0.5, hardness: 0.3, scale: .log,
                                 stamps: [BrushStamp(time: 0.3, hz: 2000), BrushStamp(time: 0.4, hz: 2500)])
        let second = FilterStroke(gainDB: 6, radiusSeconds: 0.04, radiusAxis: 0.4, hardness: 0.5, scale: .mel,
                                  stamps: [BrushStamp(time: 1.0, hz: 500)])
        let window = WindowKind.hann.make(1024)
        var raster = MaskRaster(grid: grid, strokes: [first])
        var incremental = x
        Resynthesizer.render(source: x, grid: grid, window: window, mask: raster, into: &incremental)
        let frames = raster.add(second)
        Resynthesizer.render(source: x, grid: grid, window: window, mask: raster, frames: frames, into: &incremental)
        var full = x
        Resynthesizer.render(source: x, grid: grid, window: window, mask: MaskRaster(grid: grid, strokes: [first, second]), into: &full)
        for i in 0..<x.count { XCTAssertEqual(incremental[i], full[i], accuracy: 1e-5); if abs(incremental[i] - full[i]) > 1e-5 { break } }
    }
}

final class MaskTests: XCTestCase {
    let grid = STFTGrid(sampleRate: 44_100, fftSize: 2048, hop: 512, sampleCount: 44_100)

    func testStampCentreGetsFullGainAndEdgesFade() {
        let stroke = FilterStroke(gainDB: -30, radiusSeconds: 0.1, radiusAxis: 0.5, hardness: 0.2, scale: .log,
                                  stamps: [BrushStamp(time: 0.5, hz: 1000)])
        let r = MaskRaster(grid: grid, strokes: [stroke])
        let f = Int(grid.frame(at: 0.5).rounded()), k = Int(grid.bin(at: 1000).rounded())
        XCTAssertEqual(r.gainDB(frame: f, bin: k), -30, accuracy: 1)
        XCTAssertEqual(r.gainDB(frame: f, bin: Int(grid.bin(at: 5000))), 0)            // outside in frequency
        XCTAssertEqual(r.gainDB(frame: Int(grid.frame(at: 0.9)), bin: k), 0)          // outside in time
        let edge = r.gainDB(frame: Int(grid.frame(at: 0.58)), bin: k)
        XCTAssertTrue(edge < 0 && edge > -30, "soft edge, got \(edge)")
    }

    func testOverlappingStampsInOneStrokeDontStack() {
        let stamps = Array(repeating: BrushStamp(time: 0.5, hz: 1000), count: 10)
        let r = MaskRaster(grid: grid, strokes: [FilterStroke(gainDB: -12, radiusSeconds: 0.1, radiusAxis: 0.5, hardness: 0.5, scale: .log, stamps: stamps)])
        XCTAssertEqual(r.gainDB(frame: Int(grid.frame(at: 0.5)), bin: Int(grid.bin(at: 1000).rounded())), -12, accuracy: 0.5)
    }

    func testSeparateStrokesAddAndClamp() {
        let s = FilterStroke(gainDB: -40, radiusSeconds: 0.1, radiusAxis: 0.5, hardness: 0.9, scale: .log, stamps: [BrushStamp(time: 0.5, hz: 1000)])
        var t = s; t.id = UUID()
        let r = MaskRaster(grid: grid, strokes: [s, t])
        XCTAssertEqual(r.gainDB(frame: Int(grid.frame(at: 0.5)), bin: Int(grid.bin(at: 1000).rounded())), -64)
    }

    func testUndoRedoAndClear() {
        var m = FilterMask()
        let a = FilterStroke(gainDB: -10, radiusSeconds: 0.1, radiusAxis: 0.5, hardness: 0.5, scale: .log, stamps: [BrushStamp(time: 0.2, hz: 500)])
        let b = FilterStroke(gainDB: 6, radiusSeconds: 0.1, radiusAxis: 0.5, hardness: 0.5, scale: .log, stamps: [BrushStamp(time: 0.6, hz: 500)])
        m.add(a); m.add(b)
        XCTAssertEqual(m.undo().map(\.id), [b.id])
        XCTAssertEqual(m.strokes.map(\.id), [a.id])
        XCTAssertEqual(m.redo().map(\.id), [b.id])
        m.clear()
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(Set(m.undo().map(\.id)), [a.id, b.id])
        XCTAssertEqual(m.strokes.count, 2)
        XCTAssertTrue(m.canRedo)
    }
}

final class AnalysisTests: XCTestCase {
    func testSpectrogramPeakAtToneFrequency() {
        let x = sine(1000, seconds: 0.5, amplitude: 1)
        let a = Analyzer.analyze(x, sampleRate: 44_100, settings: AnalysisSettings())!
        let t = a.grid.frameCount / 2
        let peakBin = (0..<a.grid.bins).max { a.db(frame: t, bin: $0) < a.db(frame: t, bin: $1) }!
        XCTAssertEqual(a.grid.hz(ofBin: peakBin), 1000, accuracy: a.grid.sampleRate / Double(a.grid.fftSize))
        XCTAssertEqual(a.db(frame: t, bin: peakBin), 0, accuracy: 2, "full-scale sine should read about 0 dB")
    }

    func testPitchTrackerFindsSineAndHarmonicTone() {
        let tracker = PitchTracker(sampleRate: 44_100, minHz: 60, maxHz: 1000, threshold: 0.15)
        for hz in [82.4, 220.0, 440.0, 880.0] {
            let x = sine(hz, seconds: 0.3)
            let est = x.withUnsafeBufferPointer { tracker.estimate($0, start: 2000) }
            XCTAssertEqual(Double(est.hz), hz, accuracy: hz * 0.01, "sine \(hz)")
        }
        // Harmonic-rich tone with a weak fundamental: YIN should still find 150 Hz, not 300.
        let n = 13_230
        let tone = (0..<n).map { i -> Float in
            let t = Double(i) / 44_100
            return Float(0.2 * sin(2 * .pi * 150 * t) + 0.5 * sin(2 * .pi * 300 * t) + 0.3 * sin(2 * .pi * 450 * t))
        }
        let est = tone.withUnsafeBufferPointer { tracker.estimate($0, start: 3000) }
        XCTAssertEqual(Double(est.hz), 150, accuracy: 2)
    }

    func testPitchTrackerSilenceIsUnvoiced() {
        let tracker = PitchTracker(sampleRate: 44_100, minHz: 60, maxHz: 1000, threshold: 0.15)
        let x = [Float](repeating: 0, count: 8000)
        XCTAssertEqual(x.withUnsafeBufferPointer { tracker.estimate($0, start: 0) }.hz, 0)
    }

    func testMFCCZerothCoefficientIsScaledMeanLogEnergy() {
        let m = MFCC(bands: 40, coefficients: 13, fftSize: 2048, sampleRate: 44_100)
        var scratch = [Float](repeating: 0, count: 40)
        let power = [Float](repeating: 1, count: 1025)
        var out = [Float](repeating: 0, count: 13)
        power.withUnsafeBufferPointer { m.compute(power: $0.baseAddress!, scratch: &scratch, into: &out) }
        // c0 = mean(log energies) * sqrt(40)
        let mean = scratch.reduce(0, +) / 40
        XCTAssertEqual(out[0], mean * sqrtf(40), accuracy: 1e-3)
    }

    func testIncrementalAnalysisMatchesFull() {
        let x = (0..<40_000).map { _ in Float.random(in: -0.5...0.5) }
        var y = x
        for i in 15_000..<20_000 { y[i] *= 0.1 }
        let s = AnalysisSettings()
        var a = Analyzer.analyze(x, sampleRate: 44_100, settings: s)!
        let grid = a.grid
        let margin = s.pitchWindowMargin(sampleRate: 44_100) / grid.hop + 1
        let touched = grid.frames(touching: 15_000..<20_000)
        Analyzer.update(&a, samples: y, frames: (touched.lowerBound - margin)..<(touched.upperBound + margin))
        let b = Analyzer.analyze(y, sampleRate: 44_100, settings: s)!
        XCTAssertEqual(a.levels, b.levels)
        XCTAssertEqual(a.pitchHz, b.pitchHz)
    }
}

final class FileTests: XCTestCase {
    func testWAVRoundTripThroughLoader() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spectrogram-studio-test.wav")
        let x = sine(440, seconds: 0.5, sampleRate: 48_000)
        try AudioFile.writeWAV(x, sampleRate: 48_000, to: url, floatingPoint: true)
        let decoded = try await AudioFile.load(url)
        XCTAssertEqual(decoded.sampleRate, 48_000)
        XCTAssertEqual(decoded.samples.count, x.count)
        XCTAssertEqual(decoded.samples[1234], x[1234], accuracy: 1e-6)
        XCTAssertFalse(decoded.isVideo)
    }

    func testCompressedStereoIsMixedToMono() async throws {
        // AAC in .m4a, stereo: left 440 Hz, right silent.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spectrogram-studio-test.m4a")
        try? FileManager.default.removeItem(at: url)
        do {   // the file is finalised when `file` goes out of scope
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                                                  AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            let left = sine(440, seconds: 1)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(left.count))!
            buf.frameLength = buf.frameCapacity
            for i in 0..<left.count { buf.floatChannelData![0][i] = left[i]; buf.floatChannelData![1][i] = 0 }
            try file.write(from: buf)
        }
        let decoded = try await AudioFile.load(url)
        XCTAssertEqual(decoded.channelCount, 2)
        XCTAssertEqual(Double(decoded.samples.count), 44_100, accuracy: 4096)
        let a = Analyzer.analyze(decoded.samples, sampleRate: decoded.sampleRate, settings: AnalysisSettings())!
        let voiced = a.pitchHz.filter { $0 > 0 }
        XCTAssertGreaterThan(voiced.count, a.pitchHz.count / 2)
        XCTAssertEqual(Double(voiced[voiced.count / 2]), 440, accuracy: 5)
    }

    func testFeedbackIsAppendedLocally() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-test.jsonl")
        try? FileManager.default.removeItem(at: url)
        try FeedbackStore.save(.init(date: Date(), kind: "Idea", message: "one"), to: url)
        try FeedbackStore.save(.init(date: Date(), kind: "Bug", message: "two"), to: url)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("\"two\""))
    }
}

final class ScaleTests: XCTestCase {
    func testScalesRoundTrip() {
        for s in FrequencyScale.allCases {
            for hz in [50.0, 440, 8000] {
                let p = s.position(of: hz, minHz: s.minHz(), maxHz: 22_050)
                XCTAssertEqual(s.frequency(at: p, minHz: s.minHz(), maxHz: 22_050), hz, accuracy: 1e-6 * hz)
            }
        }
    }

    func testNoteNames() {
        XCTAssertEqual(NoteName.describe(440).name, "A4")
        XCTAssertEqual(NoteName.describe(261.63).name, "C4")
        XCTAssertEqual(NoteName.describe(445).cents, 20)
    }
}
