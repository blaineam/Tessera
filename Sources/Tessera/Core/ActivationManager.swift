//
//  ActivationManager.swift
//  Tessera
//
//  Device seat limiting — restricts a license to a maximum number of machines.
//
//  Uses the same Cloudflare Worker as the trial registry, with HMAC-authenticated
//  requests. The server stores activated device fingerprints per license ID and
//  enforces MAX_DEVICES.
//
//  On first activation, the app must be online. After that, the activation status
//  is cached locally and re-verified periodically (same cadence as revocation checks).
//  Within the offline grace period, the cached activation is trusted.
//

import Foundation
import CryptoKit

/// Response from the activation server (HMAC-signed).
private struct ActivationResponse: Codable {
    let activated: Bool?
    let deactivated: Bool?
    let active: Bool?
    let device_count: Int?
    let max_devices: Int?
    let nonce: String
    let hmac: String
}

/// Manages device activation/seat limiting for a license.
struct ActivationManager {
    private let configuration: TesseraConfiguration
    private let keychain: KeychainStore

    private static let activationStatusKey = "activation_status"
    private static let activationCheckedAtKey = "activation_checked_at"
    private static let activatedLicenseIDKey = "activation_license_id"

    init(configuration: TesseraConfiguration) {
        self.configuration = configuration
        self.keychain = KeychainStore(appIdentifier: configuration.appIdentifier)
    }

    /// Whether device activation is enabled (requires registry URL and maxDevices > 0).
    var isEnabled: Bool {
        configuration.maxDevicesPerLicense > 0 && configuration.trialRegistryURL != nil
    }

    // MARK: - Public API

    enum ActivationResult {
        case activated(deviceCount: Int, maxDevices: Int)
        case limitReached(deviceCount: Int, maxDevices: Int)
        case alreadyActive(deviceCount: Int, maxDevices: Int)
        case serverUnreachable
    }

    enum DeactivationResult {
        case deactivated(deviceCount: Int)
        case serverUnreachable
    }

    enum CheckResult {
        case active
        case notActive
        case serverUnreachable
    }

    /// Activate this device for a license. Requires network connectivity.
    func activate(licenseID: String) async -> ActivationResult {
        guard isEnabled else { return .activated(deviceCount: 1, maxDevices: 0) }

        guard let fingerprint = hardwareFingerprint else {
            return .serverUnreachable
        }

        let result = await callActivationEndpoint(
            path: "activation/activate",
            licenseID: licenseID,
            fingerprint: fingerprint
        )

        switch result {
        case .success(let response):
            let action = (response.activated == true) ? "activate:ok" : "activate:denied"
            guard verifyResponseHMAC(response: response, fingerprint: fingerprint, action: action) else {
                return .serverUnreachable
            }

            let deviceCount = response.device_count ?? 0
            let maxDevices = response.max_devices ?? 0

            if response.activated == true {
                cacheActivationStatus(licenseID: licenseID, active: true)
                return .activated(deviceCount: deviceCount, maxDevices: maxDevices)
            } else {
                // Check if we're already activated (re-activation of same device)
                if response.active == true {
                    cacheActivationStatus(licenseID: licenseID, active: true)
                    return .alreadyActive(deviceCount: deviceCount, maxDevices: maxDevices)
                }
                return .limitReached(deviceCount: deviceCount, maxDevices: maxDevices)
            }

        case .failure:
            return .serverUnreachable
        }
    }

    /// Deactivate this device for a license (frees up a seat).
    func deactivate(licenseID: String) async -> DeactivationResult {
        guard isEnabled else { return .deactivated(deviceCount: 0) }

        clearActivationCache()

        guard let fingerprint = hardwareFingerprint else {
            return .serverUnreachable
        }

        let result = await callActivationEndpoint(
            path: "activation/deactivate",
            licenseID: licenseID,
            fingerprint: fingerprint
        )

        switch result {
        case .success(let response):
            guard verifyResponseHMAC(response: response, fingerprint: fingerprint, action: "deactivate:ok") else {
                return .serverUnreachable
            }
            return .deactivated(deviceCount: response.device_count ?? 0)

        case .failure:
            return .serverUnreachable
        }
    }

