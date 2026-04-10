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
- **Dual App Store / Direct distribution** — single codebase, compile-time flag separates builds
- **TestFlight support** — App Store scheme covers both production and TestFlight

All of this runs on **free infrastructure**: GitHub Actions, GitHub Pages, and Cloudflare Workers (free tier).

---

## Repository Structure

```
Tessera/
├── Sources/Tessera/          # Swift Package — the library you import
│   ├── Core/                 # License validator, revocation, keychain, build info helpers
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
                #if APP_STORE
                // App Store / TestFlight: no licensing gate
                #else
                .tesseraGate(tessera)
                #endif
        }
    }
}
```

> **Note:** Tessera uses a compile-time `APP_STORE` flag to separate App Store and direct distribution builds. See [Dual Distribution](#dual-distribution-app-store--direct) below for setup instructions. Use `tesseraGate` (without the `IfNeeded`) in the direct distribution branch — it always enforces licensing.

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

Support both App Store and direct distribution from a single codebase using **separate Xcode schemes** and a **compile-time flag**.

> **Why not runtime detection?** StoreKit 2's `AppTransaction.shared` is unreliable on macOS TestFlight — it can throw `SKInternalErrorDomain` errors instead of returning the expected `.sandbox` environment. A compile-time flag is deterministic and never fails.

### Setup

#### 1. Add a `Release-AppStore` build configuration

In Xcode, go to **Project → Info → Configurations** and duplicate your existing `Release` configuration. Name it `Release-AppStore`.

#### 2. Add the `APP_STORE` compilation condition

Select your **target** (not the project), go to **Build Settings → Swift Compiler - Custom Flags → Active Compilation Conditions**, and add `APP_STORE` to the `Release-AppStore` configuration only.

#### 3. Create two schemes

| Scheme | Purpose | Launch Config | Archive Config |
|--------|---------|---------------|----------------|
| **MyApp** | App Store / TestFlight | `Release-AppStore` | `Release-AppStore` |
| **MyApp-Direct** | Notarized direct distribution | `Debug` | `Release` |

The App Store scheme uses `Release-AppStore` which defines `APP_STORE`, so the Tessera gate is compiled out entirely. The Direct scheme uses the standard `Release` config — no `APP_STORE` flag — so Tessera licensing is enforced.

#### 4. Gate your content view

```swift
import Tessera

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                #if APP_STORE
                // App Store / TestFlight: no licensing gate
                #else
                .tesseraGate(tessera)
                #endif
        }
    }
}
```

#### 5. Build and distribute

- **App Store / TestFlight**: Archive with the `MyApp` scheme → Upload to App Store Connect
- **Direct distribution**: Archive with the `MyApp-Direct` scheme → Notarize and distribute
- **Xcode Cloud**: Set the workflow to use the `MyApp` scheme for TestFlight builds

### TesseraState reference

If you have exhaustive switches on `TesseraState`, all cases still apply in the direct distribution build:

```swift
switch tessera.state {
case .licensed(let license): // Valid license
case .trial(let days):       // Trial period active
case .expired(let license):  // License expired
case .revoked(_, let msg):   // License revoked
case .trialExpired:          // Trial ended
case .unlicensed:            // No license or trial
case .appStore:              // Only reachable if using runtime detection
}
```

The `.appStore` state is only relevant if you use the optional runtime `tesseraGateIfNeeded` modifier with `TesseraBuildInfo.resolve()`. With the compile-time approach, the gate is never applied on App Store builds, so `.appStore` is not reachable.

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
