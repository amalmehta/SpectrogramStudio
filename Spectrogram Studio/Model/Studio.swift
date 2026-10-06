import AppKit
import Foundation
import UniformTypeIdentifiers

/// The app's one document: the loaded audio, its analyses, the painted filter and playback.
///
/// Heavy work (decoding, analysis, resynthesis) runs off the main actor; results are published here.
/// Painting only re-renders the frames a stroke touches, so even long files respond immediately.
@MainActor
final class Studio: ObservableObject {
    enum Source: String, CaseIterable, Identifiable { case filtered = "Filtered", original = "Original"; var id: String { rawValue } }

    // File
    @Published private(set) var fileName: String?
    @Published private(set) var fileDetails = ""
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    // Signals and analyses (big arrays aren't @Published; `version` tells views to redraw)
    private(set) var original: [Float] = []
    private(set) var filtered: [Float] = []
    private(set) var sampleRate: Double = 44_100
    @Published private(set) var originalAnalysis: Analysis? { didSet { analysisVersion += 1 } }
    @Published private(set) var filteredAnalysis: Analysis? { didSet { analysisVersion += 1 } }
    /// Bumped whenever either analysis is replaced, so cached images know to redraw.
    private(set) var analysisVersion = 0
    @Published private(set) var filteredPeak: Float = 0

    // Filter
    @Published private(set) var mask = FilterMask()
    private(set) var raster: MaskRaster?
    @Published private(set) var maskVersion = 0
    @Published private(set) var isRendering = false

    // Listening and viewing
    @Published var hear: Source = .filtered { didSet { player.bypass = hear == .original } }
    @Published var show: Source = .filtered
    @Published private(set) var isPlaying = false
    @Published private(set) var visibleStart: Double = 0
    @Published private(set) var visibleDuration: Double = 1
    @Published var statusMessage: String?

