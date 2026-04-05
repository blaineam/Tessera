//
//  TesseraActivationView.swift
//  Tessera
//
//  Default activation UI shown when the app is locked.
//  Apps can replace this with their own branded activation view.
//

import SwiftUI

/// The default Tessera activation/licensing UI.
///
/// Shows different content based on the current state:
/// - Unlicensed: license key input + optional "Start Trial" button
/// - Trial expired: license key input + "Trial expired" notice
/// - Expired: license key input + renewal prompt
/// - Revoked: revocation message + license key input
public struct TesseraActivationView: View {
    @ObservedObject var tessera: Tessera
    @State private var licenseKeyInput: String = ""
    @State private var isActivating: Bool = false
    @State private var errorMessage: String?
    @State private var showSuccess: Bool = false

    public init(tessera: Tessera) {
        self.tessera = tessera
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // Icon
                stateIcon
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                // Title & subtitle
                VStack(spacing: 8) {
                    Text(stateTitle)
                        .font(.title2.weight(.semibold))

                    Text(stateSubtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }

                // License key input
                VStack(spacing: 12) {
                    TextField("TESS-xxxx...xxxx", text: $licenseKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 480)
                        #if os(macOS)
                        .textFieldStyle(.squareBorder)
                        #endif

                    Button(action: activateLicense) {
                        if isActivating {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 100)
                        } else {
                            Text("Activate License")
                                .frame(width: 160)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(licenseKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || isActivating)
                    .keyboardShortcut(.return, modifiers: [])

                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                    }
                }

                // Trial button (only if no prior trial exists)
                if canStartTrial {
                    Divider()
                        .frame(maxWidth: 200)

                    VStack(spacing: 8) {
                        Text("or")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Button("Start \(tessera.configuration.trialDurationDays)-Day Free Trial") {
                            Task {
                                await tessera.evaluate()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // Purchase link
                if let purchaseURL = tessera.configuration.purchaseURL {
                    Link("Purchase a License", destination: purchaseURL)
                        .font(.callout)
                        .foregroundStyle(.blue)
                }
            }
            .padding(40)

            Spacer()

            // Footer
            Text("Powered by Tessera")
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    // MARK: - State-dependent content

    private var stateIcon: some View {
        Group {
            switch tessera.state {
            case .unlicensed:
                Image(systemName: "key.fill")
            case .trialExpired:
                Image(systemName: "clock.badge.exclamationmark")
            case .expired:
                Image(systemName: "calendar.badge.exclamationmark")
            case .revoked:
                Image(systemName: "xmark.shield.fill")
            default:
                Image(systemName: "key.fill")
            }
        }
    }

    private var stateTitle: String {
        switch tessera.state {
        case .trialExpired:
            return "Trial Expired"
        case .expired:
            return "License Expired"
        case .revoked(_, let message):
            return message ?? "License Revoked"
        default:
            return "Activate \(tessera.configuration.appDisplayName)"
        }
    }

    private var stateSubtitle: String {
        switch tessera.state {
        case .unlicensed:
            return "Enter your license key to get started."
        case .trialExpired:
            return "Your free trial has ended. Enter a license key to continue using \(tessera.configuration.appDisplayName)."
        case .expired(let license):
            if let date = license.expirationDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                return "Your license expired on \(formatter.string(from: date)). Please renew to continue."
            }
            return "Your license has expired. Please renew to continue."
        case .revoked:
            return "This license is no longer valid. If you believe this is an error, please contact support."
        default:
            return "Enter your license key below."
        }
    }

    private var canStartTrial: Bool {
        if tessera.configuration.trialDurationDays == 0 { return false }
        if tessera.hasUsedTrial { return false }
        if case .trialExpired = tessera.state { return false }
        return true
    }

    // MARK: - Actions

    private func activateLicense() {
        isActivating = true
        errorMessage = nil

        Task {
            do {
                try await tessera.activate(rawKey: licenseKeyInput)
                showSuccess = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isActivating = false
        }
    }
}
