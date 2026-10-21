import SwiftUI
import TwilightKit

@main
struct TwilightApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .environment(model.hosts)
        }
        .defaultSize(width: 1180, height: 760)

        WindowGroup(id: "stream") {
            StreamWindow()
                .environment(model)
        }
        .windowStyle(.plain)
        .defaultSize(width: 1920, height: 1080 * 1.025)
    }
}

/// App-wide state: saved hosts, settings and the active stream.
@MainActor
@Observable
final class AppModel {
    let hosts = HostStore()
    var settings = StreamSettings.load() {
        didSet { settings.save() }
    }
    private(set) var session: StreamSession?

    /// Starts streaming `app` from `host`. The caller opens the stream window.
    func launch(host: HostRecord, app: HostApp) {
        if let session, case .streaming = session.state { return }
        let session = StreamSession(http: host.makeHTTP(), appId: app.id, appName: app.name, settings: settings)
        self.session = session
        // Pause host polling so it doesn't compete with the launch for the host's attention
        hosts.isStreaming = true
        Task { await session.start() }
    }

    func endSession(quitApp: Bool) async {
        guard let session else { return }
        await session.stop(quitApp: quitApp)
        self.session = nil
        hosts.isStreaming = false
    }
}
