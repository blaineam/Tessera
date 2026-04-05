/**
 * Tessera Worker — Stripe Fulfillment + Trial Registry + Device Activation
 *
 * A Cloudflare Worker that handles:
 * 1. Stripe webhooks → automatic license generation
 * 2. Trial registration → prevents unlimited trial resets
 * 3. Device activation → seat limiting per license key
 *
 * The trial registry and activation system use Cloudflare KV
 * (free tier: 100K reads/day, 1K writes/day) to store state server-side.
 *
 * Routes:
 *   POST /webhook                — Stripe webhook handler
 *   POST /trial/register         — Register a trial start (app calls this)
 *   POST /trial/check            — Check if a machine already had a trial
 *   POST /activation/activate    — Register a device for a license
 *   POST /activation/deactivate  — Release a device seat
 *   POST /activation/check       — Check if a device is still activated
 *   GET  /health                 — Health check
 *
 * Environment variables (set in Cloudflare dashboard):
 *   STRIPE_WEBHOOK_SECRET  — Stripe webhook signing secret (whsec_...)
 *   STRIPE_SECRET_KEY      — Stripe API secret key (sk_live_...)
 *   GITHUB_TOKEN           — GitHub PAT with repo + actions scope
 *   GITHUB_REPO            — e.g. "username/repo-with-tessera"
 *   GITHUB_WORKFLOW_ID     — e.g. "tessera-generate-license.yml"
 *   TRIAL_SECRET           — Shared secret for trial + activation API authentication
 *   MAX_DEVICES            — Maximum devices per license (default: 3)
 *
 * KV Namespace binding:
 *   TRIAL_KV               — Cloudflare KV namespace for trial + activation records
 *
 * Deploy:
 *   npx wrangler deploy --name tessera
 */

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // CORS headers for the trial API (called from the app)
    const corsHeaders = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
    };

    if (request.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders });
    }

    try {
      // --- Health ---
      if (url.pathname === "/health") {
        return jsonResponse({ status: "ok", service: "tessera" }, 200, corsHeaders);
      }

      // --- Trial Registration ---
      if (url.pathname === "/trial/register" && request.method === "POST") {
        return await handleTrialRegister(request, env, corsHeaders);
      }

      // --- Trial Check ---
      if (url.pathname === "/trial/check" && request.method === "POST") {
        return await handleTrialCheck(request, env, corsHeaders);
      }

      // --- Device Activation ---
      if (url.pathname === "/activation/activate" && request.method === "POST") {
        return await handleActivationActivate(request, env, corsHeaders);
      }

      if (url.pathname === "/activation/deactivate" && request.method === "POST") {
        return await handleActivationDeactivate(request, env, corsHeaders);
      }

      if (url.pathname === "/activation/check" && request.method === "POST") {
        return await handleActivationCheck(request, env, corsHeaders);
      }

      // --- Stripe Webhook ---
      if (url.pathname === "/webhook" && request.method === "POST") {
        return await handleStripeWebhook(request, env);
      }

      return new Response("Not found", { status: 404 });
    } catch (err) {
      console.error("Worker error:", err);
      return jsonResponse({ error: err.message }, 500, corsHeaders);
    }
  }
};

// ============================================================
// Trial Registry (HMAC-authenticated, MITM-resistant)
// ============================================================
//
// The TRIAL_SECRET never goes over the wire. Both sides prove
// they know it via HMAC:
//
// Request:  {fingerprint, app_id, timestamp, request_hmac}
//   request_hmac = HMAC(secret, fingerprint + ":" + app_id + ":" + timestamp)
//
// Response: {used/allowed, registered_at, nonce, hmac}
//   hmac = HMAC(secret, action + ":" + fingerprint + ":" + nonce + ":" + registered_at)
//
// Even with full TLS interception:
// - Attacker sees HMACs but can't extract the secret (one-way)
// - Attacker can't forge a valid response without the secret
// - Random nonce in response prevents replaying old valid responses
// - Timestamp in request prevents replaying old requests (5-min window)

