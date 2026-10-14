import { createContext, useContext, useEffect, useState } from "react";
import { supabase } from "../lib/supabaseClient";

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  // "loading" | "signedOut" | "signedIn"
  const [status, setStatus] = useState("loading");
  const [session, setSession] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setStatus(data.session ? "signedIn" : "signedOut");
    });

    const { data: listener } = supabase.auth.onAuthStateChange((_event, newSession) => {
      setSession(newSession);
      setStatus(newSession ? "signedIn" : "signedOut");
    });

    return () => listener.subscription.unsubscribe();
  }, []);

  async function signIn(email, password) {
    setError(null);
    const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });
    if (signInError) {
      setError(signInError.message);
      return signInError;
    }
    return null;
  }

  async function signUp(email, password) {
    setError(null);
    const { data, error: signUpError } = await supabase.auth.signUp({ email, password });
    if (signUpError) {
      setError(signUpError.message);
      return signUpError;
    }
    if (!data.session) {
      const msg = "Account aangemaakt - bevestig je e-mailadres via de link die we stuurden, en log dan opnieuw in.";
      setError(msg);
      return { message: msg };
    }
    return null;
  }

  async function signOut() {
    await supabase.auth.signOut();
  }

  return (
    <AuthContext.Provider value={{ status, session, error, signIn, signUp, signOut }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}

/** Convenience for API calls: the current access token, or null if signed out. */
export function useAccessToken() {
  const { session } = useAuth();
  return session?.access_token ?? null;
}
