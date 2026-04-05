//
//  MASFallback.swift
//  Tessera
//
//  Helpers for dual MAS / direct-distribution builds.
//
//  Use the APPSTORE compiler flag to gate Tessera:
//
//  In Xcode → Build Settings → Swift Compiler - Custom Flags:
//    - Mac App Store target: add -DAPPSTORE
//    - Direct distribution target: leave it out
//
//  Then in your app:
//  ```swift
//  ContentView()
//      .tesseraGateIfNeeded(tessera)
//  ```
//
//  On APPSTORE builds, the gate is a no-op. On direct builds, it enforces licensing.
//

import SwiftUI

public extension View {
    /// Conditionally applies the Tessera licensing gate.
    ///
    /// On App Store builds (when `APPSTORE` flag is set), this is a no-op — the view
    /// passes through unmodified. On direct distribution builds, it enforces licensing.
    ///
    /// This allows a single codebase for both distribution channels:
    /// ```swift
    /// ContentView()
    ///     .tesseraGateIfNeeded(tessera)
    /// ```
    @ViewBuilder
    func tesseraGateIfNeeded(_ tessera: Tessera?) -> some View {
        #if APPSTORE
        self
        #else
        if let tessera = tessera {
            self.tesseraGate(tessera)
        } else {
            self
        }
        #endif
    }

    /// Conditionally applies the Tessera licensing gate with a custom activation view.
    @ViewBuilder
    func tesseraGateIfNeeded<ActivationContent: View>(
        _ tessera: Tessera?,
        @ViewBuilder activationView: @escaping () -> ActivationContent
    ) -> some View {
        #if APPSTORE
        self
        #else
        if let tessera = tessera {
            self.tesseraGate(tessera, activationView: activationView)
        } else {
            self
        }
        #endif
    }
}

/// Utility to detect if the current build is an App Store build at runtime.
/// This complements the compile-time APPSTORE flag with a runtime check.
public struct TesseraBuildInfo {
    /// Whether this build has an App Store receipt (indicates MAS distribution).
    public static var hasAppStoreReceipt: Bool {
        #if os(macOS)
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "receipt"
        #else
        return Bundle.main.appStoreReceiptURL != nil
        #endif
    }

    /// Whether the APPSTORE compiler flag is set.
    public static var isAppStoreBuild: Bool {
        #if APPSTORE
        return true
        #else
        return false
        #endif
    }
}
