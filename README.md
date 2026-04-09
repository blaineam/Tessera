# Tessera

**Cryptographic App Licensing for macOS & iOS**

Unforgeable licenses. Stripe subscriptions. Multi-app support. Zero tracking.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## What is Tessera?

Tessera is a complete, self-contained licensing platform for macOS and iOS apps distributed outside the App Store. Fork this repo, configure your app, and you have:

- **Ed25519 signed license keys** — cryptographically unforgeable
- **Multi-app support** — one Tessera repo manages licensing for all your apps
- **Hardware-anchored trials** — tamper-resistant, clock-manipulation-proof
- **Remote revocation** — via a static JSON file on your domain (no servers needed)
- **Instant revocation enforcement** — checks on every app foreground, no 24h wait
- **Device seat limiting** — restrict each license to N machines, server-enforced
- **Stripe subscription billing** — automatic license delivery and renewal
- **Management dashboard** — multi-app tabs, generate signed keys, revoke licenses
- **GitHub Action CI** — generate licenses per-app from anywhere
- **Marketing site** — glassmorphic GitHub Pages site ready to deploy
- **Dual App Store / Direct distribution** — single codebase, automatic detection via StoreKit 2 `AppTransaction`
- **TestFlight support** — treated as App Store on both macOS and iOS

All of this runs on **free infrastructure**: GitHub Actions, GitHub Pages, and Cloudflare Workers (free tier).

---

## Repository Structure

```
Tessera/
├── Sources/Tessera/          # Swift Package — the library you import
│   ├── Core/                 # License validator, revocation, keychain, StoreKit 2 detection
│   ├── Trial/                # Hardware-anchored trial system
│   ├── Security/             # Binary integrity checker
│   ├── UI/                   # SwiftUI gate, activation view, status badge
│   └── Types/                # License, state, config, error types
├── Tests/TesseraTests/       # Unit tests
├── Tools/                    # CLI, Stripe worker, setup script
│   ├── tessera_cli.py        # License generation & management CLI
│   ├── stripe_worker.js      # Cloudflare Worker for Stripe webhooks
│   ├── wrangler.toml         # Cloudflare Worker config
│   ├── setup.sh              # One-command setup wizard
│   └── requirements.txt      # Python dependencies
├── Site/                     # GitHub Pages site (deploy from this repo)
│   ├── index.html            # Marketing page
│   ├── dashboard.html        # Multi-app license management dashboard
│   ├── checkout.html         # Stripe checkout page template
│   ├── apps/<app>/licensing/ # Per-app license & revocation data
│   └── CNAME                 # Custom domain config
├── .github/workflows/        # GitHub Actions
│   ├── tessera-generate-license.yml   # Per-app license generation
│   ├── tessera-renew-license.yml      # Per-app subscription renewal
│   └── static.yml                     # GitHub Pages deployment
├── Package.swift             # Swift Package Manager manifest (macOS 13+, iOS 16+)
├── tessera.config.example.json  # Configuration template
├── INTEGRATION_GUIDE.md      # Step-by-step integration docs
├── WHY_TESSERA.md            # Comparison with alternatives
└── LICENSE                   # MIT
```

---

## Quick Start

### 1. Fork this repo

Click **Fork** on GitHub, or:
```bash
gh repo create my-licensing --template blaineam/tessera --public
```

### 2. Run the setup wizard

```bash
cd tessera
chmod +x Tools/setup.sh
./Tools/setup.sh
```

This will:
- Generate your Ed25519 keypair
- Create `tessera.config.json` from the template
- Print the public key to embed in your app

### 3. Add repo secrets

Go to **Settings → Secrets and variables → Actions** and add:

| Secret | Value |
|--------|-------|
| `TESSERA_PRIVATE_KEY` | Shared fallback private key (PEM) |
| `TESSERA_PRIVATE_KEY_<APP>` | Per-app private key, e.g. `TESSERA_PRIVATE_KEY_ARI` (optional, overrides shared) |

And optionally (for email delivery):

| Secret | Value |
|--------|-------|
| `SMTP_USERNAME` | Email account for license delivery |
| `SMTP_PASSWORD` | Email password or app password |
| `SMTP_FROM` | Sender address (e.g. `noreply@yourdomain.com`) |

And optionally (for Stripe):

| Secret | Value |
|--------|-------|
| `STRIPE_SECRET_KEY` | `sk_live_...` from Stripe |
| `STRIPE_WEBHOOK_SECRET` | `whsec_...` from Stripe |

### 4. Add the Swift package to your app

In Xcode: **File → Add Package Dependencies** → enter your Tessera repo URL.

Or in `Package.swift`:
```swift
.package(url: "https://github.com/yourname/Tessera", branch: "main")
```

Then in your app:

```swift
import Tessera

@MainActor
let tessera = Tessera(configuration: .init(
    publicKeyBase64: "YOUR_PUBLIC_KEY_FROM_SETUP",
    revocationURL: URL(string: "https://yourdomain.com/apps/myapp/licensing/revoked.json")!,
    appIdentifier: "com.yourcompany.yourapp",
    appDisplayName: "Your App"
))

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tesseraGateIfNeeded(tessera)
        }
    }
}
```

