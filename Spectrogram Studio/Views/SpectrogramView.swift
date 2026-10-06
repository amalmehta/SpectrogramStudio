import AppKit
import SwiftUI

/// Width of the frequency-label gutter shared by every timeline row, so their time axes line up.
let timelineGutter: CGFloat = 56

/// The paintable spectrogram: SwiftUI wrapper around an AppKit view (mouse painting, scroll-wheel
/// zoom and fast bitmap drawing are much simpler in AppKit).
struct SpectrogramView: NSViewRepresentable {
    @ObservedObject var studio: Studio
    @ObservedObject var clock: PlayheadClock
    @AppStorage(Prefs.frequencyScale) private var scale = FrequencyScale.log.rawValue
    @AppStorage(Prefs.colorMap) private var colorMap = ColorMap.magma.rawValue
    @AppStorage(Prefs.floorDB) private var floorDB = -90.0
    @AppStorage(Prefs.maxDisplayHz) private var maxDisplayHz = 0.0
    @AppStorage(Prefs.showMaskOverlay) private var showMask = true
    @AppStorage(Prefs.brushGainDB) private var gainDB = -24.0
    @AppStorage(Prefs.brushSize) private var brushSize = 24.0
    @AppStorage(Prefs.brushHardness) private var hardness = 0.4

    func makeNSView(context: Context) -> SpectrogramNSView { SpectrogramNSView() }

    func updateNSView(_ v: SpectrogramNSView, context: Context) {
        v.studio = studio
        let analysis = studio.displayedAnalysis
        let nyquist = analysis?.grid.nyquist ?? 22_050
        let fScale = FrequencyScale(rawValue: scale) ?? .log
        let mapping = TimelineMapping(start: studio.visibleStart, duration: studio.visibleDuration,
                                      minHz: fScale.minHz(), maxHz: maxDisplayHz > 0 ? min(maxDisplayHz, nyquist) : nyquist,
                                      scale: fScale)
        let display = SpectrogramNSView.Display(
            mapping: mapping, colorMap: ColorMap(rawValue: colorMap) ?? .magma, floorDB: Float(floorDB),
            showMask: showMask, analysisID: analysisIdentity(analysis), maskVersion: studio.maskVersion)
        v.analysis = analysis
        v.raster = studio.raster
        v.brush = .init(gainDB: gainDB, size: brushSize, hardness: hardness)
        v.playhead = clock.time
        if v.display != display { v.display = display }
        v.needsDisplay = true
    }

    /// Changes whenever the shown analysis is replaced (new file, new render, Original/Filtered switch).
    private func analysisIdentity(_ a: Analysis?) -> String {
        guard a != nil else { return "none" }
        let which = studio.show == .filtered && !studio.mask.isEmpty ? "f" : "o"
        return "\(which)-\(studio.analysisVersion)"
    }
}

final class SpectrogramNSView: NSView {
    struct Display: Equatable {
        var mapping: TimelineMapping
        var colorMap: ColorMap
        var floorDB: Float
        var showMask: Bool
        var analysisID: String
        var maskVersion: Int
    }
    struct Brush { var gainDB = -24.0, size = 24.0, hardness = 0.4 }

    weak var studio: Studio?
    /// Called with each finished stroke (defaults to adding it to `studio`; tests replace it).
    var onStroke: ((FilterStroke) -> Void)?
    var analysis: Analysis?
    var raster: MaskRaster?
    var brush = Brush()
    var playhead: Double = 0
    var display: Display? { didSet { cachedImage = nil; cachedMask = nil } }

    private var cachedImage: CGImage?
    private var cachedMask: CGImage?
    private var cachedSize: CGSize = .zero
    private var hoverPoint: CGPoint?
    private var strokePoints: [CGPoint] = []
    private var scrubbing = false

