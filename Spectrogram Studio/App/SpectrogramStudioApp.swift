import SwiftUI

@main
struct SpectrogramStudioApp: App {
    @StateObject private var studio = Studio()
    @State private var showFeedback = false

    init() { Prefs.registerDefaults() }

    var body: some Scene {
        Window("Spectrogram Studio", id: "main") {
            ContentView(studio: studio, showFeedback: $showFeedback)
                .frame(minWidth: 1000, minHeight: 620)
                .task { handleLaunchArguments() }
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { studio.showOpenPanel() }.keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("Export Filtered Audio…") { studio.exportFiltered() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!studio.hasAudio)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Stroke") { studio.undo() }.keyboardShortcut("z").disabled(!studio.mask.canUndo)
                Button("Redo Stroke") { studio.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!studio.mask.canRedo)
            }
            CommandMenu("Audio") {
                Button(studio.isPlaying ? "Pause" : "Play") { studio.togglePlay() }.disabled(!studio.hasAudio)
                Button("Back to Start") { studio.seek(to: 0) }.keyboardShortcut(.leftArrow, modifiers: [.command]).disabled(!studio.hasAudio)
                Divider()
                Button(studio.hear == .filtered ? "Hear Original" : "Hear Filtered") {
                    studio.hear = studio.hear == .filtered ? .original : .filtered
                }
                .keyboardShortcut("b").disabled(!studio.hasAudio)
                Divider()
                Button("Clear Filters") { studio.clearFilters() }
                    .keyboardShortcut(.delete, modifiers: [.command]).disabled(studio.mask.isEmpty)
                Divider()
                Button("Zoom In") { studio.zoom(by: 2) }.keyboardShortcut("=").disabled(!studio.hasAudio)
                Button("Zoom Out") { studio.zoom(by: 0.5) }.keyboardShortcut("-").disabled(!studio.hasAudio)
                Button("Zoom to Fit") { studio.zoomToFit() }.keyboardShortcut("0").disabled(!studio.hasAudio)
            }
            CommandGroup(after: .help) {
                Button("Send Feedback…") { showFeedback = true }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        // The standard Settings scene gives the app menu item and ⌘, for free.
        Settings { SettingsView() }
    }

    /// Launch arguments used by scripts/screenshots.sh: `-openFile <path>` opens a file;
    /// then `-demoStrokes YES` paints a few example filters and `-seekTo <seconds>` moves the playhead.
    /// `-showFeedback YES` opens the feedback sheet; `-openSettings YES` opens Settings.
    @MainActor private func handleLaunchArguments() {
        let d = UserDefaults.standard
        if let path = d.string(forKey: "openFile") {
            studio.open(URL(fileURLWithPath: path))
            Task {
                while !studio.hasAudio { try? await Task.sleep(for: .milliseconds(100)) }
                if d.bool(forKey: "demoStrokes") { studio.paintDemoStrokes() }
                if d.object(forKey: "seekTo") != nil { studio.seek(to: d.double(forKey: "seekTo")) }
            }
        }
        if d.bool(forKey: "showFeedback") { showFeedback = true }
        if d.bool(forKey: "openSettings") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
    }
}