> **Note:** `tesseraGateIfNeeded` is the recommended entry point. It uses StoreKit 2's `AppTransaction` to detect App Store and TestFlight builds at runtime and skips the licensing gate — no compiler flags needed. Use `tesseraGate` if you always want to enforce licensing regardless of distribution channel.

### 5. Set up per-app data

Create the licensing data files in your Site directory:

```bash
mkdir -p Site/apps/myapp/licensing
echo '{"licenses":[],"updated":""}' > Site/apps/myapp/licensing/licenses.json
echo '{"revoked":[],"messages":{},"updated":""}' > Site/apps/myapp/licensing/revoked.json
```

### 6. Add the app to the workflow

Edit `.github/workflows/tessera-generate-license.yml` and add your app to the `app` input choices:

```yaml
inputs:
  app:
    type: choice
    options:
      - myapp
```

### 7. Deploy the site

The `Site/` directory is deployed automatically to GitHub Pages via the included `static.yml` workflow on every push to `main`.

### 8. Generate your first license

**Via the dashboard** at `https://yourdomain.com/dashboard.html`:
- Connect with a GitHub PAT
- Configure your app with its slug, licenses path, and revocation path
- Optionally paste your Ed25519 private key for client-side signing
- Click "+ New License" — keys are generated and optionally emailed

**Via GitHub Actions UI**: go to Actions → "Tessera: Generate License" → Run workflow

**Via CLI**:
```bash
python3 Tools/tessera_cli.py generate \
    --private-key keys/private.pem \
    --tier pro --duration 365
```

---

## Multi-App Support

Tessera manages licensing for multiple apps from a single repo. Each app gets:

- **Its own data directory**: `Site/apps/<app-slug>/licensing/`
- **Its own private key** (optional): `TESSERA_PRIVATE_KEY_<APP_UPPER>` secret
- **Its own tab** in the dashboard

### Workflow

The generate and renew workflows accept an `app` input that determines:
1. Which private key to use (tries `TESSERA_PRIVATE_KEY_<APP>`, falls back to `TESSERA_PRIVATE_KEY`)
2. Where to write license data (`Site/apps/<app>/licensing/`)

### Dashboard

The dashboard supports multiple apps via tabs. Each app is configured with:
- **Name**: Display name
- **Slug**: Lowercase identifier that matches the workflow's `app` choice (e.g. `ari`)
- **Licenses path**: Path to `licenses.json` in the repo (e.g. `Site/apps/ari/licensing/licenses.json`)
- **Revocation path**: Path to `revoked.json` in the repo

Add apps in the initial setup screen or via Settings.

> **Encryption note:** Any PII (customer emails, names) stored in license data is encrypted end-to-end in the dashboard. The encryption key never leaves your browser, so GitHub (the storage backend) cannot read customer data at rest.

---

## Dual Distribution (App Store + Direct)

Support both App Store and direct distribution from one codebase — **no compiler flags needed**.

Tessera uses **StoreKit 2's `AppTransaction`** to reliably detect the distribution environment at runtime:

| Environment | `AppTransaction.environment` | Licensing |
|-------------|------------------------------|-----------|
| **App Store** | `.production` | Skipped — gate is a no-op |
| **TestFlight** | `.sandbox` | Skipped — gate is a no-op |
| **Xcode** | `.xcode` | Enforced |
| **Direct / Notarized** | Error (no transaction) | Enforced |
| **Simulator** | — | Enforced (early return) |

```swift
// Automatically a no-op on App Store and TestFlight builds
ContentView()
    .tesseraGateIfNeeded(tessera)
```

### How it works

On app launch, `evaluate()` calls `AppTransaction.shared` to resolve the distribution environment. The result is cached for the lifetime of the process.

