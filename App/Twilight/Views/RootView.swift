import SwiftUI
import TwilightKit

/// Twilight's shell: hosts along the side, games in a library.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(HostStore.self) private var hosts
    @State private var selection: String?
    @State private var showingAddHost = false
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Hosts") {
                    ForEach(hosts.hosts) { host in
                        HostRow(host: host, status: hosts.status[host.id] ?? .unknown)
                            .tag(host.id)
                            .contextMenu {
                                if host.isPaired {
                                    Button("Unpair", systemImage: "link.badge.plus") {
                                        Task { await hosts.unpair(host) }
                                    }
                                }
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    if selection == host.id { selection = nil }
                                    hosts.remove(host)
                                }
                            }
                    }
                }

                if !hosts.discovered.isEmpty {
                    Section("Found on This Network") {
                        ForEach(hosts.discovered.sorted(by: { $0.key < $1.key }), id: \.key) { name, address in
                            Button {
                                Task {
                                    if let record = try? await hosts.addHost(address: address) {
                                        selection = record.id
                                    }
                                }
                            } label: {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(name)
                                        Text(address).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "plus.circle")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Twilight")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Host", systemImage: "plus") { showingAddHost = true }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
            }
            .overlay {
                if hosts.hosts.isEmpty && hosts.discovered.isEmpty {
                    ContentUnavailableView {
                        Label("No Hosts", systemImage: "desktopcomputer")
                    } description: {
                        Text("Twilight looks for Sunshine and GeForce Experience hosts on your network. You can also add one by address.")
                    } actions: {
                        Button("Add Host") { showingAddHost = true }
                    }
                }
            }
        } detail: {
            if let id = selection, let host = hosts.host(id: id) {
                HostDetailView(host: host)
                    .id(host.id)
            } else {
                ContentUnavailableView("Choose a Host", systemImage: "sparkles.tv",
                                       description: Text("Pick a computer on the left to see its games."))
            }
        }
        .sheet(isPresented: $showingAddHost) {
            AddHostSheet { record in selection = record.id }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onAppear {
            hosts.startPolling()
            if selection == nil { selection = hosts.hosts.first?.id }
        }
        .onDisappear { hosts.stopPolling() }
    }
}

struct HostRow: View {
    let host: HostRecord
    let status: HostStatus

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "desktopcomputer")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
        }
    }

    private var subtitle: String {
        switch status {
        case .unknown: return "Checking…"
        case .offline: return "Offline"
        case .online(let paired, let game):
            if !paired { return "Not paired" }
            return game != 0 ? "In a session" : "Online"
        }
    }

    private var iconColor: Color {
        switch status {
        case .online(true, _): return .green
        case .online(false, _): return .orange
        case .offline: return .secondary
        case .unknown: return .primary
        }
    }
}
