//
//  TesseraError.swift
//  Tessera
//
//  Error types for the Tessera licensing system.
//

import Foundation

/// Errors that can occur during license operations.
public enum TesseraError: LocalizedError, Sendable {
    case invalidKeyFormat
    case signatureVerificationFailed
    case licenseExpired
    case licenseRevoked(message: String?)
    case trialExpired
    case trialTampered
    case clockTampered
    case keychainError(String)
    case invalidPublicKey
    case decodingFailed
    case integrityCheckFailed
    case activationLimitReached(maxDevices: Int)
    case deviceNotActivated
    case activationServerUnreachable

    public var errorDescription: String? {
        switch self {
        case .invalidKeyFormat:
            return "Invalid license key format. Keys should start with TESS- followed by the encoded key."
        case .signatureVerificationFailed:
            return "License signature verification failed. This key may be invalid or corrupted."
        case .licenseExpired:
            return "This license has expired."
        case .licenseRevoked(let message):
            return message ?? "This license has been revoked."
        case .trialExpired:
            return "The trial period has expired."
        case .trialTampered:
            return "Trial data integrity check failed."
        case .clockTampered:
            return "System clock inconsistency detected."
        case .keychainError(let detail):
            return "Keychain operation failed: \(detail)"
        case .invalidPublicKey:
            return "Invalid public key configuration."
        case .decodingFailed:
            return "Failed to decode license data."
        case .integrityCheckFailed:
            return "Application integrity check failed."
        case .activationLimitReached(let maxDevices):
            return "This license has reached its device limit (\(maxDevices) device\(maxDevices == 1 ? "" : "s")). Deactivate another device first."
        case .deviceNotActivated:
            return "This device is not activated for this license."
        case .activationServerUnreachable:
            return "Unable to reach the activation server. Please check your internet connection and try again."
        }
    }
}
