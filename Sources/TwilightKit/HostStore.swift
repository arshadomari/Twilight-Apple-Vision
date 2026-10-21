import Foundation
import Network
import Observation

/// A saved host. Equivalent to Twilight's persisted NvComputer.
public struct HostRecord: Codable, Identifiable, Hashable, Sendable {
    /// The host's uniqueid from /serverinfo (or a placeholder until first contact).
    public var id: String
    public var name: String
    public var address: String
    public var httpPort: UInt16 = GameStreamHTTP.defaultHttpPort
    public var httpsPort: UInt16 = 47984
    public var serverCertPem: String?
    public var macAddress: String?

    public var isPaired: Bool { serverCertPem != nil }

    public func makeHTTP() -> GameStreamHTTP {
        GameStreamHTTP(address: address, httpPort: httpPort, httpsPort: httpsPort, serverCertPem: serverCertPem)
    }
}

public enum HostStatus: Equatable, Sendable {
    case unknown
    case offline
    case online(paired: Bool, currentGame: Int)
}

/// Saved hosts, their live status and app lists, plus Bonjour discovery.
@MainActor
@Observable
public final class HostStore {
    public private(set) var hosts: [HostRecord] = []
    public private(set) var status: [String: HostStatus] = [:]
    public private(set) var apps: [String: [HostApp]] = [:]
    public private(set) var boxArt: [String: Data] = [:]
    /// Hosts found on the local network that aren't saved yet.
    public private(set) var discovered: [String: String] = [:] // name -> address

