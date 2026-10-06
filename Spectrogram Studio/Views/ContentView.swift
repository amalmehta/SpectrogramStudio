import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var studio: Studio
    @Binding var showFeedback: Bool
    @State private var dropTargeted = false

    // Preferences that need re-analysis or the player when they change.
    @AppStorage(Prefs.fftSize) private var fftSize = 2048
    @AppStorage(Prefs.window) private var window = WindowKind.hann.rawValue
    @AppStorage(Prefs.melBands) private var melBands = 40
    @AppStorage(Prefs.mfccCount) private var mfccCount = 13
    @AppStorage(Prefs.pitchMinHz) private var pitchMinHz = 60.0
    @AppStorage(Prefs.pitchMaxHz) private var pitchMaxHz = 1000.0
    @AppStorage(Prefs.pitchThreshold) private var pitchThreshold = 0.15
    @AppStorage(Prefs.volume) private var volume = 0.8
    @AppStorage(Prefs.loop) private var loop = false

    var body: some View {
        VStack(spacing: 0) {
            if studio.hasAudio {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        SpectrogramView(studio: studio, clock: studio.clock)
                            .frame(minHeight: 260)
                        Divider()
                        MFCCView(studio: studio).frame(height: 96)
                        Divider()
                        PitchTrackView(studio: studio).frame(height: 120)
                    }
                    Divider()
                    InspectorView(studio: studio, clock: studio.clock, pointer: studio.pointer)
                        .frame(width: 280)
                }
            } else {
                EmptyStateView(studio: studio, targeted: dropTargeted)
            }
            Divider()
            StatusBar(studio: studio, showFeedback: $showFeedback)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in studio.open(url) } }
            }
            return true
        }
        .toolbar { StudioToolbar(studio: studio) }
        .navigationTitle(studio.fileName ?? "Spectrogram Studio")
        .navigationSubtitle(studio.fileName == nil ? "" : studio.fileDetails)
        .alert("Something went wrong", isPresented: Binding(get: { studio.errorMessage != nil }, set: { if !$0 { studio.errorMessage = nil } })) {
            Button("OK") { studio.errorMessage = nil }
        } message: { Text(studio.errorMessage ?? "") }
        .sheet(isPresented: $showFeedback) { FeedbackView() }
        .onChange(of: [fftSize, melBands, mfccCount]) { studio.analysisSettingsChanged() }
        .onChange(of: [pitchMinHz, pitchMaxHz, pitchThreshold]) { studio.analysisSettingsChanged() }
        .onChange(of: window) { studio.analysisSettingsChanged() }
        .onChange(of: volume) { studio.applyPlaybackPrefs() }
        .onChange(of: loop) { studio.applyPlaybackPrefs() }
    }
}

private struct EmptyStateView: View {
    @ObservedObject var studio: Studio
    let targeted: Bool
    var body: some View {
        VStack(spacing: 14) {
            if studio.isLoading {
                ProgressView().controlSize(.large)
                Text(studio.statusMessage ?? "Opening…").foregroundStyle(.secondary)
            } else {
                Image(systemName: "waveform.badge.plus").font(.system(size: 52, weight: .light)).foregroundStyle(.secondary)
                Text("Drop an audio or video file here").font(.title2.weight(.medium))
                Text("WAV, AIFF, MP3, AAC, FLAC, ALAC, MP4, MOV… — anything macOS can play.")
                    .foregroundStyle(.secondary)
                Button("Open File…") { studio.showOpenPanel() }.controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.3)).padding(24))
    }
}

