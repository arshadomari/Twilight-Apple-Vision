import XCTest
@testable import TwilightKit

final class CryptoTests: XCTestCase {
    func testIdentitySignVerifyRoundTrip() throws {
        let identity = try Crypto.generateIdentity()
        XCTAssertTrue(identity.certPem.contains("BEGIN CERTIFICATE"))
        XCTAssertTrue(identity.keyPem.contains("PRIVATE KEY"))

        let message = Data("twilight".utf8)
        let signature = try Crypto.sign(message, keyPem: identity.keyPem)
        XCTAssertEqual(signature.count, 256)
        XCTAssertTrue(Crypto.verify(message, signature: signature, certPem: identity.certPem))
        XCTAssertFalse(Crypto.verify(Data("tampered".utf8), signature: signature, certPem: identity.certPem))

        // The certificate's own signature must be extractable (used in the pairing hash)
        XCTAssertEqual(try Crypto.certSignature(pem: identity.certPem).count, 256)
        XCTAssertGreaterThan(try Crypto.certDer(fromPem: identity.certPem).count, 500)
        XCTAssertGreaterThan(try Crypto.privateKeyDer(fromPem: identity.keyPem).count, 1000)
    }

    func testCertIsUsableBySecurityFramework() throws {
        let identity = try Crypto.generateIdentity()
        let der = try Crypto.certDer(fromPem: identity.certPem)
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        XCTAssertEqual(SecCertificateCopySubjectSummary(cert) as String?, "NVIDIA GameStream Client")

        let keyDer = try Crypto.privateKeyDer(fromPem: identity.keyPem)
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        XCTAssertNotNil(SecKeyCreateWithData(keyDer as CFData, attrs as CFDictionary, nil))
    }

    func testAesEcbKnownAnswer() throws {
        // FIPS-197 appendix C.1 (AES-128)
        let key = Data(hexString: "000102030405060708090a0b0c0d0e0f")!
        let plain = Data(hexString: "00112233445566778899aabbccddeeff")!
        let cipher = try Crypto.aesEncrypt(plain, key: key)
        XCTAssertEqual(cipher.hexString, "69c4e0d86a7b0430d8cdb78070b4c55a")
        XCTAssertEqual(try Crypto.aesDecrypt(cipher, key: key), plain)
    }

    func testHashes() {
        XCTAssertEqual(Crypto.sha256(Data("abc".utf8)).hexString,
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Crypto.sha1(Data("abc".utf8)).hexString, "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    func testHex() {
        XCTAssertEqual(Data(hexString: "DEADbeef")?.hexString, "deadbeef")
        XCTAssertNil(Data(hexString: "abc"))
        XCTAssertNil(Data(hexString: "zz"))
    }
}

final class VideoTests: XCTestCase {
    func testAnnexBConversion() {
        // 4-byte start code + NAL, 3-byte start code + NAL
        let annexB = Data([0, 0, 0, 1, 0x65, 0xAA, 0xBB, 0, 0, 1, 0x41, 0xCC])
        let avcc = VideoRenderer.annexBToLengthPrefixed(annexB)
        XCTAssertEqual(Array(avcc), [0, 0, 0, 3, 0x65, 0xAA, 0xBB, 0, 0, 0, 2, 0x41, 0xCC])
    }

    func testAnnexBEdgeCases() {
        // 4-byte start codes with trailing zeros before the next code, and a lone 00 00 01 at the end
        let stream = Data([0, 0, 0, 1, 0x40, 0x01, 0, 0, 0, 0, 1, 0x42, 0x01, 0x02, 0, 0, 1])
        XCTAssertEqual(Array(VideoRenderer.annexBToLengthPrefixed(stream)),
                       [0, 0, 0, 2, 0x40, 0x01, 0, 0, 0, 3, 0x42, 0x01, 0x02])
        // Emulation-prevented payload (00 00 03) must not be split
        let epb = Data([0, 0, 1, 0x26, 0, 0, 3, 1, 0x80])
        XCTAssertEqual(Array(VideoRenderer.annexBToLengthPrefixed(epb)), [0, 0, 0, 6, 0x26, 0, 0, 3, 1, 0x80])
        // No start code: the whole buffer is one NAL unit
        XCTAssertEqual(Array(VideoRenderer.annexBToLengthPrefixed(Data([0x65, 0x88]))), [0, 0, 0, 2, 0x65, 0x88])
        XCTAssertTrue(VideoRenderer.annexBToLengthPrefixed(Data()).isEmpty)
    }

