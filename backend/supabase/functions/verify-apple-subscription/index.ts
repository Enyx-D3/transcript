import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.48.0";

type Body = {
  product_id?: string;
  purchase_token?: string; // App Store receipt data (base64) or JWS transaction
};

// ✅ Product IDs (must match subscription_products.dart)
const LIFETIME_PRODUCT_ID = "transcript_pro_lifetime";
const SUB_MONTHLY_ID = "transcript_pro_monthly";
const SUB_MONTHLY_APPLE_ID = "transcript_pro_monthly_apple";
const SUB_YEARLY_ID = "transcript_pro_yearly";

const TOKEN_ALREADY_CLAIMED = "TOKEN_ALREADY_CLAIMED";

// Apple App Store Server API endpoints
const APPLE_PRODUCTION_URL = "https://api.storekit.itunes.apple.com";
const APPLE_SANDBOX_URL = "https://api.storekit-sandbox.itunes.apple.com";

serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, error: "Method not allowed" }, 405);

  try {
    const body = (await req.json()) as Body;
    const productId = body.product_id?.trim();
    const purchaseToken = body.purchase_token?.trim();
    const tokenLooksJws = looksLikeJWS(purchaseToken ?? "");

    if (!productId || !purchaseToken) {
      return json({ ok: false, error: "Missing product_id / purchase_token" }, 400);
    }

    // ✅ Sanity: only allow known products
    const allowed = new Set([
      LIFETIME_PRODUCT_ID,
      SUB_MONTHLY_ID, // legacy monthly id
      SUB_MONTHLY_APPLE_ID, // current iOS monthly id
      SUB_YEARLY_ID,
    ]);
    if (!allowed.has(productId)) {
      return json(
        {
          ok: false,
          error: `Unknown product_id: ${productId}`,
          allowed: Array.from(allowed),
        },
        400,
      );
    }

    // ---- env ----
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const supabaseServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    // Apple App Store Server API credentials
    const appleKeyId = Deno.env.get("APPLE_KEY_ID");
    const appleIssuerId = Deno.env.get("APPLE_ISSUER_ID");
    const applePrivateKey = Deno.env.get("APPLE_PRIVATE_KEY"); // .p8 key contents
    const appleBundleId = Deno.env.get("APPLE_BUNDLE_ID") ?? "com.enyxdigital.transcript";
    const appleEnvironment = Deno.env.get("APPLE_ENVIRONMENT") ?? "Production"; // "Sandbox" or "Production"

    if (!supabaseUrl || !supabaseAnonKey || !supabaseServiceRoleKey) {
      return json(
        { ok: false, error: "Missing Supabase env vars" },
        500,
      );
    }

    // ---- user from Supabase JWT ----
    const authHeader = req.headers.get("Authorization") ?? "";
    if (!authHeader) return json({ ok: false, error: "Missing Authorization header" }, 401);

    const sbUser = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userData, error: userErr } = await sbUser.auth.getUser();
    if (userErr || !userData?.user) return json({ ok: false, error: "Unauthorized" }, 401);
    const userId = userData.user.id;

    // ---- admin client (service role) ----
    const sbAdmin = createClient(supabaseUrl, supabaseServiceRoleKey);

    const isLifetime = productId === LIFETIME_PRODUCT_ID;
    const isSubscription = productId === SUB_MONTHLY_ID ||
      productId === SUB_MONTHLY_APPLE_ID ||
      productId === SUB_YEARLY_ID;

    let proExpiresAt: string | null = null;
    let verifiedTransactionId: string | null = null;

    // =========================================================
    // 1) Verify with Apple
    // =========================================================
    if (appleKeyId && appleIssuerId && applePrivateKey) {
      // ---- App Store Server API v2 (preferred) ----
      const result = await verifyWithAppStoreServerAPI({
        purchaseToken,
        productId,
        appleKeyId,
        appleIssuerId,
        applePrivateKey: applePrivateKey.replaceAll("\\n", "\n"),
        appleBundleId,
        isProduction: appleEnvironment === "Production",
      });

      if (!result.valid) {
        return json({ ok: false, error: result.error ?? "Apple verification failed" }, 400);
      }

      proExpiresAt = result.expiresAt ?? null;
      verifiedTransactionId = result.transactionId ?? purchaseToken;
    } else if (!tokenLooksJws) {
      // ---- Fallback: verifyReceipt (legacy, but works without API key) ----
      const result = await verifyWithReceiptEndpoint({
        receiptData: purchaseToken,
        productId,
        isProduction: appleEnvironment === "Production",
      });

      if (!result.valid) {
        return json({ ok: false, error: result.error ?? "Apple receipt verification failed" }, 400);
      }

      proExpiresAt = result.expiresAt ?? null;
      verifiedTransactionId = result.transactionId ?? purchaseToken;
    } else {
      // StoreKit 2 usually provides JWS transaction data, which cannot be
      // verified via verifyReceipt fallback. Require App Store Server API keys.
      return json(
        {
          ok: false,
          error:
            "Missing APPLE_KEY_ID / APPLE_ISSUER_ID / APPLE_PRIVATE_KEY for StoreKit transaction verification",
        },
        500,
      );
    }

    // Use transactionId as the lock key (more stable than receipt data)
    const lockToken = verifiedTransactionId ?? purchaseToken;

    // =========================================================
    // 2) Token lock (purchase_token -> user_id)
    // =========================================================
    const { data: existingLock, error: lockReadErr } = await sbAdmin
      .from("purchase_token_locks")
      .select("user_id, product_id")
      .eq("purchase_token", lockToken)
      .maybeSingle();

    if (lockReadErr) {
      console.error("Token lock read error:", lockReadErr);
      return json({ ok: false, error: "Token lock read failed" }, 500);
    }

    if (!existingLock) {
      const { error: insErr } = await sbAdmin.from("purchase_token_locks").insert({
        platform: "apple",
        purchase_token: lockToken,
        product_id: productId,
        user_id: userId,
      });

      if (insErr) {
        const { data: again, error: againErr } = await sbAdmin
          .from("purchase_token_locks")
          .select("user_id, product_id")
          .eq("purchase_token", lockToken)
          .maybeSingle();

        if (againErr || !again) {
          console.error("Token lock insert failed:", insErr, againErr);
          return json({ ok: false, error: "Token lock claim failed" }, 500);
        }

        if (again.user_id !== userId) {
          return json(
            {
              ok: false,
              code: TOKEN_ALREADY_CLAIMED,
              error: "This purchase is already linked to another account.",
            },
            403,
          );
        }
      }
    } else {
      if (existingLock.user_id !== userId) {
        return json(
          {
            ok: false,
            code: TOKEN_ALREADY_CLAIMED,
            error: "This purchase is already linked to another account.",
          },
          403,
        );
      }

      await sbAdmin
        .from("purchase_token_locks")
        .update({
          last_seen_at: new Date().toISOString(),
          product_id: productId,
        })
        .eq("purchase_token", lockToken);
    }

    // =========================================================
    // 3) Apply entitlement to profile
    // =========================================================
    const { error: upErr } = await sbAdmin
      .from("profiles")
      .update({
        is_upgraded: true,
        is_lifetime: isLifetime,
        pro_expires_at: proExpiresAt,
      })
      .eq("id", userId);

    if (upErr) {
      console.error("Supabase update error:", upErr);
      return json({ ok: false, error: "Failed to update profile" }, 500);
    }

    return json({
      ok: true,
      product_id: productId,
      is_lifetime: isLifetime,
      expires_at: proExpiresAt,
    });
  } catch (e) {
    console.error("verify-apple-subscription error:", e);
    const msg =
      e instanceof Error ? `${e.name}: ${e.message}\n${e.stack ?? ""}` : `Non-Error thrown: ${JSON.stringify(e)}`;
    return json({ ok: false, error: msg }, 500);
  }
});

