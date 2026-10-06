import AVFoundation
import os

/// Plays the original and filtered signals through one AVAudioSourceNode.
///
/// Both buffers stay loaded so switching "Hear: Original / Filtered" is instant and sample-accurate,
/// and a freshly rendered filtered buffer can be swapped in mid-playback without a gap — that's what
/// makes painted filters audible "straight away".
final class AudioPlayer {
    private struct State {
        var original: [Float] = []
        var filtered: [Float] = []
        var position = 0
        var playing = false
        var bypass = false      // true = play the original
        var loop = false
        var volume: Float = 1
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private(set) var sampleRate: Double = 44_100

    /// Loads new audio (stops playback, rewinds). `filtered` starts as a copy of `original`.
    func load(_ samples: [Float], sampleRate: Double) {
        stop()
        state.withLock { $0 = State(original: samples, filtered: samples, loop: $0.loop, volume: $0.volume) }
        guard sampleRate != self.sampleRate || source == nil else { return }
        self.sampleRate = sampleRate
        if let source { engine.detach(source) }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let node = AVAudioSourceNode(format: format) { [state] _, _, frameCount, bufferList -> OSStatus in
            let n = Int(frameCount)
            state.withLock { s in
                let out = UnsafeMutableAudioBufferListPointer(bufferList)
                for buf in out {
                    let dst = buf.mData!.assumingMemoryBound(to: Float.self)
                    dst.update(repeating: 0, count: n)
                }
                guard s.playing else { return }
                let src = s.bypass ? s.original : s.filtered
                var written = 0
                while written < n {
                    if s.position >= src.count {
                        if s.loop && !src.isEmpty { s.position = 0 } else { s.playing = false; break }
                    }
                    let take = min(n - written, src.count - s.position)
                    src.withUnsafeBufferPointer { p in
                        for buf in out {
                            let dst = buf.mData!.assumingMemoryBound(to: Float.self) + written
                            for i in 0..<take { dst[i] = p[s.position + i] * s.volume }
                        }
                    }
                    written += take
                    s.position += take
                }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
    }

    /// Swaps in a new filtered signal (same length) without interrupting playback.
    func setFiltered(_ samples: [Float]) {
        state.withLock { if samples.count == $0.original.count { $0.filtered = samples } }
    }

    func play() throws {
        if !engine.isRunning { try engine.start() }
        state.withLock { s in
            if s.position >= s.original.count { s.position = 0 }
            s.playing = true
        }
    }

    func pause() { state.withLock { $0.playing = false } }

    func stop() {
        state.withLock { $0.playing = false; $0.position = 0 }
        engine.pause()
    }

    func seek(toSeconds t: Double) {
        state.withLock { s in s.position = max(0, min(s.original.count, Int(t * sampleRate))) }
    }

    var isPlaying: Bool { state.withLock { $0.playing } }
    var currentTime: Double { Double(state.withLock { $0.position }) / sampleRate }
    var bypass: Bool { get { state.withLock { $0.bypass } } set { state.withLock { $0.bypass = newValue } } }
    var loop: Bool { get { state.withLock { $0.loop } } set { state.withLock { $0.loop = newValue } } }
    var volume: Float { get { state.withLock { $0.volume } } set { state.withLock { $0.volume = newValue } } }
}
