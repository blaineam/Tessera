//
//  LicenseValidator.swift
//  Tessera
//
//  Ed25519 signature verification for license keys.
//

import Foundation
import CryptoKit

/// Validates Tessera license keys using Ed25519 signature verification.
///
/// The app ships with only the public key. License generation (signing) happens
/// offline using the private key, which never leaves the developer's machine.
public struct LicenseValidator: Sendable {
    private let publicKey: Curve25519.Signing.PublicKey

    /// Initialize with a base64-encoded Ed25519 public key (32 bytes).
    public init(publicKeyBase64: String) throws {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              keyData.count == 32 else {
            throw TesseraError.invalidPublicKey
        }
        self.publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    }

    /// Verify and decode a license key string.
    ///
    /// 1. Parses the TESS-<payload>.<signature> format
    /// 2. Verifies the Ed25519 signature over the raw payload bytes
    /// 3. Decodes the JSON payload into a `TesseraLicense`
    ///
    /// - Parameter rawKey: The full license key string entered by the user.
    /// - Returns: A verified `TesseraLicense` on success.
    /// - Throws: `TesseraError` if parsing, verification, or decoding fails.
    public func verify(rawKey: String) throws -> TesseraLicense {
        let key = try TesseraLicenseKey(rawKey: rawKey)

        // Verify Ed25519 signature over the raw payload bytes
        guard publicKey.isValidSignature(key.signatureData, for: key.payloadData) else {
            throw TesseraError.signatureVerificationFailed
        }

        // Decode the verified payload
        let decoder = JSONDecoder()
        guard let license = try? decoder.decode(TesseraLicense.self, from: key.payloadData) else {
            throw TesseraError.decodingFailed
        }

        return license
    }

    /// Verify a license key and also check expiry.
    ///
    /// - Parameter rawKey: The full license key string.
    /// - Returns: A verified, non-expired `TesseraLicense`.
    /// - Throws: `TesseraError.licenseExpired` if the license has expired.
    public func verifyAndCheckExpiry(rawKey: String) throws -> TesseraLicense {
        let license = try verify(rawKey: rawKey)

        if license.isExpired {
            throw TesseraError.licenseExpired
        }

        return license
    }
}