- **App Store** (`.production`) and **TestFlight** (`.sandbox`) builds set the state to `.appStore`, which `isUnlocked` treats as `true`. All licensing checks (integrity, revocation, trials) are skipped.
- **Xcode** builds (`.xcode`) and **direct distribution** builds (where `AppTransaction` throws because there's no App Store transaction) proceed through normal license enforcement.
- **Simulator** builds return early before the StoreKit 2 check and are always treated as direct builds.

This approach is more reliable than the legacy receipt-file heuristic, which could fail on macOS App Store first launch before the receipt was written to disk.

### TesseraState.appStore

The `.appStore` state is returned by `evaluate()` when StoreKit 2 detects an App Store or TestFlight environment. It returns `true` for `isUnlocked`. If you have exhaustive switches on `TesseraState`, add a case for `.appStore`:

```swift
switch tessera.state {
case .licensed(let license): // ...
case .trial(let days):       // ...
case .appStore:              // App Store / TestFlight — no license needed
case .expired(let license):  // ...
case .revoked(_, let msg):   // ...
case .trialExpired:          // ...
case .unlicensed:            // ...
}
```

TestFlight builds on **both macOS and iOS** are treated as App Store installs — users won't see a licensing prompt.

---

## Revocation

Revoked licenses are enforced via a static `revoked.json` file:

```json
{
  "revoked": ["license-uuid-1", "license-uuid-2"],
  "messages": {
    "license-uuid-1": "Transferred to a new key"
  },
  "updated": "2026-04-05T12:00:00Z"
}
```

### Instant enforcement

Tessera checks the revocation list:
- **On every app launch** (during `evaluate()`)
- **On every app foreground** (via `recheckRevocation()`, called automatically by the gate modifier)

Foreground checks always bypass the cache and fetch the latest list. There's no 24-hour wait for revocations to take effect.

### Offline behavior

If the revocation server is unreachable, Tessera uses the cached list within the **offline grace period** (default: 30 days). After the grace period expires without a successful check, the app requires connectivity.

---

## Stripe Integration

Tessera includes a complete Stripe subscription billing pipeline:

```
Customer → Checkout Page → Stripe → Webhook → Cloudflare Worker → GitHub Action → License Key → Email
                                                                                                 ↓
                                                                          Subscription Renewal → New License → Email
```

### Setup

1. **Create Stripe Products & Prices** in your Stripe Dashboard
2. **Configure `checkout.html`** with your Stripe publishable key and Price IDs
3. **Deploy the Cloudflare Worker**:
   ```bash
   cd Tools
   npx wrangler secret put STRIPE_WEBHOOK_SECRET
   npx wrangler secret put STRIPE_SECRET_KEY
   npx wrangler secret put GITHUB_TOKEN
   npx wrangler secret put GITHUB_REPO        # yourname/tessera
   npx wrangler secret put GITHUB_WORKFLOW_ID  # tessera-generate-license.yml
   npx wrangler deploy
   ```
4. **Add the webhook URL** in Stripe Dashboard → Webhooks:
   - URL: `https://tessera-stripe.yourname.workers.dev/webhook`
   - Events: `checkout.session.completed`, `invoice.paid`, `customer.subscription.deleted`

5. **Set metadata on your Stripe Prices** (in the Stripe Dashboard):
   - `tier`: `personal`, `pro`, or `team`
   - `duration_days`: `365` (or `30` for monthly)
   - `features`: `0`

---

## Device Seat Limiting

Restrict each license key to a maximum number of simultaneous devices:

```swift
let tessera = Tessera(configuration: .init(
    publicKeyBase64: "YOUR_KEY",
    revocationURL: URL(string: "https://yourdomain.com/apps/myapp/licensing/revoked.json")!,
    appIdentifier: "com.yourcompany.yourapp",
    appDisplayName: "Your App",
    trialRegistryURL: URL(string: "https://tessera.yourname.workers.dev")!,
    trialRegistrySecret: "YOUR_SECRET",
    maxDevicesPerLicense: 3  // 0 = unlimited (default)
))
```

The activation system uses the same Cloudflare Worker as the trial registry.

---

## Security Model

| Attack | Defense |
|--------|---------|
| Forge license | Ed25519 signature — computationally infeasible |
| Patch binary | `SecCodeCheckValidity` runtime integrity check |
| Reset trial (delete app) | Keychain + hidden file persist |
| Reset trial (delete Keychain) | Hidden file persists; any anchor = trial started |
| Clock manipulation | Monotonic date tracking detects backwards clock |
| Copy trial between Macs | Hardware fingerprint (IOPlatformUUID) mismatch |
| Share license globally | Device seat limiting — server-enforced max devices |
| MITM activation/trial | HMAC-authenticated requests & responses |
| MITM revocation check | HTTPS + JSON schema validation |

---

## Configuration Reference

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `publicKeyBase64` | String | required | Ed25519 public key (base64, 32 bytes) |
| `revocationURL` | URL | required | URL to `revoked.json` |
| `trialDurationDays` | Int | 14 | Trial length (0 = no trial, license required immediately) |
| `appIdentifier` | String | required | Bundle ID (used for Keychain namespace) |
| `offlineGracePeriodDays` | Int | 7 | Days without revocation check allowed |
| `revocationCheckIntervalHours` | Int | 24 | Revocation cache TTL (foreground checks always bypass) |
| `trialSalt` | String | "tessera-v1" | Salt for trial tokens (change between major versions) |
| `purchaseURL` | URL? | nil | Link to purchase page |
| `appDisplayName` | String | "App" | Name shown in activation UI |
| `trialRegistryURL` | URL? | nil | Cloudflare Worker URL for server-side trials + activation |
| `trialRegistrySecret` | String? | nil | Shared secret for Worker authentication |
| `maxDevicesPerLicense` | Int | 0 | Max devices per license (0 = unlimited) |
| `expectedTeamID` | String? | nil | Apple Team ID for binary signing verification |
| `responseVerificationKeyBase64` | String? | nil | Ed25519 key for server response verification |
| `allowedOrigin` | String? | nil | CORS origin for trial/activation API |

---

## License

MIT — free for commercial and open-source use.

Copyright (c) 2026 Blaine Miller
