//
//  TesseraStatusView.swift
//  Tessera
//
//  A small status badge view showing the current license state.
//  Drop this into a settings/about screen.
//

import SwiftUI

/// A compact license status view for use in settings or about screens.
///
/// Shows the current license state with an icon, description, and
/// optional deactivate button.
public struct TesseraStatusView: View {
    @ObservedObject var tessera: Tessera
    @State private var showDeactivateConfirm = false

    public init(tessera: Tessera) {
        self.tessera = tessera
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                statusIcon
                    .foregroundStyle(statusColor)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tessera.state.statusDescription)
                        .font(.body.weight(.medium))

                    if let license = tessera.license {
                        Text("ID: \(String(license.lid.prefix(8)))...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Spacer()

                if tessera.license != nil {
                    Button("Deactivate", role: .destructive) {
                        showDeactivateConfirm = true
                    }
                    .controlSize(.small)
                    .confirmationDialog(
                        "Deactivate License?",
                        isPresented: $showDeactivateConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Deactivate", role: .destructive) {
                            tessera.deactivate()
                        }
                    } message: {
                        Text("You can re-activate later with the same license key.")
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var statusIcon: some View {
        Group {
            switch tessera.state {
            case .licensed, .appStore:
                Image(systemName: "checkmark.seal.fill")
            case .trial:
                Image(systemName: "clock.fill")
            case .trialExpired, .expired:
                Image(systemName: "exclamationmark.triangle.fill")
            case .revoked:
                Image(systemName: "xmark.seal.fill")
            case .unlicensed:
                Image(systemName: "lock.fill")
            }
        }
    }

    private var statusColor: Color {
        switch tessera.state {
        case .licensed, .appStore: return .green
        case .trial: return .blue
        case .trialExpired, .expired: return .orange
        case .revoked: return .red
        case .unlicensed: return .secondary
        }
    }
}
