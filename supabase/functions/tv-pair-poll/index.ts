// tv-pair-poll — TV calls this every few seconds to check whether the code
// it's showing has been claimed by the phone yet. Single-use: a claimed row
// is deleted the moment it's handed back, so the same refresh token can
// never be read twice (replay protection).
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  let body: { code?: string };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const code = body.code?.trim().toUpperCase();
  if (!code) {
    return new Response(JSON.stringify({ error: "Missing code" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: row } = await supabase
    .from("tv_pair_codes")
    .select("status, expires_at, refresh_token")
    .eq("code", code)
    .maybeSingle();

  if (!row) {
    return new Response(JSON.stringify({ status: "expired" }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  if (new Date(row.expires_at).getTime() < Date.now()) {
    await supabase.from("tv_pair_codes").delete().eq("code", code);
    return new Response(JSON.stringify({ status: "expired" }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  if (row.status === "claimed" && row.refresh_token) {
    await supabase.from("tv_pair_codes").delete().eq("code", code);
    return new Response(
      JSON.stringify({ status: "claimed", refreshToken: row.refresh_token }),
      { headers: { "Content-Type": "application/json" } },
    );
  }

  return new Response(JSON.stringify({ status: "pending" }), {
    headers: { "Content-Type": "application/json" },
  });
});
