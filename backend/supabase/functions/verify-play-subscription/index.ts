import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.48.0";
import { GoogleAuth } from "https://esm.sh/google-auth-library@9.14.1";
import { androidpublisher_v3, google } from "https://esm.sh/googleapis@137.0.0";

type Body = {
  product_id?: string;
  purchase_token?: string;
};

const LIFETIME_PRODUCT_ID = "transcript_pro_lifetime";
// (Optional) If you want, also hardcode subscription product id(s) for sanity.
const SUBSCRIPTION_PRODUCT_ID = "transcript_pro";

serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({ ok: false, error: "Method not allowed" }, 405);
  }

  try {
    const body = (await req.json()) as Body;
    const productId = body.product_id?.trim();
    const purchaseToken = body.purchase_token?.trim();

    if (!productId || !purchaseToken) {
      return json({ ok: false, error: "Missing product_id / purchase_token" }, 400);
    }

    // ---- Read secrets ----
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const supabaseServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    const svcEmail = Deno.env.get("GOOGLE_SERVICE_ACCOUNT_EMAIL");
    const rawPrivateKey = Deno.env.get("GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY");

    const packageName = Deno.env.get("ANDROID_PACKAGE_NAME") ?? "com.fllama.transcript";

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

    const svcPrivateKey = rawPrivateKey.replaceAll("\\n", "\n");

    // ---- Identify user from Supabase JWT ----
    const authHeader = req.headers.get("Authorization") ?? "";
    if (!authHeader) {
      return json({ ok: false, error: "Missing Authorization header" }, 401);
    }

    const sbUser = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userData, error: userErr } = await sbUser.auth.getUser();
    if (userErr || !userData?.user) {
      return json({ ok: false, error: "Unauthorized" }, 401);
    }
    const userId = userData.user.id;

    // ---- Setup Google auth client ----
    const auth = new GoogleAuth({
      credentials: { client_email: svcEmail, private_key: svcPrivateKey },
      scopes: ["https://www.googleapis.com/auth/androidpublisher"],
    });

    const authClient = await auth.getClient();

    const androidpublisher = google.androidpublisher({
      version: "v3",
      auth: authClient,
    }) as androidpublisher_v3.Androidpublisher;

    // ---- Branch: Lifetime product vs Subscription ----
    const isLifetime = productId === LIFETIME_PRODUCT_ID;

    // We'll compute these and then write profiles once.
    let proExpiresAt: string | null = null;

    if (isLifetime) {
      // ========== ONE-TIME MANAGED PRODUCT ==========
      const prod = await androidpublisher.purchases.products.get({
        packageName,
        productId,
        token: purchaseToken,
      });

      const purchase = prod.data;
      if (!purchase) {
        return json({ ok: false, error: "No product purchase data from Google Play" }, 400);
      }

      // purchaseState: 0 Purchased, 1 Canceled, 2 Pending (varies by doc versions but 0=OK)
      const purchaseState = purchase.purchaseState;
      if (purchaseState !== 0) {
        return json(
          { ok: false, error: `Lifetime purchase not completed: purchaseState=${purchaseState}` },
          400,
        );
      }

      // Lifetime: never expires
      proExpiresAt = null;
    } else {
      // ========== SUBSCRIPTION (Subscriptions v2) ==========
      // Note: subscriptionsv2.get does not require productId, only token.
      const subs = await androidpublisher.purchases.subscriptionsv2.get({
        packageName,
        token: purchaseToken,
      });

      const purchase = subs.data;
      if (!purchase) {
        return json({ ok: false, error: "No subscription data from Google Play" }, 400);
      }

      const state = purchase.subscriptionState;
      const activeStates = new Set([
        "SUBSCRIPTION_STATE_ACTIVE",
        "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
      ]);

      if (!state || !activeStates.has(state)) {
        return json(
          { ok: false, error: `Subscription not active: ${state ?? "unknown"}` },
          400,
        );
      }

      const lineItems = purchase.lineItems ?? [];
      if (lineItems.length === 0) {
        return json({ ok: false, error: "No lineItems in subscription purchase" }, 400);
      }

      // Prefer matching productId if present, else first item.
      // (Some Play responses may have productId in lineItems.)
      const li = lineItems.find((x) => x.productId === productId) ?? lineItems[0];
      const expiryTime = li?.expiryTime;

      if (!expiryTime) {
        return json({ ok: false, error: "Missing expiryTime" }, 400);
      }

      const expiryDate = new Date(expiryTime);
      if (isNaN(expiryDate.getTime())) {
        return json({ ok: false, error: `Bad expiryTime: ${expiryTime}` }, 400);
      }

      proExpiresAt = expiryDate.toISOString();
    }

    // ---- Update profiles using service role (bypasses RLS) ----
    const sbAdmin = createClient(supabaseUrl, supabaseServiceRoleKey);

    const { error: upErr } = await sbAdmin
      .from("profiles")
      .update({
        is_upgraded: true,
        is_lifetime: isLifetime,
        pro_expires_at: proExpiresAt,          // null for lifetime
        trial_expires_at: new Date().toISOString(),
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
      expires_at: proExpiresAt, // null for lifetime
    });
  } catch (e) {
    console.error("verify-play-entitlement error", e);
    return json({ ok: false, error: String(e) }, 500);
  }
});

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
