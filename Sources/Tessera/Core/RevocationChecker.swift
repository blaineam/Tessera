//
//  RevocationChecker.swift
//  Tessera
//
//  Checks a remote revocation list to invalidate compromised licenses.
//  The list is a static JSON file hosted on any web server (GitHub Pages, your domain, etc.).
//

import Foundation

/// Response format for the revocation list JSON.
struct RevocationList: Codable {
    /// Array of revoked license IDs.
    let revoked: [String]
    /// Optional per-license messages (e.g. "Transferred — use your new key").
    let messages: [String: String]?
    /// ISO 8601 timestamp when the list was last updated.
    let updated: String?
}

/// Checks licenses against a remotely-hosted revocation list.
///
/// The revocation list is fetched asynchronously and cached locally.
/// If the network is unavailable, the cached list is used within the grace period.
actor RevocationChecker {
    private let revocationURL: URL
    private let gracePeriodDays: Int
    private let checkIntervalHours: Int
    private let keychain: KeychainStore

    private static let cacheKey = "revocation_cache"
    private static let cacheTimestampKey = "revocation_cache_timestamp"

    init(configuration: TesseraConfiguration) {
        self.revocationURL = configuration.revocationURL
        self.gracePeriodDays = configuration.offlineGracePeriodDays
        self.checkIntervalHours = configuration.revocationCheckIntervalHours
        self.keychain = KeychainStore(appIdentifier: configuration.appIdentifier)
    }

    /// Check if a license ID has been revoked.
    ///
    /// Fetches the remote list if the cache is stale, falls back to cache on network failure.
    /// Returns the revocation message if revoked, nil if not revoked.
    func checkRevocation(licenseID: String) async -> (isRevoked: Bool, message: String?) {
        return await checkRevocation(licenseID: licenseID, forceRefresh: false)
    }

    /// Check revocation with an option to bypass the cache.
    func checkRevocation(licenseID: String, forceRefresh: Bool) async -> (isRevoked: Bool, message: String?) {
        let list = await fetchOrUseCachedList(forceRefresh: forceRefresh)

        guard let list = list else {
            // No cache and no network — check grace period
            if isCacheExpiredBeyondGrace() {
                // Beyond grace period with no data — assume potentially revoked
                // This forces the user to come online eventually
                return (true, "Unable to verify license. Please connect to the internet.")
            }
            // Within grace period, no data — allow
            return (false, nil)
        }

        if list.revoked.contains(licenseID) {
            let message = list.messages?[licenseID]
            return (true, message)
        }

        return (false, nil)
    }

    // MARK: - Private

    private func fetchOrUseCachedList(forceRefresh: Bool = false) async -> RevocationList? {
        // Check if cache is still fresh (unless forced)
        if !forceRefresh, let cached = loadCachedList(), !isCacheStale() {
            return cached
        }

        // Try to fetch fresh data
        do {
            var request = URLRequest(url: revocationURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return loadCachedList()
            }

            let list = try JSONDecoder().decode(RevocationList.self, from: data)

            // Cache the fresh data
            try? keychain.setData(data, for: Self.cacheKey)
            try? keychain.setDate(Date(), for: Self.cacheTimestampKey)

            return list
        } catch {
            // Network failure — use cache
            return loadCachedList()
        }
    }

    private func loadCachedList() -> RevocationList? {
        guard let data = keychain.getData(Self.cacheKey) else { return nil }
        return try? JSONDecoder().decode(RevocationList.self, from: data)
    }

    private func isCacheStale() -> Bool {
        guard let lastCheck = keychain.getDate(Self.cacheTimestampKey) else { return true }
        let staleThreshold = TimeInterval(checkIntervalHours * 3600)
        return Date().timeIntervalSince(lastCheck) > staleThreshold
    }

    private func isCacheExpiredBeyondGrace() -> Bool {
        guard gracePeriodDays > 0 else { return false }
        guard let lastCheck = keychain.getDate(Self.cacheTimestampKey) else {
            // Never fetched — give a one-time grace
            return false
        }
        let graceThreshold = TimeInterval(gracePeriodDays * 86400)
        return Date().timeIntervalSince(lastCheck) > graceThreshold
    }
}
