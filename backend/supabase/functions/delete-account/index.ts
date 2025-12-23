// supabase/functions/delete-account/index.ts
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing Authorization header" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Client to read the user from the JWT
    // (Auth guide shows extracting token from Authorization header and calling getUser) :contentReference[oaicite:2]{index=2}
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const token = authHeader.replace("Bearer ", "");
    const { data: userData, error: userErr } = await userClient.auth.getUser(token);
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: userErr?.message ?? "Invalid user" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    const userId = userData.user.id;

    // Admin client (service role) for deleting auth users :contentReference[oaicite:3]{index=3}
    const admin = createClient(supabaseUrl, serviceRoleKey);

    // 1) Delete profile row first (avoids FK conflicts if your FK isn't cascade)
    const { error: profileErr } = await admin
      .from("profiles")
      .delete()
      .eq("id", userId);

    if (profileErr) {
      return new Response(JSON.stringify({ error: `Profile delete failed: ${profileErr.message}` }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    // 2) Delete auth user
    const { error: delErr } = await admin.auth.admin.deleteUser(userId);
    if (delErr) {
      return new Response(JSON.stringify({ error: `Auth delete failed: ${delErr.message}` }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
