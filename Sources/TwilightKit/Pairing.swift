import Foundation

public enum PairingResult: Sendable {
    /// Paired successfully. Contains the host certificate (PEM) to pin.
    case paired(serverCertPem: String)
    case wrongPin
    case alreadyInProgress
    case failed(String)
}

/// The GameStream PIN pairing handshake. A direct port of Twilight's NvPairingManager::pair().
public enum Pairing {
    /// Generates a random 4-digit PIN for the user to enter on the host.
    public static func generatePin() -> String {
        String(format: "%04u", arc4random_uniform(10000))
    }

    public static func pair(http: GameStreamHTTP, serverMajorVersion: Int, pin: String, deviceName: String) async -> PairingResult {
        do {
            return try await pairThrowing(http: http, serverMajorVersion: serverMajorVersion, pin: pin, deviceName: deviceName)
        } catch {
            await http.unpair()
            return .failed(error.localizedDescription)
        }
    }

    private static func pairThrowing(http: GameStreamHTTP, serverMajorVersion: Int, pin: String, deviceName: String) async throws -> PairingResult {
        let identity = ClientIdentity.shared
        let pairingArgs = "devicename=" + (deviceName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "Vision")

        // Gen 7+ servers use SHA-256, older ones SHA-1
        let hash: (Data) -> Data = serverMajorVersion >= 7 ? Crypto.sha256 : Crypto.sha1
        let hashLength = serverMajorVersion >= 7 ? 32 : 20

        let salt = Crypto.randomBytes(16)
        let aesKey = hash(salt + Data(pin.utf8)).prefix(16)

        // Stage 1: exchange certificates. This blocks until the user enters the PIN on the host.
        let getCert = try await http.request(
            https: false, command: "pair",
            query: pairingArgs + "&updateState=1&phrase=getservercert&salt=\(salt.hexString)&clientcert=\(Data(identity.certPem.utf8).hexString)",
            timeout: 300)
        guard getCert.string("paired") == "1" else {
            return .failed("The host rejected pairing.")
        }
        guard let plainCertHex = getCert.string("plaincert"), !plainCertHex.isEmpty,
              let plainCert = Data(hexString: plainCertHex),
              let serverCertPem = String(data: plainCert, encoding: .utf8) else {
            await http.unpair()
            return .alreadyInProgress
        }
        guard (try? Crypto.certDer(fromPem: serverCertPem)) != nil else {
            await http.unpair()
            return .failed("The host sent an unreadable certificate.")
        }

        // Pin this cert for TLS until pairing completes
        http.serverCertPem = serverCertPem

        // Stage 2: send our encrypted challenge
        let randomChallenge = Crypto.randomBytes(16)
        let encryptedChallenge = try Crypto.aesEncrypt(randomChallenge, key: aesKey)
        let challengeXml = try await http.request(
            https: false, command: "pair",
            query: pairingArgs + "&updateState=1&clientchallenge=\(encryptedChallenge.hexString)")
        guard challengeXml.string("paired") == "1",
              let challengeResponseHex = challengeXml.string("challengeresponse"),
              let challengeResponseEnc = Data(hexString: challengeResponseHex) else {
            await http.unpair()
            return .failed("Pairing failed at stage 2.")
        }
        let challengeResponseData = try Crypto.aesDecrypt(challengeResponseEnc, key: aesKey)
        guard challengeResponseData.count >= hashLength + 16 else {
            await http.unpair()
            return .failed("Invalid challenge response.")
        }

        // Stage 3: respond to the server's challenge
        let clientSecret = Crypto.randomBytes(16)
        let serverResponse = challengeResponseData.prefix(hashLength)
        var challengeResponse = Data(challengeResponseData[challengeResponseData.startIndex + hashLength ..< challengeResponseData.startIndex + hashLength + 16])
        challengeResponse.append(try Crypto.certSignature(pem: identity.certPem))
        challengeResponse.append(clientSecret)

        var paddedHash = hash(challengeResponse)
        paddedHash.append(Data(count: 32 - paddedHash.count))
        let encryptedResponseHash = try Crypto.aesEncrypt(paddedHash, key: aesKey)
        let respXml = try await http.request(
            https: false, command: "pair",
            query: pairingArgs + "&updateState=1&serverchallengeresp=\(encryptedResponseHash.hexString)")
        guard respXml.string("paired") == "1",
              let pairingSecretHex = respXml.string("pairingsecret"),
              let pairingSecret = Data(hexString: pairingSecretHex), pairingSecret.count > 16 else {
            await http.unpair()
            return .failed("Pairing failed at stage 3.")
        }

        let serverSecret = pairingSecret.prefix(16)
        let serverSignature = pairingSecret.dropFirst(16)
        guard Crypto.verify(Data(serverSecret), signature: Data(serverSignature), certPem: serverCertPem) else {
            await http.unpair()
            return .failed("The host's signature didn't verify. Someone may be intercepting the connection.")
        }

        var expected = randomChallenge
        expected.append(try Crypto.certSignature(pem: serverCertPem))
        expected.append(serverSecret)
        guard hash(expected) == Data(serverResponse) else {
            await http.unpair()
            return .wrongPin
        }

        // Stage 4: send our signed secret
        var clientPairingSecret = clientSecret
        clientPairingSecret.append(try Crypto.sign(clientSecret, keyPem: identity.keyPem))
        let secretXml = try await http.request(
            https: false, command: "pair",
            query: pairingArgs + "&updateState=1&clientpairingsecret=\(clientPairingSecret.hexString)")
        guard secretXml.string("paired") == "1" else {
            await http.unpair()
            return .failed("Pairing failed at stage 4.")
        }

        // Stage 5: confirm over HTTPS with our client certificate
        let challenge = try await http.request(https: true, command: "pair", query: pairingArgs + "&updateState=1&phrase=pairchallenge")
        guard challenge.string("paired") == "1" else {
            await http.unpair()
            return .failed("Pairing failed at stage 5.")
        }

        return .paired(serverCertPem: serverCertPem)
    }
}
