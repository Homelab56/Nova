// tv-pair-login — wat de gsm opent na het scannen van de QR-code op de tv.
//
// GET  ?code=XXXX  -> doorsturen (302) naar de koppelpagina op de Streamify-website
//                     (Supabase toont HTML van Edge Functions als platte tekst, dus de
//                     pagina zelf staat daar). Op die pagina logt de gsm in, of gebruikt
//                     hij de sessie die hij al had.
// POST {code, access_token} (JSON, vanaf die pagina)
//                  -> controleert de code en het token van de gsm, maakt een NIEUWE sessie
//                     voor dezelfde gebruiker aan (zodat tv en gsm elk een eigen sessie
//                     hebben en elkaar niet uitloggen) en zet die klaar voor tv-pair-poll.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// Adres van de Streamify-website met de koppelpagina (/tv-login).
const WEB_URL = (Deno.env.get("TV_PAIR_WEB_URL") ?? "http://192.168.1.75:8004").replace(/\/+$/, "");

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type, authorization, apikey, x-client-info",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });

  const url = new URL(req.url);

  if (req.method === "GET") {
    const code = url.searchParams.get("code")?.trim().toUpperCase() ?? "";
    const target = `${WEB_URL}/tv-login${code ? `?code=${encodeURIComponent(code)}` : ""}`;
    return new Response(null, { status: 302, headers: { ...CORS, Location: target } });
  }

  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  let body: { code?: string; access_token?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Ongeldig verzoek." }, 400);
  }
  const code = body.code?.trim().toUpperCase() ?? "";
  const accessToken = body.access_token ?? "";
  if (!code || !accessToken) return json({ error: "Code of sessie ontbreekt." }, 400);

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: row } = await admin
    .from("tv_pair_codes")
    .select("status, expires_at")
    .eq("code", code)
    .maybeSingle();
  if (!row || new Date(row.expires_at).getTime() < Date.now()) {
    return json({ error: "Deze code is verlopen. Vraag een nieuwe QR-code aan op de tv." }, 410);
  }
  if (row.status === "claimed") {
    return json({ error: "Deze code is al gebruikt. Vraag een nieuwe QR-code aan op de tv." }, 409);
  }

  // Wie is de gsm? (token wordt door Supabase zelf gecontroleerd)
  const { data: userData, error: userErr } = await admin.auth.getUser(accessToken);
  const email = userData?.user?.email;
  if (userErr || !email) return json({ error: "Je sessie is verlopen. Log opnieuw in." }, 401);

  // Nieuwe, aparte sessie voor de tv: eenmalige login-link aanmaken (wordt niet gemaild)
  // en die meteen inwisselen.
  const { data: link, error: linkErr } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  const tokenHash = link?.properties?.hashed_token;
  if (linkErr || !tokenHash) return json({ error: "Kon geen sessie voor de tv maken." }, 500);

  const anon = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: verified, error: otpErr } = await anon.auth.verifyOtp({ token_hash: tokenHash, type: "email" });
  const refreshToken = verified?.session?.refresh_token;
  if (otpErr || !refreshToken) return json({ error: "Kon geen sessie voor de tv maken." }, 500);

  const { error: updErr } = await admin
    .from("tv_pair_codes")
    .update({ status: "claimed", refresh_token: refreshToken })
    .eq("code", code)
    .eq("status", "pending");
  if (updErr) return json({ error: "Koppelen mislukt, probeer opnieuw." }, 500);

  return json({ ok: true });
});
