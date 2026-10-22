import Foundation
import Observation
import TwilightKitC
import VideoToolbox

public enum StreamState: Equatable, Sendable {
    case idle
    case starting(String)
    case streaming
    case ended(String?)
}

public enum StreamStartError: Error, LocalizedError {
    case otherAppRunning(currentAppId: Int)
    case connectionFailed(stage: String, code: Int32)
    case noVideoCodec

    public var errorDescription: String? {
        switch self {
        case .otherAppRunning:
            return "Another app is already running on the host. Quit it first."
        case .connectionFailed(let stage, let code):
            return "Connection failed during \(stage) (error \(code)). Check that the host's firewall allows Moonlight/Sunshine ports."
        case .noVideoCodec:
            return "This device can't decode any video format the host offers."
        }
    }
}

/// Runs one streaming session: launch/resume on the host, then moonlight-common-c's connection,
/// with video, audio and input wired up. Only one session can be active at a time
/// (moonlight-common-c is a singleton).
@MainActor
@Observable
public final class StreamSession {
    public private(set) var state: StreamState = .idle
    public private(set) var stats = StreamStats()
    public private(set) var connectionPoor = false
    /// Whether the host says its display is in HDR mode (ConnListenerSetHdrMode).
    public private(set) var hostHdrActive = false

    public let video = VideoRenderer()
    public let input = InputManager()
    public let settings: StreamSettings
    public let appId: Int
    public let appName: String
    let http: GameStreamHTTP

    private var audio: AudioRenderer?

    /// The stream's audio volume (0...1), adjustable while streaming.
    public var volume: Double {
        didSet { audio?.setVolume(Float(volume)) }
    }
    private var cStrings: [UnsafeMutablePointer<CChar>] = []
    private var statsTimer: Timer?
    private var stopping = false

    public init(http: GameStreamHTTP, appId: Int, appName: String, settings: StreamSettings) {
        self.http = http
        self.appId = appId
        self.appName = appName
        self.settings = settings
        self.volume = settings.streamVolume
    }

    // MARK: Lifecycle

    public func start() async {
        guard case .idle = state else { return }
        state = .starting("Contacting host")
        do {
            try await startThrowing()
        } catch {
            TwilightLog.error("Stream start failed: \(error)")
            teardown()
            state = .ended(error.localizedDescription)
        }
    }

    /// Ends the stream. If `quitApp` is set, also asks the host to close the running game.
    public func stop(quitApp: Bool = false) async {
        guard !stopping else { return }
        stopping = true
        if case .streaming = state {
            state = .starting("Disconnecting")
        }
        await Task.detached { LiStopConnection() }.value
        teardown()
        if quitApp {
            try? await http.quitApp()
        }
        if case .ended = state {} else {
            state = .ended(nil)
        }
    }