async function handleTrialRegister(request, env, corsHeaders) {
  const body = await request.json();
  const { fingerprint, app_id, timestamp, request_hmac } = body;

  if (!fingerprint || !app_id || !timestamp || !request_hmac) {
    return jsonResponse({ error: "missing fields" }, 400, corsHeaders);
  }

  // Verify request HMAC (proves the app knows the secret)
  const validRequest = await verifyRequestHMAC(fingerprint, app_id, timestamp, request_hmac, env.TRIAL_SECRET);
  if (!validRequest) {
    return jsonResponse({ error: "unauthorized" }, 401, corsHeaders);
  }

  // Reject requests with timestamps more than 5 minutes old (anti-replay)
  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - parseInt(timestamp)) > 300) {
    return jsonResponse({ error: "request expired" }, 400, corsHeaders);
  }

  const kvKey = `trial:${app_id}:${fingerprint}`;
  const nonce = crypto.randomUUID();

  // Check if already registered
  const existing = await env.TRIAL_KV.get(kvKey);
  if (existing) {
    const record = JSON.parse(existing);
    const registeredAt = record.registered_at;
    const action = "register:denied";
    const responseHMAC = await computeResponseHMAC(action, fingerprint, nonce, registeredAt, env.TRIAL_SECRET);

    return jsonResponse({
      allowed: false,
      registered_at: registeredAt,
      nonce,
      hmac: responseHMAC
    }, 200, corsHeaders);
  }

  // Register
  const registeredAt = new Date().toISOString();
  const record = {
    registered_at: registeredAt,
    app_id,
    fingerprint_prefix: fingerprint.substring(0, 8)
  };
  await env.TRIAL_KV.put(kvKey, JSON.stringify(record));

  const action = "register:ok";
  const responseHMAC = await computeResponseHMAC(action, fingerprint, nonce, registeredAt, env.TRIAL_SECRET);

  return jsonResponse({
    allowed: true,
    registered_at: registeredAt,
    nonce,
    hmac: responseHMAC
  }, 200, corsHeaders);
}

async function handleTrialCheck(request, env, corsHeaders) {
  const body = await request.json();
  const { fingerprint, app_id, timestamp, request_hmac } = body;

  if (!fingerprint || !app_id || !timestamp || !request_hmac) {
    return jsonResponse({ error: "missing fields" }, 400, corsHeaders);
  }

  // Verify request HMAC
  const validRequest = await verifyRequestHMAC(fingerprint, app_id, timestamp, request_hmac, env.TRIAL_SECRET);
  if (!validRequest) {
    return jsonResponse({ error: "unauthorized" }, 401, corsHeaders);
  }

  // Reject stale requests
  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - parseInt(timestamp)) > 300) {
    return jsonResponse({ error: "request expired" }, 400, corsHeaders);
  }

  const kvKey = `trial:${app_id}:${fingerprint}`;
  const existing = await env.TRIAL_KV.get(kvKey);
  const nonce = crypto.randomUUID();

  if (existing) {
    const record = JSON.parse(existing);
    const registeredAt = record.registered_at;
    const action = "check:used";
    const responseHMAC = await computeResponseHMAC(action, fingerprint, nonce, registeredAt, env.TRIAL_SECRET);

    return jsonResponse({
      used: true,
      registered_at: registeredAt,
      nonce,
      hmac: responseHMAC
    }, 200, corsHeaders);
  }

  const action = "check:fresh";
  const responseHMAC = await computeResponseHMAC(action, fingerprint, nonce, "", env.TRIAL_SECRET);

  return jsonResponse({
    used: false,
    nonce,
    hmac: responseHMAC
  }, 200, corsHeaders);
}

// --- HMAC Helpers ---

async function verifyRequestHMAC(fingerprint, appId, timestamp, providedHMAC, secret) {
  const message = `${fingerprint}:${appId}:${timestamp}`;
  const expectedHMAC = await computeHMAC(message, secret);
  return timingSafeEqual(expectedHMAC, providedHMAC);
}

