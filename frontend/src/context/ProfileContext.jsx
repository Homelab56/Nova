import { createContext, useCallback, useContext, useEffect, useState } from "react";
import { useAuth } from "./AuthContext";
import { supabase } from "../lib/supabaseClient";

const ProfileContext = createContext(null);
const STORAGE_KEY = "nova.selectedProfileId";

export function ProfileProvider({ children }) {
  const { status, session } = useAuth();
  const [profiles, setProfiles] = useState([]);
  const [loading, setLoading] = useState(true);
  const [selectedProfileId, setSelectedProfileId] = useState(() => localStorage.getItem(STORAGE_KEY));

  // Gebruikt steeds het ACTUELE token: supabase.auth.getSession() ververst een verlopen
  // token zelf. Het token uit de render waarin deze functie ooit gemaakt werd raakt anders
  // verlopen in langlopende closures (een film van >1u, een tabblad dat lang openstaat,
  // timers) waardoor opslaan/ophalen stil mislukte en de lijsten leeg leken. Bij een 401
  // wordt de sessie expliciet ververst en de aanvraag één keer herhaald.
  const authedFetch = useCallback(
    async (path, options = {}) => {
      const send = (token) =>
        fetch(`/api${path}`, {
          ...options,
          headers: { ...(options.headers || {}), Authorization: `Bearer ${token}` },
        });
      const { data } = await supabase.auth.getSession();
      const token = data?.session?.access_token || session?.access_token;
      if (!token) throw new Error("Niet ingelogd");
      let res = await send(token);
      if (res.status === 401) {
        const { data: refreshed } = await supabase.auth.refreshSession();
        const fresh = refreshed?.session?.access_token;
        if (fresh && fresh !== token) res = await send(fresh);
      }
      return res;
    },
    [session]
  );

  const refreshProfiles = useCallback(async () => {
    if (!session) {
      setProfiles([]);
      setLoading(false);
      return;
    }
    setLoading(true);
    try {
      const res = await authedFetch("/profiles/");
      const data = res.ok ? await res.json() : [];
      setProfiles(data);
      // Een geselecteerd profiel dat niet (meer) bestaat (verwijderd, of van een
      // ander account na uitloggen/inloggen) telt niet mee als een geldige keuze.
      if (selectedProfileId && !data.some((p) => p.id === selectedProfileId)) {
        setSelectedProfileId(null);
        localStorage.removeItem(STORAGE_KEY);
      }
    } catch {
      setProfiles([]);
    } finally {
      setLoading(false);
    }
  }, [authedFetch, session, selectedProfileId]);

  useEffect(() => {
    if (status === "signedIn") refreshProfiles();
    if (status === "signedOut") {
      setProfiles([]);
      setSelectedProfileId(null);
      localStorage.removeItem(STORAGE_KEY);
      setLoading(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [status]);

  function selectProfile(profileId) {
    setSelectedProfileId(profileId);
    localStorage.setItem(STORAGE_KEY, profileId);
  }

  function clearSelectedProfile() {
    setSelectedProfileId(null);
    localStorage.removeItem(STORAGE_KEY);
  }

  async function createProfile(name, avatarColorHex) {
    const res = await authedFetch("/profiles/", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name, avatar_color_hex: avatarColorHex, is_admin: profiles.length === 0 }),
    });
    if (!res.ok) throw new Error("Profiel aanmaken mislukt");
    await refreshProfiles();
  }

  async function deleteProfile(profileId) {
    await authedFetch(`/profiles/${profileId}`, { method: "DELETE" });
    if (selectedProfileId === profileId) clearSelectedProfile();
    await refreshProfiles();
  }

  const selectedProfile = profiles.find((p) => p.id === selectedProfileId) || null;

  return (
    <ProfileContext.Provider
      value={{
        profiles,
        loading,
        selectedProfile,
        selectedProfileId,
        selectProfile,
        clearSelectedProfile,
        createProfile,
        deleteProfile,
        refreshProfiles,
        authedFetch,
      }}
    >
      {children}
    </ProfileContext.Provider>
  );
}

export function useProfile() {
  const ctx = useContext(ProfileContext);
  if (!ctx) throw new Error("useProfile must be used within ProfileProvider");
  return ctx;
}
