import Foundation
import Security

/// The client certificate, private key and unique ID this device presents to GameStream hosts.
/// Equivalent to Twilight's IdentityManager.
public final class ClientIdentity: @unchecked Sendable {
    public static let shared = ClientIdentity()

    public let certPem: String
    public let keyPem: String
    public let uniqueId: String

    private let lock = NSLock()
    private var cachedIdentity: SecIdentity?

    private static let keychainService = "com.twilight.vision.identity"
    private static let keyTag = Data("com.twilight.vision.clientkey".utf8)
    private static let certLabel = "Twilight Vision Client Certificate"

    private init() {
        let defaults = UserDefaults.standard
        if let cert = defaults.string(forKey: "Twilight.ClientCert"),
           let key = ClientIdentity.loadKeyPem(),
           let uid = defaults.string(forKey: "Twilight.UniqueId"),
           (try? Crypto.certDer(fromPem: cert)) != nil {
            certPem = cert
            keyPem = key
            uniqueId = uid
            return
        }

        TwilightLog.info("Generating a new client identity")
        let generated: (certPem: String, keyPem: String)
        do {
            generated = try Crypto.generateIdentity()
        } catch {
            fatalError("Unable to generate client identity: \(error)")
        }
        var uid: UInt64 = 0
        withUnsafeMutableBytes(of: &uid) { arc4random_buf($0.baseAddress, 8) }

        certPem = generated.certPem
        keyPem = generated.keyPem
        uniqueId = String(uid, radix: 16)

        ClientIdentity.storeKeyPem(keyPem)
        defaults.set(certPem, forKey: "Twilight.ClientCert")
        defaults.set(uniqueId, forKey: "Twilight.UniqueId")
        ClientIdentity.removeKeychainIdentity()
    }

    /// Returns a SecIdentity for TLS client authentication, importing the key and certificate
    /// into the Keychain the first time it's needed.
    public func secIdentity() throws -> SecIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let cachedIdentity { return cachedIdentity }

        if let identity = Self.findIdentity() {
            cachedIdentity = identity
            return identity
        }

        Self.removeKeychainIdentity()

        let keyDer = try Crypto.privateKeyDer(fromPem: keyPem)
        let keyAttrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(keyDer as CFData, keyAttrs as CFDictionary, &error) else {
            throw CryptoError.failed("SecKeyCreateWithData: \(error!.takeRetainedValue())")
        }
        var status = SecItemAdd([
            kSecClass: kSecClassKey,
            kSecValueRef: secKey,
            kSecAttrApplicationTag: Self.keyTag,
            kSecAttrIsPermanent: true,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw CryptoError.failed("Keychain key import (\(status))")
        }

        let certDer = try Crypto.certDer(fromPem: certPem)
        guard let secCert = SecCertificateCreateWithData(nil, certDer as CFData) else {
            throw CryptoError.failed("SecCertificateCreateWithData")
        }
        status = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: secCert,
            kSecAttrLabel: Self.certLabel,
        ] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw CryptoError.failed("Keychain certificate import (\(status))")
        }

        guard let identity = Self.findIdentity() else {
            throw CryptoError.failed("Keychain identity lookup")
        }
        cachedIdentity = identity
        return identity
    }

    private static func findIdentity() -> SecIdentity? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: certLabel,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let result else { return nil }
        return (result as! SecIdentity)
    }

    private static func removeKeychainIdentity() {
        SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: keyTag] as CFDictionary)
        SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: certLabel] as CFDictionary)
    }

    private static func loadKeyPem() -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: "privateKeyPem",
            kSecReturnData: true,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func storeKeyPem(_ pem: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: "privateKeyPem",
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData] = Data(pem.utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            TwilightLog.error("Unable to store private key in Keychain: \(status)")
        }
    }
}
