//
//  MASFallback.swift
//  Tessera
//
//  Helpers for dual MAS / direct-distribution builds.
//
//  Tessera automatically detects App Store vs. direct distribution at runtime
//  by inspecting the receipt path — no compiler flags needed.
//
//  Usage:
//  ```swift
//  ContentView()
//      .tesseraGateIfNeeded(tessera)
//  ```
//
//  On App Store builds, the gate is a no-op. On direct builds, it enforces licensing.
//

import SwiftUI

public extension View {
    /// Conditionally applies the Tessera licensing gate.
    ///
    /// On App Store builds (detected at runtime via receipt path), this is a no-op —
    /// the view passes through unmodified. On direct distribution builds, it enforces licensing.
    ///
    /// This allows a single binary/codebase for both distribution channels:
    /// ```swift
    /// ContentView()
    ///     .tesseraGateIfNeeded(tessera)
    /// ```
    @ViewBuilder
    func tesseraGateIfNeeded(_ tessera: Tessera?) -> some View {
        if TesseraBuildInfo.isAppStore {
            self
        } else if let tessera = tessera {
            self.tesseraGate(tessera)
        } else {
            self
        }
    }

    /// Conditionally applies the Tessera licensing gate with a custom activation view.
    @ViewBuilder
    func tesseraGateIfNeeded<ActivationContent: View>(
        _ tessera: Tessera?,
        @ViewBuilder activationView: @escaping () -> ActivationContent
    ) -> some View {
        if TesseraBuildInfo.isAppStore {
            self
        } else if let tessera = tessera {
            self.tesseraGate(tessera, activationView: activationView)
        } else {
            self
        }
    }
}

/// Runtime detection of App Store vs. direct distribution.
///
/// No compiler flags needed — Tessera inspects the bundle's receipt path
/// to determine the distribution channel automatically.
public struct TesseraBuildInfo {
    /// Whether this app is running as a Mac App Store, iOS App Store, or TestFlight build.
    ///
    /// Detection method:
    /// - **macOS**: App Store receipts live at `_MASReceipt/receipt` inside the bundle.
    ///   Direct distribution builds use `Resources/receipt` (or have no receipt at all).
    /// - **iOS**: TestFlight builds are detected via the sandbox receipt URL
    ///   (`appStoreReceiptURL` contains "sandboxReceipt"). App Store builds do NOT
    ///   contain `embedded.mobileprovision`. Both are treated as valid App Store installs.
    public static var isAppStore: Bool {
        #if os(macOS)
        return Bundle.main.appStoreReceiptURL?.path.contains("_MASReceipt") == true
        #elseif os(iOS)
        // TestFlight builds have a sandbox receipt — treat them as App Store
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            return true
        }
        // App Store builds lack embedded.mobileprovision; ad-hoc/dev builds have it
        return !FileManager.default.fileExists(
            atPath: Bundle.main.bundlePath + "/embedded.mobileprovision"
        )
        #else
        return false
        #endif
    }
}
