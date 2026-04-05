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

    func body(content: Content) -> some View {
        Group {
            if !hasEvaluated {
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
        .onReceive(TesseraAppLifecycle.didBecomeActivePublisher) { _ in
            Task {
                await tessera.recheckRevocation()
            }
        }
    }
}

/// Cross-platform app lifecycle publisher.
enum TesseraAppLifecycle {
    static var didBecomeActivePublisher: NotificationCenter.Publisher {
        #if os(macOS)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        #else
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        #endif
    }
}
