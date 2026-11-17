import { useState } from "react";
import { useAuth } from "../context/AuthContext";
import { supabase } from "../lib/supabaseClient";

// Koppelpagina voor de tv: hier komt de gsm terecht na het scannen van de QR-code.
// Ben je op deze gsm al ingelogd, dan is het één tik; anders eerst inloggen.
// De tv krijgt een eigen sessie (via de Edge Function tv-pair-login), dus gsm en tv
// loggen elkaar niet uit.
const PAIR_URL = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/tv-pair-login`;

export default function TvLogin() {
  const { status, session, signIn } = useAuth();
  const code = (new URLSearchParams(window.location.search).get("code") || "").trim().toUpperCase();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [done, setDone] = useState(false);

  async function pair() {
    setBusy(true);
    setError("");
    try {
      const { data } = await supabase.auth.getSession();
      const token = data?.session?.access_token;
      if (!token) throw new Error("Log eerst in.");
      const res = await fetch(PAIR_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code, access_token: token }),
      });
      const body = await res.json().catch(() => ({}));
      if (!res.ok || !body.ok) throw new Error(body.error || "Koppelen mislukt, probeer opnieuw.");
      setDone(true);
    } catch (e) {
      setError(e.message || "Koppelen mislukt, probeer opnieuw.");
    }
    setBusy(false);
  }

  async function loginAndPair(e) {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setError("");
    const err = await signIn(email.trim(), password);
    if (err) {
      setError("Onjuist e-mailadres of wachtwoord.");
      setBusy(false);
      return;
    }
    await pair();
  }

  let content;
  if (!code) {
    content = (
      <>
        <h1 className="text-xl font-bold mb-2">Geen code gevonden</h1>
        <p className="text-gray-400 text-sm">Scan de QR-code opnieuw vanaf de tv.</p>
      </>
    );
  } else if (done) {
    content = (
      <div className="text-center">
        <div className="w-16 h-16 mx-auto mb-4 rounded-full bg-green-500/15 text-green-400 flex items-center justify-center text-3xl">✓</div>
        <h1 className="text-xl font-bold mb-2">Gelukt!</h1>
        <p className="text-gray-400 text-sm">De tv logt nu vanzelf in. Je kunt dit venster sluiten.</p>
      </div>
    );
  } else if (status === "loading") {
    content = <div className="w-8 h-8 mx-auto border-2 border-nova-accent border-t-transparent rounded-full animate-spin" />;
  } else if (status === "signedIn") {
    content = (
      <>
        <h1 className="text-xl font-bold mb-1">Inloggen op de tv</h1>
        <p className="text-gray-400 text-sm mb-6">
          Je bent ingelogd als <strong className="text-white">{session?.user?.email}</strong>.
        </p>
        <button
          onClick={pair}
          disabled={busy}
          className="w-full py-3 rounded-xl bg-nova-accent hover:bg-nova-hover text-white font-semibold disabled:opacity-60"
        >
          {busy ? "Bezig…" : "Tv koppelen"}
        </button>
      </>
    );
  } else {
    content = (
      <form onSubmit={loginAndPair}>
        <h1 className="text-xl font-bold mb-1">Inloggen op de tv</h1>
        <p className="text-gray-400 text-sm mb-6">Log in met je Streamify-account om de tv te koppelen.</p>
        <label className="block text-sm text-gray-400 mb-1">E-mailadres</label>
        <input
          type="email"
          autoComplete="email"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          className="w-full bg-black/30 border border-gray-700 rounded-xl px-4 py-3 text-white mb-4 outline-none focus:border-nova-accent"
        />
        <label className="block text-sm text-gray-400 mb-1">Wachtwoord</label>
        <input
          type="password"
          autoComplete="current-password"
          required
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          className="w-full bg-black/30 border border-gray-700 rounded-xl px-4 py-3 text-white outline-none focus:border-nova-accent"
        />
        <button
          type="submit"
          disabled={busy}
          className="w-full mt-6 py-3 rounded-xl bg-nova-accent hover:bg-nova-hover text-white font-semibold disabled:opacity-60"
        >
          {busy ? "Bezig…" : "Inloggen en tv koppelen"}
        </button>
      </form>
    );
  }

  return (
    <div className="min-h-screen bg-nova-bg text-white flex items-center justify-center p-6">
      <div className="w-full max-w-sm bg-nova-card border border-white/10 rounded-2xl p-7 shadow-2xl">
        <div className="text-nova-accent font-black text-lg mb-5">Streamify</div>
        {content}
        {error && <p className="text-sm text-red-400 mt-4">{error}</p>}
      </div>
    </div>
  );
}