    private func startThrowing() async throws {
        try Crypto.ensureInitialized()
        let info = try await http.serverInfo(timeout: 8, retries: 2)
        guard info.paired else { throw GameStreamError.notPaired }
        http.useTrueUid = !info.isNvidiaSoftware

        if info.currentGame != 0 && info.currentGame != appId {
            throw StreamStartError.otherAppRunning(currentAppId: info.currentGame)
        }

        // Stream configuration
        var config = STREAM_CONFIGURATION()
        LiInitializeStreamConfiguration(&config)
        config.width = Int32(settings.width)
        config.height = Int32(settings.height)
        config.fps = Int32(settings.fps)
        config.bitrate = Int32(settings.effectiveBitrateKbps)
        config.packetSize = 1392
        config.streamingRemotely = STREAM_CFG_AUTO
        config.audioConfiguration = settings.audio.audioConfiguration
        config.supportedVideoFormats = try supportedVideoFormats(serverCodecSupport: info.serverCodecModeSupport)
        config.clientRefreshRateX100 = Int32(settings.fps * 100)
        // Always ask for Rec. 709, like Twilight. The host switches to HDR (BT.2020 PQ, signalled in
        // the bitstream) only while its display is actually in HDR; asking for Rec. 2020 here made
        // hosts without HDR send SDR video in wide-gamut colour, which looked washed out.
        config.colorSpace = Int32(COLORSPACE_REC_709)
        config.colorRange = Int32(COLOR_RANGE_LIMITED)
        config.encryptionFlags = Int32(bitPattern: ENCFLG_ALL)

        let riKey = Crypto.randomBytes(16)
        let riKeyId = Crypto.randomBytes(4)
        withUnsafeMutableBytes(of: &config.remoteInputAesKey) { _ = riKey.copyBytes(to: $0) }
        withUnsafeMutableBytes(of: &config.remoteInputAesIv) { raw in
            for i in 0..<raw.count { raw[i] = 0 }
            _ = riKeyId.copyBytes(to: raw)
        }
        let riKeyIdValue = riKeyId.withUnsafeBytes { Int32(bigEndian: $0.loadUnaligned(as: Int32.self)) }

        // Launch or resume the app on the host
        let resume = info.currentGame == appId
        state = .starting(resume ? "Resuming \(appName)" : "Starting \(appName)")
        let gamepadMask = input.activeGamepadMask
        var query = "mode=\(settings.width)x\(settings.height)x\(info.isNvidiaSoftware && settings.fps > 60 ? 0 : settings.fps)"
        query += "&additionalStates=1&sops=\(settings.optimizeGameSettings ? 1 : 0)"
        query += "&rikey=\(riKey.hexString)&rikeyid=\(riKeyIdValue)"
        if config.supportedVideoFormats & Int32(VIDEO_FORMAT_MASK_10BIT) != 0 {
            query += "&hdrMode=1&clientHdrCapVersion=0&clientHdrCapSupportedFlagsInUint32=0&clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1&clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0"
        }
        query += "&localAudioPlayMode=\(settings.playAudioOnHost ? 1 : 0)"
        query += "&surroundAudioInfo=\(settings.audio.surroundAudioInfo)"
        query += "&remoteControllersBitmap=\(gamepadMask)&gcmap=\(gamepadMask)&gcpersist=0"
        query += String(cString: LiGetLaunchUrlQueryParameters())
        let sessionUrl = try await http.startApp(resume: resume, appId: appId, query: query)

        // Server information for moonlight-common-c. The strings must outlive the connection.
        var serverInfo = SERVER_INFORMATION()
        LiInitializeServerInformation(&serverInfo)
        serverInfo.address = UnsafePointer(retain(http.address))
        serverInfo.serverInfoAppVersion = UnsafePointer(retain(info.appVersion))
        if let gfe = info.gfeVersion {
            serverInfo.serverInfoGfeVersion = UnsafePointer(retain(gfe))
        }
        if let sessionUrl {
            serverInfo.rtspSessionUrl = UnsafePointer(retain(sessionUrl))
        }
        serverInfo.serverCodecModeSupport = info.serverCodecModeSupport

        let audio = AudioRenderer(spatialMode: settings.spatialAudio, volume: Float(volume))
        self.audio = audio
        StreamCallbacks.install(session: self, video: video, audio: audio, input: input)

        state = .starting("Connecting")
        let result: Int32 = await Task.detached {
            var config = config
            var serverInfo = serverInfo
            var listener = StreamCallbacks.connectionCallbacks()
            var videoCallbacks = StreamCallbacks.videoCallbacks()
            var audioCallbacks = StreamCallbacks.audioCallbacks()
            return LiStartConnection(&serverInfo, &config, &listener, &videoCallbacks, &audioCallbacks, nil, 0, nil, 0)
        }.value

        if result != 0 {
            let stage = StreamCallbacks.failedStage
            throw StreamStartError.connectionFailed(stage: stage.map { String(cString: LiGetStageName($0)) } ?? "startup",
                                                    code: StreamCallbacks.failedStageCode ?? result)
        }

        input.start(swapFaceButtons: settings.swapFaceButtons)
        startStatsTimer()
        state = .streaming
    }

    private func supportedVideoFormats(serverCodecSupport: Int32) throws -> Int32 {
        let hevcHardware = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        var formats: Int32 = 0
        switch settings.codec {
        case .h264:
            formats = Int32(VIDEO_FORMAT_H264)
        case .hevc, .automatic:
            formats = Int32(VIDEO_FORMAT_H264)
            if hevcHardware {
                formats |= Int32(VIDEO_FORMAT_H265)
                if settings.enableHdr {
                    formats |= Int32(VIDEO_FORMAT_H265_MAIN10)
                }
            }
        }
        if formats == 0 { throw StreamStartError.noVideoCodec }
        return formats
    }

    private func retain(_ string: String) -> UnsafeMutablePointer<CChar> {
        let p = strdup(string)!
        cStrings.append(p)
        return p
    }