async function computeResponseHMAC(action, fingerprint, nonce, registeredAt, secret) {
  const message = `${action}:${fingerprint}:${nonce}:${registeredAt}`;
  return computeHMAC(message, secret);
}

async function computeHMAC(message, secret) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return btoa(String.fromCharCode(...new Uint8Array(sig)));
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return mismatch === 0;
}

// ============================================================
// Device Activation (Seat Limiting)
// ============================================================
//
// Each license can be activated on up to MAX_DEVICES machines.
// Activation records are stored in KV under "activation:{license_id}".
//
// KV value format:
// { "devices": [ { "fingerprint": "abc...", "activated_at": "2026-..." } ] }
//
// Uses the same HMAC authentication as the trial registry.

async function handleActivationActivate(request, env, corsHeaders) {
  const body = await request.json();
  const { license_id, fingerprint, app_id, timestamp, request_hmac } = body;

  if (!license_id || !fingerprint || !app_id || !timestamp || !request_hmac) {
    return jsonResponse({ error: "missing fields" }, 400, corsHeaders);
  }

  const validRequest = await verifyRequestHMAC(fingerprint, app_id, timestamp, request_hmac, env.TRIAL_SECRET);
  if (!validRequest) {
    return jsonResponse({ error: "unauthorized" }, 401, corsHeaders);
  }

  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - parseInt(timestamp)) > 300) {
    return jsonResponse({ error: "request expired" }, 400, corsHeaders);
  }

  const maxDevices = parseInt(env.MAX_DEVICES || "3");
  const kvKey = `activation:${license_id}`;
  const nonce = crypto.randomUUID();

  // Load existing activation record
  const existing = await env.TRIAL_KV.get(kvKey);
  let record = existing ? JSON.parse(existing) : { devices: [] };

  // Check if this device is already activated
  const alreadyActive = record.devices.some(d => d.fingerprint === fingerprint);
  if (alreadyActive) {
    const action = "activate:ok";
    const responseHMAC = await computeResponseHMAC(action, fingerprint, nonce, "", env.TRIAL_SECRET);
    return jsonResponse({
      activated: true,
      active: true,
      device_count: record.devices.length,
      max_devices: maxDevices,
      nonce,
      hmac: responseHMAC
    }, 200, corsHeaders);
  }

  // Check device limit
  if (record.devices.length >= maxDevices) {
    const action = "activate:denied";
    const responseHMAC = await computeResponseHMAC(action, fingerprint, nonce, "", env.TRIAL_SECRET);
    return jsonResponse({
      activated: false,
      active: false,
      device_count: record.devices.length,
      max_devices: maxDevices,
      nonce,
      hmac: responseHMAC
    }, 200, corsHeaders);
  }

  // Activate this device
  record.devices.push({
    fingerprint,
    activated_at: new Date().toISOString()
  });
  await env.TRIAL_KV.put(kvKey, JSON.stringify(record));

  const action = "activate:ok";
  const responseHMAC = await computeResponseHMAC(action, fingerprint, nonce, "", env.TRIAL_SECRET);
  return jsonResponse({
    activated: true,
    device_count: record.devices.length,
    max_devices: maxDevices,
    nonce,
    hmac: responseHMAC
  }, 200, corsHeaders);
}

