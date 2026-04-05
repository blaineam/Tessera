//
//  TesseraTests.swift
//  TesseraTests
//

import XCTest
@testable import Tessera

final class TesseraTests: XCTestCase {

    // MARK: - License Key Parsing

    func testValidKeyParsing() throws {
        // A syntactically valid key (signature won't verify without matching keypair)
        let payload = #"{"lid":"test-123","iat":1712300000,"exp":0,"tier":"pro","feat":0,"v":1}"#
        let payloadB64 = Data(payload.utf8).base64URLEncodedString()
        let fakeSignature = Data(repeating: 0, count: 64).base64URLEncodedString()

        let rawKey = "TESS-\(payloadB64).\(fakeSignature)"
        let parsed = try TesseraLicenseKey(rawKey: rawKey)

        XCTAssertEqual(parsed.payloadData, Data(payload.utf8))
        XCTAssertEqual(parsed.signatureData.count, 64)
    }

    func testInvalidKeyPrefix() {
        XCTAssertThrowsError(try TesseraLicenseKey(rawKey: "INVALID-abcdef.ghijkl")) { error in
            XCTAssertEqual(error as? TesseraError, .invalidKeyFormat)
        }
    }

    func testMissingSeparator() {
        let payload = Data("test".utf8).base64URLEncodedString()
        XCTAssertThrowsError(try TesseraLicenseKey(rawKey: "TESS-\(payload)")) { error in
            XCTAssertEqual(error as? TesseraError, .invalidKeyFormat)
        }
    }

    // MARK: - License Model

    func testPerpetualLicense() {
        let license = TesseraLicense(
            lid: "test", iat: 1712300000, exp: 0, tier: "pro", feat: 0, v: 1
        )
        XCTAssertTrue(license.isPerpetual)
        XCTAssertFalse(license.isExpired)
        XCTAssertNil(license.expirationDate)
    }

    func testExpiredLicense() {
        let license = TesseraLicense(
            lid: "test", iat: 1712300000, exp: 1712300001, tier: "pro", feat: 0, v: 1
        )
        XCTAssertFalse(license.isPerpetual)
        XCTAssertTrue(license.isExpired)
        XCTAssertNotNil(license.expirationDate)
    }

    func testFutureLicense() {
        let futureExp = Date().timeIntervalSince1970 + 86400 * 365
        let license = TesseraLicense(
            lid: "test", iat: 1712300000, exp: futureExp, tier: "pro", feat: 0, v: 1
        )
        XCTAssertFalse(license.isExpired)
    }

    func testFeatureFlags() {
        let license = TesseraLicense(
            lid: "test", iat: 1712300000, exp: 0, tier: "pro", feat: 0b1010, v: 1
        )
        XCTAssertTrue(license.hasFeature(0b0010))
        XCTAssertTrue(license.hasFeature(0b1000))
        XCTAssertFalse(license.hasFeature(0b0001))
        XCTAssertFalse(license.hasFeature(0b0100))
    }

    // MARK: - Base64URL

    func testBase64URLRoundtrip() {
        let original = Data("Hello, Tessera! 🔑".utf8)
        let encoded = original.base64URLEncodedString()

        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))

        let decoded = Data(base64URLEncoded: encoded)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - License State

    func testStateIsUnlocked() {
        let license = TesseraLicense(
            lid: "test", iat: 1712300000, exp: 0, tier: "pro", feat: 0, v: 1
        )

        XCTAssertTrue(TesseraState.licensed(license).isUnlocked)
        XCTAssertTrue(TesseraState.trial(daysRemaining: 7).isUnlocked)
        XCTAssertFalse(TesseraState.trialExpired.isUnlocked)
        XCTAssertFalse(TesseraState.expired(license).isUnlocked)
        XCTAssertFalse(TesseraState.revoked(license, message: nil).isUnlocked)
        XCTAssertFalse(TesseraState.unlicensed.isUnlocked)
    }
}

// Make TesseraError Equatable for test assertions
extension TesseraError: Equatable {
    public static func == (lhs: TesseraError, rhs: TesseraError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidKeyFormat, .invalidKeyFormat),
             (.signatureVerificationFailed, .signatureVerificationFailed),
             (.licenseExpired, .licenseExpired),
             (.trialExpired, .trialExpired),
             (.trialTampered, .trialTampered),
             (.clockTampered, .clockTampered),
             (.invalidPublicKey, .invalidPublicKey),
             (.decodingFailed, .decodingFailed),
             (.integrityCheckFailed, .integrityCheckFailed):
            return true
        case (.licenseRevoked(let a), .licenseRevoked(let b)):
            return a == b
        case (.keychainError(let a), .keychainError(let b)):
            return a == b
        default:
            return false
        }
    }
}
