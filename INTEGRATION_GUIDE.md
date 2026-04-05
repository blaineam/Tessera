# Tessera Integration Guide

A step-by-step guide to adding Tessera licensing to your existing macOS app.

---

## Prerequisites

- macOS app with SwiftUI (minimum deployment: macOS 13+)
- Python 3.8+ (for the license generation CLI)
- A domain or GitHub Pages site (for hosting the revocation list)

## Step 1: Add the Package

Copy the `Tessera/` directory into your project, then in Xcode:

1. **File → Add Package Dependencies**
2. Click **"Add Local..."**
3. Select the `Tessera/` directory
4. Ensure "Tessera" library is added to your app target

## Step 2: Generate Your Keypair

```bash
cd TesseraTools
pip install -r requirements.txt
python3 tessera_cli.py generate-keypair --output-dir ../keys
```

Output:
```
Private key saved to: ../keys/private.pem
Public key (base64, for embedding in your app):
  A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8S9T0U1V2
```

**Keep `private.pem` secret.** Add it to `.gitignore`. Store it securely (1Password, encrypted vault, etc.).

The base64 public key goes into your app code.

## Step 3: Host the Revocation List

Create a `revoked.json` file at a URL you control:

```json
{
  "revoked": [],
  "messages": {},
  "updated": "2026-04-05T00:00:00Z"
}
```

Good hosting options:
- **Your domain** (recommended): `https://yourdomain.com/licensing/revoked.json`
- **GitHub Pages**: `https://username.github.io/repo/revoked.json`

Using your own domain is recommended — if you ever migrate hosting, the URL stays the same as long as you own the domain.

## Step 4: Configure Tessera

Create a configuration file in your app:

```swift
// LicenseConfig.swift
import Tessera

#if !APPSTORE
enum MyLicense {
    @MainActor
    static let shared: Tessera = {
        Tessera(configuration: .init(
            publicKeyBase64: "YOUR_PUBLIC_KEY_BASE64_HERE",
            revocationURL: URL(string: "https://yourdomain.com/licensing/revoked.json")!,
            trialDurationDays: 14,
            appIdentifier: Bundle.main.bundleIdentifier ?? "com.yourcompany.yourapp",
            offlineGracePeriodDays: 30,
            trialSalt: "myapp-v1-2026",
            purchaseURL: URL(string: "https://yourdomain.com/pricing"),
            appDisplayName: "My App"
        ))
    }()
}
#endif
```

## Step 5: Gate Your App

In your `@main` App struct:

```swift
import SwiftUI
#if !APPSTORE
import Tessera
#endif

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                #if !APPSTORE
                .tesseraGateIfNeeded(MyLicense.shared)
                #endif
        }
    }
}
```

## Step 6: Set Up Dual Distribution (Optional)

To support both MAS and direct distribution from one codebase:

1. **Duplicate your app target** in Xcode (right-click target → Duplicate)
2. Rename the duplicate to "MyApp (Direct)"
3. In the Direct target's Build Settings:
   - **Swift Compiler - Custom Flags → Other Swift Flags**: leave empty (no `-DAPPSTORE`)
4. In the MAS target's Build Settings:
   - **Swift Compiler - Custom Flags → Other Swift Flags**: add `-DAPPSTORE`
5. The MAS target won't compile any Tessera code (all gated behind `#if !APPSTORE`)

## Step 7: Add License Status to Settings (Optional)

Add a license status view to your settings/preferences:

```swift
import Tessera

struct SettingsView: View {
    var body: some View {
        Form {
            // ... your other settings ...
            
            Section("License") {
                #if !APPSTORE
                TesseraStatusView(tessera: MyLicense.shared)
                #else
                Text("App Store Edition")
                #endif
            }
        }
    }
}
```

## Step 8: Generate Your First License

```bash
python3 TesseraTools/tessera_cli.py generate \
    --private-key ./keys/private.pem \
    --tier pro \
    --duration 365

# Output:
# License ID: 550e8400-e29b-41d4-a716-446655440000
# Expires: 2027-04-05
# Key: TESS-eyJsa...Qw==-a8Hk...9g==
```

Give this key to your user. They enter it in the activation screen and they're good to go.

## Step 9: Set Up GitHub Action (Optional)

To generate licenses from anywhere without your local machine:

1. Add repository secrets:
   - `TESSERA_PRIVATE_KEY`: Contents of `private.pem`
   - `PAGES_REPO_TOKEN`: GitHub PAT with repo scope

2. Copy `.github/workflows/tessera-generate-license.yml` to your repo

3. Go to Actions → "Tessera: Generate License" → Run workflow

---

## Troubleshooting

### "Invalid public key" crash on launch
The base64 public key must decode to exactly 32 bytes. Make sure you're using the base64 string output by `generate-keypair`, not the PEM file contents.

### Trial resets when running from Xcode
Debug builds may use a different Keychain access group. The hidden file anchor (`~/Library/.tessera_*`) will still detect the prior trial.

### License works locally but not in notarized build
Ensure the Tessera package is properly linked in your archive scheme. Check that `CryptoKit` is available (it is on macOS 13+).

### Revocation check not working
Verify the URL returns valid JSON with `curl`:
```bash
curl -v https://yourdomain.com/licensing/revoked.json
```
Check that CORS headers aren't blocking (shouldn't matter for URLSession, but verify the response is 200).
