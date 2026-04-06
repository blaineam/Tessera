# Tessera Security Audit

**Date:** 2026-04-06
**Scope:** Full codebase — Swift library, Cloudflare Worker, CLI tools, GitHub Actions workflows, static site

---

## CRITICAL Findings

### 1. [FIXED] GitHub Actions Script Injection via Workflow Inputs
**Files:** `.github/workflows/tessera-generate-license.yml`, `.github/workflows/tessera-renew-license.yml`
**Severity:** CRITICAL

Workflow inputs (e.g. `nickname`, `customer_email`, `features`) were interpolated directly into inline Python scripts and shell commands using `${{ inputs.* }}` syntax. An attacker who could trigger `workflow_dispatch` could inject arbitrary code to exfiltrate the Ed25519 private signing key.

**Fix applied:**
- All inputs are now passed via `env:` block at the job level and referenced as `$INPUT_*` environment variables
- Added input validation step that rejects non-integer `features`/`duration_days` and dangerous characters in `nickname`
- Inline Python scripts now read values from `os.environ` instead of string interpolation

---

### 2. [FIXED] Shared HMAC Secret (`trialRegistrySecret`) Embedded in Client Binary
**Files:** `TesseraConfiguration.swift`, `TrialManager.swift`, `ActivationManager.swift`
**Severity:** CRITICAL

The `trialRegistrySecret` is compiled into the binary and can be extracted, allowing forgery of both requests and responses.

**Fix applied:**
- Added Ed25519 asymmetric response signing: the server signs all responses with a private key (`RESPONSE_SIGNING_KEY`), and the client verifies with a public key (`responseVerificationKeyBase64`)
- Client prefers Ed25519 verification over HMAC when available
- HMAC remains as a backwards-compatible fallback
- The signing private key never leaves the server, so response forgery is not possible even with the HMAC secret extracted
- Added documentation noting the HMAC secret is a speed bump, not a security boundary

**Deployment note:** Generate a new Ed25519 keypair for response signing, set the private key as `RESPONSE_SIGNING_KEY` in Cloudflare, and set the public key as `responseVerificationKeyBase64` in your `TesseraConfiguration`.

---

## HIGH Findings

### 3. [FIXED] License Key Exposed in GitHub Actions Logs and Step Summary
**Files:** `.github/workflows/tessera-generate-license.yml`, `.github/workflows/tessera-renew-license.yml`
**Severity:** HIGH

**Fix applied:**
- Added `::add-mask::` for the license key before any logging
- Removed the license key from `$GITHUB_STEP_SUMMARY`
- License key is now only delivered via email; the summary shows the license ID only

---

### 4. [FIXED] `licenses.json` Committed to Public Repository with Customer PII
**File:** `Site/apps/ari/licensing/licenses.json`
**Severity:** HIGH

**Fix applied:**
- Removed `customer_email`, `stripe_customer_id`, and `stripe_session_id` from the license entries written to `licenses.json` in both generate and renew workflows
- Existing entries with PII in the file should be cleaned up manually from git history if the repo is public

---

### 5. [FIXED] Revocation List Fetched Over HTTP Without Integrity Verification
**Files:** `RevocationChecker.swift`, `tessera_cli.py`
**Severity:** HIGH

**Fix applied:**
- Revocation list now supports an `signature` field containing an Ed25519 signature
- `RevocationChecker` verifies the signature using the license public key before accepting a fetched list
- If signature verification fails, the client falls back to the cached (previously verified) list
- If no signature is present and a verifier is configured, the list is rejected
- `tessera_cli.py revoke` now accepts `--private-key` to sign the revocation list
- Canonical message format: sorted revoked IDs joined by "," + ":" + updated timestamp

---

### 6. [FIXED] CORS Wildcard on All Worker Endpoints
**File:** `Tools/stripe_worker.js`
**Severity:** HIGH

**Fix applied:**
- Removed `Access-Control-Allow-Origin: *`
- CORS headers are now only set when the request `Origin` matches the configured `ALLOWED_ORIGIN` environment variable
- If `ALLOWED_ORIGIN` is not set, no CORS headers are sent (native apps don't need them)
- Preflight `OPTIONS` requests from non-matching origins get 403

---

### 7. [FIXED] Offline Grace Period Allows Extended Use of Revoked Licenses
**Files:** `TesseraConfiguration.swift`
**Severity:** HIGH

**Fix applied:**
- Reduced default `offlineGracePeriodDays` from 30 to 7
- This is an inherent trade-off; the reduced default limits the window while still allowing reasonable offline use

---

### 8. [FIXED] Weak Integrity Check — No Hardened Runtime Verification
**File:** `Sources/Tessera/Security/IntegrityChecker.swift`
**Severity:** HIGH

**Fix applied:**
- Added `expectedTeamID` static property to `IntegrityChecker`
- Added `expectedTeamID` configuration option to `TesseraConfiguration`
- When set, `SecCodeCheckValidity` is called with a `SecRequirement` that verifies `certificate leaf[subject.OU]` matches the Team ID
- Prevents re-signing attacks where an attacker modifies the binary and signs with their own certificate
- Falls back to basic signature check if no Team ID is configured

---

## Medium/Low Findings

### 9. [FIXED] Clock Tampering Detection Only Catches Backward Jumps
**File:** `TrialManager.swift`
**Severity:** Medium

**Fix applied:**
- Added forward clock jump detection: jumps > 48 hours since last check are now flagged as tampering
- This catches the attack pattern of advancing the clock to expire a trial, resetting, then setting it back

---

### 10. [FIXED] Keychain Protection Level
**File:** `KeychainStore.swift`
**Severity:** Medium

**Fix applied:**
- Changed from `kSecAttrAccessibleAfterFirstUnlock` to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- Data is now only accessible when the device is unlocked and cannot be migrated to other devices via backup

---

### 11. [FIXED] Error Details in Worker Responses
**File:** `Tools/stripe_worker.js`
**Severity:** Low

**Fix applied:**
- Generic `"internal error"` message replaces `err.message` in the 500 error response
- Internal details are still logged server-side via `console.error` for debugging

---

### 12. [FIXED] Decoy Keychain Prefix Collision Risk
**File:** `TrialManager.swift`
**Severity:** Low

**Fix applied:**
- Changed decoy keychain prefix from `com.apple.preference.*` to `com.tessera.cache.*`
- Avoids potential collisions with real Apple keychain entries

---

### 13. [FIXED] No Rate Limiting on Trial/Activation API Endpoints
**File:** `Tools/stripe_worker.js`
**Severity:** Medium

**Fix applied:**
- Added per-IP rate limiting: 30 requests per minute for `/trial/*` and `/activation/*` endpoints
- Uses KV with TTL for automatic cleanup
- Returns 429 when limit is exceeded

---

### 14. No Passphrase Protection on Private Key
**File:** `tessera_cli.py`
**Severity:** Low — Not fixed (operational choice for CI compatibility)

---

### 15. [FIXED] Features Input Validation
**File:** `.github/workflows/tessera-generate-license.yml`
**Severity:** Low

**Fix applied:** Input validation step rejects non-integer `features` values.

---

## Summary

| Severity | Count | Fixed |
|----------|-------|-------|
| **Critical** | 2 | 2 |
| **High** | 6 | 6 |
| **Medium** | 3 | 3 |
| **Low** | 3 | 2 (1 deferred) |

All critical and high findings have been remediated. The only deferred item (#14) is a low-severity operational choice.
