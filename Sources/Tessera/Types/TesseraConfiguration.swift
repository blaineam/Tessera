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
    /// Format: { "revoked": ["uuid1", "uuid2"], "messages": { "uuid1": "reason" }, "signature": "<base64>" }
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
    ///
    /// Note: This secret is embedded in the binary and can be extracted by a determined attacker.
    /// It provides a speed bump against casual attacks but is not a strong security boundary.
    /// The server-side Ed25519 response signing (via `responseVerificationKeyBase64`) provides
    /// stronger protection against response forgery.
    public let trialRegistrySecret: String?

    /// Maximum number of devices that can simultaneously use a single license key.
    /// Set to 0 to disable device activation limits (unlimited installs).
    /// Requires `trialRegistryURL` to be set (uses the same Cloudflare Worker).
    /// The server enforces this via the `MAX_DEVICES` environment variable —
    /// this value is sent as a hint but the server has the final say.
    public let maxDevicesPerLicense: Int

    /// Your Apple Developer Team ID (e.g. "ABC123XYZ").
    /// When set, runtime integrity checks verify the binary was signed by this specific team,
    /// preventing re-signing attacks where an attacker modifies the binary and signs with
    /// their own certificate. Strongly recommended for release builds.
    public let expectedTeamID: String?

    /// Ed25519 public key (32 bytes, base64-encoded) for verifying server responses.
    /// The corresponding private key is held by the Cloudflare Worker and used to sign
    /// all trial/activation API responses. This provides asymmetric authentication that
    /// cannot be forged even if the `trialRegistrySecret` is extracted from the binary.
    /// Only needed if trialRegistryURL is set.
    public let responseVerificationKeyBase64: String?

    /// Allowed origin for CORS on the trial/activation API.
    /// Passed to the worker configuration. Not used client-side.
    public let allowedOrigin: String?

    public init(
        publicKeyBase64: String,
        revocationURL: URL,
        trialDurationDays: Int = 14,
        appIdentifier: String,
        offlineGracePeriodDays: Int = 7,
        revocationCheckIntervalHours: Int = 24,
        trialSalt: String = "tessera-v1",
        purchaseURL: URL? = nil,
        appDisplayName: String = "App",
        trialRegistryURL: URL? = nil,
        trialRegistrySecret: String? = nil,
        maxDevicesPerLicense: Int = 0,
        expectedTeamID: String? = nil,
        responseVerificationKeyBase64: String? = nil,
        allowedOrigin: String? = nil
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
        self.expectedTeamID = expectedTeamID
        self.responseVerificationKeyBase64 = responseVerificationKeyBase64
        self.allowedOrigin = allowedOrigin
    }
}