// ================================================================
// App Store Server API v2 verification
// ================================================================

interface ServerAPIResult {
  valid: boolean;
  error?: string;
  expiresAt?: string;
  transactionId?: string;
}

async function verifyWithAppStoreServerAPI(opts: {
  purchaseToken: string;
  productId: string;
  appleKeyId: string;
  appleIssuerId: string;
  applePrivateKey: string;
  appleBundleId: string;
  isProduction: boolean;
}): Promise<ServerAPIResult> {
  try {
    const jwt = await generateAppleJWT({
      keyId: opts.appleKeyId,
      issuerId: opts.appleIssuerId,
      privateKey: opts.applePrivateKey,
      bundleId: opts.appleBundleId,
    });

    const baseUrl = opts.isProduction ? APPLE_PRODUCTION_URL : APPLE_SANDBOX_URL;

    // The purchase token may be:
    // 1) transaction ID
    // 2) signed transaction JWS (StoreKit 2)
    let transactionId = opts.purchaseToken;
    if (looksLikeJWS(opts.purchaseToken)) {
      const purchasePayload = decodeJWSPayload(opts.purchaseToken);
      const fromPayload = purchasePayload?.transactionId ??
        purchasePayload?.originalTransactionId;
      if (fromPayload) transactionId = String(fromPayload);
    }

    const url = `${baseUrl}/inApps/v1/transactions/${encodeURIComponent(transactionId)}`;
    const resp = await fetch(url, {
      headers: { Authorization: `Bearer ${jwt}` },
    });

    if (!resp.ok) {
      // If production fails with 4xx, try sandbox (TestFlight / StoreKit testing)
      if (opts.isProduction && resp.status >= 400 && resp.status < 500) {
        return verifyWithAppStoreServerAPI({
          ...opts,
          isProduction: false,
        });
      }

      const text = await resp.text();
      return { valid: false, error: `Apple API error ${resp.status}: ${text}` };
    }

    const data = await resp.json();

    // Response contains signedTransactionInfo as a JWS
    const signedInfo = data.signedTransactionInfo;
    if (!signedInfo) {
      return { valid: false, error: "No signedTransactionInfo in response" };
    }

    // Decode the JWS payload (middle part)
    const payload = decodeJWSPayload(signedInfo);
    if (!payload) {
      return { valid: false, error: "Failed to decode transaction JWS" };
    }

    // Verify the product matches
    if (payload.productId !== opts.productId) {
      return {
        valid: false,
        error: `Product mismatch: expected ${opts.productId}, got ${payload.productId}`,
      };
    }

    // Verify bundle ID
    if (payload.bundleId !== opts.appleBundleId) {
      return {
        valid: false,
        error: `Bundle ID mismatch: expected ${opts.appleBundleId}, got ${payload.bundleId}`,
      };
    }

    // Check revocation
    if (payload.revocationDate) {
      return { valid: false, error: "Transaction has been revoked/refunded" };
    }

    // For subscriptions, check expiration
    let expiresAt: string | undefined;
    if (payload.expiresDate) {
      const expiryDate = new Date(payload.expiresDate);
      if (expiryDate.getTime() < Date.now()) {
        return { valid: false, error: "Subscription has expired" };
      }
      expiresAt = expiryDate.toISOString();
    }

    return {
      valid: true,
      expiresAt,
      transactionId: String(payload.originalTransactionId ?? payload.transactionId ?? transactionId),
    };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return { valid: false, error: `App Store Server API error: ${msg}` };
  }
}

