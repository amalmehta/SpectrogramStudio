import Charts
import SwiftUI

/// A row under the spectrogram: a label gutter of the same width, then content sharing its time axis.
struct TimelineRow<Labels: View, Content: View>: View {
    let title: String
    @ViewBuilder var labels: Labels
    @ViewBuilder var content: Content
    @ObservedObject var studio: Studio

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6).padding(.top, 3)
                labels.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: timelineGutter)
            content
                .overlay { PlayheadOverlay(clock: studio.clock, start: studio.visibleStart, duration: studio.visibleDuration) }
                .clipped()
        }
    }
}

struct PlayheadOverlay: View {
    @ObservedObject var clock: PlayheadClock
    let start: Double, duration: Double
    var body: some View {
        GeometryReader { g in
            let x = (clock.time - start) / duration * g.size.width
            if x >= 0 && x <= g.size.width {
                Rectangle().fill(.primary.opacity(0.8)).frame(width: 1.5).offset(x: x - 0.75)
            }
        }
        .allowsHitTesting(false)
    }
}

/// MFCC heatmap for the visible time window.
struct MFCCView: View {
    @ObservedObject var studio: Studio
    @AppStorage(Prefs.colorMap) private var colorMap = ColorMap.magma.rawValue

    var body: some View {
        TimelineRow(title: "MFCC", labels: {
            VStack { Spacer(); Text("c1").font(.caption2).foregroundStyle(.tertiary) }
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 8).padding(.bottom, 2)
        }, content: {
            GeometryReader { g in
                if let a = studio.displayedAnalysis,
                   let img = SpectrogramRenderer.mfccImage(a, start: studio.visibleStart, duration: studio.visibleDuration,
                                                           width: max(1, Int(g.size.width)), colorMap: ColorMap(rawValue: colorMap) ?? .magma) {
                    Image(decorative: img, scale: 1).resizable().interpolation(.none)
                        .frame(width: g.size.width, height: g.size.height)
                }
            }
            .background(.black)
        }, studio: studio)
        .help("Mel-frequency cepstral coefficients 1–\((studio.displayedAnalysis?.settings.mfccCount ?? 13) - 1), each scaled to its own range over the file")
    }
}

/// Fundamental frequency (YIN) over the visible time window, on a log axis with note labels.
struct PitchTrackView: View {
    @ObservedObject var studio: Studio

    private struct Point: Identifiable { let id: Int; let t: Double; let hz: Double; let segment: Int }

    var body: some View {
        let a = studio.displayedAnalysis
        let lo = a?.settings.pitchMinHz ?? 60, hi = a?.settings.pitchMaxHz ?? 1000
        TimelineRow(title: "Pitch", labels: {
            GeometryReader { g in
                ForEach(noteTicks(lo, hi), id: \.self) { hz in
                    let y = (1 - log(hz / lo) / log(hi / lo)) * g.size.height
                    Text(NoteName.describe(hz).name).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .position(x: g.size.width - 18, y: min(g.size.height - 6, max(6, y)))
                }
            }
        }, content: {
            GeometryReader { g in
                let points = a.map { visiblePoints($0, width: Int(g.size.width)) } ?? []
                Chart {
                    ForEach(noteTicks(lo, hi), id: \.self) { hz in
                        RuleMark(y: .value("Note", hz)).foregroundStyle(.secondary.opacity(0.18)).lineStyle(.init(lineWidth: 0.5))
                    }
                    ForEach(points) { p in
                        LineMark(x: .value("Time", p.t), y: .value("Hz", p.hz), series: .value("Segment", p.segment))
                            .foregroundStyle(Color.accentColor).lineStyle(.init(lineWidth: 2))
                    }
                }
                .chartXScale(domain: studio.visibleStart...(studio.visibleStart + studio.visibleDuration), range: .plotDimension(padding: 0))
                .chartYScale(domain: lo...hi, range: .plotDimension(padding: 0), type: .log)
                .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .chartPlotStyle { $0.frame(width: g.size.width, height: g.size.height) }
            }
        }, studio: studio)
    }

    private func noteTicks(_ lo: Double, _ hi: Double) -> [Double] {
        // Every C (C1 = 32.7 Hz) that falls in range.
        (1...8).map { 32.703 * pow(2, Double($0 - 1)) }.filter { $0 >= lo && $0 <= hi }
    }

    /// Voiced frames in view, thinned to about one per pixel. A gap, or a jump of more than half an
    /// octave (a new note, or the tracker locking onto a different source), starts a new line segment.
    private func visiblePoints(_ a: Analysis, width: Int) -> [Point] {
        let grid = a.grid
        let f0 = max(0, Int(grid.frame(at: studio.visibleStart)) - 1)
        let f1 = min(grid.frameCount, Int(grid.frame(at: studio.visibleStart + studio.visibleDuration)) + 2)
        guard f0 < f1 else { return [] }
        let stride = max(1, (f1 - f0) / max(1, width))
        var out: [Point] = []
        var segment = 0, lastVoiced = false, lastHz = 0.0
        for t in Swift.stride(from: f0, to: f1, by: stride) {
            let hz = Double(a.pitchHz[t])
            let voiced = hz > 0 && hz >= a.settings.pitchMinHz && hz <= a.settings.pitchMaxHz
            if voiced {
                if !lastVoiced || abs(log2(hz / lastHz)) > 0.5 { segment += 1 }
                lastHz = hz
                out.append(Point(id: t, t: grid.time(ofFrame: t), hz: hz, segment: segment))
            }
            lastVoiced = voiced
        }
        return out
    }
}