    /// Check if this device is still activated. Uses cache within the check interval.
    func checkActivation(licenseID: String) async -> CheckResult {
        guard isEnabled else { return .active }

        // Check cache first
        if let cached = getCachedActivation(licenseID: licenseID) {
            if cached.isWithinCheckInterval {
                return cached.isActive ? .active : .notActive
            }
            // Cache is stale — try to re-verify with server
        }

        guard let fingerprint = hardwareFingerprint else {
            // Can't generate fingerprint — trust cache within grace period
            if let cached = getCachedActivation(licenseID: licenseID), cached.isWithinGracePeriod {
                return cached.isActive ? .active : .notActive
            }
            return .serverUnreachable
        }

        let result = await callActivationEndpoint(
            path: "activation/check",
            licenseID: licenseID,
            fingerprint: fingerprint
        )

        switch result {
        case .success(let response):
            let isActive = response.active == true
            let action = isActive ? "check:active" : "check:inactive"
            guard verifyResponseHMAC(response: response, fingerprint: fingerprint, action: action) else {
                // Bad HMAC — trust cache within grace period
                if let cached = getCachedActivation(licenseID: licenseID), cached.isWithinGracePeriod {
                    return cached.isActive ? .active : .notActive
                }
                return .serverUnreachable
            }

            cacheActivationStatus(licenseID: licenseID, active: isActive)
            return isActive ? .active : .notActive

        case .failure:
            // Server unreachable — trust cache within grace period
            if let cached = getCachedActivation(licenseID: licenseID), cached.isWithinGracePeriod {
                return cached.isActive ? .active : .notActive
            }
            return .serverUnreachable
        }
    }

    /// Clear all activation data (for testing/development only).
    func resetActivation() {
        clearActivationCache()
    }

    // MARK: - Cache

    private struct CachedActivation {
        let isActive: Bool
        let checkedAt: Date
        let licenseID: String
        let gracePeriodDays: Int
        let checkIntervalHours: Int

        var isWithinCheckInterval: Bool {
            Date().timeIntervalSince(checkedAt) < TimeInterval(checkIntervalHours * 3600)
        }

        var isWithinGracePeriod: Bool {
            Date().timeIntervalSince(checkedAt) < TimeInterval(gracePeriodDays * 86400)
        }
    }

    private func getCachedActivation(licenseID: String) -> CachedActivation? {
        guard let statusStr = keychain.getString(Self.activationStatusKey),
              let checkedAt = keychain.getDate(Self.activationCheckedAtKey),
              let cachedLicenseID = keychain.getString(Self.activatedLicenseIDKey),
              cachedLicenseID == licenseID else {
            return nil
        }

        return CachedActivation(
            isActive: statusStr == "active",
            checkedAt: checkedAt,
            licenseID: licenseID,
            gracePeriodDays: configuration.offlineGracePeriodDays,
            checkIntervalHours: configuration.revocationCheckIntervalHours
        )
    }

    private func cacheActivationStatus(licenseID: String, active: Bool) {
        try? keychain.setString(active ? "active" : "inactive", for: Self.activationStatusKey)
        try? keychain.setDate(Date(), for: Self.activationCheckedAtKey)
        try? keychain.setString(licenseID, for: Self.activatedLicenseIDKey)
    }

    private func clearActivationCache() {
        keychain.delete(Self.activationStatusKey)
        keychain.delete(Self.activationCheckedAtKey)
        keychain.delete(Self.activatedLicenseIDKey)
    }

    // MARK: - Networking

    private var hardwareFingerprint: String? {
        HardwareFingerprint.generate(salt: configuration.trialSalt)
    }

    private func callActivationEndpoint(
        path: String,
        licenseID: String,
        fingerprint: String
    ) async -> Result<ActivationResponse, Error> {
        guard let baseURL = configuration.trialRegistryURL else {
            return .failure(TesseraError.activationLimitReached(maxDevices: 0))
        }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        guard let requestHMAC = computeRequestHMAC(fingerprint: fingerprint, timestamp: timestamp) else {
            return .failure(TesseraError.activationLimitReached(maxDevices: 0))
        }

        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: String] = [
            "license_id": licenseID,
            "fingerprint": fingerprint,
            "app_id": configuration.appIdentifier,
            "timestamp": timestamp,
            "request_hmac": requestHMAC
        ]
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failure(TesseraError.activationLimitReached(maxDevices: 0))
            }
            let result = try JSONDecoder().decode(ActivationResponse.self, from: data)
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - HMAC

    private func computeRequestHMAC(fingerprint: String, timestamp: String) -> String? {
        guard let secret = configuration.trialRegistrySecret else { return nil }
        let message = "\(fingerprint):\(configuration.appIdentifier):\(timestamp)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(mac).base64EncodedString()
    }

    private func verifyResponseHMAC(response: ActivationResponse, fingerprint: String, action: String) -> Bool {
        guard let secret = configuration.trialRegistrySecret else { return false }
        let message = "\(action):\(fingerprint):\(response.nonce):"
        let key = SymmetricKey(data: Data(secret.utf8))
        guard let expectedMAC = Data(base64Encoded: response.hmac) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(expectedMAC, authenticating: Data(message.utf8), using: key)
    }
}
