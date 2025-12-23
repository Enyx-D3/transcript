// supabase/functions/verify-play-subscription/index.ts
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.48.0';
import { GoogleAuth } from 'https://esm.sh/google-auth-library@9.14.1';
import { androidpublisher_v3, google } from 'https://esm.sh/googleapis@137.0.0';

type Body = {
  product_id?: string;
  purchase_token?: string;
  user_id?: string; // we'll send this from Flutter
};

serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  try {
    const body = (await req.json()) as Body;
    const productId = body.product_id;
    const purchaseToken = body.purchase_token;
    const userId = body.user_id;

    if (!productId || !purchaseToken || !userId) {
      return json({ ok: false, error: 'Missing product_id / purchase_token / user_id' }, 400);
    }

    // Read secrets
    const svcEmail = Deno.env.get('GOOGLE_SERVICE_ACCOUNT_EMAIL');
    const svcPrivateKey = Deno.env.get('GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY');
    const supabaseUrl = Deno.env.get('SB_URL');
    const supabaseServiceRoleKey = Deno.env.get('SB_SERVICE_ROLE_KEY');

    if (!svcEmail || !svcPrivateKey || !supabaseUrl || !supabaseServiceRoleKey) {
      return json({ ok: false, error: 'Missing env vars' }, 500);
    }

    // 1) Setup Google auth client
    const auth = new GoogleAuth({
      credentials: {
        client_email: svcEmail,
        private_key: svcPrivateKey,
      },
      scopes: ['https://www.googleapis.com/auth/androidpublisher'],
    });

    const authClient = await auth.getClient();

    const androidpublisher = google.androidpublisher({
      version: 'v3',
      auth: authClient,
    }) as androidpublisher_v3.Androidpublisher;

    // 2) Extract package name from your Android app
    // Either hard-code here, or store in env var
    const packageName = Deno.env.get('ANDROID_PACKAGE_NAME') ?? 'com.fllama.transcript';

    // 3) Call Google Play API
    const subs = await androidpublisher.purchases.subscriptionsv2.get({
      packageName,
      token: purchaseToken,
    });

    // Basic validation
    const purchase = subs.data;

    if (!purchase) {
      return json({ ok: false, error: 'No purchase data from Google Play' }, 400);
    }

    const lineItems = purchase.lineItems ?? [];
    if (lineItems.length === 0) {
      return json({ ok: false, error: 'No lineItems in purchase' }, 400);
    }

    const li = lineItems[0];

    // status: 1 = pending, 2 = active, 3 = paused, 4 = in grace period, etc
    const state = li?.subscriptionPurchase?.purchaseState;
    if (state !== 2 && state !== 4) {
      return json({ ok: false, error: 'Subscription not active' }, 400);
    }

    // Get expiry time from Google (millis since epoch)
    const expiryMillis = li?.subscriptionPurchase?.expiryTime ?? li?.expiryTime;
    if (!expiryMillis) {
      return json({ ok: false, error: 'Missing expiry time' }, 400);
    }

    const expiryDate = new Date(Number(expiryMillis));

    // 4) Update profiles in Supabase (using service role)
    const sb = createClient(supabaseUrl, supabaseServiceRoleKey);

    const { error: upErr } = await sb
      .from('profiles')
      .update({
        is_upgraded: true,
        pro_expires_at: expiryDate.toISOString(),
        // Optionally end trial immediately
        trial_expires_at: new Date().toISOString(),
      })
      .eq('id', userId);

    if (upErr) {
      console.error('Supabase update error:', upErr);
      return json({ ok: false, error: 'Failed to update profile' }, 500);
    }

    return json({
      ok: true,
      product_id: productId,
      expires_at: expiryDate.toISOString(),
    });
  } catch (e) {
    console.error('verify-play-subscription error', e);
    return json({ ok: false, error: String(e) }, 500);
  }
});

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
