import XCTest
import CoreMedia
import TwilightKitC
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

final class AV1Tests: XCTestCase {
    /// Writes values MSB-first, as AV1's f(n) descriptor reads them.
    private struct BitWriter {
        var bytes: [UInt8] = []
        var bitCount = 0
        mutating func write(_ value: UInt32, _ bits: Int) {
            for i in stride(from: bits - 1, through: 0, by: -1) {
                if bitCount % 8 == 0 { bytes.append(0) }
                if (value >> UInt32(i)) & 1 == 1 { bytes[bytes.count - 1] |= UInt8(0x80 >> (bitCount % 8)) }
                bitCount += 1
            }
        }
    }

    /// A Main-profile sequence header: 2560x1440, 10-bit, BT.2020 PQ (HDR), limited range, level 13.
    private func sequenceHeaderOBU() -> [UInt8] {
        var w = BitWriter()
        w.write(0, 3)        // seq_profile
        w.write(0, 1)        // still_picture
        w.write(0, 1)        // reduced_still_picture_header
        w.write(0, 1)        // timing_info_present_flag
        w.write(0, 1)        // initial_display_delay_present_flag
        w.write(0, 5)        // operating_points_cnt_minus_1
        w.write(0, 12)       // operating_point_idc[0]
        w.write(13, 5)       // seq_level_idx[0]
        w.write(0, 1)        // seq_tier[0] (level > 7)
        w.write(11, 4)       // frame_width_bits_minus_1
        w.write(10, 4)       // frame_height_bits_minus_1
        w.write(2559, 12)    // max_frame_width_minus_1
        w.write(1439, 11)    // max_frame_height_minus_1
        w.write(0, 1)        // frame_id_numbers_present_flag
        w.write(0, 1)        // use_128x128_superblock
        w.write(1, 1)        // enable_filter_intra
        w.write(1, 1)        // enable_intra_edge_filter
        w.write(0, 1)        // enable_interintra_compound
        w.write(0, 1)        // enable_masked_compound
        w.write(0, 1)        // enable_warped_motion
        w.write(0, 1)        // enable_dual_filter
        w.write(1, 1)        // enable_order_hint
        w.write(0, 1)        // enable_jnt_comp
        w.write(0, 1)        // enable_ref_frame_mvs
        w.write(1, 1)        // seq_choose_screen_content_tools
        w.write(1, 1)        // seq_choose_integer_mv
        w.write(6, 3)        // order_hint_bits_minus_1
        w.write(0, 1)        // enable_superres
        w.write(1, 1)        // enable_cdef
        w.write(1, 1)        // enable_restoration
        w.write(1, 1)        // high_bitdepth
        w.write(0, 1)        // mono_chrome
        w.write(1, 1)        // color_description_present_flag
        w.write(9, 8)        // color_primaries: BT.2020
        w.write(16, 8)       // transfer_characteristics: PQ
        w.write(9, 8)        // matrix_coefficients: BT.2020 NCL
        w.write(0, 1)        // color_range: limited
        w.write(0, 2)        // chroma_sample_position
        w.write(0, 1)        // separate_uv_delta_q
        w.write(1, 1)        // trailing_one_bit
        let payload = w.bytes
        return [0x0A, UInt8(payload.count)] + payload  // OBU_SEQUENCE_HEADER with size field
    }

    func testSequenceHeaderAndAv1C() throws {
        let sequenceHeader = sequenceHeaderOBU()
        let temporalUnit: [UInt8] = [0x12, 0x00] + sequenceHeader + [0x32, 0x03, 0xAA, 0xBB, 0xCC]

        var info = TwAV1Info()
        var config = [UInt8](repeating: 0, count: 256)
        let length = TwAV1ParseSequenceHeader(temporalUnit, temporalUnit.count, &info, &config, config.count)
        XCTAssertEqual(Int(length), 4 + sequenceHeader.count)
        XCTAssertEqual(info.width, 2560)
        XCTAssertEqual(info.height, 1440)
        XCTAssertEqual(info.bitDepth, 10)
        XCTAssertEqual(info.colorPrimaries, 9)
        XCTAssertEqual(info.transferCharacteristics, 16)
        XCTAssertEqual(info.matrixCoefficients, 9)
        XCTAssertFalse(info.fullRange)

        // marker/version, profile 0 + level 13, 10-bit 4:2:0, no presentation delay, then the OBU
        XCTAssertEqual(Array(config[0..<4]), [0x81, 0x0D, 0x4C, 0x00])
        XCTAssertEqual(Array(config[4..<Int(length)]), sequenceHeader)

        // Temporal delimiter removed, everything else kept byte for byte
        let strippedLength = TwAV1StripTemporalDelimiters(temporalUnit, temporalUnit.count, nil)
        var stripped = [UInt8](repeating: 0, count: strippedLength)
        XCTAssertEqual(TwAV1StripTemporalDelimiters(temporalUnit, temporalUnit.count, &stripped), strippedLength)
        XCTAssertEqual(stripped, sequenceHeader + [0x32, 0x03, 0xAA, 0xBB, 0xCC])

        // The format description VideoToolbox will decode with, including HDR colour tags
        let description = try XCTUnwrap(VideoRenderer.makeAV1FormatDescription(config: Data(config[0..<Int(length)]), info: info))
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_AV1)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(description).width, 2560)
        XCTAssertTrue(VideoRenderer.isHDR(description))
        XCTAssertEqual(VideoRenderer.describeColor(description), "10-bit · BT.2020 · PQ (HDR) · limited range")
    }

    func testNoSequenceHeaderAndMalformedData() {
        var info = TwAV1Info()
        var config = [UInt8](repeating: 0, count: 64)
        // A temporal delimiter and a frame OBU, but no sequence header (an ordinary inter frame)
        let interFrame: [UInt8] = [0x12, 0x00, 0x32, 0x02, 0x01, 0x02]
        XCTAssertEqual(TwAV1ParseSequenceHeader(interFrame, interFrame.count, &info, &config, config.count), 0)
        // An OBU claiming more payload than there is
        let truncated: [UInt8] = [0x0A, 0x40, 0x00]
        XCTAssertEqual(TwAV1ParseSequenceHeader(truncated, truncated.count, &info, &config, config.count), -1)
        // A sequence header too big for the output buffer
        let header = sequenceHeaderOBU()
        XCTAssertEqual(TwAV1ParseSequenceHeader(header, header.count, &info, &config, 8), -1)
    }
}