// ================================================================
// Legacy verifyReceipt fallback
// ================================================================

interface ReceiptResult {
  valid: boolean;
  error?: string;
  expiresAt?: string;
  transactionId?: string;
}

async function verifyWithReceiptEndpoint(opts: {
  receiptData: string;
  productId: string;
  isProduction: boolean;
}): Promise<ReceiptResult> {
  const prodUrl = "https://buy.itunes.apple.com/verifyReceipt";
  const sandboxUrl = "https://sandbox.itunes.apple.com/verifyReceipt";

  const password = Deno.env.get("APPLE_SHARED_SECRET") ?? "";

  const payload = {
    "receipt-data": opts.receiptData,
    password,
    "exclude-old-transactions": true,
  };

  // Try production first
  let url = opts.isProduction ? prodUrl : sandboxUrl;
  let resp = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });

  let data = await resp.json();

  // Status 21007 means receipt is from sandbox
  if (data.status === 21007 && opts.isProduction) {
    resp = await fetch(sandboxUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    data = await resp.json();
  }

  if (data.status !== 0) {
    return { valid: false, error: `verifyReceipt status: ${data.status}` };
  }

  const receipt = data.receipt;
  if (!receipt) {
    return { valid: false, error: "No receipt in response" };
  }

  // Check bundle ID
  const bundleId = Deno.env.get("APPLE_BUNDLE_ID") ?? "com.enyxdigital.transcript";
  if (receipt.bundle_id !== bundleId) {
    return { valid: false, error: `Bundle mismatch: ${receipt.bundle_id}` };
  }

  // Find matching in-app purchase
  const isLifetime = opts.productId === LIFETIME_PRODUCT_ID;
  const inApps: any[] = data.latest_receipt_info ?? receipt.in_app ?? [];

  // For subscriptions, find the latest matching transaction
  const matching = inApps
    .filter((tx: any) => tx.product_id === opts.productId)
    .sort((a: any, b: any) => {
      const aMs = parseInt(a.purchase_date_ms ?? "0", 10);
      const bMs = parseInt(b.purchase_date_ms ?? "0", 10);
      return bMs - aMs;
    });

  if (matching.length === 0) {
    return { valid: false, error: `No transaction for product ${opts.productId}` };
  }

  const latest = matching[0];

  // Check cancellation
  if (latest.cancellation_date_ms) {
    return { valid: false, error: "Transaction was cancelled/refunded" };
  }

  let expiresAt: string | undefined;
  if (!isLifetime && latest.expires_date_ms) {
    const expiry = new Date(parseInt(latest.expires_date_ms, 10));
    if (expiry.getTime() < Date.now()) {
      return { valid: false, error: "Subscription has expired" };
    }
    expiresAt = expiry.toISOString();
  }

  return {
    valid: true,
    expiresAt,
    transactionId: latest.original_transaction_id ?? latest.transaction_id,
  };
}

