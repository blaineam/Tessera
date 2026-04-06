//
//  Tessera.swift
//  Tessera — Cryptographic App Licensing for macOS
//
//  The main entry point for the Tessera licensing system.
//  Initialize with a TesseraConfiguration, then query `currentState()`
//  or use the `.tesseraGate()` SwiftUI modifier.
//

import Foundation
import SwiftUI
import Combine

/// The Tessera licensing manager.
///
/// Usage:
/// ```swift
/// let tessera = Tessera(configuration: .init(
///     publicKeyBase64: "<your-ed25519-public-key>",
///     revocationURL: URL(string: "https://example.com/revoked.json")!,
///     appIdentifier: "com.example.myapp",
///     appDisplayName: "My App"
/// ))
///
/// // In SwiftUI:
/// ContentView()
///     .tesseraGate(tessera)
/// ```
@MainActor
public final class Tessera: ObservableObject {
    /// The current licensing state. Observe this to react to changes.
    @Published public private(set) var state: TesseraState = .unlicensed

    /// The active license (if any).
    @Published public private(set) var license: TesseraLicense?

    public let configuration: TesseraConfiguration

    private let validator: LicenseValidator
    private let revocationChecker: RevocationChecker
    private let trialManager: TrialManager
    private let activationManager: ActivationManager
    private let keychain: KeychainStore

    private static let licenseKeyStorageKey = "active_license_key"

    /// Initialize the Tessera licensing system.
    ///
    /// - Parameter configuration: The licensing configuration (public key, revocation URL, etc.).
    public init(configuration: TesseraConfiguration) {
        self.configuration = configuration

        do {
            self.validator = try LicenseValidator(publicKeyBase64: configuration.publicKeyBase64)
        } catch {
            fatalError("Tessera: Invalid public key — \(error.localizedDescription)")
        }

        self.revocationChecker = RevocationChecker(configuration: configuration)
        self.trialManager = TrialManager(configuration: configuration)
        self.activationManager = ActivationManager(configuration: configuration)
        self.keychain = KeychainStore(appIdentifier: configuration.appIdentifier)

        // Configure integrity checker with Team ID for hardened code signing verification
        IntegrityChecker.expectedTeamID = configuration.expectedTeamID
    }

    // MARK: - Public API

    /// Evaluate the current licensing state.
    ///
    /// This checks (in order):
    /// 1. Binary integrity
    /// 2. Stored license key validity + expiry
    /// 3. Revocation status (async, cached)
    /// 4. Trial status
    ///
    /// Call this on app launch and periodically (e.g. when app becomes active).
    public func evaluate() async {
        // Step 1: Integrity check
        do {
            try IntegrityChecker.verify()
        } catch {
            state = .unlicensed
            return
        }

        // Step 2: Check for stored license
        if let rawKey = keychain.getString(Self.licenseKeyStorageKey) {
            do {
                let verifiedLicense = try validator.verifyAndCheckExpiry(rawKey: rawKey)

                // Step 3: Check revocation (async)
                let revocation = await revocationChecker.checkRevocation(licenseID: verifiedLicense.lid)
                if revocation.isRevoked {
                    license = verifiedLicense
                    state = .revoked(verifiedLicense, message: revocation.message)
                    return
                }

                // Step 3b: Check device activation (if seat limiting is enabled)
                if activationManager.isEnabled {
                    let activationCheck = await activationManager.checkActivation(licenseID: verifiedLicense.lid)
                    switch activationCheck {
                    case .active:
                        break // Device is activated, continue
                    case .notActive:
                        // Device was deactivated remotely — remove license
                        keychain.delete(Self.licenseKeyStorageKey)
                        license = nil
                        state = .unlicensed
                        return
                    case .serverUnreachable:
                        break // Within grace period or cache — allow through
                    }
                }

                license = verifiedLicense
                state = .licensed(verifiedLicense)
                return
            } catch TesseraError.licenseExpired {
                // License exists but expired — try to decode it for the UI
                if let expiredLicense = try? validator.verify(rawKey: rawKey) {
                    license = expiredLicense
                    state = .expired(expiredLicense)
                    return
                }
            } catch {
                // Invalid license — fall through to trial check
                keychain.delete(Self.licenseKeyStorageKey)
            }
        }

        // Step 4: Check trial (async — may contact trial registry server)
        let trialResult = await trialManager.checkTrial()
        switch trialResult {
        case .success(let daysRemaining):
            state = .trial(daysRemaining: daysRemaining)
        case .failure(let error):
            switch error {
            case .trialExpired:
                state = .trialExpired
            case .clockTampered:
                state = .trialExpired // Treat clock tampering as expired
            default:
                state = .unlicensed
            }
        }
    }

