# Tessera

**Cryptographic App Licensing for macOS**

Unforgeable licenses. Device seat limiting. Stripe subscriptions. Zero tracking.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## What is Tessera?

Tessera is a complete, self-contained licensing platform for macOS apps distributed outside the Mac App Store. Fork this repo, run the setup wizard, and you have:

- **Ed25519 signed license keys** — cryptographically unforgeable
- **Device seat limiting** — restrict each license to N machines, server-enforced
- **Hardware-anchored trials** — tamper-resistant, clock-manipulation-proof
- **Remote revocation** — via a static JSON file on your domain (no servers)
- **Stripe subscription billing** — automatic license delivery and renewal
- **Management dashboard** — monitor, revoke, and nickname licenses
- **GitHub Action CI** — generate licenses from anywhere
- **Marketing site** — glassmorphic GitHub Pages site ready to deploy
- **Dual MAS/Direct distribution** — single codebase, automatic runtime detection

All of this runs on **free infrastructure**: GitHub Actions, GitHub Pages, and Cloudflare Workers (free tier).

---

## Repository Structure

```
Tessera/
├── Sources/Tessera/          # Swift Package — the library you import
│   ├── Core/                 # License validator, revocation, keychain
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
├── Site/                     # GitHub Pages site (deploy to your repo)
│   ├── index.html            # Marketing page
│   ├── dashboard.html        # License management dashboard
│   ├── checkout.html         # Stripe checkout page template
│   └── CNAME                 # Custom domain config
├── .github/workflows/        # GitHub Actions
│   ├── tessera-generate-license.yml   # Manual + webhook license generation
│   └── tessera-renew-license.yml      # Subscription renewal handling
├── Package.swift             # Swift Package Manager manifest
├── tessera.config.example.json  # Configuration template
├── INTEGRATION_GUIDE.md      # Step-by-step integration docs
├── WHY_TESSERA.md            # Comparison with alternatives
└── LICENSE                   # MIT
```

---

## Quick Start (Fork & Deploy)

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
| `TESSERA_PRIVATE_KEY` | Contents of `Tools/keys/private.pem` |
| `PAGES_REPO_TOKEN` | GitHub PAT with `repo` scope |

And optionally (for Stripe):

| Secret | Value |
|--------|-------|
| `STRIPE_SECRET_KEY` | `sk_live_...` from Stripe |
| `STRIPE_WEBHOOK_SECRET` | `whsec_...` from Stripe |
| `SMTP_USERNAME` | Email account for license delivery |
| `SMTP_PASSWORD` | Email password or app password |

Also add **repository variables** (Settings → Variables):

| Variable | Value |
|----------|-------|
| `TESSERA_PAGES_REPO` | `yourname/yourname.github.io` |
| `TESSERA_DATA_PATH` | `licensing` (path in pages repo) |

### 4. Add the Swift package to your app

In Xcode: **File → Add Package Dependencies → Add Local** → select this directory.

Then in your app:

```swift
import Tessera

// Configure once
@MainActor
let tessera = Tessera(configuration: .init(
    publicKeyBase64: "YOUR_PUBLIC_KEY_FROM_SETUP",
    revocationURL: URL(string: "https://yourdomain.com/licensing/revoked.json")!,
    appIdentifier: "com.yourcompany.yourapp",
    appDisplayName: "Your App"
))

// Gate your app (one line)
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tesseraGate(tessera)
        }
    }
}
```

### 5. Deploy the site

Copy `Site/` contents to your GitHub Pages repo. Update the `CNAME` file with your domain.

### 6. Generate your first license

Via GitHub Actions UI, or locally:
```bash
python3 Tools/tessera_cli.py generate \
    --private-key Tools/keys/private.pem \
    --tier pro --duration 365
```

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

### How Renewals Work

