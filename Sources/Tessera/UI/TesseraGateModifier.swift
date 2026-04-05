//
//  TesseraGateModifier.swift
//  Tessera
//
//  SwiftUI view modifier that gates content behind a valid license.
//

import SwiftUI

/// A view modifier that shows either the app content or the activation screen
/// depending on the current Tessera licensing state.
struct TesseraGateModifier<ActivationContent: View>: ViewModifier {
    @ObservedObject var tessera: Tessera
    let customActivationView: () -> ActivationContent
    @State private var hasEvaluated = false
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        Group {
            if !hasEvaluated {
                // Show loading while initial evaluation runs
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Verifying license...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tessera.state.isUnlocked {
                content
            } else {
                customActivationView()
            }
        }
        .task {
            await tessera.evaluate()
            hasEvaluated = true
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                Task {
                    await tessera.recheckRevocation()
                }
            }
        }
    }
}