    let clock = PlayheadClock()
    let pointer = PointerState()
    private let player = AudioPlayer()
    private var settings = Prefs.analysisSettings()
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var renderGeneration = 0
    private var dirtyFrames: Range<Int>?
    private var inFlightFrames: Range<Int>?
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        applyPlaybackPrefs()
    }

    var hasAudio: Bool { originalAnalysis != nil }
    var duration: Double { Double(original.count) / sampleRate }
    var grid: STFTGrid? { originalAnalysis?.grid }

    /// The analysis the views show: the filtered one once anything is painted and "Show: Filtered" is on.
    var displayedAnalysis: Analysis? {
        if show == .filtered, !mask.isEmpty, let f = filteredAnalysis { return f }
        return originalAnalysis
    }

    // MARK: - Opening

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AudioFile.openableTypes
        panel.message = "Choose an audio or video file"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        loadTask?.cancel(); renderTask?.cancel()
        player.stop()
        isLoading = true
        errorMessage = nil
        statusMessage = "Opening \(url.lastPathComponent)…"
        let settings = Prefs.analysisSettings()
        loadTask = Task { [weak self] in
            do {
                let decoded = try await AudioFile.load(url)
                guard !decoded.samples.isEmpty else { throw AudioFileError.readFailed("the audio track is empty") }
                let analysis = await background {
                    Analyzer.analyze(decoded.samples, sampleRate: decoded.sampleRate, settings: settings, isCancelled: { Task.isCancelled })
                }
                guard let self, !Task.isCancelled, let analysis else { return }
                self.install(decoded, analysis: analysis, settings: settings, name: url.lastPathComponent)
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            } catch is CancellationError {
            } catch {
                self?.isLoading = false
                self?.statusMessage = nil
                self?.errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func install(_ decoded: DecodedAudio, analysis: Analysis, settings: AnalysisSettings, name: String) {
        self.settings = settings
        original = decoded.samples
        filtered = decoded.samples
        sampleRate = decoded.sampleRate
        player.load(decoded.samples, sampleRate: decoded.sampleRate)
        applyPlaybackPrefs()
        mask = FilterMask()
        raster = MaskRaster(grid: analysis.grid)
        maskVersion += 1
        originalAnalysis = analysis
        filteredAnalysis = analysis
        filteredPeak = AudioFile.peak(decoded.samples)
        fileName = name
        let channels = decoded.channelCount == 1 ? "mono" : "\(decoded.channelCount) ch → mono"
        fileDetails = "\(formatTime(duration)) · \(Int(sampleRate)) Hz · \(channels)\(decoded.isVideo ? " · audio from video" : "")"
        visibleStart = 0
        visibleDuration = duration
        clock.time = 0
        isLoading = false
        statusMessage = nil
    }

    /// Re-analyses after a preference change (FFT size, window, MFCC or pitch settings).
    /// Strokes are stored in seconds and Hz, so they carry over to the new grid unchanged.
    func analysisSettingsChanged() {
        let new = Prefs.analysisSettings()
        guard new != settings, hasAudio else { return }
        settings = new
        renderTask?.cancel()
        statusMessage = "Re-analysing…"
        let samples = original, rate = sampleRate, strokes = mask.strokes
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let analysis = await background {
                Analyzer.analyze(samples, sampleRate: rate, settings: new, isCancelled: { Task.isCancelled })
            }
            guard let self, !Task.isCancelled, let analysis else { return }
            self.originalAnalysis = analysis
            self.filteredAnalysis = analysis
            self.raster = MaskRaster(grid: analysis.grid, strokes: strokes)
            self.maskVersion += 1
            self.filtered = self.original
            self.statusMessage = nil
            self.dirtyFrames = nil
            if !strokes.isEmpty { self.requestRender(0..<analysis.grid.frameCount) }
        }
    }

    // MARK: - Painting

    func addStroke(_ stroke: FilterStroke) {
        guard var r = raster else { return }
        mask.add(stroke)
        let frames = r.add(stroke)
        raster = r
        maskVersion += 1
        requestRender(frames)
    }

    func undo() { applyHistory(mask.undo()) }
    func redo() { applyHistory(mask.redo()) }

    func clearFilters() {
        let all = mask.strokes
        mask.clear()
        applyHistory(all)
    }

    private func applyHistory(_ changed: [FilterStroke]) {
        guard let grid, !changed.isEmpty else { return }
        let r = MaskRaster(grid: grid, strokes: mask.strokes)
        raster = r
        maskVersion += 1
        let ranges = changed.map { r.frameRange(of: $0) }.filter { !$0.isEmpty }
        guard let lo = ranges.map(\.lowerBound).min(), let hi = ranges.map(\.upperBound).max() else { return }
        requestRender(lo..<hi)
    }

    /// Re-renders the filtered signal over `frames` (merged with anything still pending), hands it to
    /// the player as soon as it's ready, then refreshes the filtered analysis for that stretch.
    private func requestRender(_ frames: Range<Int>) {
        guard !frames.isEmpty, let grid, let raster else { return }
        if renderTask != nil, let inFlight = inFlightFrames { dirtyFrames = hull(dirtyFrames, inFlight) }
        dirtyFrames = hull(dirtyFrames, frames)
        renderTask?.cancel()
        guard let region = dirtyFrames else { return }
        dirtyFrames = nil
        inFlightFrames = region
        renderGeneration += 1
        let generation = renderGeneration
        isRendering = true
        let source = original, base = filtered, window = settings.window.make(grid.fftSize)
        let analysis = filteredAnalysis

        renderTask = Task { [weak self] in
            let rendered = await background { () -> ([Float], Range<Int>)? in
                var out = base
                let changed = Resynthesizer.render(source: source, grid: grid, window: window, mask: raster,
                                                   frames: region, into: &out, isCancelled: { Task.isCancelled })
                return Task.isCancelled ? nil : (out, changed)
            }
            guard let self, generation == self.renderGeneration, let (out, changed) = rendered else { return }
            self.filtered = out
            self.player.setFiltered(out)
            self.filteredPeak = AudioFile.peak(out)

            // Analysis frames whose STFT window or pitch window overlaps the changed samples.
            guard let analysis else { return self.finishRender(generation) }
            let margin = (analysis.settings.pitchWindowMargin(sampleRate: grid.sampleRate) + grid.hop - 1) / grid.hop
            let touched = grid.frames(touching: changed)
            let frames = max(0, touched.lowerBound - margin)..<min(grid.frameCount, touched.upperBound + margin)
            let updated = await background { () -> Analysis? in
                var a = analysis
                return Analyzer.update(&a, samples: out, frames: frames, isCancelled: { Task.isCancelled }) ? a : nil
            }
            guard generation == self.renderGeneration, let updated else { return }
            self.filteredAnalysis = updated
            self.finishRender(generation)
        }
    }

    private func finishRender(_ generation: Int) {
        guard generation == renderGeneration else { return }
        isRendering = false
        inFlightFrames = nil
        renderTask = nil
    }

    private func hull(_ a: Range<Int>?, _ b: Range<Int>) -> Range<Int> {
        guard let a else { return b }
        return min(a.lowerBound, b.lowerBound)..<max(a.upperBound, b.upperBound)
    }

    // MARK: - Playback

    func togglePlay() {
        guard hasAudio else { return }
        if player.isPlaying { player.pause() } else {
            do { try player.play() } catch { errorMessage = "Couldn't start audio: \(error.localizedDescription)" }
        }
        isPlaying = player.isPlaying
    }

    func seek(to t: Double) {
        player.seek(toSeconds: t)
        clock.time = player.currentTime
    }

    func applyPlaybackPrefs() {
        let d = UserDefaults.standard
        player.volume = Float(d.double(forKey: Prefs.volume))
        player.loop = d.bool(forKey: Prefs.loop)
    }

    private func tick() {
        guard hasAudio else { return }
        let t = player.currentTime
        if t != clock.time { clock.time = t }
        let playing = player.isPlaying
        if playing != isPlaying { isPlaying = playing }
        // Page the view along with the playhead when zoomed in.
        if playing, UserDefaults.standard.bool(forKey: Prefs.followPlayhead), visibleDuration < duration,
           t > visibleStart + visibleDuration || t < visibleStart {
            setVisible(start: t - visibleDuration * 0.05, duration: visibleDuration)
        }
    }

    // MARK: - Zoom and scroll (shared by every timeline view)

    func setVisible(start: Double, duration d: Double) {
        let total = max(duration, 0.01)
        let minDuration = min(total, max(0.05, Double(settings.hop * 32) / sampleRate))
        let newDuration = max(minDuration, min(total, d))
        let newStart = max(0, min(total - newDuration, start))
        if newDuration != visibleDuration { visibleDuration = newDuration }
        if newStart != visibleStart { visibleStart = newStart }
    }

    func zoom(by factor: Double, around t: Double? = nil) {
        let anchor = t ?? (visibleStart + visibleDuration / 2)
        let frac = (anchor - visibleStart) / visibleDuration
        let d = visibleDuration / factor
        setVisible(start: anchor - frac * d, duration: d)
    }

    func scroll(bySeconds dt: Double) { setVisible(start: visibleStart + dt, duration: visibleDuration) }
    func zoomToFit() { setVisible(start: 0, duration: duration) }

    // MARK: - Export

    func exportFiltered() {
        guard hasAudio, let fileName else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        let stem = (fileName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(stem) (filtered).wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let d = UserDefaults.standard
        var samples = filtered
        let peak = AudioFile.peak(samples)
        let normalise = d.bool(forKey: Prefs.normaliseExport), asFloat = d.bool(forKey: Prefs.exportFloat)
        if normalise, peak > 1 { samples = samples.map { $0 * (0.999 / peak) } }
        do {
            try AudioFile.writeWAV(samples, sampleRate: sampleRate, to: url, floatingPoint: asFloat)
            statusMessage = "Exported \(url.lastPathComponent)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if self?.statusMessage == "Exported \(url.lastPathComponent)" { self?.statusMessage = nil }
            }
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Screenshot / demo support

    /// Paints a few fixed strokes so a freshly opened file shows what painting looks like
    /// (used by `scripts/screenshots.sh` via the `-demoStrokes YES` launch argument).
    func paintDemoStrokes() {
        guard hasAudio else { return }
        let d = duration
        func line(_ t0: Double, _ t1: Double, _ hz0: Double, _ hz1: Double) -> [BrushStamp] {
            (0...60).map { i in
                let u = Double(i) / 60
                return BrushStamp(time: t0 + (t1 - t0) * u, hz: hz0 * pow(hz1 / hz0, u))
            }
        }
        addStroke(FilterStroke(gainDB: -40, radiusSeconds: d * 0.02, radiusAxis: 0.35, hardness: 0.4, scale: .log,
                               stamps: line(d * 0.1, d * 0.45, 3000, 3000)))
        addStroke(FilterStroke(gainDB: -30, radiusSeconds: d * 0.03, radiusAxis: 0.5, hardness: 0.3, scale: .log,
                               stamps: line(d * 0.55, d * 0.85, 300, 2400)))
        addStroke(FilterStroke(gainDB: 12, radiusSeconds: d * 0.025, radiusAxis: 0.3, hardness: 0.5, scale: .log,
                               stamps: line(d * 0.6, d * 0.9, 6000, 6000)))
    }
}

/// Runs `work` off the main actor; cancelling the calling task cancels it too.
func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    let job = Task.detached(priority: .userInitiated, operation: work)
    return await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
}

extension AnalysisSettings {
    /// Samples either side of a frame centre that its pitch estimate reads.
    func pitchWindowMargin(sampleRate: Double) -> Int {
        PitchTracker(sampleRate: sampleRate, minHz: pitchMinHz, maxHz: pitchMaxHz, threshold: pitchThreshold).windowSize / 2
    }
}

/// Playhead time, published separately (30 times a second) so only the playhead overlays redraw.
@MainActor
final class PlayheadClock: ObservableObject {
    @Published var time: Double = 0
}

/// Where the pointer is over the spectrogram, for the inspector's readout.
@MainActor
final class PointerState: ObservableObject {
    @Published var time: Double?
    @Published var hz: Double?
}

func formatTime(_ t: Double) -> String {
    let m = Int(t) / 60, s = t - Double(m * 60)
    return String(format: "%d:%05.2f", m, s)
}