// ================================================================
// Apple JWT generation for App Store Server API
// ================================================================

async function generateAppleJWT(opts: {
  keyId: string;
  issuerId: string;
  privateKey: string;
  bundleId: string;
}): Promise<string> {
  const header = {
    alg: "ES256",
    kid: opts.keyId,
    typ: "JWT",
  };

  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: opts.issuerId,
    iat: now,
    exp: now + 3600,
    aud: "appstoreconnect-v1",
    bid: opts.bundleId,
  };

  const encodedHeader = base64urlEncode(JSON.stringify(header));
  const encodedPayload = base64urlEncode(JSON.stringify(payload));
  const signingInput = `${encodedHeader}.${encodedPayload}`;

  // Import the EC private key
  const pemBody = opts.privateKey
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");

  const keyData = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));

  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyData,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );

  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );

  // Convert DER signature to raw r||s format for JWS
  const rawSig = derToRaw(new Uint8Array(signature));
  const encodedSignature = base64urlEncodeBytes(rawSig);

  return `${signingInput}.${encodedSignature}`;
}

// ---- helpers ----

function decodeJWSPayload(jws: string): any | null {
  try {
    const parts = jws.split(".");
    if (parts.length !== 3) return null;
    const payload = parts[1];
    // Add padding
    const padded = payload + "=".repeat((4 - (payload.length % 4)) % 4);
    const decoded = atob(padded.replace(/-/g, "+").replace(/_/g, "/"));
    return JSON.parse(decoded);
  } catch {
    return null;
  }
}

function looksLikeJWS(value: string): boolean {
  return value.split(".").length === 3;
}

function base64urlEncode(str: string): string {
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64urlEncodeBytes(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// Convert DER-encoded ECDSA signature to raw r||s (64 bytes for P-256)
function derToRaw(der: Uint8Array): Uint8Array {
  // Some implementations return raw format directly
  if (der.length === 64) return der;

  // DER format: 0x30 <len> 0x02 <r_len> <r> 0x02 <s_len> <s>
  let offset = 2; // skip 0x30 and total length
  if (der[0] !== 0x30) return der; // not DER, assume raw

  // r
  if (der[offset] !== 0x02) return der;
  offset++;
  const rLen = der[offset];
  offset++;
  let r = der.slice(offset, offset + rLen);
  offset += rLen;

  // s
  if (der[offset] !== 0x02) return der;
  offset++;
  const sLen = der[offset];
  offset++;
  let s = der.slice(offset, offset + sLen);

  // Remove leading zeros and pad to 32 bytes
  if (r.length > 32) r = r.slice(r.length - 32);
  if (s.length > 32) s = s.slice(s.length - 32);

  const raw = new Uint8Array(64);
  raw.set(r, 32 - r.length);
  raw.set(s, 64 - s.length);
  return raw;
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
