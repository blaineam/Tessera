//
//  MASFallback.swift
//  Tessera
//
//  Helpers for dual MAS / direct-distribution builds.
//
//  Tessera uses StoreKit 2's AppTransaction to reliably detect the distribution
//  environment (App Store, TestFlight, Xcode, or direct distribution).
//
//  Usage:
//  ```swift
//  ContentView()
//      .tesseraGateIfNeeded(tessera)
//  ```
//
//  On App Store / TestFlight builds, the gate is a no-op.
//  On direct distribution builds, it enforces licensing.
//

import StoreKit
import SwiftUI

public extension View {
    /// Conditionally applies the Tessera licensing gate.
    ///
    /// On App Store / TestFlight builds, this is a no-op — the view passes through
    /// unmodified. On direct distribution builds, it enforces licensing.
    ///
    /// Detection uses StoreKit 2's AppTransaction (resolved in the gate's `.task`)
    /// with a fast synchronous fallback for already-resolved environments.
    ///
    /// ```swift
    /// ContentView()
    ///     .tesseraGateIfNeeded(tessera)
    /// ```
    @ViewBuilder
    func tesseraGateIfNeeded(_ tessera: Tessera?) -> some View {
        if TesseraBuildInfo.isAppStore {
            // Already resolved as App Store — skip gate entirely
            self
        } else if let tessera = tessera {
            // Not yet resolved or direct distribution — apply gate
            // (evaluate() will resolve StoreKit 2 environment and unlock if App Store)
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

/// Runtime detection of App Store vs. direct distribution using StoreKit 2.
///
/// Uses `AppTransaction.shared` to determine the distribution environment:
/// - `.production` → App Store
/// - `.sandbox` → TestFlight
/// - `.xcode` → Xcode development builds (licensing enforced)
/// - Error / unavailable → Direct distribution (licensing enforced)
public struct TesseraBuildInfo {
    /// Cached StoreKit 2 environment, set by `resolve()`.
    private static var _resolvedEnvironment: AppStore.Environment?
    private static var _resolved = false

    /// Whether the environment has been resolved via StoreKit 2.
    public static var isResolved: Bool { _resolved }

    /// The resolved StoreKit 2 environment, if available.
    public static var resolvedEnvironment: AppStore.Environment? { _resolvedEnvironment }

    /// Whether this app is running as an App Store or TestFlight build.
    ///
    /// Returns `true` if StoreKit 2 has resolved the environment as `.production`
    /// or `.sandbox`. Before resolution, returns `false` (safe default — the gate
    /// modifier will resolve via `evaluate()` before making licensing decisions).
    public static var isAppStore: Bool {
        guard let env = _resolvedEnvironment else { return false }
        return env == .production || env == .sandbox
    }

    /// Resolve the distribution environment using StoreKit 2's AppTransaction.
    ///
    /// Call this early (e.g. at the start of `evaluate()`) to determine the
    /// distribution channel. The result is cached — subsequent calls are no-ops.
    ///
    /// Environment mapping:
    /// - `.production` → App Store (skip licensing)
    /// - `.sandbox` → TestFlight (skip licensing)
    /// - `.xcode` → Xcode dev builds (enforce licensing)
    /// - Error → Direct distribution / notarized (enforce licensing)
    public static func resolve() async {
        guard !_resolved else { return }
        _resolved = true

        // Simulator is never App Store
        #if targetEnvironment(simulator)
        return
        #else
        // Try the local cached AppTransaction first
        if let env = Self.extractEnvironment(try? await AppTransaction.shared) {
            _resolvedEnvironment = env
            return
        }

        // .shared can fail if there's no local cache (e.g. macOS TestFlight).
        // .refresh() forces a server-side fetch from the App Store.
        if let env = Self.extractEnvironment(try? await AppTransaction.refresh()) {
            _resolvedEnvironment = env
            return
        }

        // Both failed → direct distribution → licensing enforced
        #endif
    }

    /// Extract the environment from an AppTransaction verification result.
    private static func extractEnvironment(_ result: VerificationResult<AppTransaction>?) -> AppStore.Environment? {
        guard let result else { return nil }
        switch result {
        case .verified(let transaction):
            return transaction.environment
        case .unverified(let transaction, _):
            return transaction.environment
        }
    }
}