async function handleActivationDeactivate(request, env, corsHeaders) {
  const body = await request.json();
  const { license_id, fingerprint, app_id, timestamp, request_hmac } = body;

  if (!license_id || !fingerprint || !app_id || !timestamp || !request_hmac) {
    return jsonResponse({ error: "missing fields" }, 400, corsHeaders);
  }

  const validRequest = await verifyRequestHMAC(fingerprint, app_id, timestamp, request_hmac, env.TRIAL_SECRET);
  if (!validRequest) {
    return jsonResponse({ error: "unauthorized" }, 401, corsHeaders);
  }

  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - parseInt(timestamp)) > 300) {
    return jsonResponse({ error: "request expired" }, 400, corsHeaders);
  }

  const kvKey = `activation:${license_id}`;
  const nonce = crypto.randomUUID();

  const existing = await env.TRIAL_KV.get(kvKey);
  let record = existing ? JSON.parse(existing) : { devices: [] };

  // Remove this device
  record.devices = record.devices.filter(d => d.fingerprint !== fingerprint);
  await env.TRIAL_KV.put(kvKey, JSON.stringify(record));

  const action = "deactivate:ok";
  const responseHMAC = await computeResponseHMAC(action, fingerprint, nonce, "", env.TRIAL_SECRET);
  return jsonResponse({
    deactivated: true,
    device_count: record.devices.length,
    nonce,
    hmac: responseHMAC
  }, 200, corsHeaders);
}

async function handleActivationCheck(request, env, corsHeaders) {
  const body = await request.json();
  const { license_id, fingerprint, app_id, timestamp, request_hmac } = body;

  if (!license_id || !fingerprint || !app_id || !timestamp || !request_hmac) {
    return jsonResponse({ error: "missing fields" }, 400, corsHeaders);
  }

  const validRequest = await verifyRequestHMAC(fingerprint, app_id, timestamp, request_hmac, env.TRIAL_SECRET);
  if (!validRequest) {
    return jsonResponse({ error: "unauthorized" }, 401, corsHeaders);
  }

  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - parseInt(timestamp)) > 300) {
    return jsonResponse({ error: "request expired" }, 400, corsHeaders);
  }

  const maxDevices = parseInt(env.MAX_DEVICES || "3");
  const kvKey = `activation:${license_id}`;
  const nonce = crypto.randomUUID();

  const existing = await env.TRIAL_KV.get(kvKey);
  const record = existing ? JSON.parse(existing) : { devices: [] };

  const isActive = record.devices.some(d => d.fingerprint === fingerprint);
  const action = isActive ? "check:active" : "check:inactive";
  const responseHMAC = await computeResponseHMAC(action, fingerprint, nonce, "", env.TRIAL_SECRET);

  return jsonResponse({
    active: isActive,
    device_count: record.devices.length,
    max_devices: maxDevices,
    nonce,
    hmac: responseHMAC
  }, 200, corsHeaders);
}

// ============================================================
// Stripe Webhook Handler
// ============================================================

async function handleStripeWebhook(request, env) {
  const body = await request.text();
  const signature = request.headers.get("stripe-signature");

  if (!signature) {
    return new Response("Missing signature", { status: 400 });
  }

  const event = await verifyStripeWebhook(body, signature, env.STRIPE_WEBHOOK_SECRET);
  if (!event) {
    return new Response("Invalid signature", { status: 400 });
  }

  switch (event.type) {
    case "checkout.session.completed":
      await handleCheckoutCompleted(event.data.object, env);
      break;
    case "invoice.paid":
      await handleInvoicePaid(event.data.object, env);
      break;
    case "customer.subscription.deleted":
      await handleSubscriptionCanceled(event.data.object, env);
      break;
  }

  return jsonResponse({ received: true });
}

// --- Stripe Event Handlers ---

async function handleCheckoutCompleted(session, env) {
  const metadata = session.metadata || {};
  const tier = metadata.tier || "personal";
  const durationDays = metadata.duration_days || "365";
  const features = metadata.features || "0";
  const customerEmail = session.customer_email || session.customer_details?.email || "";
  const customerName = session.customer_details?.name || "";
  const nickname = customerName || customerEmail.split("@")[0] || "Customer";

  await triggerLicenseGeneration(env, {
    tier,
    duration_days: durationDays,
    features,
    nickname,
    customer_email: customerEmail,
    stripe_session_id: session.id,
    stripe_customer_id: session.customer || ""
  });
}