    private func startStatsTimer() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stats = self.video.currentStats
            }
        }
    }

    private func teardown() {
        statsTimer?.invalidate()
        statsTimer = nil
        input.stop()
        StreamCallbacks.uninstall()
        audio = nil
        cStrings.forEach { free($0) }
        cStrings.removeAll()
    }

    // MARK: Events from moonlight-common-c (delivered on the main actor)

    func handleStageStarting(_ stage: Int32) {
        if case .starting = state {
            state = .starting(String(cString: LiGetStageName(stage)).capitalized)
        }
    }

    func handleTerminated(_ errorCode: Int32) {
        let message: String?
        switch errorCode {
        case Int32(ML_ERROR_GRACEFUL_TERMINATION): message = nil
        case Int32(ML_ERROR_NO_VIDEO_TRAFFIC): message = "No video arrived from the host. Check the host's firewall for UDP ports 47998-48000."
        case Int32(ML_ERROR_NO_VIDEO_FRAME): message = "The connection is too unreliable to keep streaming."
        case Int32(ML_ERROR_PROTECTED_CONTENT): message = "The host is showing protected content that can't be streamed."
        case Int32(ML_ERROR_UNEXPECTED_EARLY_TERMINATION): message = "The host ended the stream unexpectedly."
        default: message = "The connection was lost (error \(errorCode))."
        }
        state = .ended(message)
        Task { await stop() }
    }

    func handleHdrMode(_ enabled: Bool) {
        hostHdrActive = enabled
        TwilightLog.info("Host HDR mode: \(enabled ? "on" : "off")")
    }

    func handleConnectionStatus(_ status: Int32) {
        connectionPoor = status == Int32(CONN_STATUS_POOR)
    }

    /// Sends the stream window size used for absolute mouse coordinates.
    public var videoSize: CGSize {
        CGSize(width: settings.width, height: settings.height)
    }
}

/// Static trampolines for moonlight-common-c's C callbacks, which can't capture context.
enum StreamCallbacks {
    nonisolated(unsafe) static weak var session: StreamSession?
    nonisolated(unsafe) static var video: VideoRenderer?
    nonisolated(unsafe) static var audio: AudioRenderer?
    nonisolated(unsafe) static var input: InputManager?
    nonisolated(unsafe) static var failedStage: Int32?
    nonisolated(unsafe) static var failedStageCode: Int32?

    static func install(session: StreamSession, video: VideoRenderer, audio: AudioRenderer, input: InputManager) {
        self.session = session
        self.video = video
        self.audio = audio
        self.input = input
        failedStage = nil
        failedStageCode = nil
    }

    static func uninstall() {
        audio?.cleanup()
        video = nil
        audio = nil
        input = nil
    }

    static func connectionCallbacks() -> CONNECTION_LISTENER_CALLBACKS {
        var cb = CONNECTION_LISTENER_CALLBACKS()
        LiInitializeConnectionCallbacks(&cb)
        cb.stageStarting = { stage in
            DispatchQueue.main.async { StreamCallbacks.session?.handleStageStarting(stage) }
        }
        cb.stageFailed = { stage, code in
            StreamCallbacks.failedStage = stage
            StreamCallbacks.failedStageCode = code
        }
        cb.connectionTerminated = { code in
            DispatchQueue.main.async { StreamCallbacks.session?.handleTerminated(code) }
        }
        cb.setHdrMode = { enabled in
            DispatchQueue.main.async { StreamCallbacks.session?.handleHdrMode(enabled) }
        }
        cb.connectionStatusUpdate = { status in
            DispatchQueue.main.async { StreamCallbacks.session?.handleConnectionStatus(status) }
        }
        cb.rumble = { controller, low, high in
            StreamCallbacks.input?.rumble(controller: Int(controller), lowFrequency: low, highFrequency: high)
        }
        cb.logMessage = TwLogMessageCallback()
        return cb
    }

    static func videoCallbacks() -> DECODER_RENDERER_CALLBACKS {
        var cb = DECODER_RENDERER_CALLBACKS()
        LiInitializeVideoCallbacks(&cb)
        cb.setup = { format, width, height, fps, _, _ in
            StreamCallbacks.video?.setup(videoFormat: format, width: width, height: height, fps: fps) ?? -1
        }
        cb.cleanup = {
            StreamCallbacks.video?.cleanup()
        }
        cb.submitDecodeUnit = { unit in
            guard let unit, let video = StreamCallbacks.video else { return Int32(DR_OK) }
            return video.submit(unit)
        }
        return cb
    }

    static func audioCallbacks() -> AUDIO_RENDERER_CALLBACKS {
        var cb = AUDIO_RENDERER_CALLBACKS()
        LiInitializeAudioCallbacks(&cb)
        cb.`init` = { audioConfiguration, opusConfig, _, _ in
            guard let opusConfig, let audio = StreamCallbacks.audio else { return -1 }
            return audio.initialize(audioConfiguration: audioConfiguration, opusConfig: opusConfig.pointee)
        }
        cb.cleanup = {
            StreamCallbacks.audio?.cleanup()
        }
        cb.decodeAndPlaySample = { data, length in
            StreamCallbacks.audio?.decodeAndPlay(data, length: length)
        }
        cb.capabilities = Int32(CAPABILITY_DIRECT_SUBMIT)
        return cb
    }
}
