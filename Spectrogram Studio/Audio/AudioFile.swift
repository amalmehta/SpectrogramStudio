import Accelerate
import AVFoundation
import UniformTypeIdentifiers

/// Decoded audio: mono float samples at the file's own sample rate.
struct DecodedAudio: Sendable {
    var samples: [Float]
    var sampleRate: Double
    var channelCount: Int   // in the source, before mixing to mono
    var isVideo: Bool
}

enum AudioFileError: LocalizedError {
    case noAudioTrack, readFailed(String)
    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "This file has no audio track."
        case .readFailed(let why): return "Couldn't read the audio: \(why)"
        }
    }
}

enum AudioFile {
    /// Anything AVFoundation can open: audio files and the audio track of video files.
    static let openableTypes: [UTType] = [.audio, .movie, .audiovisualContent]

    /// Decodes the first audio track of any audio or video file AVFoundation understands,
    /// mixed down to mono by the reader.
    static func load(_ url: URL) async throws -> DecodedAudio {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AudioFileError.noAudioTrack }
        let isVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
        var sampleRate = 44_100.0, channels = 1
        if let desc = try await track.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
            channels = Int(asbd.mChannelsPerFrame)
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw AudioFileError.readFailed(reader.error?.localizedDescription ?? "unknown error") }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: length / MemoryLayout<Float>.size))
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                               destination: raw.baseAddress! + start * MemoryLayout<Float>.size)
            }
        }
        if reader.status == .failed { throw AudioFileError.readFailed(reader.error?.localizedDescription ?? "unknown error") }
        return DecodedAudio(samples: samples, sampleRate: sampleRate, channelCount: channels, isVideo: isVideo)
    }

    /// Writes mono samples as a WAV file (24-bit, or 32-bit float to keep anything above 0 dBFS).
    static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL, floatingPoint: Bool) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: floatingPoint ? 32 : 24,
            AVLinearPCMIsFloatKey: floatingPoint,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let chunk = 65_536
        var offset = 0
        while offset < samples.count {
            let n = min(chunk, samples.count - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress! + offset, count: n)
            }
            try file.write(from: buffer)
            offset += n
        }
    }

    static func peak(_ samples: [Float]) -> Float {
        var m: Float = 0
        vDSP_maxmgv(samples, 1, &m, vDSP_Length(samples.count))
        return m
    }
}
