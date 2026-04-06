//
//  IntegrityChecker.swift
//  Tessera
//
//  Runtime binary integrity verification using macOS code signing.
//  Detects if the binary has been tampered with (e.g. hex-editing the public key).
//

import Foundation
#if os(macOS)
import Security

/// Verifies the application's code signature at runtime.
///
/// This detects binary patching attacks (e.g. replacing the embedded public key).
/// On macOS, it uses `SecCodeCheckValidity` to verify the running code against
/// its code signature. If the signature doesn't match, the binary was modified.
struct IntegrityChecker {
    /// Optional Team ID for hardened integrity checks.
    /// When set, the integrity check verifies the binary was signed by this specific team,
    /// preventing re-signing attacks where an attacker modifies the binary and signs it
    /// with their own developer certificate.
    ///
    /// Set this to your Apple Developer Team ID (e.g. "ABC123XYZ"):
    /// ```swift
    /// IntegrityChecker.expectedTeamID = "YOUR_TEAM_ID"
    /// ```
    static var expectedTeamID: String?

    /// Check if the running application's code signature is valid.
    ///
    /// - Returns: `true` if the signature is valid or if running in a debug/unsigned build.
    ///           `false` if the signature has been tampered with.
    static func isSignatureValid() -> Bool {
        var code: SecCode?
        let selfStatus = SecCodeCopySelf([], &code)

        guard selfStatus == errSecSuccess, let code = code else {
            // Can't get reference to self — likely running in Xcode debug.
            // Allow in debug, but this would fail for a notarized release.
            #if DEBUG
            return true
            #else
            return false
            #endif
        }

        // Build a requirement that checks the Team ID if configured
        var requirement: SecRequirement?
        if let teamID = expectedTeamID, !teamID.isEmpty {
            // Sanitize Team ID: must be alphanumeric only (Apple Team IDs are 10 alphanumeric chars)
            let sanitizedTeamID = teamID.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            guard sanitizedTeamID == teamID, !sanitizedTeamID.isEmpty else {
                #if DEBUG
                return true
                #else
                return false
                #endif
            }
            let requirementString = "anchor apple generic and certificate leaf[subject.OU] = \"\(sanitizedTeamID)\"" as CFString
            let reqStatus = SecRequirementCreateWithString(requirementString, [], &requirement)
            if reqStatus != errSecSuccess {
                // Failed to create requirement — fail closed in release
                #if DEBUG
                return true
                #else
                return false
                #endif
            }
        }

        // Validate the code signature against the requirement (or basic validation if no Team ID)
        let validityStatus = SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), requirement)
        return validityStatus == errSecSuccess
    }

    /// Verify integrity and throw if tampered.
    static func verify() throws {
        guard isSignatureValid() else {
            throw TesseraError.integrityCheckFailed
        }
    }
}
#else
/// On iOS, code signing is enforced by the OS — no runtime check needed.
struct IntegrityChecker {
    static var expectedTeamID: String?
    static func isSignatureValid() -> Bool { true }
    static func verify() throws { /* iOS enforces signing at the kernel level */ }
}
#endif