    static let rulerHeight: CGFloat = 20

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var plotRect: CGRect {
        CGRect(x: timelineGutter, y: Self.rulerHeight, width: max(1, bounds.width - timelineGutter),
               height: max(1, bounds.height - Self.rulerHeight))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.black.setFill(); bounds.fill()
        guard let analysis, let display else { return }
        let plot = plotRect
        let scaleFactor = window?.backingScaleFactor ?? 2
        let px = (Int(plot.width * scaleFactor), Int(plot.height * scaleFactor))
        if cachedImage == nil || cachedSize != plot.size {
            cachedSize = plot.size
            cachedImage = SpectrogramRenderer.image(analysis, mapping: display.mapping, width: px.0, height: px.1,
                                                    floorDB: display.floorDB, colorMap: display.colorMap)
            cachedMask = display.showMask && raster != nil
                ? SpectrogramRenderer.maskImage(raster!, mapping: display.mapping, width: px.0 / 2, height: px.1 / 2) : nil
        }
        // CGImage draws bottom-up in a flipped view; flip locally.
        func drawImage(_ img: CGImage, interpolate: Bool) {
            ctx.saveGState()
            ctx.translateBy(x: plot.minX, y: plot.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = interpolate ? .medium : .none
            ctx.draw(img, in: CGRect(origin: .zero, size: plot.size))
            ctx.restoreGState()
        }
        if let img = cachedImage { drawImage(img, interpolate: false) }
        if let m = cachedMask { drawImage(m, interpolate: true) }

        drawFrequencyAxis(display.mapping, plot)
        drawRuler(display.mapping, plot)
        drawStrokePreview(plot)

        // Playhead
        let x = xFor(time: playhead, plot, display.mapping)
        if x >= plot.minX && x <= plot.maxX {
            NSColor.white.setFill()
            NSRect(x: x - 0.75, y: 0, width: 1.5, height: bounds.height).fill()
        }
        // Brush cursor
        if let p = hoverPoint, plot.contains(p) {
            let r = brush.size / 2
            let ring = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            ring.lineWidth = 1.5
            (brush.gainDB < 0 ? NSColor.systemCyan : NSColor.systemOrange).withAlphaComponent(0.9).setStroke()
            ring.stroke()
        }
    }

    private func xFor(time t: Double, _ plot: CGRect, _ m: TimelineMapping) -> CGFloat {
        plot.minX + CGFloat((t - m.start) / m.duration) * plot.width
    }

    private func drawFrequencyAxis(_ m: TimelineMapping, _ plot: CGRect) {
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: timelineGutter, height: bounds.height).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        for hz in axisTicks(m) {
            let pos = m.scale.position(of: hz, minHz: m.minHz, maxHz: m.maxHz)
            guard pos >= 0, pos <= 1 else { continue }
            let y = plot.maxY - CGFloat(pos) * plot.height
            let label = hz >= 1000 ? (hz.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(hz / 1000))k" : String(format: "%.1fk", hz / 1000)) : "\(Int(hz))"
            let s = NSAttributedString(string: label, attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: timelineGutter - size.width - 8, y: min(plot.maxY - size.height, max(plot.minY, y - size.height / 2))))
            NSColor.secondaryLabelColor.setFill()
            NSRect(x: timelineGutter - 5, y: y - 0.5, width: 5, height: 1).fill()
        }
        let unit = NSAttributedString(string: "Hz", attributes: attrs)
        unit.draw(at: NSPoint(x: 6, y: 3))
    }

    private func axisTicks(_ m: TimelineMapping) -> [Double] {
        switch m.scale {
        case .log, .mel:
            return [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000].filter { $0 >= m.minHz && $0 <= m.maxHz }
        case .linear:
            let step = niceStep(m.maxHz / 6)
            return stride(from: 0, through: m.maxHz, by: step).map { $0 }
        }
    }

    private func drawRuler(_ m: TimelineMapping, _ plot: CGRect) {
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: timelineGutter, y: 0, width: plot.width, height: Self.rulerHeight).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        let step = niceStep(m.duration / max(2, Double(plot.width) / 90))
        var t = (m.start / step).rounded(.up) * step
        while t <= m.start + m.duration {
            let x = xFor(time: t, plot, m)
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: x, y: Self.rulerHeight - 6, width: 1, height: 6).fill()
            let label = step < 1 ? String(format: "%.2fs", t) : formatTime(t).replacingOccurrences(of: ".00", with: "")
            let text = NSAttributedString(string: label, attributes: attrs)
            if x + 3 + text.size().width <= plot.maxX { text.draw(at: NSPoint(x: x + 3, y: 3)) }
            t += step
        }
    }

    private func drawStrokePreview(_ plot: CGRect) {
        guard !strokePoints.isEmpty else { return }
        let r = brush.size / 2
        let path = NSBezierPath()
        for p in strokePoints { path.appendOval(in: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
        (brush.gainDB < 0 ? NSColor.systemCyan : NSColor.systemOrange).withAlphaComponent(0.18).setFill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot).addClip()
        path.windingRule = .nonZero
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        if p.y < Self.rulerHeight || event.modifierFlags.contains(.option) {
            scrubbing = true
            seek(to: p)
        } else if plotRect.contains(p), display != nil {
            strokePoints = [p]
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverPoint = p
        if scrubbing { seek(to: p); return }
        guard let last = strokePoints.last else { return }
        // Fill gaps so fast drags still leave a continuous stroke.
        let spacing = max(1, brush.size * 0.2)
        let dist = hypot(p.x - last.x, p.y - last.y)
        if dist >= spacing {
            let steps = Int(dist / spacing)
            for i in 1...steps {
                let u = CGFloat(i) / CGFloat(steps)
                strokePoints.append(CGPoint(x: last.x + (p.x - last.x) * u, y: last.y + (p.y - last.y) * u))
            }
        }
        updatePointer(p)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { strokePoints = []; scrubbing = false; needsDisplay = true }
        guard !scrubbing, !strokePoints.isEmpty, let m = display?.mapping else { return }
        let plot = plotRect
        let stamps = strokePoints.map { p -> BrushStamp in
            let x = Double(p.x - plot.minX), y = Double(min(max(p.y, plot.minY), plot.maxY) - plot.minY)
            return BrushStamp(time: m.time(atColumn: x, width: Int(plot.width)),
                              hz: m.hz(atRow: y, height: Int(plot.height)))
        }
        let r = brush.size / 2
        let axisSpan = m.scale.warp(m.maxHz) - m.scale.warp(m.minHz)
        let stroke = FilterStroke(gainDB: brush.gainDB,
                                  radiusSeconds: Double(r / plot.width) * m.duration,
                                  radiusAxis: Double(r / plot.height) * axisSpan,
                                  hardness: brush.hardness, scale: m.scale, stamps: stamps)
        if let onStroke { onStroke(stroke) } else { studio?.addStroke(stroke) }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverPoint = p
        updatePointer(p)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        studio?.pointer.time = nil
        studio?.pointer.hz = nil
        needsDisplay = true
    }

    private func updatePointer(_ p: CGPoint) {
        guard let m = display?.mapping, let studio else { return }
        let plot = plotRect
        guard plot.contains(p) else { studio.pointer.time = nil; studio.pointer.hz = nil; return }
        studio.pointer.time = m.time(atColumn: Double(p.x - plot.minX), width: Int(plot.width))
        studio.pointer.hz = m.hz(atRow: Double(p.y - plot.minY), height: Int(plot.height))
    }

    private func seek(to p: CGPoint) {
        guard let m = display?.mapping else { return }
        let plot = plotRect
        studio?.seek(to: m.time(atColumn: Double(min(max(p.x, plot.minX), plot.maxX) - plot.minX), width: Int(plot.width)))
    }

    // Two-finger scroll pans; ⌘-scroll or pinch zooms around the pointer.
    override func scrollWheel(with event: NSEvent) {
        guard let studio, let m = display?.mapping else { return }
        let p = convert(event.locationInWindow, from: nil)
        let plot = plotRect
        let anchor = m.time(atColumn: Double(p.x - plot.minX), width: Int(plot.width))
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        if event.modifierFlags.contains(.command) {
            studio.zoom(by: exp(Double(event.scrollingDeltaY * scale) * 0.01), around: anchor)
        } else {
            let dx = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            studio.scroll(bySeconds: -Double(dx * scale / plot.width) * m.duration)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let studio, let m = display?.mapping else { return }
        let p = convert(event.locationInWindow, from: nil)
        let plot = plotRect
        studio.zoom(by: 1 + Double(event.magnification), around: m.time(atColumn: Double(p.x - plot.minX), width: Int(plot.width)))
    }
}

/// 1, 2 or 5 × a power of ten, at least `raw`.
func niceStep(_ raw: Double) -> Double {
    guard raw > 0 else { return 1 }
    let p = pow(10, floor(log10(raw)))
    for m in [1.0, 2, 5, 10] where m * p >= raw { return m * p }
    return 10 * p
}
