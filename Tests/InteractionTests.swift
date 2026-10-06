import AppKit
import XCTest
@testable import Spectrogram_Studio

/// Drives the spectrogram view and the player the way a person would, without UI automation.
@MainActor
final class InteractionTests: XCTestCase {
    func testDraggingPaintsAStrokeWhereThePointerWent() throws {
        let view = SpectrogramNSView(frame: NSRect(x: 0, y: 0, width: 856, height: 420))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        let x = sine(440, seconds: 2)
        view.analysis = Analyzer.analyze(x, sampleRate: 44_100, settings: AnalysisSettings())
        let mapping = TimelineMapping(start: 0, duration: 2, minHz: 20, maxHz: 22_050, scale: .log)
        view.display = .init(mapping: mapping, colorMap: .magma, floorDB: -90, showMask: true, analysisID: "t", maskVersion: 0)
        view.brush = .init(gainDB: -30, size: 40, hardness: 0.5)
        var strokes: [FilterStroke] = []
        view.onStroke = { strokes.append($0) }

        // Window coordinates are bottom-up; the view is flipped. Plot spans x 56…856, y 20…420 (top-down).
        func event(_ type: NSEvent.EventType, _ px: CGFloat, _ py: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: px, y: 420 - py), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let midY: CGFloat = 20 + 200   // halfway up the log axis
        view.mouseDown(with: event(.leftMouseDown, 256, midY))      // t = 0.5 s
        view.mouseDragged(with: event(.leftMouseDragged, 456, midY)) // t = 1.0 s
        view.mouseUp(with: event(.leftMouseUp, 456, midY))

        let stroke = try XCTUnwrap(strokes.first)
        XCTAssertEqual(strokes.count, 1)
        XCTAssertEqual(stroke.gainDB, -30)
        XCTAssertEqual(stroke.stamps.first!.time, 0.5, accuracy: 0.01)
        XCTAssertEqual(stroke.stamps.last!.time, 1.0, accuracy: 0.01)
        XCTAssertGreaterThan(stroke.stamps.count, 10, "fast drags are filled in")
        let expectedHz = FrequencyScale.log.frequency(at: 0.5, minHz: 20, maxHz: 22_050)
        XCTAssertEqual(stroke.stamps[0].hz, expectedHz, accuracy: expectedHz * 0.01)
        XCTAssertEqual(stroke.radiusSeconds, 20.0 / 800 * 2, accuracy: 1e-9)
    }

    func testClickOnRulerSeeksInsteadOfPainting() {
        let view = SpectrogramNSView(frame: NSRect(x: 0, y: 0, width: 856, height: 420))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.display = .init(mapping: TimelineMapping(start: 0, duration: 2, minHz: 20, maxHz: 22_050, scale: .log),
                             colorMap: .magma, floorDB: -90, showMask: true, analysisID: "t", maskVersion: 0)
        var painted = false
        view.onStroke = { _ in painted = true }
        let e = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 300, y: 420 - 10), modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: e)
        view.mouseUp(with: e)
        XCTAssertFalse(painted)
    }

    func testPlayerAdvancesSwapsAndBypasses() throws {
        let player = AudioPlayer()
        let x = sine(440, seconds: 3)
        player.load(x, sampleRate: 44_100)
        player.volume = 0
        do { try player.play() } catch { throw XCTSkip("No audio output device: \(error)") }
        let start = Date()
        while player.currentTime < 0.2, Date().timeIntervalSince(start) < 3 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertGreaterThan(player.currentTime, 0.1, "playhead should move while playing")
        player.setFiltered([Float](repeating: 0, count: x.count))   // swap mid-playback
        XCTAssertTrue(player.isPlaying)
        player.pause()
        let t = player.currentTime
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(player.currentTime, t, "paused playhead stays put")
        player.seek(toSeconds: 2.5)
        XCTAssertEqual(player.currentTime, 2.5, accuracy: 0.001)
        player.stop()
    }
}
