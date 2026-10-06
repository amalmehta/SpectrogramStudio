import SwiftUI

/// Every preference in one window (⌘, or the gear in the toolbar).
struct SettingsView: View {
    var body: some View {
        TabView {
            AnalysisSettingsTab().tabItem { Label("Analysis", systemImage: "waveform.path.ecg") }
            DisplaySettingsTab().tabItem { Label("Display", systemImage: "paintpalette") }
            BrushSettingsTab().tabItem { Label("Brush", systemImage: "paintbrush.pointed") }
            PlaybackSettingsTab().tabItem { Label("Playback & Export", systemImage: "speaker.wave.2") }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 360)
    }
}

private struct AnalysisSettingsTab: View {
    @AppStorage(Prefs.fftSize) private var fftSize = 2048
    @AppStorage(Prefs.window) private var window = WindowKind.hann.rawValue
    @AppStorage(Prefs.melBands) private var melBands = 40
    @AppStorage(Prefs.mfccCount) private var mfccCount = 13
    @AppStorage(Prefs.pitchMinHz) private var pitchMinHz = 60.0
    @AppStorage(Prefs.pitchMaxHz) private var pitchMaxHz = 1000.0
    @AppStorage(Prefs.pitchThreshold) private var pitchThreshold = 0.15

    var body: some View {
        Form {
            Section("STFT") {
                Picker("FFT size", selection: $fftSize) {
                    ForEach([512, 1024, 2048, 4096, 8192], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Window", selection: $window) {
                    ForEach(WindowKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Text("Hop is a quarter of the FFT size (75% overlap). Bigger FFTs resolve pitch finely but smear timing. Painted filters carry over when you change these.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("MFCC") {
                Stepper("Mel bands: \(melBands)", value: $melBands, in: 20...128, step: 4)
                Stepper("Coefficients: \(mfccCount)", value: $mfccCount, in: 8...40)
            }
            Section("Pitch tracking (YIN)") {
                Stepper("Lowest pitch: \(Int(pitchMinHz)) Hz", value: $pitchMinHz, in: 30...400, step: 10)
                Stepper("Highest pitch: \(Int(pitchMaxHz)) Hz", value: $pitchMaxHz, in: 200...4000, step: 50)
                Slider(value: $pitchThreshold, in: 0.05...0.5, step: 0.01) {
                    Text("Voicing threshold: \(pitchThreshold, specifier: "%.2f")")
                }
            }
        }
    }
}

private struct DisplaySettingsTab: View {
    @AppStorage(Prefs.frequencyScale) private var scale = FrequencyScale.log.rawValue
    @AppStorage(Prefs.colorMap) private var colorMap = ColorMap.magma.rawValue
    @AppStorage(Prefs.floorDB) private var floorDB = -90.0
    @AppStorage(Prefs.maxDisplayHz) private var maxDisplayHz = 0.0
    @AppStorage(Prefs.showMaskOverlay) private var showMask = true
    @AppStorage(Prefs.followPlayhead) private var follow = true

    var body: some View {
        Form {
            Picker("Frequency axis", selection: $scale) {
                ForEach(FrequencyScale.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("Top of axis", selection: $maxDisplayHz) {
                Text("Nyquist (half the sample rate)").tag(0.0)
                ForEach([4000.0, 8000, 12000, 16000], id: \.self) { Text("\(Int($0 / 1000)) kHz").tag($0) }
            }
            Picker("Colours", selection: $colorMap) {
                ForEach(ColorMap.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Slider(value: $floorDB, in: -120 ... -40, step: 5) { Text("Quietest shown: \(Int(floorDB)) dB") }
            Toggle("Show painted filters over the spectrogram", isOn: $showMask)
            Toggle("Scroll to follow the playhead when zoomed in", isOn: $follow)
        }
    }
}

private struct BrushSettingsTab: View {
    @AppStorage(Prefs.brushGainDB) private var gainDB = -24.0
    @AppStorage(Prefs.brushSize) private var size = 24.0
    @AppStorage(Prefs.brushHardness) private var hardness = 0.4

    var body: some View {
        Form {
            Picker("Mode", selection: Binding(get: { gainDB < 0 }, set: { gainDB = $0 ? -abs(gainDB) : min(24, abs(gainDB)) })) {
                Text("Cut").tag(true); Text("Boost").tag(false)
            }
            .pickerStyle(.segmented)
            Slider(value: Binding(get: { abs(gainDB) }, set: { gainDB = gainDB < 0 ? -$0 : min(24, $0) }), in: 3...60, step: 1) {
                Text("Amount: \(Int(abs(gainDB))) dB")
            }
            Slider(value: $size, in: 6...120, step: 1) { Text("Size: \(Int(size)) pt") }
            Slider(value: $hardness, in: 0...0.95) { Text("Hardness: \(Int(hardness * 100))%") }
            Text("Size is on screen, so zoom in for finer strokes. Soft edges avoid ringing and clicks.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PlaybackSettingsTab: View {
    @AppStorage(Prefs.volume) private var volume = 0.8
    @AppStorage(Prefs.loop) private var loop = false
    @AppStorage(Prefs.exportFloat) private var exportFloat = false
    @AppStorage(Prefs.normaliseExport) private var normalise = true

    var body: some View {
        Form {
            Section("Playback") {
                Slider(value: $volume, in: 0...1) { Text("Volume") }
                Toggle("Loop", isOn: $loop)
            }
            Section("Export") {
                Picker("WAV format", selection: $exportFloat) {
                    Text("24-bit").tag(false)
                    Text("32-bit float").tag(true)
                }
                Toggle("Normalise if the filtered audio would clip", isOn: $normalise)
                Text("Export is mono at the file's own sample rate.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
