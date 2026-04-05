//
//  LicenseState.swift
//  Tessera
//
//  The possible states of the licensing gate.
//

import Foundation

/// Represents the current licensing state of the application.
public enum TesseraState: Sendable {
    /// A valid, verified license is active.
    case licensed(TesseraLicense)
    /// The user is within the trial period.
    case trial(daysRemaining: Int)
    /// The trial has expired and no license is present.
    case trialExpired
    /// A license was found but it has expired.
    case expired(TesseraLicense)
    /// A license was found but it has been revoked.
    case revoked(TesseraLicense, message: String?)
    /// No license or trial — app is locked.
    case unlicensed

    /// Whether the app should be unlocked (usable).
    public var isUnlocked: Bool {
        switch self {
        case .licensed, .trial:
            return true
        case .expired, .revoked, .trialExpired, .unlicensed:
            return false
        }
    }

    /// A human-readable status string.
    public var statusDescription: String {
        switch self {
        case .licensed(let license):
            if license.isPerpetual {
                return "Licensed (\(license.tier))"
            } else if let exp = license.expirationDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                return "Licensed until \(formatter.string(from: exp))"
            }
            return "Licensed"
        case .trial(let days):
            return "\(days) day\(days == 1 ? "" : "s") remaining in trial"
        case .trialExpired:
            return "Trial expired"
        case .expired:
            return "License expired"
        case .revoked(_, let message):
            return message ?? "License revoked"
        case .unlicensed:
            return "No license"
        }
    }
}