    private var browser: NWBrowser?
    private var resolving: [NWConnection] = []
    private var pollTask: Task<Void, Never>?
    /// Hosts with a status request in flight, so polls don't pile up on a slow host.
    private var refreshing: Set<String> = []
    /// Consecutive failed status checks per host. One miss doesn't make a host "offline".
    private var failures: [String: Int] = [:]
    private static let failuresBeforeOffline = 2
    /// Set while a stream is starting or running so polling doesn't compete with it.
    public var isStreaming = false
    private static let defaultsKey = "Twilight.Hosts"

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([HostRecord].self, from: data) {
            hosts = saved
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    public func host(id: String) -> HostRecord? {
        hosts.first { $0.id == id }
    }

    // MARK: Adding and removing

    /// Contacts a host by address (IP or hostname, optionally with :port) and saves it.
    @discardableResult
    public func addHost(address rawAddress: String) async throws -> HostRecord {
        var address = rawAddress.trimmingCharacters(in: .whitespaces)
        var port = GameStreamHTTP.defaultHttpPort
        // "host:port" (but not a bare IPv6 address)
        if let colon = address.lastIndex(of: ":"), address.filter({ $0 == ":" }).count == 1,
           let p = UInt16(address[address.index(after: colon)...]) {
            port = p
            address = String(address[..<colon])
        }
        address = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        let http = GameStreamHTTP(address: address, httpPort: port)
        let info = try await http.serverInfo()

        var record = hosts.first { $0.id == info.uniqueId } ?? HostRecord(id: info.uniqueId, name: info.hostname, address: address)
        record.name = info.hostname
        record.address = address
        record.httpPort = port
        record.httpsPort = info.httpsPort
        record.macAddress = info.macAddress ?? record.macAddress
        upsert(record)
        status[record.id] = .online(paired: record.isPaired && info.paired, currentGame: info.currentGame)
        discovered = discovered.filter { $0.value != address }
        return record
    }

    public func remove(_ host: HostRecord) {
        hosts.removeAll { $0.id == host.id }
        status[host.id] = nil
        apps[host.id] = nil
        save()
    }

    private func upsert(_ record: HostRecord) {
        if let i = hosts.firstIndex(where: { $0.id == record.id }) {
            hosts[i] = record
        } else {
            hosts.append(record)
        }
        save()
    }

    // MARK: Pairing

    public func pair(_ host: HostRecord, pin: String, deviceName: String) async -> PairingResult {
        let http = host.makeHTTP()
        http.serverCertPem = nil
        let info: ServerInfo
        do {
            info = try await http.serverInfo()
        } catch {
            return .failed(error.localizedDescription)
        }
        if info.paired && host.isPaired {
            return .paired(serverCertPem: host.serverCertPem!)
        }
        let result = await Pairing.pair(http: http, serverMajorVersion: info.serverMajorVersion, pin: pin, deviceName: deviceName)
        if case .paired(let cert) = result {
            var updated = host
            updated.serverCertPem = cert
            updated.httpsPort = info.httpsPort
            upsert(updated)
            status[host.id] = .online(paired: true, currentGame: info.currentGame)
        }
        return result
    }

    public func unpair(_ host: HostRecord) async {
        await host.makeHTTP().unpair()
        var updated = host
        updated.serverCertPem = nil
        upsert(updated)
        apps[host.id] = nil
        status[host.id] = .unknown
    }

    // MARK: Status and apps

    public func refresh(_ host: HostRecord) async {
        guard !refreshing.contains(host.id) else { return }
        refreshing.insert(host.id)
        defer { refreshing.remove(host.id) }

        let http = host.makeHTTP()
        do {
            let info = try await http.serverInfo(timeout: 5)
            failures[host.id] = 0
            var record = host
            record.name = info.hostname
            record.httpsPort = info.httpsPort
            record.macAddress = info.macAddress ?? record.macAddress
            if !info.paired && record.isPaired && http.serverCertPem != nil {
                // The host forgot us (or its cert changed). Require pairing again.
                record.serverCertPem = nil
            }
            if record != host { upsert(record) }
            status[host.id] = .online(paired: record.isPaired && info.paired, currentGame: info.currentGame)
        } catch {
            let count = (failures[host.id] ?? 0) + 1
            failures[host.id] = count
            if count >= Self.failuresBeforeOffline || status[host.id] == nil || status[host.id] == .unknown {
                status[host.id] = .offline
            }
        }
    }

    public func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for host in hosts {
                group.addTask { await self.refresh(host) }
            }
        }
    }

    public func loadApps(_ host: HostRecord) async throws {
        let list = try await host.makeHTTP().appList()
        apps[host.id] = list
        for app in list where boxArt["\(host.id)/\(app.id)"] == nil {
            Task {
                if let data = try? await host.makeHTTP().boxArt(appId: app.id), !data.isEmpty {
                    self.boxArt["\(host.id)/\(app.id)"] = data
                }
            }
        }
    }

    public func boxArt(host: HostRecord, app: HostApp) -> Data? {
        boxArt["\(host.id)/\(app.id)"]
    }

    public func quitApp(on host: HostRecord) async throws {
        try await host.makeHTTP().quitApp()
        await refresh(host)
    }

    /// Polls host status every few seconds while the host list is visible.
    public func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if self?.isStreaming == false {
                    await self?.refreshAll()
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        startDiscovery()
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        browser?.cancel()
        browser = nil
    }

    // MARK: Bonjour discovery (_nvstream._tcp, advertised by GFE and Sunshine)

    private func startDiscovery() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_nvstream._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                for result in results {
                    self?.resolve(result.endpoint)
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func resolve(_ endpoint: NWEndpoint) {
        guard case .service(let name, _, _, _) = endpoint, discovered[name] == nil else { return }
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolving.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
                    var address: String
                    switch host {
                    case .ipv4(let ip): address = "\(ip)"
                    case .ipv6(let ip): address = "\(ip)"
                    case .name(let n, _): address = n
                    @unknown default: address = "\(host)"
                    }
                    // Strip any interface scope (e.g. "%en0")
                    if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
                    Task { @MainActor in
                        guard let self else { return }
                        if !self.hosts.contains(where: { $0.address == address || $0.name == name }) {
                            self.discovered[name] = address
                        }
                    }
                }
                connection.cancel()
            case .failed, .cancelled:
                Task { @MainActor in self?.resolving.removeAll { $0 === connection } }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }
}