When a subscription renews:
1. Stripe fires `invoice.paid`
2. The Cloudflare Worker receives it and triggers the **renewal workflow**
3. A new license key is generated with the new expiration date
4. The old license is marked as `renewed_by` in `licenses.json`
5. The new key is emailed to the customer
6. The old key continues to work until its original expiry (graceful overlap)

---

## Dual Distribution (MAS + Direct)

Support both Mac App Store and direct distribution from one codebase — **no compiler flags needed**.

Tessera automatically detects the distribution channel at runtime by inspecting the bundle's receipt path:
- **macOS**: App Store receipts live at `_MASReceipt/receipt`; direct distribution uses `Resources/receipt`
- **iOS**: App Store builds lack `embedded.mobileprovision`; TestFlight/ad-hoc builds include it

```swift
// Automatically a no-op on App Store builds — detected at runtime
ContentView()
    .tesseraGateIfNeeded(tessera)
```

---

## Device Seat Limiting

Restrict each license key to a maximum number of simultaneous devices:

```swift
let tessera = Tessera(configuration: .init(
    publicKeyBase64: "YOUR_KEY",
    revocationURL: URL(string: "https://yourdomain.com/licensing/revoked.json")!,
    appIdentifier: "com.yourcompany.yourapp",
    appDisplayName: "Your App",
    trialRegistryURL: URL(string: "https://tessera.yourname.workers.dev")!,
    trialRegistrySecret: "YOUR_SECRET",
    maxDevicesPerLicense: 3  // 0 = unlimited (default)
))
```

### How it works

1. On **first activation**, the app registers the device fingerprint with the Cloudflare Worker
2. The worker checks how many devices are already activated for that license
3. If under the limit → activation succeeds; at the limit → activation is rejected
4. On **deactivation**, the device seat is released so another machine can use it
5. Activation status is **cached locally** with the same offline grace period as revocation

### Worker setup

The activation system uses the same Cloudflare Worker as the trial registry. Add the `MAX_DEVICES` env var:

```bash
npx wrangler secret put TRIAL_SECRET        # same secret used for trials
echo "3" | npx wrangler secret put MAX_DEVICES  # max devices per license
npx wrangler deploy
```

### Offline behavior

- **Initial activation** requires network connectivity (must register the device)
- After activation, the app caches the status and works **offline for the grace period** (default: 30 days)
- Re-verification happens on the same schedule as revocation checks (default: every 24 hours)
- If the server is unreachable within the grace period, the cached activation is trusted

---

## Management Dashboard

Open `Site/dashboard.html` in your browser. It connects to GitHub via your PAT (stored in localStorage only) and provides:

- License overview (active, expiring, expired, revoked counts)
- Expiration timeline visualization
- Editable nicknames for each license
- One-click revocation with custom messages
- Subscription tracking with renewal indicators
- Manual license entry

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
| Share license globally | Device seat limiting — server-enforced max devices per license |
| MITM activation/trial | HMAC-authenticated requests & responses — secret never on wire |
| MITM revocation check | HTTPS + JSON schema validation |

---

## Configuration Reference

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `publicKeyBase64` | String | required | Ed25519 public key |
| `revocationURL` | URL | required | URL to `revoked.json` |
| `trialDurationDays` | Int | 14 | Trial length (0 = disabled) |
| `appIdentifier` | String | required | Bundle ID |
| `offlineGracePeriodDays` | Int | 30 | Days without revocation check allowed |
| `revocationCheckIntervalHours` | Int | 24 | Revocation check frequency |
| `trialSalt` | String | "tessera-v1" | Salt for trial tokens |
| `purchaseURL` | URL? | nil | Link to purchase page |
| `appDisplayName` | String | "App" | Name in activation UI |
| `trialRegistryURL` | URL? | nil | Cloudflare Worker URL for trials + activation |
| `trialRegistrySecret` | String? | nil | Shared secret for Worker authentication |
| `maxDevicesPerLicense` | Int | 0 | Max devices per license (0 = unlimited) |

---

## License

MIT — free for commercial and open-source use.

Copyright (c) 2026 Blaine Miller
