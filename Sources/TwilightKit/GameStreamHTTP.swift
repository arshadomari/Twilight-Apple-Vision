import Foundation
import Security

public enum GameStreamError: Error, LocalizedError {
    case status(code: Int, message: String)
    case malformedResponse
    case network(Error)
    case certificateMismatch
    case notPaired

    public var errorDescription: String? {
        switch self {
        case .status(let code, let message):
            return message.isEmpty ? "The host returned error \(code)." : "\(message) (\(code))"
        case .malformedResponse:
            return "The host sent a response Twilight couldn't read."
        case .network(let error):
            return error.localizedDescription
        case .certificateMismatch:
            return "The host's certificate changed. Pair again."
        case .notPaired:
            return "This device isn't paired with the host."
        }
    }
}

/// Parsed /serverinfo response.
public struct ServerInfo: Sendable {
    public var hostname: String
    public var uniqueId: String
    public var macAddress: String?
    public var httpsPort: UInt16
    public var appVersion: String
    public var gfeVersion: String?
    public var paired: Bool
    public var currentGame: Int
    public var serverCodecModeSupport: Int32
    public var maxLumaPixelsHEVC: Int
    public var displayModes: [(width: Int, height: Int, refresh: Int)]

    /// GeForce Experience reports a "MJOLNIR" state; Sunshine and its forks don't.
    public var isNvidiaSoftware: Bool

    init(_ xml: XMLNode) throws {
        guard let uid = xml.string("uniqueid") else { throw GameStreamError.malformedResponse }
        hostname = xml.string("hostname") ?? "Host"
        uniqueId = uid
        let mac = xml.string("mac")
        macAddress = (mac == nil || mac == "00:00:00:00:00:00") ? nil : mac
        httpsPort = UInt16(xml.string("HttpsPort") ?? "") ?? 47984
        appVersion = xml.string("appversion") ?? ""
        gfeVersion = xml.string("GfeVersion")
        paired = xml.string("PairStatus") == "1"
        let state = xml.string("state") ?? ""
        isNvidiaSoftware = state.contains("MJOLNIR")
        currentGame = state.hasSuffix("_SERVER_BUSY") ? (Int(xml.string("currentgame") ?? "") ?? 0) : 0
        serverCodecModeSupport = Int32(truncatingIfNeeded: Int64(xml.string("ServerCodecModeSupport") ?? "") ?? 0)
        maxLumaPixelsHEVC = Int(xml.string("MaxLumaPixelsHEVC") ?? "") ?? 0
        displayModes = xml.all("DisplayMode").compactMap { node in
            guard let w = Int(node.string("Width") ?? ""), let h = Int(node.string("Height") ?? "") else { return nil }
            return (w, h, Int(node.string("RefreshRate") ?? "") ?? 60)
        }
    }

    /// The server generation, from the first component of appversion (7+ uses SHA-256 pairing).
    public var serverMajorVersion: Int {
        Int(appVersion.split(separator: ".").first ?? "") ?? 0
    }
}

public struct HostApp: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var hdrSupported: Bool
}

/// HTTP(S) client for one GameStream host. Equivalent to Twilight's NvHTTP.
public final class GameStreamHTTP: NSObject, URLSessionDelegate, @unchecked Sendable {
    public static let defaultHttpPort: UInt16 = 47989

    public let address: String
    public let httpPort: UInt16
    public var httpsPort: UInt16
    /// The pinned host certificate (PEM). Required for HTTPS requests.
    public var serverCertPem: String?
    /// Sunshine accepts the true unique ID; GFE wants a fixed placeholder.
    public var useTrueUid = true

    private var pinnedCertDer: Data? {
        serverCertPem.flatMap { try? Crypto.certDer(fromPem: $0) }
    }

    public init(address: String, httpPort: UInt16 = GameStreamHTTP.defaultHttpPort, httpsPort: UInt16 = 47984, serverCertPem: String? = nil) {
        self.address = address
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.serverCertPem = serverCertPem
    }

    // MARK: Requests

    func url(https: Bool, command: String, query: String?) -> URL {
        let host = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
        let uid = useTrueUid ? ClientIdentity.shared.uniqueId : "0123456789ABCDEF"
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var string = "\(https ? "https" : "http")://\(host):\(https ? httpsPort : httpPort)/\(command)?uniqueid=\(uid)&uuid=\(uuid)"
        if let query, !query.isEmpty {
            string += "&" + query
        }
        return URL(string: string)!
    }

