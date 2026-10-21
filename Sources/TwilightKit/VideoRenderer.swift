import AVFoundation
import CoreMedia
import Foundation
import TwilightKitC
import VideoToolbox

/// Live performance numbers for the overlay.
public struct StreamStats: Sendable {
    public var receivedFps: Double = 0
    public var droppedFrames: Int = 0
    public var rttMs: UInt32 = 0
    public var rttVarianceMs: UInt32 = 0
    public var hostLatencyMs: Double = 0
    public var bitrateMbps: Double = 0
    public var codec: String = ""
    /// Average time the client spends preparing each frame for the decoder.
    public var frameProcessingMs: Double = 0
    public var width: Int = 0
    public var height: Int = 0
}

/// Turns moonlight-common-c decode units (Annex-B H.264/HEVC) into CMSampleBuffers and
/// hands them to an AVSampleBufferDisplayLayer, which decodes with VideoToolbox in hardware.
public final class VideoRenderer: @unchecked Sendable {
    public let displayLayer = AVSampleBufferDisplayLayer()

    private var videoFormat: Int32 = 0
    private var formatDescription: CMVideoFormatDescription?
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    /// Reusable buffer the picture data of each frame is gathered into (Annex-B).
    private var frameBuffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16)
    private var frameCapacity = 1 << 20
    private var frameLength = 0

    // Stats, guarded by statsLock
    private let statsLock = NSLock()
    private var windowStart = CACurrentMediaTime()
    private var windowFrames = 0
    private var windowBytes = 0
    private var windowHostLatency = 0.0
    private var windowHostLatencySamples = 0
    private var windowProcessingTime = 0.0
    private var droppedFrames = 0
    private var statsWindows = 0
    private var lastFrameNumber: Int32 = 0
    private var stats = StreamStats()

    public init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    deinit {
        frameBuffer.deallocate()
    }

    private func appendFrameData(_ data: UnsafeRawPointer, count: Int) {
        if frameLength + count > frameCapacity {
            var newCapacity = frameCapacity * 2
            while newCapacity < frameLength + count { newCapacity *= 2 }
            let newBuffer = UnsafeMutableRawPointer.allocate(byteCount: newCapacity, alignment: 16)
            newBuffer.copyMemory(from: frameBuffer, byteCount: frameLength)
            frameBuffer.deallocate()
            frameBuffer = newBuffer
            frameCapacity = newCapacity
        }
        (frameBuffer + frameLength).copyMemory(from: data, byteCount: count)
        frameLength += count
    }

    public var currentStats: StreamStats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return stats
    }

    // MARK: Decoder callbacks

    func setup(videoFormat: Int32, width: Int32, height: Int32, fps: Int32) -> Int32 {
        self.videoFormat = videoFormat
        formatDescription = nil
        vps = nil
        sps = nil
        pps = nil
        frameLength = 0
        statsLock.lock()
        stats = StreamStats()
        stats.width = Int(width)
        stats.height = Int(height)
        stats.codec = Self.codecName(videoFormat)
        statsLock.unlock()

        guard videoFormat & Int32(VIDEO_FORMAT_MASK_H264 | VIDEO_FORMAT_MASK_H265) != 0 else {
            TwilightLog.error("Unsupported video format \(videoFormat)")
            return -1
        }
        DispatchQueue.main.async { [displayLayer] in
            displayLayer.sampleBufferRenderer.flush()
        }
        return 0
    }

    func cleanup() {
        DispatchQueue.main.async { [displayLayer] in
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    func submit(_ unit: UnsafeMutablePointer<DECODE_UNIT>) -> Int32 {
        let started = CACurrentMediaTime()
        let du = unit.pointee
        let isHevc = videoFormat & Int32(VIDEO_FORMAT_MASK_H265) != 0

        frameLength = 0
        var entry = du.bufferList
        var parameterSetsChanged = false
        while let e = entry {
            let buffer = UnsafeRawBufferPointer(start: e.pointee.data, count: Int(e.pointee.length))
            switch e.pointee.bufferType {
            case Int32(BUFFER_TYPE_PICDATA):
                if let base = buffer.baseAddress, buffer.count > 0 {
                    appendFrameData(base, count: buffer.count)
                }
            case Int32(BUFFER_TYPE_SPS), Int32(BUFFER_TYPE_PPS), Int32(BUFFER_TYPE_VPS):
                let nal = Self.stripStartCode(buffer)
                switch e.pointee.bufferType {
                case Int32(BUFFER_TYPE_SPS): if nal != sps { sps = nal; parameterSetsChanged = true }
                case Int32(BUFFER_TYPE_PPS): if nal != pps { pps = nal; parameterSetsChanged = true }
                default: if nal != vps { vps = nal; parameterSetsChanged = true }
                }
            default:
                break
            }
            entry = e.pointee.next
        }

        if du.frameType == Int32(FRAME_TYPE_IDR) && (parameterSetsChanged || formatDescription == nil) {
            formatDescription = makeFormatDescription(hevc: isHevc)
            if formatDescription == nil {
                TwilightLog.error("Unable to create video format description")
                return Int32(DR_NEED_IDR)
            }
        }

        guard let formatDescription else {
            // Waiting for the first IDR frame
            return Int32(DR_NEED_IDR)
        }

        guard let sampleBuffer = makeSampleBuffer(formatDescription: formatDescription, presentationTimeUs: du.presentationTimeUs) else {
            return Int32(DR_NEED_IDR)
        }

        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            TwilightLog.error("Video renderer failed: \(String(describing: renderer.error)); requesting IDR")
            renderer.flush()
            self.formatDescription = nil
            return Int32(DR_NEED_IDR)
        }
        renderer.enqueue(sampleBuffer)

        recordFrame(du, processingTime: CACurrentMediaTime() - started)
        return Int32(DR_OK)
    }

    // MARK: Helpers

    private func makeFormatDescription(hevc: Bool) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        if hevc {
            guard let vps, let sps, let pps else { return nil }
            let sets = [vps, sps, pps]
            Self.withPointers(sets) { pointers, sizes in
                _ = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
            }
        } else {
            guard let sps, let pps else { return nil }
            let sets = [sps, pps]
            Self.withPointers(sets) { pointers, sizes in
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        return description
    }

    /// Converts the Annex-B frame in `frameBuffer` to 4-byte length-prefixed NAL units, written
    /// straight into the CMBlockBuffer the decoder reads (one copy, done in C).
    private func makeSampleBuffer(formatDescription: CMVideoFormatDescription, presentationTimeUs: UInt64) -> CMSampleBuffer? {
        let input = UnsafeRawPointer(frameBuffer).assumingMemoryBound(to: UInt8.self)
        let outputLength = TwAnnexBToLengthPrefixed(input, frameLength, nil)
        guard outputLength > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: outputLength,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: outputLength, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer else { return nil }
        var destination: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil,
                                          dataPointerOut: &destination) == noErr,
              let destination else { return nil }
        let written = destination.withMemoryRebound(to: UInt8.self, capacity: outputLength) {
            TwAnnexBToLengthPrefixed(input, frameLength, $0)
        }
        guard written == outputLength else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(presentationTimeUs), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sampleSize = outputLength
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDescription,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return nil }

        // Show frames as soon as they're decoded; we're latency-bound, not smoothness-bound
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }

    private func recordFrame(_ du: DECODE_UNIT, processingTime: Double) {
        statsLock.lock()
        defer { statsLock.unlock() }

        if lastFrameNumber != 0 && du.frameNumber > lastFrameNumber + 1 {
            droppedFrames += Int(du.frameNumber - lastFrameNumber - 1)
        }
        lastFrameNumber = du.frameNumber
        windowFrames += 1
        windowBytes += Int(du.fullLength)
        windowProcessingTime += processingTime
        if du.frameHostProcessingLatency != 0 {
            windowHostLatency += Double(du.frameHostProcessingLatency) / 10
            windowHostLatencySamples += 1
        }

        let now = CACurrentMediaTime()
        let elapsed = now - windowStart
        if elapsed >= 1 {
            stats.receivedFps = Double(windowFrames) / elapsed
            stats.bitrateMbps = Double(windowBytes) * 8 / elapsed / 1_000_000
            stats.droppedFrames = droppedFrames
            stats.frameProcessingMs = windowFrames > 0 ? windowProcessingTime / Double(windowFrames) * 1000 : 0
            stats.hostLatencyMs = windowHostLatencySamples > 0 ? windowHostLatency / Double(windowHostLatencySamples) : 0
            var rtt: UInt32 = 0, variance: UInt32 = 0
            if LiGetEstimatedRttInfo(&rtt, &variance) {
                stats.rttMs = rtt
                stats.rttVarianceMs = variance
            }
            statsWindows += 1
            if statsWindows % 5 == 1 {
                TwilightLog.debug(String(format: "Video: %.0f fps, %.1f Mbps, %d dropped, rtt %u ms",
                                        stats.receivedFps, stats.bitrateMbps, stats.droppedFrames, stats.rttMs))
            }
            windowStart = now
            windowFrames = 0
            windowBytes = 0
            windowHostLatency = 0
            windowHostLatencySamples = 0
            windowProcessingTime = 0
        }
    }

    static func codecName(_ format: Int32) -> String {
        if format & Int32(VIDEO_FORMAT_MASK_H265) != 0 {
            return format & Int32(VIDEO_FORMAT_MASK_10BIT) != 0 ? "HEVC Main10 (HDR)" : "HEVC"
        }
        return "H.264"
    }

    static func stripStartCode(_ buffer: UnsafeRawBufferPointer) -> Data {
        let bytes = buffer.bindMemory(to: UInt8.self)
        if bytes.count >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 1 {
            return Data(bytes[4...])
        }
        if bytes.count >= 3 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 1 {
            return Data(bytes[3...])
        }
        return Data(bytes)
    }

    /// Converts an Annex-B byte stream to 4-byte length-prefixed NAL units (via TwVideo.c).
    static func annexBToLengthPrefixed(_ data: Data) -> Data {
        data.withUnsafeBytes { raw -> Data in
            guard let input = raw.bindMemory(to: UInt8.self).baseAddress else { return Data() }
            let length = TwAnnexBToLengthPrefixed(input, raw.count, nil)
            var out = Data(count: length)
            out.withUnsafeMutableBytes { _ = TwAnnexBToLengthPrefixed(input, raw.count, $0.bindMemory(to: UInt8.self).baseAddress) }
            return out
        }
    }

    private static func withPointers(_ sets: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> Void) {
        let copies = sets.map { data -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(data.count, 1))
            data.copyBytes(to: p, count: data.count)
            return p
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = sets.map { $0.count }
        pointers.withUnsafeBufferPointer { pp in
            sizes.withUnsafeBufferPointer { sp in
                body(pp.baseAddress!, sp.baseAddress!)
            }
        }
    }
}