    func testAnnexBLargeFrame() {
        // A 2 MB frame of random payload split into slices, as at high bitrates
        var frame = Data()
        var expected = Data()
        for slice in 0..<8 {
            var payload = Data((0..<(256 * 1024)).map { _ in UInt8.random(in: 2...255) })
            payload[0] = 0x26
            payload[payload.count - 1] = UInt8(slice + 1)
            frame.append(contentsOf: slice == 0 ? [0, 0, 0, 1] : [0, 0, 1])
            frame.append(payload)
            var len = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: &len) { expected.append(contentsOf: $0) }
            expected.append(payload)
        }
        measure {
            XCTAssertEqual(VideoRenderer.annexBToLengthPrefixed(frame), expected)
        }
    }

    func testStripStartCode() {
        let sps = Data([0, 0, 0, 1, 0x67, 0x42])
        sps.withUnsafeBytes { XCTAssertEqual(Array(VideoRenderer.stripStartCode($0)), [0x67, 0x42]) }
    }
}

final class SettingsTests: XCTestCase {
    func testDefaultBitrateMatchesTwilight() {
        XCTAssertEqual(StreamSettings.defaultBitrate(width: 1920, height: 1080, fps: 60), 20_000)
        XCTAssertEqual(StreamSettings.defaultBitrate(width: 1280, height: 720, fps: 60), 10_000)
        XCTAssertEqual(StreamSettings.defaultBitrate(width: 3840, height: 2160, fps: 60), 80_000)
    }

    func testAudioConfiguration() {
        // AUDIO_CONFIGURATION_STEREO = MAKE_AUDIO_CONFIGURATION(2, 0x3)
        XCTAssertEqual(AudioChannelPreference.stereo.audioConfiguration, (0x3 << 16) | (2 << 8) | 0xCA)
        XCTAssertEqual(AudioChannelPreference.surround51.surroundAudioInfo, (0x3F << 16) | 6)
    }

    func testVirtualKeys() {
        XCTAssertEqual(InputManager.virtualKey(forHidUsage: 0x04), 0x41) // A
        XCTAssertEqual(InputManager.virtualKey(forHidUsage: 0x27), 0x30) // 0
        XCTAssertEqual(InputManager.virtualKey(forHidUsage: 0x3A), 0x70) // F1
        XCTAssertEqual(InputManager.virtualKey(forHidUsage: 0xE1), 0xA0) // Left Shift
    }
}

final class XMLTests: XCTestCase {
    func testAppListParsing() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <root status_code="200"><App><IsHdrSupported>1</IsHdrSupported><AppTitle>Desktop</AppTitle><ID>881448767</ID></App>
        <App><AppTitle>Steam Big Picture</AppTitle><ID>1093255277</ID></App></root>
        """
        let root = try XCTUnwrap(XMLNode.parse(Data(xml.utf8)))
        XCTAssertNoThrow(try GameStreamHTTP.verifyStatus(root))
        let apps = root.all("App")
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps[0].string("AppTitle"), "Desktop")
        XCTAssertEqual(apps[1].string("ID"), "1093255277")
    }

    func testErrorStatus() throws {
        let root = try XCTUnwrap(XMLNode.parse(Data(#"<root status_code="401" status_message="The client is not authorized"/>"#.utf8)))
        XCTAssertThrowsError(try GameStreamHTTP.verifyStatus(root)) { error in
            guard case GameStreamError.status(let code, _) = error else { return XCTFail() }
            XCTAssertEqual(code, 401)
        }
    }
}

final class HTTPTests: XCTestCase {
    func testTransientErrors() {
        XCTAssertTrue(GameStreamHTTP.isTransient(GameStreamError.network(URLError(.timedOut))))
        XCTAssertTrue(GameStreamHTTP.isTransient(GameStreamError.network(URLError(.networkConnectionLost))))
        XCTAssertFalse(GameStreamHTTP.isTransient(GameStreamError.status(code: 401, message: "")))
        XCTAssertFalse(GameStreamHTTP.isTransient(GameStreamError.certificateMismatch))
    }

    func testServerInfoRetriesThenFails() async {
        // Nothing listens on this port, so every attempt fails fast with a transient error
        let http = GameStreamHTTP(address: "127.0.0.1", httpPort: 9)
        let start = Date()
        do {
            _ = try await http.serverInfo(timeout: 2, retries: 2)
            XCTFail("Expected failure")
        } catch {
            XCTAssertTrue(GameStreamHTTP.isTransient(error), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
