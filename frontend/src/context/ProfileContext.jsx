import { createContext, useCallback, useContext, useEffect, useState } from "react";
import { useAuth } from "./AuthContext";
import { supabase } from "../lib/supabaseClient";
import PinDialog from "../components/PinDialog";

const ProfileContext = createContext(null);
const STORAGE_KEY = "nova.selectedProfileId";

export function ProfileProvider({ children }) {
  const { status, session } = useAuth();
  const [profiles, setProfiles] = useState([]);
  const [loading, setLoading] = useState(true);
  const [selectedProfileId, setSelectedProfileId] = useState(() => localStorage.getItem(STORAGE_KEY));
  const [locks, setLocks] = useState({}); // profiel-id -> true als het met een pincode vergrendeld is
  const [pinRequest, setPinRequest] = useState(null);

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
      const [res, lockRes] = await Promise.all([
        authedFetch("/profiles/"),
        authedFetch("/profiles/locks/all").catch(() => null),
      ]);
      const data = res.ok ? await res.json() : [];
      setProfiles(data);
      if (lockRes?.ok) setLocks(await lockRes.json());
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

  async function apiError(res, fallback) {
    let msg = fallback;
    try { msg = (await res.json())?.detail || fallback; } catch {}
    return new Error(msg);
  }

  // Vraagt een pincode via het venster. `submit(pin)` mag een fout gooien (blijft dan open).
  function askPin({ title, subtitle, profile, submit }) {
    return new Promise((resolve) => {
      setPinRequest({
        id: Date.now() + Math.random(),
        title, subtitle, profile,
        onSubmit: async (pin) => { await submit(pin); setPinRequest(null); resolve(pin); },
        onCancel: () => { setPinRequest(null); resolve(null); },
      });
    });
  }

  async function verifyPin(profileId, pin) {
    const res = await authedFetch(`/profiles/${profileId}/unlock`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ pin }),
    });
    if (!res.ok) throw await apiError(res, "Verkeerde pincode");
  }

  // Profiel openen: vraagt eerst de pincode als het vergrendeld is.
  async function openProfile(profileId) {
    const profile = profiles.find((p) => p.id === profileId);
    if (locks[profileId]) {
      const ok = await askPin({
        title: profile?.name || "Profiel",
        subtitle: "Voer de pincode in",
        profile,
        submit: (pin) => verifyPin(profileId, pin),
      });
      if (!ok) return false;
    }
    selectProfile(profileId);
    return true;
  }

  const adminProfile = profiles.find((p) => p.is_admin) || null;

  // Pincode van het hoofdprofiel vragen (nodig om pincodes te beheren), of null als die er niet is.
  async function askAdminPin(reason) {
    if (!adminProfile || !locks[adminProfile.id]) return "";
    return askPin({
      title: `Pincode van ${adminProfile.name}`,
      subtitle: reason,
      profile: adminProfile,
      submit: (pin) => verifyPin(adminProfile.id, pin),
    });
  }

  async function setProfilePin(profileId, pin, adminPin) {
    const res = await authedFetch(`/profiles/${profileId}/pin`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ pin, admin_pin: adminPin || null }),
    });
    if (!res.ok) throw await apiError(res, "Pincode instellen mislukt");
    await refreshProfiles();
  }

  async function clearProfilePin(profileId, adminPin) {
    const res = await authedFetch(`/profiles/${profileId}/pin`, {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ admin_pin: adminPin || null }),
    });
    if (!res.ok) throw await apiError(res, "Pincode verwijderen mislukt");
    await refreshProfiles();
  }

  async function updateProfile(profileId, changes) {
    const res = await authedFetch(`/profiles/${profileId}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(changes),
    });
    if (!res.ok) throw new Error("Profiel opslaan mislukt");
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
        updateProfile,
        locks,
        adminProfile,
        openProfile,
        askPin,
        askAdminPin,
        setProfilePin,
        clearProfilePin,
        deleteProfile,
        refreshProfiles,
        authedFetch,
      }}
    >
      {children}
      {pinRequest && (
        <PinDialog
          key={pinRequest.id}
          title={pinRequest.title}
          subtitle={pinRequest.subtitle}
          profile={pinRequest.profile}
          onSubmit={pinRequest.onSubmit}
          onCancel={pinRequest.onCancel}
        />
      )}
    </ProfileContext.Provider>
  );
}

export function useProfile() {
  const ctx = useContext(ProfileContext);
  if (!ctx) throw new Error("useProfile must be used within ProfileProvider");
  return ctx;
}
