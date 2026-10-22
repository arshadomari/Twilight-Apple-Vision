import Foundation
import TwilightKitC

public enum VideoCodecPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, h264, hevc
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }
}

public enum AudioChannelPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case stereo, surround51, surround71
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .stereo: return "Stereo"
        case .surround51: return "5.1 Surround"
        case .surround71: return "7.1 Surround"
        }
    }

    var channelCount: Int32 {
        switch self {
        case .stereo: return 2
        case .surround51: return 6
        case .surround71: return 8
        }
    }

    var channelMask: Int32 {
        switch self {
        case .stereo: return 0x3
        case .surround51: return 0x3F
        case .surround71: return 0x63F
        }
    }

    /// MAKE_AUDIO_CONFIGURATION() from Limelight.h (function-like macros aren't visible to Swift).
    var audioConfiguration: Int32 {
        (channelMask << 16) | (channelCount << 8) | 0xCA
    }

    /// SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION()
    var surroundAudioInfo: Int32 {
        (channelMask << 16) | channelCount
    }
}

/// How visionOS places the stream's audio. Maps to AVAudioSession's spatial experience.
public enum SpatialAudioMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Sound comes from the stream window and stays put as you turn your head.
    case anchored
    /// Sound stays fixed relative to your head (Twilight's default with head tracking off).
    case followHead
    /// No spatialization.
    case off

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .anchored: return "Anchored to Window"
        case .followHead: return "Follow Head"
        case .off: return "Off"
        }
    }
}

/// How look-and-pinch controls the host's mouse.
public enum PointerMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Pinch and drag moves the cursor like a trackpad; a quick pinch clicks. Uses relative
    /// mouse motion, like Twilight's default mouse mode, so it works with every host.
    case trackpad
    /// Pinch where you look to move the cursor there and click. Uses absolute positioning,
    /// which some hosts ignore.
    case direct

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .trackpad: return "Trackpad"
        case .direct: return "Direct (Look and Pinch)"
        }
    }
}

public struct StreamSettings: Codable, Equatable, Sendable {
    public var width = 1920
    public var height = 1080
    public var fps = 60
    public var bitrateKbps = 20_000
    public var autoBitrate = true
    public var codec: VideoCodecPreference = .automatic
    public var enableHdr = false
    public var audio: AudioChannelPreference = .stereo
    public var spatialAudio: SpatialAudioMode = .anchored
    public var optimizeGameSettings = true
    public var playAudioOnHost = false
    public var showPerformanceOverlay = false
    public var swapFaceButtons = false
    public var dimSurroundings = true
    public var pointerMode: PointerMode = .trackpad
    public var pointerSpeed: Double = 1.5
    /// Volume of the stream's own audio, 0...1. Doesn't affect other apps or the system volume.
    public var streamVolume: Double = 1.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StreamSettings()
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? d.width
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? d.height
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
        bitrateKbps = try c.decodeIfPresent(Int.self, forKey: .bitrateKbps) ?? d.bitrateKbps
        autoBitrate = try c.decodeIfPresent(Bool.self, forKey: .autoBitrate) ?? d.autoBitrate
        codec = (try? c.decodeIfPresent(VideoCodecPreference.self, forKey: .codec)) ?? d.codec
        enableHdr = try c.decodeIfPresent(Bool.self, forKey: .enableHdr) ?? d.enableHdr
        audio = (try? c.decodeIfPresent(AudioChannelPreference.self, forKey: .audio)) ?? d.audio
        spatialAudio = (try? c.decodeIfPresent(SpatialAudioMode.self, forKey: .spatialAudio)) ?? d.spatialAudio
        optimizeGameSettings = try c.decodeIfPresent(Bool.self, forKey: .optimizeGameSettings) ?? d.optimizeGameSettings
        playAudioOnHost = try c.decodeIfPresent(Bool.self, forKey: .playAudioOnHost) ?? d.playAudioOnHost
        showPerformanceOverlay = try c.decodeIfPresent(Bool.self, forKey: .showPerformanceOverlay) ?? d.showPerformanceOverlay
        swapFaceButtons = try c.decodeIfPresent(Bool.self, forKey: .swapFaceButtons) ?? d.swapFaceButtons
        dimSurroundings = try c.decodeIfPresent(Bool.self, forKey: .dimSurroundings) ?? d.dimSurroundings
        pointerMode = (try? c.decodeIfPresent(PointerMode.self, forKey: .pointerMode)) ?? d.pointerMode
        pointerSpeed = try c.decodeIfPresent(Double.self, forKey: .pointerSpeed) ?? d.pointerSpeed
        streamVolume = try c.decodeIfPresent(Double.self, forKey: .streamVolume) ?? d.streamVolume
    }

    public static let resolutions: [(String, Int, Int)] = [
        ("720p", 1280, 720),
        ("1080p", 1920, 1080),
        ("1440p", 2560, 1440),
        ("4K", 3840, 2160),
    ]

    public static let frameRates = [30, 60, 90, 100, 120]

    /// The bitrate Moonlight/Twilight would pick for this resolution and frame rate.
    public static func defaultBitrate(width: Int, height: Int, fps: Int) -> Int {
        let frameRateFactor = (fps <= 60 ? Double(fps) : (Double(fps) / 60).squareRoot() * 60) / 30
        let table: [(pixels: Int, factor: Double)] = [
            (640 * 360, 1), (854 * 480, 2), (1280 * 720, 5),
            (1920 * 1080, 10), (2560 * 1440, 20), (3840 * 2160, 40),
        ]
        let pixels = width * height
        var resolutionFactor = table.last!.factor
        for (i, entry) in table.enumerated() where pixels <= entry.pixels {
            if pixels == entry.pixels || i == 0 {
                resolutionFactor = entry.factor
            } else {
                let prev = table[i - 1]
                resolutionFactor = Double(pixels - prev.pixels) / Double(entry.pixels - prev.pixels) * (entry.factor - prev.factor) + prev.factor
            }
            break
        }
        return Int((resolutionFactor * frameRateFactor).rounded()) * 1000
    }

    public var effectiveBitrateKbps: Int {
        autoBitrate ? Self.defaultBitrate(width: width, height: height, fps: fps) : bitrateKbps
    }

    // MARK: Persistence

    private static let defaultsKey = "Twilight.StreamSettings"

    public static func load() -> StreamSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(StreamSettings.self, from: data) else {
            return StreamSettings()
        }
        return settings
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
