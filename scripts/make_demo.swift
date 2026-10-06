// Synthesises demo media for trying the app and taking screenshots:
//   <out>/Demo Melody.wav  — a sung-like melody with vibrato and harmonics, a chirp, a hum and noise bursts
//   <out>/Demo Melody.mp4  — the same audio inside a short H.264 video (to exercise the video path)
// Usage: swift scripts/make_demo.swift build/demo
import AVFoundation
import CoreVideo

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/demo")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let sr = 44_100.0, seconds = 12.0
let n = Int(sr * seconds)

// MARK: Audio
var x = [Float](repeating: 0, count: n)
var rng = SystemRandomNumberGenerator()
let melody: [(start: Double, len: Double, midi: Double)] = [
    (0.3, 0.9, 57), (1.3, 0.9, 60), (2.3, 0.9, 64), (3.3, 1.6, 62),
    (5.2, 0.9, 60), (6.2, 0.9, 57), (7.2, 1.8, 55), (9.3, 2.2, 57),
]
var phase = 0.0
for i in 0..<n {
    let t = Double(i) / sr
    var s = 0.0
    if let note = melody.first(where: { t >= $0.start && t < $0.start + $0.len }) {
        let local = t - note.start
        let f0 = 440 * pow(2, (note.midi - 69) / 12) * (1 + 0.012 * sin(2 * .pi * 5.5 * local))
        phase += 2 * .pi * f0 / sr
        let env = min(1, local / 0.05) * min(1, (note.start + note.len - t) / 0.12)
        for h in 1...10 { s += env * 0.22 / Double(h) * sin(Double(h) * phase) }
    }
    s += 0.03 * sin(2 * .pi * 60 * t) + 0.015 * sin(2 * .pi * 180 * t)          // mains hum
    let chirpT = t - 4.9
    if chirpT >= 0 && chirpT < 2.5 {                                               // rising whistle
        s += 0.06 * sin(2 * .pi * 2000 * (pow(4, chirpT / 2.5) - 1) / (log(4) / 2.5)) * min(1, chirpT / 0.1) * min(1, (2.5 - chirpT) / 0.1)
    }
    let beat = t.truncatingRemainder(dividingBy: 0.5)                               // hi-hat-like ticks
    if beat < 0.03 { s += Double.random(in: -1...1, using: &rng) * 0.08 * (1 - beat / 0.03) }
    x[i] = Float(s)
}

let wavURL = outDir.appendingPathComponent("Demo Melody.wav")
try? FileManager.default.removeItem(at: wavURL)
do {
    let file = try AVAudioFile(forWriting: wavURL, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr,
                                                              AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                                              AVLinearPCMIsFloatKey: false])
    let buf = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    for i in 0..<n { buf.floatChannelData![0][i] = x[i] }
    try file.write(from: buf)
}
print("Wrote \(wavURL.path)")

// MARK: Video (a slowly changing colour field) with the same audio as AAC
let mp4URL = outDir.appendingPathComponent("Demo Melody.mp4")
try? FileManager.default.removeItem(at: mp4URL)
let writer = try AVAssetWriter(outputURL: mp4URL, fileType: .mp4)
let w = 320, h = 180, fps = 10
let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr,
                                                                    AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000])
videoIn.expectsMediaDataInRealTime = false
audioIn.expectsMediaDataInRealTime = false
writer.add(videoIn); writer.add(audioIn)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let frames = Int(seconds) * fps
var asbd = AudioStreamBasicDescription(mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
                                       mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
                                       mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
var fmtDesc: CMAudioFormatDescription?
CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmtDesc)

func appendVideoFrame(_ f: Int) {
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pb!)
    for y in 0..<h { for xx in 0..<w {
        let p = base + y * stride + xx * 4
        p[0] = UInt8((xx + f * 4) % 256); p[1] = UInt8((y * 2) % 256); p[2] = UInt8((f * 9) % 256); p[3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
}

func appendAudio(at offset: Int, count: Int) {
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 4, blockAllocator: nil,
                                       customBlockSource: nil, offsetToData: 0, dataLength: count * 4, flags: 0, blockBufferOut: &block)
    x.withUnsafeBytes { raw in
        _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + offset * 4, blockBuffer: block!, offsetIntoDestination: 0, dataLength: count * 4)
    }
    var sample: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmtDesc!, sampleCount: count,
                                                         presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(sr)),
                                                         packetDescriptions: nil, sampleBufferOut: &sample)
    audioIn.append(sample!)
}

// Interleave by timestamp: AVAssetWriter stalls one input while waiting for the other to catch up.
let chunk = 4096
var nextFrame = 0, offset = 0
while nextFrame < frames || offset < n {
    let videoTime = nextFrame < frames ? Double(nextFrame) / Double(fps) : .infinity
    let audioTime = offset < n ? Double(offset) / sr : .infinity
    if videoTime <= audioTime {
        if videoIn.isReadyForMoreMediaData { appendVideoFrame(nextFrame); nextFrame += 1 } else { usleep(1000) }
    } else {
        if audioIn.isReadyForMoreMediaData {
            let count = min(chunk, n - offset)
            appendAudio(at: offset, count: count); offset += count
        } else { usleep(1000) }
    }
    if nextFrame == frames { videoIn.markAsFinished(); nextFrame += 1 }
}
audioIn.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "Wrote \(mp4URL.path)" : "Video failed: \(String(describing: writer.error))")
