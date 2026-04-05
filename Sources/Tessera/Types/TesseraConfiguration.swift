//
//  TesseraConfiguration.swift
//  Tessera
//
//  Configuration for the Tessera licensing system.
//

import Foundation

/// Configuration required to initialize the Tessera licensing system.
public struct TesseraConfiguration: Sendable {
    /// The Ed25519 public key (32 bytes, base64-encoded) used to verify license signatures.
    /// The corresponding private key is kept offline for license generation.
    public let publicKeyBase64: String

    /// URL of the revocation list JSON file (e.g. hosted on your domain or GitHub Pages).
    /// Format: { "revoked": ["uuid1", "uuid2"], "messages": { "uuid1": "reason" } }
    public let revocationURL: URL

    /// Number of days for the free trial period. Set to 0 to disable trials.
    public let trialDurationDays: Int

    /// Unique identifier for this app (typically the bundle identifier).
    /// Used to namespace Keychain and trial storage.
    public let appIdentifier: String

    /// How many days the app continues to work when it can't reach the revocation server.
    /// After this period, a network check is required. Set to 0 for no grace period.
    public let offlineGracePeriodDays: Int

    /// How often (in hours) to re-check the revocation list. Default: 24 hours.
    public let revocationCheckIntervalHours: Int

    /// A salt value compiled into the binary, used to derive hardware-bound trial tokens.
    /// Change this between major versions to invalidate old trial tokens.
    public let trialSalt: String

    /// Optional URL where users can purchase a license.
    public let purchaseURL: URL?

    /// The display name of the app (used in the default activation UI).
    public let appDisplayName: String

    /// Optional URL of the Tessera trial registry (Cloudflare Worker).
    /// When set, trial starts are registered server-side, making them impossible
    /// to reset by wiping local storage. Format: "https://tessera.yourname.workers.dev"
    /// Set to nil to use local-only trial enforcement (less secure but zero-infra).
    public let trialRegistryURL: URL?

    /// Shared secret for authenticating with the trial registry.
    /// Must match the TRIAL_SECRET configured on the Cloudflare Worker.
    /// Only needed if trialRegistryURL is set.
    public let trialRegistrySecret: String?

    /// Maximum number of devices that can simultaneously use a single license key.
    /// Set to 0 to disable device activation limits (unlimited installs).
    /// Requires `trialRegistryURL` to be set (uses the same Cloudflare Worker).
    /// The server enforces this via the `MAX_DEVICES` environment variable —
    /// this value is sent as a hint but the server has the final say.
    public let maxDevicesPerLicense: Int

    public init(
        publicKeyBase64: String,
        revocationURL: URL,
        trialDurationDays: Int = 14,
        appIdentifier: String,
        offlineGracePeriodDays: Int = 30,
        revocationCheckIntervalHours: Int = 24,
        trialSalt: String = "tessera-v1",
        purchaseURL: URL? = nil,
        appDisplayName: String = "App",
        trialRegistryURL: URL? = nil,
        trialRegistrySecret: String? = nil,
        maxDevicesPerLicense: Int = 0
    ) {
        self.publicKeyBase64 = publicKeyBase64
        self.revocationURL = revocationURL
        self.trialDurationDays = trialDurationDays
        self.appIdentifier = appIdentifier
        self.offlineGracePeriodDays = offlineGracePeriodDays
        self.revocationCheckIntervalHours = revocationCheckIntervalHours
        self.trialSalt = trialSalt
        self.purchaseURL = purchaseURL
        self.appDisplayName = appDisplayName
        self.trialRegistryURL = trialRegistryURL
        self.trialRegistrySecret = trialRegistrySecret
        self.maxDevicesPerLicense = maxDevicesPerLicense
    }
}
