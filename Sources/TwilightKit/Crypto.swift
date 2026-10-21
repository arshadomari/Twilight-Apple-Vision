import Foundation
import TwilightKitC

public enum CryptoError: Error, LocalizedError {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let what): return "Crypto operation failed: \(what)"
        }
    }
}

/// Swift wrappers over the mbedTLS-backed primitives in TwCrypto.c.
enum Crypto {
    private static let initialized: Bool = {
        TwilightLog.installCoreHandler()
        return TwCryptoInit() == 0
    }()

    static func ensureInitialized() throws {
        guard initialized else { throw CryptoError.failed("psa_crypto_init") }
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { _ = TwRandomBytes($0.baseAddress!.assumingMemoryBound(to: UInt8.self), count) }
        return data
    }

    static func generateIdentity() throws -> (certPem: String, keyPem: String) {
        try ensureInitialized()
        var cert = [CChar](repeating: 0, count: 8192)
        var key = [CChar](repeating: 0, count: 8192)
        guard TwGenerateIdentity(&cert, cert.count, &key, key.count) == 0 else {
            throw CryptoError.failed("generate identity")
        }
        return (String(cString: cert), String(cString: key))
    }

    static func privateKeyDer(fromPem pem: String) throws -> Data {
        try withOutput(capacity: 4096, "private key DER") { TwPrivateKeyPemToDer(pem, $0, $1) }
    }

    static func certDer(fromPem pem: String) throws -> Data {
        try withOutput(capacity: 8192, "certificate DER") { TwCertPemToDer(pem, $0, $1) }
    }

    static func certSignature(pem: String) throws -> Data {
        try withOutput(capacity: 1024, "certificate signature") { TwCertSignature(pem, $0, $1) }
    }

    static func sha256(_ data: Data) -> Data {
        var out = Data(count: 32)
        data.withUnsafeBytes { input in
            out.withUnsafeMutableBytes { _ = TwSha256(input.bindMemory(to: UInt8.self).baseAddress, data.count, $0.bindMemory(to: UInt8.self).baseAddress) }
        }
        return out
    }

    static func sha1(_ data: Data) -> Data {
        var out = Data(count: 20)
        data.withUnsafeBytes { input in
            out.withUnsafeMutableBytes { _ = TwSha1(input.bindMemory(to: UInt8.self).baseAddress, data.count, $0.bindMemory(to: UInt8.self).baseAddress) }
        }
        return out
    }

    static func aesEncrypt(_ data: Data, key: Data) throws -> Data {
        try aes(data, key: key, encrypt: true)
    }

    static func aesDecrypt(_ data: Data, key: Data) throws -> Data {
        try aes(data, key: key, encrypt: false)
    }

    private static func aes(_ data: Data, key: Data, encrypt: Bool) throws -> Data {
        guard key.count == 16, data.count % 16 == 0 else { throw CryptoError.failed("AES input size") }
        var out = Data(count: data.count)
        let ret = key.withUnsafeBytes { k in
            data.withUnsafeBytes { i in
                out.withUnsafeMutableBytes { o in
                    let kp = k.bindMemory(to: UInt8.self).baseAddress
                    let ip = i.bindMemory(to: UInt8.self).baseAddress
                    let op = o.bindMemory(to: UInt8.self).baseAddress
                    return encrypt ? TwAes128EcbEncrypt(kp, ip, data.count, op) : TwAes128EcbDecrypt(kp, ip, data.count, op)
                }
            }
        }
        guard ret == 0 else { throw CryptoError.failed("AES") }
        return out
    }

    static func sign(_ data: Data, keyPem: String) throws -> Data {
        try withOutput(capacity: 1024, "sign") { out, cap in
            data.withUnsafeBytes { TwSignSha256(keyPem, $0.bindMemory(to: UInt8.self).baseAddress, data.count, out, cap) }
        }
    }

    static func verify(_ data: Data, signature: Data, certPem: String) -> Bool {
        data.withUnsafeBytes { d in
            signature.withUnsafeBytes { s in
                TwVerifySha256(certPem, d.bindMemory(to: UInt8.self).baseAddress, data.count,
                               s.bindMemory(to: UInt8.self).baseAddress, signature.count)
            }
        }
    }

    private static func withOutput(capacity: Int, _ what: String, _ body: (UnsafeMutablePointer<UInt8>, Int) -> Int32) throws -> Data {
        try ensureInitialized()
        var buffer = [UInt8](repeating: 0, count: capacity)
        let length = buffer.withUnsafeMutableBufferPointer { body($0.baseAddress!, capacity) }
        guard length > 0 else { throw CryptoError.failed(what) }
        return Data(buffer[0..<Int(length)])
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }
}
