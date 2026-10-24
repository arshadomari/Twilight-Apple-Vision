import SwiftUI
import TwilightKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Video") {
                    Picker("Resolution", selection: resolutionBinding) {
                        ForEach(StreamSettings.resolutions, id: \.0) { name, _, _ in
                            Text(name).tag(name)
                        }
                    }
                    Picker("Frame Rate", selection: $model.settings.fps) {
                        ForEach(StreamSettings.frameRates, id: \.self) { Text("\($0) FPS").tag($0) }
                    }
                    Toggle("Automatic Bitrate", isOn: $model.settings.autoBitrate)
                    if model.settings.autoBitrate {
                        LabeledContent("Bitrate", value: "\(model.settings.effectiveBitrateKbps / 1000) Mbps")
                    } else {
                        VStack(alignment: .leading) {
                            Text("Bitrate: \(model.settings.bitrateKbps / 1000) Mbps")
                            Slider(value: bitrateBinding, in: 5...1000, step: 5)
                        }
                    }
                    Picker("Codec", selection: $model.settings.codec) {
                        ForEach(VideoCodecPreference.allCases) { codec in
                            if codec != .av1 || VideoCodecPreference.av1Available {
                                Text(codec.label).tag(codec)
                            }
                        }
                    }
                    if model.settings.codec == .av1 {
                        Text("AV1 needs a GPU with an AV1 encoder on the host (GeForce RTX 40 or newer, Radeon RX 7000 or newer, Intel Arc). Otherwise the stream uses HEVC.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("HDR (10-bit)", isOn: $model.settings.enableHdr)
                    Picker("Frame Pacing", selection: $model.settings.framePacing) {
                        ForEach(FramePacing.allCases) { Text($0.label).tag($0) }
                    }
                    Text(model.settings.framePacing == .off
                         ? "Frames are shown the moment they arrive, for the lowest latency."
                         : "Buffers frames to smooth out Wi-Fi stalls (such as AWDL). Each frame adds about \(Int((1000.0 / Double(model.settings.fps)).rounded())) ms of latency at \(model.settings.fps) FPS.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Channels", selection: $model.settings.audio) {
                        ForEach(AudioChannelPreference.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Spatial Audio", selection: $model.settings.spatialAudio) {
                        ForEach(SpatialAudioMode.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Play Audio on Host", isOn: $model.settings.playAudioOnHost)
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Anchored to Window places the game's sound at the stream, so it stays put as you turn your head.")
                }

                Section {
                    Picker("Pointer", selection: $model.settings.pointerMode) {
                        ForEach(PointerMode.allCases) { Text($0.label).tag($0) }
                    }
                    if model.settings.pointerMode == .trackpad {
                        VStack(alignment: .leading) {
                            Text("Pointer Speed: \(model.settings.pointerSpeed, specifier: "%.1f")×")
                            Slider(value: $model.settings.pointerSpeed, in: 0.5...4, step: 0.1)
                        }
                    }
                    Toggle("Swap A/B and X/Y", isOn: $model.settings.swapFaceButtons)
                } header: {
                    Text("Input")
                } footer: {
                    Text(model.settings.pointerMode == .trackpad
                         ? "Pinch and drag to move the cursor, pinch quickly to click, and pinch and hold to drag."
                         : "Look at a spot and pinch to click there. Some hosts ignore this; switch to Trackpad if the cursor doesn't move.")
                }

                Section("Host") {
                    Toggle("Optimize Game Settings", isOn: $model.settings.optimizeGameSettings)
                }

                Section("Stream Window") {
                    Toggle("Dim Surroundings", isOn: $model.settings.dimSurroundings)
                    Toggle("Performance Overlay", isOn: $model.settings.showPerformanceOverlay)
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Text("Twilight for Apple Vision Pro is based on Twilight 7.1.0 by Neguete10, a fork of Moonlight Qt. Moonlight has not endorsed it. Licensed under GPL-3.0.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 640, height: 720)
    }

    private var resolutionBinding: Binding<String> {
        Binding {
            StreamSettings.resolutions.first { $0.1 == model.settings.width && $0.2 == model.settings.height }?.0 ?? "1080p"
        } set: { name in
            if let match = StreamSettings.resolutions.first(where: { $0.0 == name }) {
                model.settings.width = match.1
                model.settings.height = match.2
            }
        }
    }

    private var bitrateBinding: Binding<Double> {
        Binding {
            Double(model.settings.bitrateKbps) / 1000
        } set: {
            model.settings.bitrateKbps = Int($0) * 1000
        }
    }
}
