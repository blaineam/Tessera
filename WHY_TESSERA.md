# Why Tessera?

## The Problem

You've built a great macOS app. You want to sell it outside the Mac App Store — maybe to avoid the 30% commission, offer features Apple doesn't allow, or reach enterprise customers directly. But now you need a licensing system.

Your options aren't great:

**SaaS licensing services** (Paddle, KeyGen, LemonSqueezy) charge ongoing fees, require your app to phone home to *their* servers, collect analytics on your users, and add a dependency on infrastructure you don't control. If they go down, your customers can't activate. If they change pricing, you're locked in. Tessera's device activation and trial registry talk to a Cloudflare Worker *you* own — no third-party dependency, no user tracking, and it runs on the free tier.

**DIY server-based licensing** means building and maintaining a license server, database, API, authentication, SSL certificates, monitoring, and backups. That's a full-time job on top of building your actual app.

**Serial number systems** are trivially crackable — anyone can share a key, and there's no way to revoke it. You end up playing whack-a-mole with pirated keys.

**No licensing at all** means you're giving your app away and hoping people pay out of goodness.

## The Tessera Approach

Tessera takes a fundamentally different approach: **cryptographic proof, not server verification.**

A Tessera license key is a JSON payload signed with Ed25519 — the same algorithm used by SSH, Signal, and blockchain systems. The signature can be verified by anyone with the public key (embedded in your app), but can only be created by someone with the private key (you).

This means:
- **Minimal infrastructure.** License verification happens on-device. Device activation and trial tracking use a Cloudflare Worker you control (free tier).
- **No user tracking.** The license contains zero PII — just an ID, tier, and expiry date.
- **No ongoing costs.** You generate keys with a CLI tool or GitHub Action. For free. Forever.
- **No single point of failure.** Your app doesn't depend on any external service being online.

## But What About Revocation?

The one thing you need a server for — or so people think — is revoking compromised licenses. Tessera solves this with a static JSON file:

```json
{"revoked": ["leaked-license-uuid"]}
```

Host it anywhere: your website, GitHub Pages, S3, a CDN. The app fetches it periodically and caches it locally. No API, no database, no server logic. Just a file.

Your domain (`yourdomain.com/revoked.json`) is the "server." If you ever migrate hosting, the URL follows your domain.

## The Trial System

Most trial systems store a "first launch date" in UserDefaults or a preference file. Users discover this in about 5 minutes and reset it to get unlimited trials.

Tessera's trial is stored in **three independent locations** (Keychain, hidden file, UserDefaults), bound to the machine's hardware fingerprint via HMAC. If *any* location retains a valid token, the trial is considered started. The earliest date always wins.

To actually reset the trial, a user would need to:
1. Delete the Keychain entry
2. Find and delete a hidden file in ~/Library
3. Clear UserDefaults
4. Somehow bypass the hardware fingerprint check

And even then, clock manipulation is detected via monotonic date tracking. This isn't Fort Knox — a determined reverse engineer can always crack anything — but it's enough to keep honest users honest, which is the actual goal of licensing.

## Comparison

| | Tessera | Paddle | KeyGen | DevMate | DIY |
|---|---|---|---|---|---|
| **Cost** | Free | 5-10% rev | $99+/mo | $0-99/mo | Dev time |
| **Infrastructure** | None | Theirs | Theirs | Theirs | Yours |
| **Offline support** | Full | Partial | Partial | Partial | Varies |
| **User tracking** | None | Analytics | Analytics | Analytics | Up to you |
| **Revocation** | Static JSON | Dashboard | API | Dashboard | Custom |
| **Open source** | Yes (MIT) | No | No | No | — |
| **Vendor lock-in** | None | High | High | Medium | None |
| **Setup time** | ~30 min | Hours | Hours | Hours | Days-Weeks |
| **MAS dual-build** | Built-in | Manual | Manual | Manual | Manual |

## Who Is Tessera For?

- **Indie developers** who want licensing without overhead
- **Small teams** that don't want to maintain infrastructure
- **Privacy-focused apps** that don't want third-party data collection
- **Enterprise tools** that need offline-capable licensing
- **Open source projects** offering commercial licenses
- **Anyone** who wants the Mac App Store convenience of "it just works" but for direct distribution

## Who Is Tessera NOT For?

- Apps that need per-seat licensing with real-time server validation
- Apps that require hardware-locked licenses (Tessera trials are hardware-locked, but licenses are not — by design, so users can transfer between machines)
- Teams that want a full-service billing/subscription platform (use Stripe directly for that)

## Getting Started

```bash
# 1. Generate your keypair
python3 tessera_cli.py generate-keypair

# 2. Add 5 lines of Swift to your app

# 3. You're done
```

See the [README](README.md) and [Integration Guide](INTEGRATION_GUIDE.md) for details.