private struct StudioToolbar: ToolbarContent {
    @ObservedObject var studio: Studio
    @AppStorage(Prefs.brushGainDB) private var gainDB = -24.0
    @AppStorage(Prefs.brushSize) private var brushSize = 24.0
    @AppStorage(Prefs.brushHardness) private var hardness = 0.4
    @AppStorage(Prefs.showMaskOverlay) private var showMask = true
    @State private var showBrush = false

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { studio.togglePlay() } label: {
                Label(studio.isPlaying ? "Pause" : "Play", systemImage: studio.isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!studio.hasAudio)
            .help("Play or pause (Space)")
        }
        ToolbarItemGroup(placement: .principal) {
            Picker("Brush", selection: Binding(get: { gainDB < 0 }, set: { cut in gainDB = cut ? -abs(gainDB) : min(24, abs(gainDB)) })) {
                Text("Cut").tag(true)
                Text("Boost").tag(false)
            }
            .pickerStyle(.segmented).fixedSize()
            .help("Paint cuts (blue) or boosts (amber) onto the spectrogram")
            Button { showBrush.toggle() } label: { Label("Brush Settings", systemImage: "paintbrush.pointed") }
                .help("Brush amount, size and softness")
                .popover(isPresented: $showBrush, arrowEdge: .bottom) { BrushPopover(gainDB: $gainDB, size: $brushSize, hardness: $hardness) }
            Toggle(isOn: $showMask) { Label("Show Filters", systemImage: "square.2.layers.3d") }
                .help("Show painted filters over the spectrogram")
            Button { studio.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!studio.mask.canUndo).help("Undo stroke (⌘Z)")
            Button { studio.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!studio.mask.canRedo).help("Redo stroke (⇧⌘Z)")
            Button { studio.clearFilters() } label: { Label("Clear Filters", systemImage: "trash") }
                .disabled(studio.mask.isEmpty).help("Remove every painted filter (undoable)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Hear", selection: $studio.hear) {
                ForEach(Studio.Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            .help("Listen to the filtered or the original audio (⌘B)")
            Button { studio.exportFiltered() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(!studio.hasAudio).help("Export filtered audio as WAV (⇧⌘E)")
            SettingsLink { Label("Settings", systemImage: "gearshape") }.help("Settings (⌘,)")
        }
    }
}

private struct BrushPopover: View {
    @Binding var gainDB: Double
    @Binding var size: Double
    @Binding var hardness: Double
    var body: some View {
        Form {
            Slider(value: Binding(get: { abs(gainDB) }, set: { gainDB = gainDB < 0 ? -$0 : min(24, $0) }), in: 3...60, step: 1) {
                Text("Amount: \(Int(abs(gainDB))) dB")
            }
            Slider(value: $size, in: 6...120, step: 1) { Text("Size: \(Int(size)) pt") }
            Slider(value: $hardness, in: 0...0.95) { Text("Hardness: \(Int(hardness * 100))%") }
            Text("Boosts are capped at +24 dB. Each stroke adds to what's already painted.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 320)
    }
}

private struct StatusBar: View {
    @ObservedObject var studio: Studio
    @Binding var showFeedback: Bool

    var body: some View {
        HStack(spacing: 12) {
            if studio.hasAudio {
                Picker("Show", selection: $studio.show) {
                    ForEach(Studio.Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize().controlSize(.small)
                .help("Analyse the filtered or the original audio")
                .disabled(studio.mask.isEmpty)
                Button("Zoom to Fit") { studio.zoomToFit() }.controlSize(.small)
                    .disabled(studio.visibleDuration >= studio.duration)
                Text("Drag to paint · ⌥-click or click the ruler to seek · ⌘-scroll or pinch to zoom")
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if studio.isRendering || studio.statusMessage != nil {
                ProgressView().controlSize(.mini).opacity(studio.isRendering ? 1 : 0)
                Text(studio.statusMessage ?? "Rendering…").font(.caption).foregroundStyle(.secondary)
            }
            if studio.filteredPeak > 1, !studio.mask.isEmpty {
                Label(String(format: "Peaks at %+.1f dBFS", 20 * log10(studio.filteredPeak)), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .help("The filtered audio clips. Export can normalise it (Settings ▸ Playback & Export).")
            }
            Button { showFeedback = true } label: { Label("Feedback", systemImage: "bubble.left").font(.caption) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Send feedback (⇧⌘F)")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.bar)
    }
}