async function handleInvoicePaid(invoice, env) {
  if (!invoice.subscription) return;
  if (invoice.billing_reason === "subscription_create") return;

  const subscription = await stripeGet(`/v1/subscriptions/${invoice.subscription}`, env.STRIPE_SECRET_KEY);
  const metadata = subscription.metadata || {};
  if (!metadata.tier) return;

  const interval = subscription.items?.data?.[0]?.price?.recurring?.interval || "year";
  const durationDays = interval === "month" ? "35" : "370";
  const customerEmail = invoice.customer_email || "";
  const nickname = metadata.nickname || customerEmail.split("@")[0] || "Customer";
  const previousLicenseId = metadata.tessera_license_id || "";

  const renewalWorkflowId = env.GITHUB_RENEWAL_WORKFLOW_ID || "tessera-renew-license.yml";

  await fetch(
    `https://api.github.com/repos/${env.GITHUB_REPO}/actions/workflows/${renewalWorkflowId}/dispatches`,
    {
      method: "POST",
      headers: {
        Authorization: `token ${env.GITHUB_TOKEN}`,
        Accept: "application/vnd.github.v3+json",
        "Content-Type": "application/json",
        "User-Agent": "Tessera-Worker"
      },
      body: JSON.stringify({
        ref: "main",
        inputs: {
          previous_license_id: previousLicenseId,
          tier: metadata.tier,
          duration_days: durationDays,
          features: metadata.features || "0",
          nickname,
          customer_email: customerEmail,
          stripe_subscription_id: invoice.subscription,
          stripe_customer_id: invoice.customer || ""
        }
      })
    }
  );
}

async function handleSubscriptionCanceled(subscription, env) {
  const metadata = subscription.metadata || {};
  if (metadata.license_id && metadata.auto_revoke === "true") {
    console.log(`Subscription canceled, would auto-revoke ${metadata.license_id}`);
  }
}

// --- GitHub Action Trigger ---

async function triggerLicenseGeneration(env, params) {
  const response = await fetch(
    `https://api.github.com/repos/${env.GITHUB_REPO}/actions/workflows/${env.GITHUB_WORKFLOW_ID}/dispatches`,
    {
      method: "POST",
      headers: {
        Authorization: `token ${env.GITHUB_TOKEN}`,
        Accept: "application/vnd.github.v3+json",
        "Content-Type": "application/json",
        "User-Agent": "Tessera-Worker"
      },
      body: JSON.stringify({
        ref: "main",
        inputs: {
          tier: params.tier,
          duration_days: params.duration_days,
          features: params.features,
          nickname: params.nickname,
          customer_email: params.customer_email || "",
          stripe_session_id: params.stripe_session_id || "",
          stripe_customer_id: params.stripe_customer_id || ""
        }
      })
    }
  );

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`GitHub API ${response.status}: ${text}`);
  }
}

// ============================================================
// Helpers
// ============================================================

function jsonResponse(data, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...extraHeaders }
  });
}

async function stripeGet(path, secretKey) {
  const response = await fetch(`https://api.stripe.com${path}`, {
    headers: {
      Authorization: `Bearer ${secretKey}`,
      "Content-Type": "application/x-www-form-urlencoded"
    }
  });
  return response.json();
}

async function verifyStripeWebhook(payload, sigHeader, secret) {
  const elements = sigHeader.split(",").reduce((acc, item) => {
    const [key, value] = item.split("=");
    acc[key.trim()] = value;
    return acc;
  }, {});

  const timestamp = elements["t"];
  const signature = elements["v1"];
  if (!timestamp || !signature) return null;

  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - parseInt(timestamp)) > 300) return null;

  const signedPayload = `${timestamp}.${payload}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const signatureBytes = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(signedPayload)
  );

  const expectedSig = Array.from(new Uint8Array(signatureBytes))
    .map(b => b.toString(16).padStart(2, "0"))
    .join("");

  if (expectedSig.length !== signature.length) return null;
  let mismatch = 0;
  for (let i = 0; i < expectedSig.length; i++) {
    mismatch |= expectedSig.charCodeAt(i) ^ signature.charCodeAt(i);
  }
  if (mismatch !== 0) return null;

  return JSON.parse(payload);
}
