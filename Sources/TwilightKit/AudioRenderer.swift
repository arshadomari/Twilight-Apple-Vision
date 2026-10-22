import AVFoundation
import Foundation
import os
import TwilightKitC

/// Decodes the host's Opus (multistream) audio and plays it through AVAudioEngine.
///
/// On visionOS the session's spatial experience decides how the system renders the
/// multichannel stream. That replaces Twilight's macOS AUSpatialMixer path.
public final class AudioRenderer: @unchecked Sendable {
    private var decoder: OpaquePointer?
    private var channelCount = 2
    private var samplesPerFrame = 240
    private var pcm: [Float] = []

    private var engine: AVAudioEngine?
    private var ring: FloatRingBuffer?
    private let spatialMode: SpatialAudioMode
    private let volumeLock = NSLock()
    private var volume: Float

    public init(spatialMode: SpatialAudioMode, volume: Float = 1) {
        self.spatialMode = spatialMode
        self.volume = volume
    }

    /// Sets the stream's own volume (0...1). Other apps and the system volume are unaffected.
    public func setVolume(_ newValue: Float) {
        volumeLock.lock()
        volume = max(0, min(1, newValue))
        engine?.mainMixerNode.outputVolume = volume
        volumeLock.unlock()
    }

    // MARK: Audio callbacks

    func initialize(audioConfiguration: Int32, opusConfig: OPUS_MULTISTREAM_CONFIGURATION) -> Int32 {
        channelCount = Int(opusConfig.channelCount)
        samplesPerFrame = Int(opusConfig.samplesPerFrame)
        pcm = [Float](repeating: 0, count: samplesPerFrame * channelCount)

        // Moonlight orders 7.1 as FL FR C LFE BL BR SL SR. CoreAudio's MPEG 7.1 C layout wants the
        // side pair before the rear pair, so swap them in the decoder's output mapping.
        var config = opusConfig
        var mapping = withUnsafeBytes(of: config.mapping) { Array($0) }
        if channelCount == 8 {
            mapping.swapAt(4, 6)
            mapping.swapAt(5, 7)
        }
        withUnsafeMutableBytes(of: &config.mapping) { raw in
            for i in 0..<min(raw.count, mapping.count) { raw[i] = mapping[i] }
        }

        var error: Int32 = 0
        mapping.withUnsafeBufferPointer { m in
            decoder = opus_multistream_decoder_create(config.sampleRate, config.channelCount, config.streams,
                                                      config.coupledStreams, m.baseAddress!, &error)
        }
        guard decoder != nil, error == OPUS_OK else {
            TwilightLog.error("Opus decoder creation failed: \(error)")
            return -1
        }

        do {
            try startEngine(sampleRate: Double(config.sampleRate))
        } catch {
            TwilightLog.error("Audio engine failed to start: \(error)")
            return -1
        }
        return 0
    }

    func cleanup() {
        engine?.stop()
        engine = nil
        ring = nil
        if let decoder {
            opus_multistream_decoder_destroy(decoder)
        }
        decoder = nil
    }

    func decodeAndPlay(_ data: UnsafeMutablePointer<CChar>?, length: Int32) {
        guard let decoder, let ring else { return }
        let frameSize = Int32(samplesPerFrame)
        let decoded = pcm.withUnsafeMutableBufferPointer { out -> Int32 in
            guard let data else {
                // No packet: let Opus conceal the loss
                return opus_multistream_decode_float(decoder, nil, 0, out.baseAddress!, frameSize, 0)
            }
            return data.withMemoryRebound(to: UInt8.self, capacity: Int(length)) { input in
                opus_multistream_decode_float(decoder, input, length, out.baseAddress!, frameSize, 0)
            }
        }
        guard decoded > 0 else { return }
        pcm.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: Int(decoded) * channelCount) }
    }

    // MARK: Engine

    private func channelLayoutTag() -> AudioChannelLayoutTag {
        switch channelCount {
        case 6: return kAudioChannelLayoutTag_MPEG_5_1_A
        case 8: return kAudioChannelLayoutTag_MPEG_7_1_C
        default: return kAudioChannelLayoutTag_Stereo
        }
    }

    private func startEngine(sampleRate: Double) throws {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        // Mix with other apps' audio instead of silencing them
        try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setPreferredSampleRate(sampleRate)
        try? session.setPreferredIOBufferDuration(0.005)
        if session.maximumOutputNumberOfChannels >= channelCount {
            try? session.setPreferredOutputNumberOfChannels(channelCount)
        }
        #if os(visionOS)
        switch spatialMode {
        case .anchored:
            try? session.setIntendedSpatialExperience(.headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic))
        case .followHead:
            try? session.setIntendedSpatialExperience(.fixed(soundStageSize: .automatic))
        case .off:
            try? session.setIntendedSpatialExperience(.bypassed)
        }
        #endif
        try session.setActive(true)
        #endif

        guard let layout = AVAudioChannelLayout(layoutTag: channelLayoutTag()) else {
            throw CryptoError.failed("channel layout")
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)

        // Up to half a second of buffering; we trim to keep latency low
        let ring = FloatRingBuffer(capacity: Int(sampleRate) / 2 * channelCount)
        self.ring = ring
        let channels = channelCount
        let maxBufferedSamples = Int(sampleRate * 0.06) * channels

        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            ring.trim(toAtMost: maxBufferedSamples)
            ring.readDeinterleaved(into: buffers, frames: Int(frameCount), channels: channels)
            return noErr
        }

        let engine = AVAudioEngine()
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        if hardwareFormat.channelCount >= AVAudioChannelCount(channelCount) {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        }
        engine.prepare()
        try engine.start()
        volumeLock.lock()
        engine.mainMixerNode.outputVolume = volume
        self.engine = engine
        volumeLock.unlock()
    }
}

/// A lock-protected ring buffer of interleaved float samples.
final class FloatRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var readIndex = 0
    private var count = 0
    private let lockPointer: os_unfair_lock_t = {
        let p = os_unfair_lock_t.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
        lockPointer.deallocate()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lockPointer)
        defer { os_unfair_lock_unlock(lockPointer) }
        return body()
    }

    func write(_ samples: UnsafePointer<Float>, count n: Int) {
        withLock {
            for i in 0..<n {
                if count == capacity {
                    // Overrun: drop the oldest sample
                    readIndex = (readIndex + 1) % capacity
                    count -= 1
                }
                storage[(readIndex + count) % capacity] = samples[i]
                count += 1
            }
        }
    }

    /// Drops the oldest samples so no more than `limit` remain buffered (keeps latency bounded).
    func trim(toAtMost limit: Int) {
        withLock {
            if count > limit {
                let drop = count - limit
                readIndex = (readIndex + drop) % capacity
                count = limit
            }
        }
    }

    func readDeinterleaved(into buffers: UnsafeMutableAudioBufferListPointer, frames: Int, channels: Int) {
        withLock {
            let available = min(frames, count / channels)
            for (ch, buffer) in buffers.enumerated() where ch < channels {
                guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in 0..<available {
                    out[f] = storage[(readIndex + f * channels + ch) % capacity]
                }
                // Underrun: pad with silence
                for f in available..<frames {
                    out[f] = 0
                }
            }
            readIndex = (readIndex + available * channels) % capacity
            count -= available * channels
        }
    }
}
