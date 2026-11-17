// tv-pair-create — TV calls this to start a QR/code login pairing session.
// Generates a short-lived, single-use code and inserts a pending row into
// public.tv_pair_codes. No auth required to call this (the TV isn't signed
// in yet); the service-role key is what lets this function write to the
// otherwise-locked-down table.
import { createClient } from "npm:@supabase/supabase-js@2";

const CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"; // no 0/O/1/I to avoid ambiguity
const CODE_LENGTH = 10;
const TTL_MINUTES = 5;

function generateCode(): string {
  let code = "";
  const bytes = new Uint8Array(CODE_LENGTH);
  crypto.getRandomValues(bytes);
  for (let i = 0; i < CODE_LENGTH; i++) {
    code += CODE_ALPHABET[bytes[i] % CODE_ALPHABET.length];
  }
  return code;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const expiresAt = new Date(Date.now() + TTL_MINUTES * 60_000).toISOString();

  // Verlopen codes opruimen zodat de tabel klein blijft.
  await supabase.from("tv_pair_codes").delete().lt("expires_at", new Date().toISOString());

  // Extremely unlikely to collide, but retry once on a primary-key clash rather than fail.
  for (let attempt = 0; attempt < 3; attempt++) {
    const code = generateCode();
    const { error } = await supabase
      .from("tv_pair_codes")
      .insert({ code, expires_at: expiresAt, status: "pending" });

    if (!error) {
      return new Response(JSON.stringify({ code, expiresAt }), {
        headers: { "Content-Type": "application/json" },
      });
    }
    if (error.code !== "23505") {
      // Not a unique-violation — a real failure, don't retry.
      return new Response(JSON.stringify({ error: error.message }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }
  }

  return new Response(JSON.stringify({ error: "Could not allocate a pairing code" }), {
    status: 500,
    headers: { "Content-Type": "application/json" },
  });
});
