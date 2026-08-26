import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.48.0";
import { SignJWT, importPKCS8 } from "https://esm.sh/jose@5.2.4";

type Body = {
  product_id?: string;
  purchase_token?: string;
};

// ✅ Product IDs
const LIFETIME_PRODUCT_ID = "transcript_pro_lifetime";
const SUB_MONTHLY_ID = "transcript_pro_monthly";
const SUB_YEARLY_ID = "transcript_pro_yearly";

const GOOGLE_SCOPE = "https://www.googleapis.com/auth/androidpublisher";
const TOKEN_URL = "https://oauth2.googleapis.com/token";

const TOKEN_ALREADY_CLAIMED = "TOKEN_ALREADY_CLAIMED";

serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, error: "Method not allowed" }, 405);

  try {
    const body = (await req.json()) as Body;
    const productId = body.product_id?.trim();
    const purchaseToken = body.purchase_token?.trim();

    if (!productId || !purchaseToken) {
      return json({ ok: false, error: "Missing product_id / purchase_token" }, 400);
    }

    // ✅ Sanity: only allow known products
    const allowed = new Set([LIFETIME_PRODUCT_ID, SUB_MONTHLY_ID, SUB_YEARLY_ID]);
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

    const svcEmail = Deno.env.get("GOOGLE_SERVICE_ACCOUNT_EMAIL");
    const rawPrivateKey = Deno.env.get("GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY");

    const packageName = Deno.env.get("ANDROID_PACKAGE_NAME") ?? "com.enyxd.transcript";

    if (!supabaseUrl || !supabaseAnonKey || !supabaseServiceRoleKey || !svcEmail || !rawPrivateKey) {
      return json(
        {
          ok: false,
          error:
            "Missing env vars: SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY / GOOGLE_SERVICE_ACCOUNT_EMAIL / GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY",
        },
        500,
      );
    }

    // important: convert literal \n to newlines
    const privateKeyPem = rawPrivateKey.replaceAll("\\n", "\n");

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

    // ---- get Google access token (Deno-safe) ----
    const accessToken = await getGoogleAccessToken({
      clientEmail: svcEmail,
      privateKeyPem,
      scope: GOOGLE_SCOPE,
    });

    const isLifetime = productId === LIFETIME_PRODUCT_ID;
    const isSubscription = productId === SUB_MONTHLY_ID || productId === SUB_YEARLY_ID;

    let proExpiresAt: string | null = null;

    // =========================================================
    // 1) Verify with Google FIRST (don't lock bogus tokens)
    // =========================================================
    if (isLifetime) {
      // ========== ONE-TIME MANAGED PRODUCT ==========
      const url =
        `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${encodeURIComponent(packageName)}` +
        `/purchases/products/${encodeURIComponent(productId)}/tokens/${encodeURIComponent(purchaseToken)}`;

      const purchase = await fetchJson(url, accessToken);

      // purchaseState: 0 Purchased, 1 Canceled, 2 Pending
      if (purchase?.purchaseState !== 0) {
        return json(
          { ok: false, error: `Lifetime purchase not completed: purchaseState=${purchase?.purchaseState}` },
          400,
        );
      }

      proExpiresAt = null; // never expires
    } else if (isSubscription) {
      // ========== SUBSCRIPTION (Subscriptions v2) ==========
      const url =
        `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${encodeURIComponent(packageName)}` +
        `/purchases/subscriptionsv2/tokens/${encodeURIComponent(purchaseToken)}`;

      const purchase = await fetchJson(url, accessToken);

      const state = purchase?.subscriptionState;
      const activeStates = new Set(["SUBSCRIPTION_STATE_ACTIVE", "SUBSCRIPTION_STATE_IN_GRACE_PERIOD"]);

      if (!state || !activeStates.has(state)) {
        return json({ ok: false, error: `Subscription not active: ${state ?? "unknown"}` }, 400);
      }

      const lineItems = purchase?.lineItems ?? [];
      if (!Array.isArray(lineItems) || lineItems.length === 0) {
        return json({ ok: false, error: "No lineItems in subscription purchase" }, 400);
      }

      // ✅ Must match the specific subscription product id (monthly/yearly)
      const li = lineItems.find((x: any) => x?.productId === productId);
      if (!li) {
        const got = lineItems.map((x: any) => x?.productId).filter(Boolean);
        return json(
          {
            ok: false,
            error: `Subscription token does not include productId=${productId}`,
            line_item_product_ids: got,
          },
          400,
        );
      }

      const expiryTime = li?.expiryTime;
      if (!expiryTime) return json({ ok: false, error: "Missing expiryTime" }, 400);

      const expiryDate = new Date(expiryTime);
      if (isNaN(expiryDate.getTime())) return json({ ok: false, error: `Bad expiryTime: ${expiryTime}` }, 400);

      proExpiresAt = expiryDate.toISOString();
    } else {
      return json({ ok: false, error: "Unhandled product type" }, 400);
    }

    // =========================================================
    // 2) Token lock (purchase_token -> user_id)
    // =========================================================
    // If token already claimed by a DIFFERENT user -> reject.
    // If claimed by SAME user -> allow and refresh last_seen_at.
    const { data: existingLock, error: lockReadErr } = await sbAdmin
      .from("purchase_token_locks")
      .select("user_id, product_id")
      .eq("purchase_token", purchaseToken)
      .maybeSingle();

    if (lockReadErr) {
      console.error("Token lock read error:", lockReadErr);
      return json({ ok: false, error: "Token lock read failed" }, 500);
    }

    if (!existingLock) {
      // Try to claim
      const { error: insErr } = await sbAdmin.from("purchase_token_locks").insert({
        platform: "android",
        purchase_token: purchaseToken,
        product_id: productId,
        user_id: userId,
      });

      if (insErr) {
        // Race / already inserted: re-check owner
        const { data: again, error: againErr } = await sbAdmin
          .from("purchase_token_locks")
          .select("user_id, product_id")
          .eq("purchase_token", purchaseToken)
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

      // Same user: update last_seen_at (optional) + product_id
      await sbAdmin
        .from("purchase_token_locks")
        .update({
          last_seen_at: new Date().toISOString(),
          product_id: productId,
        })
        .eq("purchase_token", purchaseToken);
    }

    // =========================================================
    // 3) Apply entitlement to profile
    // =========================================================
    const { error: upErr } = await sbAdmin
      .from("profiles")
      .update({
        is_upgraded: true,
        is_lifetime: isLifetime,
        pro_expires_at: proExpiresAt, // null for lifetime
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
    console.error("verify-play-entitlement error:", e);
    const msg =
      e instanceof Error ? `${e.name}: ${e.message}\n${e.stack ?? ""}` : `Non-Error thrown: ${JSON.stringify(e)}`;
    return json({ ok: false, error: msg }, 500);
  }
});

// -------- helpers --------

async function getGoogleAccessToken(opts: { clientEmail: string; privateKeyPem: string; scope: string }) {
  const now = Math.floor(Date.now() / 1000);

  const key = await importPKCS8(opts.privateKeyPem, "RS256");

  const jwt = await new SignJWT({ scope: opts.scope })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .setIssuer(opts.clientEmail)
    .setAudience(TOKEN_URL)
    .sign(key);

  const form = new URLSearchParams();
  form.set("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer");
  form.set("assertion", jwt);

  const r = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: form,
  });

  const data = await r.json();
  if (!r.ok) throw new Error(`OAuth token error: ${r.status} ${JSON.stringify(data)}`);
  if (!data.access_token) throw new Error(`OAuth token missing access_token: ${JSON.stringify(data)}`);
  return data.access_token as string;
}

async function fetchJson(url: string, accessToken: string) {
  const r = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  const text = await r.text();
  let data: any;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  if (!r.ok) throw new Error(`Google API error: ${r.status} ${url} -> ${JSON.stringify(data)}`);
  return data;
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
