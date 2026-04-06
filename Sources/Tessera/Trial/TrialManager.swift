//
//  TrialManager.swift
//  Tessera
//
//  Two-tier trial enforcement:
//
//  Tier 1 (Server-side — when trialRegistryURL is configured):
//    On trial start, the app registers a hardware fingerprint hash with the
//    Tessera Cloudflare Worker, which stores it in KV. On reinstall, the app
//    checks the server before allowing a new trial. Since the KV store is
//    server-side, users CANNOT reset it by wiping local storage.
//    This is the definitive source of truth.
//
//  Tier 2 (Local anchors — always active, offline fallback):
//    Trial tokens stored in 5 local locations act as an offline cache.
//    If the server is unreachable, local anchors are used within the grace period.
//    If the server is NOT configured, local anchors are the only enforcement.
//
//  Local anchors:
//  1. macOS Keychain (persists through app uninstall)
//  2. Hidden file in ~/Library (persists through app uninstall)
//  3. UserDefaults (fastest access)
//  4. Extended attribute on ~/Library/Preferences (hard to discover)
//  5. Decoy Keychain entry under unrelated service name
//

import Foundation
import CryptoKit

/// A trial token stored in each anchor location.
struct TrialToken: Codable {
    let start: TimeInterval
    let hw: String
    let hmac: String
}

/// Response from the trial registry server (HMAC-signed + optionally Ed25519-signed).
private struct TrialRegistryResponse: Codable {
    let used: Bool?
    let allowed: Bool?
    let registered_at: String?
    let nonce: String
    let hmac: String        // HMAC(secret, payload) — proves the server knows the secret
    let ed25519_sig: String? // Ed25519 signature — asymmetric proof (can't be forged from client secret)
}

/// Manages the two-tier trial system.
struct TrialManager {
    private let configuration: TesseraConfiguration
    private let keychain: KeychainStore
    private let responseVerifier: ResponseSignatureVerifier?

    private static let trialTokenKey = "trial_token"
    private static let lastSeenDateKey = "last_seen_date"
    private static let anchorCountKey = "anchor_watermark"
    private static let serverTrialStartKey = "server_trial_start"

    /// Maximum allowed forward clock jump before treating as tampering (48 hours).
    /// A legitimate clock jump (e.g. timezone change, NTP correction) is typically small.
    private static let maxForwardJumpSeconds: TimeInterval = 48 * 3600

