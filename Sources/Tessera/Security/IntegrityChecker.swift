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

        // Validate the code signature
        let validityStatus = SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil)
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
    static func isSignatureValid() -> Bool { true }
    static func verify() throws { /* iOS enforces signing at the kernel level */ }
}
#endif