    func rawRequest(https: Bool, command: String, query: String? = nil, timeout: TimeInterval = 5) async throws -> Data {
        if https && serverCertPem == nil {
            throw GameStreamError.notPaired
        }
        var request = URLRequest(url: url(https: https, command: command, query: query), timeoutInterval: timeout)
        // GFE doesn't like persistent connections
        request.setValue("close", forHTTPHeaderField: "Connection")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpMaximumConnectionsPerHost = 1
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, _) = try await session.data(for: request)
            return data
        } catch let error as URLError where error.code == .serverCertificateUntrusted || error.code == .secureConnectionFailed
                    || error.code == .serverCertificateHasUnknownRoot || error.code == .cancelled && https {
            throw GameStreamError.certificateMismatch
        } catch {
            throw GameStreamError.network(error)
        }
    }

    func request(https: Bool, command: String, query: String? = nil, timeout: TimeInterval = 5) async throws -> XMLNode {
        let data = try await rawRequest(https: https, command: command, query: query, timeout: timeout)
        guard let xml = XMLNode.parse(data) else { throw GameStreamError.malformedResponse }
        try Self.verifyStatus(xml)
        return xml
    }

    static func verifyStatus(_ xml: XMLNode) throws {
        guard xml.name == "root" else { throw GameStreamError.malformedResponse }
        let code = Int(Int32(truncatingIfNeeded: UInt32(xml.attributes["status_code"] ?? "") ?? 0))
        if code == 200 { return }
        var message = xml.attributes["status_message"] ?? ""
        var finalCode = code
        if code == -1 && message == "Invalid" {
            finalCode = 418
            message = "Missing audio capture device on the host."
        }
        throw GameStreamError.status(code: finalCode, message: message)
    }

    // MARK: API

    /// Fetches /serverinfo, preferring HTTPS when a cert is pinned so PairStatus is accurate.
    public func serverInfo(timeout: TimeInterval = 5, retries: Int = 0) async throws -> ServerInfo {
        var attempt = 0
        while true {
            do {
                return try await serverInfoOnce(timeout: timeout)
            } catch let error where attempt < retries && Self.isTransient(error) {
                // Hosts can be slow to answer while busy (e.g. starting a stream); try again
                attempt += 1
                TwilightLog.info("serverinfo timed out; retrying (\(attempt)/\(retries))")
            }
        }
    }

    private func serverInfoOnce(timeout: TimeInterval) async throws -> ServerInfo {
        if serverCertPem != nil {
            do {
                return try ServerInfo(try await request(https: true, command: "serverinfo", timeout: timeout))
            } catch GameStreamError.status(code: 401, _), GameStreamError.certificateMismatch {
                // Fall back to HTTP; the host will report PairStatus 0
            }
        }
        let info = try ServerInfo(try await request(https: false, command: "serverinfo", timeout: timeout))
        httpsPort = info.httpsPort
        return info
    }

    /// Timeouts and dropped connections, which are worth retrying (unlike HTTP errors).
    static func isTransient(_ error: Error) -> Bool {
        guard case GameStreamError.network(let underlying) = error, let urlError = underlying as? URLError else {
            return false
        }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(urlError.code)
    }

    public func appList() async throws -> [HostApp] {
        let xml = try await request(https: true, command: "applist")
        return xml.all("App").map { app in
            HostApp(id: Int(app.string("ID") ?? "") ?? 0,
                    name: app.string("AppTitle") ?? "",
                    hdrSupported: app.string("IsHdrSupported") == "1")
        }
    }

    public func boxArt(appId: Int) async throws -> Data {
        try await rawRequest(https: true, command: "appasset", query: "appid=\(appId)&AssetType=2&AssetIdx=0", timeout: 10)
    }

    /// Launches or resumes an app. Returns the RTSP session URL if the host supplied one.
    func startApp(resume: Bool, appId: Int, query: String) async throws -> String? {
        let xml = try await request(https: true,
                                    command: resume ? "resume" : "launch",
                                    query: "appid=\(appId)&" + query,
                                    timeout: resume ? 30 : 120)
        if !resume, xml.string("gamesession") == "0" {
            throw GameStreamError.status(code: 0, message: "The host failed to start the app.")
        }
        return xml.string("sessionUrl0")
    }

    public func quitApp() async throws {
        _ = try await request(https: true, command: "cancel", timeout: 30)
        if try await serverInfo().currentGame != 0 {
            throw GameStreamError.status(code: 599, message: "Another device started this session, so it can't be quit from here.")
        }
    }

    public func unpair() async {
        _ = try? await rawRequest(https: false, command: "unpair")
    }

    // MARK: URLSessionDelegate

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            do {
                let identity = try ClientIdentity.shared.secIdentity()
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } catch {
                TwilightLog.error("Client identity unavailable: \(error)")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }

        case NSURLAuthenticationMethodServerTrust:
            // GameStream hosts use self-signed certificates. Accept only the exact cert we pinned at pairing.
            guard let trust = challenge.protectionSpace.serverTrust,
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first,
                  let pinned = pinnedCertDer,
                  SecCertificateCopyData(leaf) as Data == pinned else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