    init(configuration: TesseraConfiguration) {
        self.configuration = configuration
        self.keychain = KeychainStore(appIdentifier: configuration.appIdentifier)

        // Initialize Ed25519 response verifier if a public key is configured
        if let keyBase64 = configuration.responseVerificationKeyBase64,
           let keyData = Data(base64Encoded: keyBase64),
           keyData.count == 32,
           let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) {
            self.responseVerifier = ResponseSignatureVerifier(publicKey: pubKey)
        } else {
            self.responseVerifier = nil
        }
    }

    private var hmacKey: SymmetricKey? {
        guard let fingerprint = HardwareFingerprint.generate(salt: configuration.trialSalt) else {
            return nil
        }
        let keyMaterial = "\(fingerprint):\(configuration.appIdentifier):\(configuration.trialSalt)"
        let hash = SHA256.hash(data: Data(keyMaterial.utf8))
        return SymmetricKey(data: hash)
    }

    private var hardwareFingerprint: String? {
        HardwareFingerprint.generate(salt: configuration.trialSalt)
    }

    // MARK: - Public API

    /// Check the current trial status (async — may contact the trial registry).
    func checkTrial() async -> Result<Int, TesseraError> {
        guard configuration.trialDurationDays > 0 else {
            return .failure(.trialExpired)
        }

        if isClockTampered() {
            return .failure(.clockTampered)
        }

        recordCurrentDate()

        // Collect local anchors
        let localTokens = collectValidTokens()
        let previousWatermark = getAnchorWatermark()

        // --- Server-side check (if configured) ---
        if configuration.trialRegistryURL != nil {
            return await checkTrialWithServer(localTokens: localTokens, previousWatermark: previousWatermark)
        }

        // --- Local-only fallback ---
        return checkTrialLocalOnly(localTokens: localTokens, previousWatermark: previousWatermark)
    }

    /// Whether a trial has ever been started on this machine (sync, local check only).
    var hasExistingTrial: Bool {
        !collectValidTokens().isEmpty
            || getAnchorWatermark() > 0
            || keychain.getString(Self.serverTrialStartKey) != nil
    }

    /// Clear all trial data (for testing/development only).
    func resetTrial() {
        keychain.delete(Self.trialTokenKey)
        keychain.delete(Self.lastSeenDateKey)
        keychain.delete(Self.anchorCountKey)
        keychain.delete(Self.serverTrialStartKey)
        decoyKeychain.delete(decoyTokenKey)
        removeHiddenFileToken()
        removeExtendedAttributeToken()
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    // MARK: - Server-side Trial

    /// Check trial with the server as the source of truth.
    private func checkTrialWithServer(localTokens: [TrialToken], previousWatermark: Int) async -> Result<Int, TesseraError> {
        guard let fingerprint = hardwareFingerprint else {
            return .failure(.trialTampered)
        }

        // Ask the server if this machine has already used a trial
        let serverResult = await queryTrialRegistry(fingerprint: fingerprint)

        switch serverResult {
        case .alreadyUsed(let registeredAt):
            // Server says trial was already used — trust the server.
            // Calculate days remaining from the server-registered start date.
            let elapsed = Date().timeIntervalSince(registeredAt)
            let trialDuration = TimeInterval(configuration.trialDurationDays * 86400)

            if elapsed >= trialDuration {
                return .failure(.trialExpired)
            }

            let daysRemaining = Int(ceil((trialDuration - elapsed) / 86400))

            // Ensure local anchors are in sync
            rehealAnchors(startTime: registeredAt.timeIntervalSince1970)

            return .success(max(1, daysRemaining))

        case .notUsed:
            // Server says no trial registered — start one
            let registered = await registerTrialWithServer(fingerprint: fingerprint)
            if registered {
                let _ = startNewLocalTrial()
                return .success(configuration.trialDurationDays)
            }
            // Server registration failed — fall back to local check
            return checkTrialLocalOnly(localTokens: localTokens, previousWatermark: previousWatermark)

        case .serverUnreachable:
            // Can't reach the server — use local anchors within grace period
            // But also check if we have a cached server start date
            if let cachedStart = getCachedServerTrialStart() {
                let elapsed = Date().timeIntervalSince(cachedStart)
                let trialDuration = TimeInterval(configuration.trialDurationDays * 86400)
                if elapsed >= trialDuration {
                    return .failure(.trialExpired)
                }
                let daysRemaining = Int(ceil((trialDuration - elapsed) / 86400))
                return .success(max(1, daysRemaining))
            }

            // No cached server data — fall back to local-only
            return checkTrialLocalOnly(localTokens: localTokens, previousWatermark: previousWatermark)
        }
    }

    private enum ServerTrialResult {
        case alreadyUsed(Date)
        case notUsed
        case serverUnreachable
    }

    // MARK: - HMAC-Authenticated Server Communication
    //
    // The TRIAL_SECRET never goes over the wire. Instead:
    //
    // Request:  {fingerprint, app_id, timestamp, request_hmac}
    //   where request_hmac = HMAC(secret, fingerprint + app_id + timestamp)
    //   The server verifies this to authenticate the request.
    //
    // Response: {used/allowed, registered_at, nonce, hmac, ed25519_sig}
    //   where hmac = HMAC(secret, used + fingerprint + nonce)  (legacy, symmetric)
    //   and ed25519_sig = Ed25519(server_private_key, same message)  (asymmetric, preferred)
    //   The app verifies the Ed25519 signature (preferred) or HMAC (fallback).
    //
    // The Ed25519 response signature cannot be forged even if the HMAC secret
    // is extracted from the binary, since the signing key is server-side only.

    private func computeRequestHMAC(fingerprint: String, timestamp: String) -> String? {
        guard let secret = configuration.trialRegistrySecret else { return nil }
        let message = "\(fingerprint):\(configuration.appIdentifier):\(timestamp)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(mac).base64EncodedString()
    }

    /// Verify a server response using Ed25519 signature (preferred) or HMAC (fallback).
    private func verifyResponse(_ response: TrialRegistryResponse, fingerprint: String, action: String) -> Bool {
        let registeredAt = response.registered_at ?? ""
        let message = "\(action):\(fingerprint):\(response.nonce):\(registeredAt)"

        // Prefer Ed25519 signature verification (asymmetric — can't be forged from client)
        if let verifier = responseVerifier,
           let sigBase64 = response.ed25519_sig,
           let sigData = Data(base64Encoded: sigBase64),
           let msgData = message.data(using: .utf8) {
            return verifier.publicKey.isValidSignature(sigData, for: msgData)
        }

        // Fallback to HMAC verification (symmetric — weaker but still validates)
        return verifyResponseHMAC(response: response, fingerprint: fingerprint, action: action)
    }

    private func verifyResponseHMAC(response: TrialRegistryResponse, fingerprint: String, action: String) -> Bool {
        guard let secret = configuration.trialRegistrySecret else { return false }

        let registeredAt = response.registered_at ?? ""
        let message = "\(action):\(fingerprint):\(response.nonce):\(registeredAt)"
        let key = SymmetricKey(data: Data(secret.utf8))

        guard let expectedMAC = Data(base64Encoded: response.hmac) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(expectedMAC, authenticating: Data(message.utf8), using: key)
    }

    private func queryTrialRegistry(fingerprint: String) async -> ServerTrialResult {
        guard let baseURL = configuration.trialRegistryURL else {
            return .serverUnreachable
        }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        guard let requestHMAC = computeRequestHMAC(fingerprint: fingerprint, timestamp: timestamp) else {
            return .serverUnreachable
        }

        let url = baseURL.appendingPathComponent("trial/check")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8

        let body: [String: String] = [
            "fingerprint": fingerprint,
            "app_id": configuration.appIdentifier,
            "timestamp": timestamp,
            "request_hmac": requestHMAC
        ]
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .serverUnreachable
            }

            let result = try JSONDecoder().decode(TrialRegistryResponse.self, from: data)

            // Verify the server's response signature
            let used = result.used ?? false
            let action = used ? "check:used" : "check:fresh"
            guard verifyResponse(result, fingerprint: fingerprint, action: action) else {
                // Invalid signature — response was tampered with
                return .serverUnreachable
            }

            if used, let dateStr = result.registered_at {
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: dateStr) {
                    try? keychain.setString(dateStr, for: Self.serverTrialStartKey)
                    return .alreadyUsed(date)
                }
            }
            return .notUsed
        } catch {
            return .serverUnreachable
        }
    }

    private func registerTrialWithServer(fingerprint: String) async -> Bool {
        guard let baseURL = configuration.trialRegistryURL else {
            return false
        }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        guard let requestHMAC = computeRequestHMAC(fingerprint: fingerprint, timestamp: timestamp) else {
            return false
        }

        let url = baseURL.appendingPathComponent("trial/register")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8

        let body: [String: String] = [
            "fingerprint": fingerprint,
            "app_id": configuration.appIdentifier,
            "timestamp": timestamp,
            "request_hmac": requestHMAC
        ]
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }

            let result = try JSONDecoder().decode(TrialRegistryResponse.self, from: data)

            // Verify response signature
            let allowed = result.allowed ?? false
            let action = allowed ? "register:ok" : "register:denied"
            guard verifyResponse(result, fingerprint: fingerprint, action: action) else {
                return false
            }

            if let dateStr = result.registered_at {
                try? keychain.setString(dateStr, for: Self.serverTrialStartKey)
            }

            return allowed
        } catch {
            return false
        }
    }

    private func getCachedServerTrialStart() -> Date? {
        guard let dateStr = keychain.getString(Self.serverTrialStartKey) else { return nil }
        return ISO8601DateFormatter().date(from: dateStr)
    }

    // MARK: - Local-only Trial

    /// Local-only trial check (used when server is not configured or unreachable).
    private func checkTrialLocalOnly(localTokens: [TrialToken], previousWatermark: Int) -> Result<Int, TesseraError> {
        if localTokens.isEmpty {
            if previousWatermark > 0 {
                return .failure(.trialTampered)
            }

            if startNewLocalTrial() {
                return .success(configuration.trialDurationDays)
            }
            return .failure(.trialTampered)
        }

        if localTokens.count > previousWatermark {
            setAnchorWatermark(localTokens.count)
        }

        if previousWatermark >= 4 && localTokens.count <= 1 {
            return .failure(.trialTampered)
        }

        let earliestStart = localTokens.map(\.start).min()!
        let startDate = Date(timeIntervalSince1970: earliestStart)
        let elapsed = Date().timeIntervalSince(startDate)
        let trialDuration = TimeInterval(configuration.trialDurationDays * 86400)

        if elapsed >= trialDuration {
            return .failure(.trialExpired)
        }

        let daysRemaining = Int(ceil((trialDuration - elapsed) / 86400))
        rehealAnchors(startTime: earliestStart)

        return .success(max(1, daysRemaining))
    }

    // MARK: - Anchor Watermark

    private func getAnchorWatermark() -> Int {
        guard let str = keychain.getString(Self.anchorCountKey),
              let val = Int(str) else { return 0 }
        return val
    }

    private func setAnchorWatermark(_ count: Int) {
        try? keychain.setString(String(count), for: Self.anchorCountKey)
    }

    // MARK: - Token Collection

    private func collectValidTokens() -> [TrialToken] {
        var tokens: [TrialToken] = []

        if let token = loadKeychainToken(), validateToken(token) { tokens.append(token) }
        if let token = loadHiddenFileToken(), validateToken(token) { tokens.append(token) }
        if let token = loadUserDefaultsToken(), validateToken(token) { tokens.append(token) }
        if let token = loadExtendedAttributeToken(), validateToken(token) { tokens.append(token) }
        if let token = loadDecoyKeychainToken(), validateToken(token) { tokens.append(token) }

        return tokens
    }

    private func startNewLocalTrial() -> Bool {
        guard let hwFingerprint = HardwareFingerprint.shortFingerprint(salt: configuration.trialSalt),
              let key = hmacKey else {
            return false
        }

        let startTime = Date().timeIntervalSince1970
        let token = createToken(start: startTime, hw: hwFingerprint, key: key)

        saveKeychainToken(token)
        saveHiddenFileToken(token)
        saveUserDefaultsToken(token)
        saveExtendedAttributeToken(token)
        saveDecoyKeychainToken(token)
        setAnchorWatermark(5)

        return true
    }

    private func rehealAnchors(startTime: TimeInterval) {
        guard let hwFingerprint = HardwareFingerprint.shortFingerprint(salt: configuration.trialSalt),
              let key = hmacKey else { return }

        let token = createToken(start: startTime, hw: hwFingerprint, key: key)

        if loadKeychainToken() == nil { saveKeychainToken(token) }
        if loadHiddenFileToken() == nil { saveHiddenFileToken(token) }
        if loadUserDefaultsToken() == nil { saveUserDefaultsToken(token) }
        if loadExtendedAttributeToken() == nil { saveExtendedAttributeToken(token) }
        if loadDecoyKeychainToken() == nil { saveDecoyKeychainToken(token) }
    }

    // MARK: - Token Creation & Validation

    private func createToken(start: TimeInterval, hw: String, key: SymmetricKey) -> TrialToken {
        let message = "\(start):\(hw)"
        let hmac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return TrialToken(start: start, hw: hw, hmac: Data(hmac).base64EncodedString())
    }

    private func validateToken(_ token: TrialToken) -> Bool {
        guard let key = hmacKey,
              let currentHW = HardwareFingerprint.shortFingerprint(salt: configuration.trialSalt) else {
            return false
        }

        guard token.hw == currentHW else { return false }

        let message = "\(token.start):\(token.hw)"
        guard let expectedHMAC = Data(base64Encoded: token.hmac) else { return false }

        return HMAC<SHA256>.isValidAuthenticationCode(expectedHMAC, authenticating: Data(message.utf8), using: key)
    }

    // MARK: - Clock Tampering Detection

    private func isClockTampered() -> Bool {
        guard let lastSeen = keychain.getDate(Self.lastSeenDateKey) else { return false }
        let delta = Date().timeIntervalSince(lastSeen)

        // Detect backward clock jumps (> 1 hour)
        if delta < -3600 {
            return true
        }

        // Detect suspicious forward clock jumps (> 48 hours since last check).
        // A user could advance the clock to expire the trial, reset local state,
        // then set the clock back. This catches the forward jump.
        if delta > Self.maxForwardJumpSeconds {
            return true
        }

        return false
    }

    private func recordCurrentDate() {
        try? keychain.setDate(Date(), for: Self.lastSeenDateKey)
    }

    // MARK: - Anchor 1: Keychain

    private func loadKeychainToken() -> TrialToken? {
        guard let data = keychain.getData(Self.trialTokenKey) else { return nil }
        return try? JSONDecoder().decode(TrialToken.self, from: data)
    }

    private func saveKeychainToken(_ token: TrialToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        try? keychain.setData(data, for: Self.trialTokenKey)
    }

    // MARK: - Anchor 2: Hidden File

    private var hiddenFilePath: URL {
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        #else
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #endif
        return base.appendingPathComponent(".tessera_\(configuration.appIdentifier)")
    }

    private func loadHiddenFileToken() -> TrialToken? {
        guard let data = try? Data(contentsOf: hiddenFilePath) else { return nil }
        return try? JSONDecoder().decode(TrialToken.self, from: data)
    }

    private func saveHiddenFileToken(_ token: TrialToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        try? data.write(to: hiddenFilePath, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: hiddenFilePath.path
        )
    }

    private func removeHiddenFileToken() {
        try? FileManager.default.removeItem(at: hiddenFilePath)
    }

    // MARK: - Anchor 3: UserDefaults

    private var userDefaultsKey: String {
        "com.tessera.\(configuration.appIdentifier).trial"
    }

    private func loadUserDefaultsToken() -> TrialToken? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(TrialToken.self, from: data)
    }

    private func saveUserDefaultsToken(_ token: TrialToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    // MARK: - Anchor 4: Extended Attribute

    #if os(macOS)
    private var xattrName: String {
        let hash = SHA256.hash(data: Data("tessera:\(configuration.appIdentifier)".utf8))
        let short = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "com.apple.metadata.ts_\(short)"
    }

    private var xattrTargetPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Preferences").path
    }

    private func loadExtendedAttributeToken() -> TrialToken? {
        let path = xattrTargetPath
        let name = xattrName
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }

        var buffer = Data(count: size)
        let readSize = buffer.withUnsafeMutableBytes { ptr in
            getxattr(path, name, ptr.baseAddress, size, 0, 0)
        }
        guard readSize == size else { return nil }
        return try? JSONDecoder().decode(TrialToken.self, from: buffer)
    }

    private func saveExtendedAttributeToken(_ token: TrialToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        data.withUnsafeBytes { ptr in
            _ = setxattr(xattrTargetPath, xattrName, ptr.baseAddress, data.count, 0, 0)
        }
    }

    private func removeExtendedAttributeToken() {
        removexattr(xattrTargetPath, xattrName, 0)
    }
    #else
    private func loadExtendedAttributeToken() -> TrialToken? { nil }
    private func saveExtendedAttributeToken(_ token: TrialToken) {}
    private func removeExtendedAttributeToken() {}
    #endif

    // MARK: - Anchor 5: Decoy Keychain

    private var decoyKeychain: KeychainStore {
        // Use a plausible-looking but Tessera-namespaced service name to avoid
        // collisions with real system entries
        guard let hwHash = HardwareFingerprint.shortFingerprint(salt: "decoy-\(configuration.trialSalt)") else {
            return KeychainStore(appIdentifier: "com.tessera.cache.\(configuration.appIdentifier.hashValue)")
        }
        return KeychainStore(appIdentifier: "com.tessera.cache.\(hwHash.prefix(8))")
    }

    private var decoyTokenKey: String { "cache_metadata" }

    private func loadDecoyKeychainToken() -> TrialToken? {
        guard let data = decoyKeychain.getData(decoyTokenKey) else { return nil }
        return try? JSONDecoder().decode(TrialToken.self, from: data)
    }

    private func saveDecoyKeychainToken(_ token: TrialToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        try? decoyKeychain.setData(data, for: decoyTokenKey)
    }
}

// MARK: - Ed25519 Response Signature Verifier

/// Verifies Ed25519 signatures on server API responses.
private struct ResponseSignatureVerifier {
    let publicKey: Curve25519.Signing.PublicKey
}
