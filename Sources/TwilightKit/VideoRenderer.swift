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
    /// Colour details from the stream itself, e.g. "10-bit · BT.2020 · PQ (HDR)".
    public var colorDescription: String = ""
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
    /// The current AV1 'av1C' record, built from the stream's sequence header.
    private var av1Config: Data?
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

        av1Config = nil
        guard videoFormat & Int32(VIDEO_FORMAT_MASK_H264 | VIDEO_FORMAT_MASK_H265 | VIDEO_FORMAT_MASK_AV1) != 0 else {
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
        let isAV1 = videoFormat & Int32(VIDEO_FORMAT_MASK_AV1) != 0

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

        if isAV1 {
            // AV1 has no separate parameter sets; the sequence header travels in keyframes
            if du.frameType == Int32(FRAME_TYPE_IDR) || formatDescription == nil,
               let (config, info) = parseAV1SequenceHeader(),
               config != av1Config || formatDescription == nil {
                av1Config = config
                installFormatDescription(Self.makeAV1FormatDescription(config: config, info: info))
                if formatDescription == nil {
                    TwilightLog.error("Unable to create AV1 format description")
                    return Int32(DR_NEED_IDR)
                }
            }
        } else if du.frameType == Int32(FRAME_TYPE_IDR) && (parameterSetsChanged || formatDescription == nil) {
            installFormatDescription(makeFormatDescription(hevc: isHevc))
            if formatDescription == nil {
                TwilightLog.error("Unable to create video format description")
                return Int32(DR_NEED_IDR)
            }
        }

        guard let formatDescription else {
            // Waiting for the first IDR frame
            return Int32(DR_NEED_IDR)
        }

        guard let sampleBuffer = makeSampleBuffer(formatDescription: formatDescription, presentationTimeUs: du.presentationTimeUs,
                                                  convert: isAV1 ? TwAV1StripTemporalDelimiters : TwAnnexBToLengthPrefixed) else {
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

    private func installFormatDescription(_ description: CMVideoFormatDescription?) {
        formatDescription = description
        guard let description else { return }
        let summary = Self.describeColor(description)
        statsLock.lock()
        stats.colorDescription = summary
        statsLock.unlock()
        TwilightLog.info("Video colour: \(summary)")
        setDynamicRange(hdr: Self.isHDR(description))
    }

    /// Reads the sequence header from the AV1 temporal unit in `frameBuffer`, if it has one.
    private func parseAV1SequenceHeader() -> (Data, TwAV1Info)? {
        var info = TwAV1Info()
        var config = [UInt8](repeating: 0, count: 1024)
        let length = TwAV1ParseSequenceHeader(UnsafeRawPointer(frameBuffer).assumingMemoryBound(to: UInt8.self),
                                              frameLength, &info, &config, config.count)
        if length < 0 {
            TwilightLog.error("Malformed AV1 sequence header")
        }
        guard length > 0 else { return nil }
        return (Data(config[0..<Int(length)]), info)
    }

    static func makeAV1FormatDescription(config: Data, info: TwAV1Info) -> CMVideoFormatDescription? {
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["av1C": config] as CFDictionary,
            kCMFormatDescriptionExtension_FullRangeVideo: info.fullRange,
            kCMFormatDescriptionExtension_BitsPerComponent: info.bitDepth,
        ]
        // AV1 uses the same ITU-T H.273 code points as VideoToolbox's colour tags
        if let primaries = CVColorPrimariesGetStringForIntegerCodePoint(Int32(info.colorPrimaries))?.takeUnretainedValue() {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = primaries
        }
        if let transfer = CVTransferFunctionGetStringForIntegerCodePoint(Int32(info.transferCharacteristics))?.takeUnretainedValue() {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = transfer
        }
        if let matrix = CVYCbCrMatrixGetStringForIntegerCodePoint(Int32(info.matrixCoefficients))?.takeUnretainedValue() {
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = matrix
        }
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_AV1,
                                                    width: Int32(info.width), height: Int32(info.height),
                                                    extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        return status == noErr ? description : nil
    }

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

    /// Converts the frame in `frameBuffer` to the decoder's sample format, written straight into the
    /// CMBlockBuffer the decoder reads (one copy, done in C): length-prefixed NAL units for
    /// H.264/HEVC, or the temporal unit without temporal delimiters for AV1.
    private func makeSampleBuffer(formatDescription: CMVideoFormatDescription, presentationTimeUs: UInt64,
                                  convert: (UnsafePointer<UInt8>, Int, UnsafeMutablePointer<UInt8>?) -> Int) -> CMSampleBuffer? {
        let input = UnsafeRawPointer(frameBuffer).assumingMemoryBound(to: UInt8.self)
        let outputLength = convert(input, frameLength, nil)
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
            convert(input, frameLength, $0)
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

    /// Lets HDR frames use the display's extra brightness. visionOS otherwise tone-maps the layer
    /// to standard range (the default since visionOS 26), which makes HDR streams look dim.
    /// Standard range is kept for SDR streams, since HDR mode costs power.
    private func setDynamicRange(hdr: Bool) {
        guard #available(visionOS 26.0, iOS 26.0, macOS 26.0, *) else { return }
        DispatchQueue.main.async { [displayLayer] in
            let range: CALayer.DynamicRange = hdr ? .high : .standard
            if displayLayer.preferredDynamicRange != range {
                displayLayer.preferredDynamicRange = range
                TwilightLog.info("Video layer dynamic range: \(hdr ? "high (HDR)" : "standard")")
            }
        }
    }

    static func isHDR(_ description: CMFormatDescription) -> Bool {
        let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        return transfer == String(kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ)
            || transfer == String(kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG)
    }

    /// Summarises the colour signalling VideoToolbox read from the stream's parameter sets.
    static func describeColor(_ description: CMFormatDescription) -> String {
        func ext(_ key: CFString) -> String? {
            CMFormatDescriptionGetExtension(description, extensionKey: key) as? String
        }
        let depth = (CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber)?.intValue
        let primaries: String
        switch ext(kCMFormatDescriptionExtension_ColorPrimaries) {
        case String(kCMFormatDescriptionColorPrimaries_ITU_R_2020): primaries = "BT.2020"
        case String(kCMFormatDescriptionColorPrimaries_ITU_R_709_2): primaries = "BT.709"
        case let other?: primaries = other
        case nil: primaries = "untagged primaries"
        }
        let transfer: String
        switch ext(kCMFormatDescriptionExtension_TransferFunction) {
        case String(kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ): transfer = "PQ (HDR)"
        case String(kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG): transfer = "HLG (HDR)"
        case String(kCMFormatDescriptionTransferFunction_ITU_R_709_2): transfer = "BT.709 (SDR)"
        case let other?: transfer = other
        case nil: transfer = "untagged transfer"
        }
        let range = (CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool) == true ? "full" : "limited"
        return [depth.map { "\($0)-bit" }, primaries, transfer, "\(range) range"].compactMap { $0 }.joined(separator: " · ")
    }

    static func codecName(_ format: Int32) -> String {
        if format & Int32(VIDEO_FORMAT_MASK_AV1) != 0 {
            return format & Int32(VIDEO_FORMAT_MASK_10BIT) != 0 ? "AV1 Main10" : "AV1"
        }
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
