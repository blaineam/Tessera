//
//  HardwareFingerprint.swift
//  Tessera
//
//  Hardware-bound fingerprint for tamper-resistant trial tokens.
//  The fingerprint stays on-device — it is never transmitted anywhere.
//

import Foundation
import CryptoKit
#if os(macOS)
import IOKit
#elseif os(iOS)
import UIKit
#endif

/// Generates a hardware-bound fingerprint used to anchor trial tokens to a specific machine.
///
/// On macOS: uses IOPlatformUUID (unique per Mac, persists through reinstalls).
/// On iOS: uses identifierForVendor (resets on app reinstall, but trials are MAS-gated on iOS).
///
/// The raw hardware ID is never stored — only a salted SHA-256 hash is used.
struct HardwareFingerprint {
    /// Generate the hardware fingerprint hash.
    ///
    /// - Parameter salt: An app-specific salt to prevent cross-app fingerprint reuse.
    /// - Returns: A hex-encoded SHA-256 hash of the hardware identity + salt.
    static func generate(salt: String) -> String? {
        guard let platformID = getPlatformIdentifier() else { return nil }

        let input = "\(platformID):\(salt)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Get the first 16 characters of the fingerprint (for embedding in trial tokens).
    static func shortFingerprint(salt: String) -> String? {
        guard let full = generate(salt: salt) else { return nil }
        return String(full.prefix(16))
    }

    // MARK: - Platform-specific

    private static func getPlatformIdentifier() -> String? {
        #if os(macOS)
        return getMacPlatformUUID()
        #elseif os(iOS)
        return getIOSIdentifier()
        #else
        return nil
        #endif
    }

    #if os(macOS)
    private static func getMacPlatformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let key = kIOPlatformUUIDKey as CFString
        guard let uuid = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else {
            return nil
        }
        return uuid
    }
    #endif

    #if os(iOS)
    private static func getIOSIdentifier() -> String? {
        return UIDevice.current.identifierForVendor?.uuidString
    }
    #endif
}
