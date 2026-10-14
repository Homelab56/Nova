import { useState } from "react";
import { useAuth } from "../context/AuthContext";

export default function Login() {
  const { signIn, signUp } = useAuth();
  const [mode, setMode] = useState("signIn"); // "signIn" | "signUp"
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [localError, setLocalError] = useState(null);

  async function handleSubmit(e) {
    e.preventDefault();
    if (submitting) return;
    if (!email.trim() || !password) {
      setLocalError("Vul e-mailadres en wachtwoord in.");
      return;
    }
    setLocalError(null);
    setSubmitting(true);
    const err = mode === "signIn" ? await signIn(email.trim(), password) : await signUp(email.trim(), password);
    setSubmitting(false);
    if (err) setLocalError(err.message);
    // Op succes verandert de auth-status zelf via onAuthStateChange - geen navigate() nodig.
  }

  return (
    <div className="min-h-screen bg-nova-bg flex items-center justify-center p-4">
      <form onSubmit={handleSubmit} className="w-full max-w-sm bg-nova-card rounded-xl p-8 border border-gray-800">
        <h1 className="text-2xl font-bold text-white mb-1">Streamify</h1>
        <p className="text-gray-400 text-sm mb-6">
          Zelfde account als op de tv - je profielen en kijkgeschiedenis staan klaar.
        </p>

        <label className="block text-sm text-gray-400 mb-1">E-mailadres</label>
        <input
          type="email"
          autoComplete="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          className="w-full bg-black/30 border border-gray-700 rounded-lg px-3 py-2 text-white mb-4 outline-none focus:border-nova-accent"
        />

        <label className="block text-sm text-gray-400 mb-1">Wachtwoord</label>
        <input
          type="password"
          autoComplete={mode === "signIn" ? "current-password" : "new-password"}
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          className="w-full bg-black/30 border border-gray-700 rounded-lg px-3 py-2 text-white mb-4 outline-none focus:border-nova-accent"
        />

        {localError && <p className="text-red-400 text-sm mb-4">{localError}</p>}

        <button
          type="submit"
          disabled={submitting}
          className="w-full bg-nova-accent hover:bg-nova-hover disabled:opacity-60 text-white font-semibold rounded-lg py-2 transition-colors"
        >
          {submitting ? "Bezig..." : mode === "signIn" ? "Inloggen" : "Account aanmaken"}
        </button>

        <button
          type="button"
          onClick={() => {
            setMode(mode === "signIn" ? "signUp" : "signIn");
            setLocalError(null);
          }}
          className="w-full text-gray-400 hover:text-white text-sm mt-4"
        >
          {mode === "signIn" ? "Nog geen account? Maak er een aan" : "Al een account? Log in"}
        </button>
      </form>
    </div>
  );
}
