import Charts
import SwiftUI

/// The live side panel: spectrum slice, pitch and MFCCs at the playhead (or under the pointer),
/// redrawn as audio plays.
struct InspectorView: View {
    @ObservedObject var studio: Studio
    @ObservedObject var clock: PlayheadClock
    @ObservedObject var pointer: PointerState

    var body: some View {
        let time = pointer.time ?? clock.time
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(pointer.time == nil ? "At playhead" : "Under pointer").font(.headline)
                    Spacer()
                    Text(formatTime(time)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let a = studio.displayedAnalysis {
                    let t = max(0, min(a.grid.frameCount - 1, Int(a.grid.frame(at: time).rounded())))
                    PitchReadout(hz: Double(a.pitchHz[t]), confidence: Double(a.pitchConfidence[t]))
                    SpectrumSlice(studio: studio, frame: t, markHz: pointer.hz)
                    MFCCBars(values: Array(a.mfcc(frame: t)))
                    if let hz = pointer.hz { PointerReadout(studio: studio, analysis: a, frame: t, hz: hz) }
                }
            }
            .padding(14)
        }
    }
}

private struct PitchReadout: View {
    let hz: Double, confidence: Double
    var body: some View {
        GroupBox {
            HStack(alignment: .firstTextBaseline) {
                if hz > 0 {
                    let note = NoteName.describe(hz)
                    Text(note.name).font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text(String(format: "%+d¢", note.cents)).foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(String(format: "%.1f Hz", hz)).monospacedDigit()
                        Text("confidence \(Int(confidence * 100))%").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No pitch").font(.title3).foregroundStyle(.secondary)
                    Spacer()
                    Text("unvoiced or silent").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
        } label: { Text("Pitch (YIN)").font(.caption.weight(.semibold)) }
    }
}

/// Level against frequency for one frame, original and filtered overlaid once anything is painted.
private struct SpectrumSlice: View {
    @ObservedObject var studio: Studio
    let frame: Int
    let markHz: Double?
    @AppStorage(Prefs.floorDB) private var floorDB = -90.0

    private struct P: Identifiable { let id: String; let hz: Double; let db: Double; let series: String }

    var body: some View {
        GroupBox {
            Chart {
                ForEach(points()) { p in
                    LineMark(x: .value("Hz", p.hz), y: .value("dB", max(floorDB, p.db)), series: .value("Signal", p.series))
                        .foregroundStyle(by: .value("Signal", p.series))
                        .lineStyle(.init(lineWidth: 1.4))
                }
                if let markHz { RuleMark(x: .value("Pointer", markHz)).foregroundStyle(.secondary).lineStyle(.init(dash: [3, 3])) }
            }
            .chartForegroundStyleScale(["Original": Color.secondary.opacity(0.6), "Filtered": Color.accentColor])
            .chartXScale(domain: 20...max(40, (studio.grid?.nyquist ?? 22_050)), type: .log)
            .chartYScale(domain: floorDB...12)
            .chartXAxis {
                AxisMarks(values: [100, 1000, 10_000]) { v in
                    AxisGridLine(); AxisValueLabel { if let hz = v.as(Double.self) { Text(hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))") } }
                }
            }
            .chartLegend(studio.mask.isEmpty ? .hidden : .visible)
            .frame(height: 150)
        } label: { Text("Spectrum (dB)").font(.caption.weight(.semibold)) }
    }

    /// About 200 log-spaced points, each the max of the bins it covers.
    private func points() -> [P] {
        var out: [P] = []
        func add(_ a: Analysis?, _ name: String) {
            guard let a, frame < a.grid.frameCount else { return }
            let g = a.grid, n = 200
            let lo = log2(20.0), hi = log2(g.nyquist)
            for i in 0..<n {
                let f0 = pow(2, lo + (hi - lo) * Double(i) / Double(n)), f1 = pow(2, lo + (hi - lo) * Double(i + 1) / Double(n))
                let b0 = max(0, Int(g.bin(at: f0).rounded())), b1 = min(g.bins - 1, max(b0, Int(g.bin(at: f1).rounded())))
                var m: Float = -200
                for b in b0...b1 { m = max(m, a.db(frame: frame, bin: b)) }
                out.append(P(id: "\(name)\(i)", hz: (f0 * f1).squareRoot(), db: Double(m), series: name))
            }
        }
        if studio.mask.isEmpty {
            add(studio.originalAnalysis, "Original")
        } else {
            add(studio.originalAnalysis, "Original")
            add(studio.filteredAnalysis, "Filtered")
        }
        return out
    }
}

private struct MFCCBars: View {
    let values: [Float]
    var body: some View {
        GroupBox {
            Chart {
                ForEach(Array(values.enumerated()).dropFirst(), id: \.offset) { i, v in
                    BarMark(x: .value("Coefficient", "c\(i)"), y: .value("Value", v))
                        .foregroundStyle(v >= 0 ? Color.accentColor : Color.orange)
                }
            }
            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 8)) } }
            .frame(height: 110)
        } label: { Text("MFCC c1–c\(values.count - 1)").font(.caption.weight(.semibold)) }
    }
}

private struct PointerReadout: View {
    @ObservedObject var studio: Studio
    let analysis: Analysis
    let frame: Int
    let hz: Double

    var body: some View {
        let bin = max(0, min(analysis.grid.bins - 1, Int(analysis.grid.bin(at: hz).rounded())))
        let note = NoteName.describe(hz)
        let gain = studio.raster?.gainDB(frame: frame, bin: bin) ?? 0
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { Text("Frequency").foregroundStyle(.secondary); Text(String(format: "%.0f Hz  (%@ %+d¢)", hz, note.name, note.cents)) }
                GridRow { Text("Level").foregroundStyle(.secondary); Text(String(format: "%.1f dB", analysis.db(frame: frame, bin: bin))) }
                GridRow { Text("Filter").foregroundStyle(.secondary); Text(gain == 0 ? "—" : String(format: "%+.1f dB", gain)) }
            }
            .font(.callout.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Pointer").font(.caption.weight(.semibold)) }
    }
}
