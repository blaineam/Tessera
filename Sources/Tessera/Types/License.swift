//
//  License.swift
//  Tessera
//
//  Cryptographically signed license token.
//

import Foundation

/// A decoded and verified Tessera license.
public struct TesseraLicense: Codable, Sendable, Identifiable {
    /// Unique license identifier (UUID) — used for revocation lookup.
    public let lid: String
    /// Unix timestamp when the license was issued.
    public let iat: TimeInterval
    /// Unix timestamp when the license expires. 0 means perpetual.
    public let exp: TimeInterval
    /// License tier (e.g. "personal", "pro", "team").
    public let tier: String
    /// Bitmask of enabled feature flags.
    public let feat: UInt64
    /// Schema version for forward compatibility.
    public let v: Int

    public var id: String { lid }

    /// Whether this license has a finite expiry.
    public var isPerpetual: Bool { exp == 0 }

    /// Whether this license has expired based on the current date.
    public var isExpired: Bool {
        guard !isPerpetual else { return false }
        return Date().timeIntervalSince1970 > exp
    }

    /// The expiration date, or nil if perpetual.
    public var expirationDate: Date? {
        guard !isPerpetual else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// The issue date.
    public var issueDate: Date {
        Date(timeIntervalSince1970: iat)
    }

    /// Check if a specific feature flag is enabled.
    public func hasFeature(_ flag: UInt64) -> Bool {
        (feat & flag) != 0
    }
}

/// Raw license token before verification — the string the user enters.
public struct TesseraLicenseKey: Sendable {
    /// The full key string (e.g. "TESS-<payload>.<signature>").
    public let rawKey: String

    /// The prefix used to identify Tessera keys.
    public static let prefix = "TESS-"

    /// Base64URL-decoded payload bytes.
    public let payloadData: Data
    /// Base64URL-decoded signature bytes.
    public let signatureData: Data

    /// Maximum reasonable length for a license key string.
    /// A typical key is ~200 chars; 2048 provides generous headroom.
    private static let maxKeyLength = 2048

    /// Parse a raw license key string into its components.
    /// Format: TESS-<base64url_payload>.<base64url_signature>
    public init(rawKey: String) throws {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count <= Self.maxKeyLength else {
            throw TesseraError.invalidKeyFormat
        }

        guard trimmed.hasPrefix(Self.prefix) else {
            throw TesseraError.invalidKeyFormat
        }

        let body = String(trimmed.dropFirst(Self.prefix.count))
        let parts = body.split(separator: ".", maxSplits: 1)

        guard parts.count == 2 else {
            throw TesseraError.invalidKeyFormat
        }

        guard let payload = Data(base64URLEncoded: String(parts[0])),
              let signature = Data(base64URLEncoded: String(parts[1])) else {
            throw TesseraError.invalidKeyFormat
        }

        self.rawKey = trimmed
        self.payloadData = payload
        self.signatureData = signature
    }
}

// MARK: - Base64URL Helpers

extension Data {
    /// Decode from Base64URL (RFC 4648 §5) — no padding required.
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Add padding if needed
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(contentsOf: String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: base64)
    }

    /// Encode to Base64URL (RFC 4648 §5) — no padding.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
