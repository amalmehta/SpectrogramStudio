import Foundation

/// Every user preference, in one place. Views read these with `@AppStorage(Prefs.key)`;
/// the Settings window (⌘,) edits them.
enum Prefs {
    // Analysis
    static let fftSize = "fftSize"
    static let window = "window"                  // WindowKind.rawValue
    static let melBands = "melBands"
    static let mfccCount = "mfccCount"
    static let pitchMinHz = "pitchMinHz"
    static let pitchMaxHz = "pitchMaxHz"
    static let pitchThreshold = "pitchThreshold"
    // Display
    static let frequencyScale = "frequencyScale"  // FrequencyScale.rawValue
    static let colorMap = "colorMap"              // ColorMap.rawValue
    static let floorDB = "floorDB"                // bottom of the colour range
    static let maxDisplayHz = "maxDisplayHz"      // 0 = Nyquist
    static let showMaskOverlay = "showMaskOverlay"
    // Brush
    static let brushGainDB = "brushGainDB"
    static let brushSize = "brushSize"            // points
    static let brushHardness = "brushHardness"
    // Playback & export
    static let volume = "volume"
    static let loop = "loop"
    static let followPlayhead = "followPlayhead"
    static let exportFloat = "exportFloat"
    static let normaliseExport = "normaliseExport"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            fftSize: 2048, window: WindowKind.hann.rawValue, melBands: 40, mfccCount: 13,
            pitchMinHz: 60.0, pitchMaxHz: 1000.0, pitchThreshold: 0.15,
            frequencyScale: FrequencyScale.log.rawValue, colorMap: ColorMap.magma.rawValue,
            floorDB: -90.0, maxDisplayHz: 0.0, showMaskOverlay: true,
            brushGainDB: -24.0, brushSize: 24.0, brushHardness: 0.4,
            volume: 0.8, loop: false, followPlayhead: true, exportFloat: false, normaliseExport: true,
        ])
    }

    static func analysisSettings(_ d: UserDefaults = .standard) -> AnalysisSettings {
        var s = AnalysisSettings()
        s.fftSize = d.integer(forKey: fftSize)
        s.window = WindowKind(rawValue: d.string(forKey: window) ?? "") ?? .hann
        s.melBands = d.integer(forKey: melBands)
        s.mfccCount = d.integer(forKey: mfccCount)
        s.pitchMinHz = d.double(forKey: pitchMinHz)
        s.pitchMaxHz = d.double(forKey: pitchMaxHz)
        s.pitchThreshold = d.double(forKey: pitchThreshold)
        return s
    }
}

/// Feedback stays on this Mac: appended to a JSON-lines file. Nothing is sent anywhere
/// unless the user explicitly chooses "Open as GitHub Issue".
enum FeedbackStore {
    static let repoIssuesURL = URL(string: "https://github.com/amalmehta/SpectrogramStudio/issues/new")!

    struct Entry: Codable { var date: Date; var kind: String; var message: String }

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spectrogram Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Feedback.jsonl")
    }

    static func save(_ entry: Entry, to url: URL = fileURL) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var line = try enc.encode(entry); line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try h.seekToEnd(); try h.write(contentsOf: line)
        } else {
            try line.write(to: url)
        }
    }

    static func issueURL(for entry: Entry) -> URL {
        var c = URLComponents(url: repoIssuesURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "title", value: "[\(entry.kind)] "), URLQueryItem(name: "body", value: entry.message)]
        return c.url!
    }
}