    /// Activate a license key.
    ///
    /// Verifies the key's signature, checks expiry, stores it in the Keychain,
    /// and updates the state.
    ///
    /// - Parameter rawKey: The license key string (e.g. "TESS-<payload>.<signature>").
    /// - Throws: `TesseraError` if the key is invalid, expired, or revoked.
    public func activate(rawKey: String) async throws {
        // Verify signature and expiry
        let verifiedLicense = try validator.verifyAndCheckExpiry(rawKey: rawKey)

        // Check revocation
        let revocation = await revocationChecker.checkRevocation(licenseID: verifiedLicense.lid)
        if revocation.isRevoked {
            throw TesseraError.licenseRevoked(message: revocation.message)
        }

        // Register device activation (if seat limiting is enabled)
        if activationManager.isEnabled {
            let result = await activationManager.activate(licenseID: verifiedLicense.lid)
            switch result {
            case .activated, .alreadyActive:
                break // Success — proceed
            case .limitReached(_, let maxDevices):
                throw TesseraError.activationLimitReached(maxDevices: maxDevices)
            case .serverUnreachable:
                throw TesseraError.activationServerUnreachable
            }
        }

        // Store the raw key
        try keychain.setString(rawKey, for: Self.licenseKeyStorageKey)

        // Update state
        license = verifiedLicense
        state = .licensed(verifiedLicense)
    }

    /// Deactivate the current license (removes it from this machine and frees the device seat).
    public func deactivate() {
        let licenseID = license?.lid

        keychain.delete(Self.licenseKeyStorageKey)
        license = nil

        // Release device seat and fall back to trial
        Task {
            // Release the device seat on the server (if activation is enabled)
            if let licenseID, activationManager.isEnabled {
                _ = await activationManager.deactivate(licenseID: licenseID)
            }

            let trialResult = await trialManager.checkTrial()
            switch trialResult {
            case .success(let daysRemaining):
                state = .trial(daysRemaining: daysRemaining)
            case .failure:
                state = trialManager.hasExistingTrial ? .trialExpired : .unlicensed
            }
        }
    }

    /// Whether a trial has been used on this machine (even if expired).
    public var hasUsedTrial: Bool {
        trialManager.hasExistingTrial
    }

    /// Force a fresh revocation check (e.g. when the app comes to foreground).
    /// Always bypasses the cache to get the latest revocation list.
    public func recheckRevocation() async {
        guard let license = license,
              case .licensed = state else { return }

        let revocation = await revocationChecker.checkRevocation(licenseID: license.lid, forceRefresh: true)
        if revocation.isRevoked {
            state = .revoked(license, message: revocation.message)
        }
    }

    #if DEBUG
    /// Reset all Tessera state (for development/testing only).
    public func resetAll() {
        keychain.delete(Self.licenseKeyStorageKey)
        trialManager.resetTrial()
        activationManager.resetActivation()
        license = nil
        state = .unlicensed
    }
    #endif
}

// MARK: - SwiftUI View Modifier

public extension View {
    /// Gates the view behind Tessera's licensing system.
    ///
    /// When the app is unlicensed, shows the activation view instead of the content.
    ///
    /// ```swift
    /// ContentView()
    ///     .tesseraGate(tessera)
    /// ```
    ///
    /// - Parameters:
    ///   - tessera: The Tessera instance managing license state.
    ///   - activationView: Optional custom activation view. Uses `TesseraActivationView` by default.
    func tesseraGate<ActivationContent: View>(
        _ tessera: Tessera,
        @ViewBuilder activationView: @escaping () -> ActivationContent
    ) -> some View {
        modifier(TesseraGateModifier(tessera: tessera, customActivationView: activationView))
    }

    /// Gates the view behind Tessera's licensing system using the default activation UI.
    func tesseraGate(_ tessera: Tessera) -> some View {
        modifier(TesseraGateModifier(tessera: tessera, customActivationView: {
            TesseraActivationView(tessera: tessera)
        }))
    }
}
