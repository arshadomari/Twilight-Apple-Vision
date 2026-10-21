import SwiftUI
import TwilightKit

struct HostDetailView: View {
    let host: HostRecord
    @Environment(AppModel.self) private var model
    @Environment(HostStore.self) private var hosts
    @Environment(\.pushWindow) private var pushWindow
    @State private var loadError: String?
    @State private var showingPair = false
    @State private var pendingLaunch: HostApp?
    @State private var actionError: String?

    private var status: HostStatus { hosts.status[host.id] ?? .unknown }
    private var currentGame: Int {
        if case .online(_, let game) = status { return game }
        return 0
    }

    var body: some View {
        Group {
            switch status {
            case .offline:
                ContentUnavailableView {
                    Label("\(host.name) Is Offline", systemImage: "wifi.slash")
                } description: {
                    Text("Make sure the computer is awake and Sunshine is running, then try again. Address: \(host.address)")
                } actions: {
                    Button("Try Again") { Task { await hosts.refresh(host) } }
                }
            case .online(false, _):
                ContentUnavailableView {
                    Label("Pair with \(host.name)", systemImage: "lock.open.laptopcomputer")
                } description: {
                    Text("Pairing lets this Vision Pro stream from the computer. You'll enter a PIN on the host to confirm.")
                } actions: {
                    Button("Pair") { showingPair = true }
                        .buttonStyle(.borderedProminent)
                }
            case .unknown:
                ProgressView("Connecting to \(host.name)…")
            case .online(true, _):
                library
            }
        }
        .navigationTitle(host.name)
        .sheet(isPresented: $showingPair) {
            PairSheet(host: host)
        }
        .alert("Another Game Is Running", isPresented: Binding(get: { pendingLaunch != nil }, set: { if !$0 { pendingLaunch = nil } })) {
            Button("Quit and Start", role: .destructive) {
                guard let app = pendingLaunch else { return }
                Task {
                    do {
                        try await hosts.quitApp(on: host)
                        launch(app)
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Quit the game that's running on \(host.name) to start \(pendingLaunch?.name ?? "this one")? Unsaved progress will be lost.")
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private var library: some View {
        ScrollView {
            if let loadError {
                ContentUnavailableView("Couldn't Load Games", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if let apps = hosts.apps[host.id] {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 28)], spacing: 32) {
                    ForEach(apps) { app in
                        AppCard(app: app, art: hosts.boxArt(host: host, app: app), running: currentGame == app.id) {
                            if currentGame != 0 && currentGame != app.id {
                                pendingLaunch = app
                            } else {
                                launch(app)
                            }
                        }
                        .contextMenu {
                            if currentGame == app.id {
                                Button("Quit Game", systemImage: "xmark.circle", role: .destructive) {
                                    Task {
                                        do { try await hosts.quitApp(on: host) } catch { actionError = error.localizedDescription }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(32)
            } else {
                ProgressView("Loading games…").padding(60)
            }
        }
        .task {
            do {
                try await hosts.loadApps(host)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
        .refreshable {
            try? await hosts.loadApps(host)
        }
    }

    private func launch(_ app: HostApp) {
        model.launch(host: host, app: app)
        // Open the stream where this window is (in front of you), hiding the library until
        // the stream window closes. A plain openWindow places it wherever visionOS likes,
        // which for a window this large is usually too high.
        pushWindow(id: "stream")
    }
}

struct AppCard: View {
    let app: HostApp
    let art: Data?
    let running: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    artwork
                        .aspectRatio(2 / 3, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 18))
                    if running {
                        Label("Running", systemImage: "play.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.green, in: .capsule)
                            .padding(10)
                    }
                }
                Text(app.name)
                    .font(.headline)
                    .lineLimit(2)
            }
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.roundedRectangle(radius: 18))
        .hoverEffect(.lift)
    }

    @ViewBuilder
    private var artwork: some View {
        if let art, let image = UIImage(data: art) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: [.indigo, .purple.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}
