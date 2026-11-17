import { useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import Sidebar from "../components/Sidebar";
import { useProfile } from "../context/ProfileContext";
import { useAuth } from "../context/AuthContext";

const COLORS = ["#1E88E5", "#E53935", "#43A047", "#FB8C00", "#8E24AA", "#00897B", "#D81B60", "#6D4C41"];

const SECTIONS = [
  { key: "taal", label: "Taal & ondertitels", icon: "🌐" },
  { key: "profielen", label: "Profielen", icon: "👤" },
  { key: "account", label: "Account", icon: "🔑" },
  { key: "systeem", label: "Systeemstatus", icon: "🛠" },
];

const AUDIO_OPTIONS = [
  { value: "en", label: "Engels", hint: "Originele versie" },
  { value: "nl", label: "Nederlands", hint: "Als er een Nederlands spoor is" },
];

const SUB_LANGS = [
  { value: "nl", label: "Nederlands" },
  { value: "nl-be", label: "Vlaams" },
  { value: "en", label: "Engels" },
  { value: "fr", label: "Frans" },
  { value: "de", label: "Duits" },
];

const DEFAULT_PREFS = {
  default_audio_lang: "en",
  default_sub_lang_1: "nl",
  default_sub_lang_2: "nl-be",
  subtitles_enabled: true,
};

// ---------- kleine bouwstenen ----------

function Avatar({ profile, size = "w-14 h-14 text-xl" }) {
  const [imgFailed, setImgFailed] = useState(false);
  return (
    <div
      className={`${size} rounded-xl flex items-center justify-center font-bold text-white overflow-hidden flex-shrink-0`}
      style={{ backgroundColor: profile?.avatar_color_hex || "#1E88E5" }}
    >
      {profile?.avatar_url && !imgFailed ? (
        <img src={profile.avatar_url} alt="" className="w-full h-full object-cover" onError={() => setImgFailed(true)} />
      ) : (
        (profile?.name || "?").charAt(0).toUpperCase()
      )}
    </div>
  );
}

function Section({ title, subtitle, children }) {
  return (
    <section className="bg-nova-card/60 border border-white/5 rounded-2xl p-6 mb-6">
      <h3 className="text-lg font-bold text-white">{title}</h3>
      {subtitle && <p className="text-sm text-gray-400 mt-1">{subtitle}</p>}
      <div className="mt-5">{children}</div>
    </section>
  );
}

function Chip({ active, onClick, children, disabled }) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className={`px-4 py-2 rounded-full text-sm font-medium border transition-colors disabled:opacity-40 ${
        active
          ? "border-nova-accent text-nova-accent bg-nova-accent/10"
          : "border-gray-700 text-gray-300 hover:text-white hover:border-gray-500"
      }`}
    >
      {children}
    </button>
  );
}

function Toggle({ checked, onChange, label }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      onClick={() => onChange(!checked)}
      className="flex items-center justify-between w-full gap-4 text-left"
    >
      <span className="text-sm font-semibold text-white">{label}</span>
      <span className={`relative w-12 h-7 rounded-full transition-colors flex-shrink-0 ${checked ? "bg-nova-accent" : "bg-gray-700"}`}>
        <span className={`absolute top-1 w-5 h-5 rounded-full bg-white shadow transition-all ${checked ? "left-6" : "left-1"}`} />
      </span>
    </button>
  );
}

// ---------- Taal ----------

function LanguageSettings({ profile }) {
  const [prefs, setPrefs] = useState(DEFAULT_PREFS);
  const [loaded, setLoaded] = useState(false);
  const [saveState, setSaveState] = useState(""); // "", "saving", "saved", "error"
  const timer = useRef(null);

  useEffect(() => {
    if (!profile?.id) return;
    setLoaded(false);
    fetch(`/api/user/prefs?profile_id=${encodeURIComponent(profile.id)}`)
      .then(r => (r.ok ? r.json() : null))
      .then(d => { if (d && typeof d === "object") setPrefs({ ...DEFAULT_PREFS, ...d }); })
      .catch(() => {})
      .finally(() => setLoaded(true));
  }, [profile?.id]);

  // Elke wijziging wordt meteen (licht vertraagd) bewaard - geen aparte opslaan-knop.
  function update(changes) {
    const next = { ...prefs, ...changes };
    if (next.default_sub_lang_2 === next.default_sub_lang_1) next.default_sub_lang_2 = "";
    setPrefs(next);
    setSaveState("saving");
    clearTimeout(timer.current);
    timer.current = setTimeout(async () => {
      try {
        const r = await fetch(`/api/user/prefs?profile_id=${encodeURIComponent(profile.id)}`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(next),
        });
        setSaveState(r.ok ? "saved" : "error");
      } catch {
        setSaveState("error");
      }
    }, 300);
  }

  const audioIsNl = String(prefs.default_audio_lang || "").startsWith("nl");

  return (
    <div className={loaded ? "" : "opacity-50 pointer-events-none"}>
      <div className="flex items-center gap-3 mb-6 text-sm text-gray-400">
        <Avatar profile={profile} size="w-8 h-8 text-sm" />
        <span>Voor profiel <strong className="text-white">{profile?.name}</strong></span>
        <span className="ml-auto text-xs">
          {saveState === "saving" && "Opslaan…"}
          {saveState === "saved" && <span className="text-green-400">✓ Opgeslagen</span>}
          {saveState === "error" && <span className="text-red-400">Opslaan mislukt</span>}
        </span>
      </div>

      <Section title="Gesproken taal" subtitle="Welk audiospoor de speler standaard kiest. Andere talen (Spaans, Italiaans, …) worden nooit automatisch gekozen.">
        <div className="grid sm:grid-cols-2 gap-3">
          {AUDIO_OPTIONS.map(o => {
            const active = o.value === "nl" ? audioIsNl : !audioIsNl;
            return (
              <button
                key={o.value}
                type="button"
                onClick={() => update({ default_audio_lang: o.value })}
                className={`text-left p-4 rounded-xl border transition-colors ${
                  active ? "border-nova-accent bg-nova-accent/10" : "border-gray-700 hover:border-gray-500"
                }`}
              >
                <div className={`font-semibold ${active ? "text-nova-accent" : "text-white"}`}>{o.label}</div>
                <div className="text-xs text-gray-400 mt-0.5">{o.hint}</div>
              </button>
            );
          })}
        </div>
      </Section>

      <Section title="Ondertitels">
        <Toggle
          label="Ondertitels standaard aan"
          checked={!!prefs.subtitles_enabled}
          onChange={(v) => update({ subtitles_enabled: v })}
        />

        <div className={`mt-6 transition-opacity ${prefs.subtitles_enabled ? "" : "opacity-40 pointer-events-none"}`}>
          <div className="text-sm font-semibold text-white mb-2">Voorkeurstaal</div>
          <div className="flex flex-wrap gap-2">
            {SUB_LANGS.map(o => (
              <Chip key={o.value} active={prefs.default_sub_lang_1 === o.value} onClick={() => update({ default_sub_lang_1: o.value })}>
                {o.label}
              </Chip>
            ))}
          </div>

          <div className="text-sm font-semibold text-white mt-6 mb-1">Als die er niet is</div>
          <p className="text-xs text-gray-500 mb-2">Tweede keuze wanneer de film of serie geen ondertitels in je voorkeurstaal heeft.</p>
          <div className="flex flex-wrap gap-2">
            <Chip active={!prefs.default_sub_lang_2} onClick={() => update({ default_sub_lang_2: "" })}>Geen</Chip>
            {SUB_LANGS.filter(o => o.value !== prefs.default_sub_lang_1).map(o => (
              <Chip key={o.value} active={prefs.default_sub_lang_2 === o.value} onClick={() => update({ default_sub_lang_2: o.value })}>
                {o.label}
              </Chip>
            ))}
          </div>
        </div>
      </Section>

      <p className="text-xs text-gray-500 px-1">
        Tijdens het kijken kun je audio en ondertitels altijd nog wisselen via de knoppen in de speler.
      </p>
    </div>
  );
}

// ---------- Profielen ----------

function ProfileEditor({ profile, isNew, canDelete, onSave, onDelete, onCancel }) {
  const [name, setName] = useState(profile?.name || "");
  const [color, setColor] = useState(profile?.avatar_color_hex || COLORS[0]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [confirmDelete, setConfirmDelete] = useState(false);

  async function submit(e) {
    e.preventDefault();
    if (!name.trim() || busy) return;
    setBusy(true);
    setError("");
    try {
      await onSave({ name: name.trim(), avatar_color_hex: color });
    } catch (err) {
      setError(err.message || "Opslaan mislukt");
      setBusy(false);
    }
  }

  async function remove() {
    setBusy(true);
    try {
      await onDelete();
    } catch {
      setError("Verwijderen mislukt");
      setBusy(false);
    }
  }

  return (
    <form onSubmit={submit} className="bg-black/30 border border-gray-700 rounded-2xl p-5 mt-4 animate-[nova-fade-in_200ms_ease-out]">
      <div className="flex items-center gap-4 mb-5">
        <Avatar profile={{ ...profile, name: name || "?", avatar_color_hex: color, avatar_url: isNew ? null : profile?.avatar_url }} />
        <div className="flex-1">
          <label className="block text-xs text-gray-400 mb-1">Naam</label>
          <input
            autoFocus
            value={name}
            maxLength={40}
            onChange={(e) => setName(e.target.value)}
            className="w-full bg-black/40 border border-gray-700 rounded-lg px-3 py-2 text-white outline-none focus:border-nova-accent"
          />
        </div>
      </div>

      <label className="block text-xs text-gray-400 mb-2">Kleur</label>
      <div className="flex flex-wrap gap-2 mb-5">
        {COLORS.map(c => (
          <button
            type="button"
            key={c}
            onClick={() => setColor(c)}
            className={`w-9 h-9 rounded-full transition-transform ${color.toLowerCase() === c.toLowerCase() ? "ring-2 ring-white scale-110" : "hover:scale-105"}`}
            style={{ backgroundColor: c }}
            aria-label={`Kleur ${c}`}
          />
        ))}
      </div>

      {error && <p className="text-sm text-red-400 mb-3">{error}</p>}

      {confirmDelete ? (
        <div className="flex flex-wrap items-center gap-3 bg-red-950/40 border border-red-900/50 rounded-xl p-3">
          <span className="text-sm text-red-200 flex-1 min-w-[12rem]">
            Profiel <strong>{profile?.name}</strong> verwijderen? Ook op de tv verdwijnt het.
          </span>
          <button type="button" onClick={remove} disabled={busy} className="px-4 py-2 rounded-lg bg-red-600 hover:bg-red-500 text-white text-sm font-semibold disabled:opacity-50">
            Ja, verwijderen
          </button>
          <button type="button" onClick={() => setConfirmDelete(false)} className="px-3 py-2 text-sm text-gray-300 hover:text-white">
            Nee
          </button>
        </div>
      ) : (
        <div className="flex flex-wrap gap-2">
          <button type="submit" disabled={busy || !name.trim()} className="px-5 py-2 rounded-lg bg-nova-accent hover:bg-nova-hover text-white text-sm font-semibold disabled:opacity-50">
            {busy ? "Bezig…" : isNew ? "Aanmaken" : "Opslaan"}
          </button>
          <button type="button" onClick={onCancel} className="px-4 py-2 text-sm text-gray-400 hover:text-white">
            Annuleren
          </button>
          {!isNew && canDelete && (
            <button type="button" onClick={() => setConfirmDelete(true)} className="ml-auto px-4 py-2 text-sm text-red-400 hover:text-red-300">
              Profiel verwijderen
            </button>
          )}
        </div>
      )}

      {!isNew && profile && <PinSection profile={profile} />}
    </form>
  );
}

const ROW_BTN = "px-4 py-2 rounded-lg border border-gray-700 text-sm text-gray-200 hover:text-white hover:border-gray-500 hover:bg-white/5 whitespace-nowrap transition-colors";

function Badge({ accent, children }) {
  return (
    <span
      className={`inline-flex items-center whitespace-nowrap leading-none text-[11px] font-semibold px-2.5 py-1 rounded-full ${
        accent ? "bg-nova-accent/15 text-nova-accent" : "bg-white/10 text-gray-300"
      }`}
    >
      {children}
    </span>
  );
}

function PinSection({ profile }) {
  const { locks, adminProfile, askPin, askAdminPin, setProfilePin, clearProfilePin } = useProfile();
  const [msg, setMsg] = useState({ text: "", ok: true });
  const locked = !!locks[profile.id];
  const isAdmin = profile.id === adminProfile?.id;
  const adminLocked = adminProfile && !!locks[adminProfile.id];
  const blocked = !isAdmin && !adminLocked;

  async function setPin() {
    setMsg({ text: "", ok: true });
    const adminPin = await askAdminPin("Bevestig met jouw pincode om pincodes te beheren.");
    if (adminPin === null) return;
    let first = null;
    const p1 = await askPin({
      title: locked ? "Nieuwe pincode" : "Kies een pincode",
      subtitle: `4 cijfers voor ${profile.name}`,
      profile,
      submit: async (pin) => { first = pin; },
    });
    if (!p1) return;
    const p2 = await askPin({
      title: "Herhaal de pincode",
      subtitle: `Ter bevestiging voor ${profile.name}`,
      profile,
      submit: async (pin) => { if (pin !== first) throw new Error("Pincodes komen niet overeen"); },
    });
    if (!p2) return;
    try {
      await setProfilePin(profile.id, first, adminPin);
      setMsg({ text: locked ? "Pincode gewijzigd." : "Profiel is nu vergrendeld met een pincode.", ok: true });
    } catch (e) {
      setMsg({ text: e.message, ok: false });
    }
  }

  async function removePin() {
    setMsg({ text: "", ok: true });
    const adminPin = await askAdminPin("Bevestig met jouw pincode om de vergrendeling op te heffen.");
    if (adminPin === null) return;
    try {
      await clearProfilePin(profile.id, adminPin);
      setMsg({ text: "Pincode verwijderd.", ok: true });
    } catch (e) {
      setMsg({ text: e.message, ok: false });
    }
  }

  return (
    <div className="mt-5 pt-5 border-t border-white/10">
      <div className="flex flex-wrap items-center gap-3">
        <div className="flex-1 min-w-[12rem]">
          <div className="text-sm font-semibold text-white">{locked ? "🔒 Vergrendeld met pincode" : "Pincode"}</div>
          <div className="text-xs text-gray-400 mt-0.5">
            {blocked
              ? `Stel eerst een pincode in voor ${adminProfile?.name || "het hoofdprofiel"}; anders kan iedereen de pincodes aanpassen.`
              : locked
                ? "Bij het openen van dit profiel wordt de pincode gevraagd."
                : "Niemand heeft een pincode nodig om dit profiel te openen."}
          </div>
        </div>
        <button type="button" onClick={setPin} disabled={blocked} className="px-4 py-2 rounded-lg bg-white/10 hover:bg-white/15 text-sm text-white disabled:opacity-40">
          {locked ? "Pincode wijzigen" : "Pincode instellen"}
        </button>
        {locked && (
          <button type="button" onClick={removePin} className="px-4 py-2 rounded-lg text-sm text-red-400 hover:text-red-300 hover:bg-red-500/10">
            Pincode verwijderen
          </button>
        )}
      </div>
      {msg.text && <p className={`text-sm mt-3 ${msg.ok ? "text-green-400" : "text-red-400"}`}>{msg.text}</p>}
    </div>
  );
}

function ProfileSettings() {
  const { profiles, selectedProfileId, selectedProfile, openProfile, clearSelectedProfile, createProfile, updateProfile, deleteProfile, locks } = useProfile();
  const [editing, setEditing] = useState(null); // profiel-id of "new"
  const canManage = !!selectedProfile?.is_admin;

  const renderEditor = (id) => {
    const target = id === "new" ? null : profiles.find(p => p.id === id);
    return (
      <ProfileEditor
        key={id}
        isNew={id === "new"}
        profile={target}
        canDelete={!!target && !target.is_admin && profiles.length > 1}
        onCancel={() => setEditing(null)}
        onSave={async (changes) => {
          if (id === "new") await createProfile(changes.name, changes.avatar_color_hex);
          else await updateProfile(id, changes);
          setEditing(null);
        }}
        onDelete={async () => {
          await deleteProfile(id);
          setEditing(null);
        }}
      />
    );
  };

  return (
    <>
      <Section
        title="Profielen"
        subtitle="Dezelfde profielen als op de tv: wijzigingen zie je daar ook. Elk profiel heeft z'n eigen kijkgeschiedenis, sterren en taalinstellingen."
      >
        <div className="flex flex-col gap-3">
          {profiles.map(p => {
            const active = p.id === selectedProfileId;
            const isEditing = editing === p.id;
            return (
              <div key={p.id}>
                <div
                  className={`flex flex-wrap items-center gap-x-4 gap-y-3 p-4 rounded-xl border transition-colors ${
                    isEditing ? "border-nova-accent bg-nova-accent/5" : "border-gray-800 hover:border-gray-700"
                  }`}
                >
                  <Avatar profile={p} />
                  <div className="flex-1 min-w-[10rem]">
                    <div className="font-semibold text-white text-base truncate">{p.name}</div>
                    {(active || p.is_admin || locks[p.id]) && (
                      <div className="flex flex-wrap gap-1.5 mt-1.5">
                        {active && <Badge accent>Actief</Badge>}
                        {p.is_admin && <Badge>Hoofdprofiel</Badge>}
                        {locks[p.id] && <Badge>🔒 Pincode</Badge>}
                      </div>
                    )}
                  </div>
                  <div className="flex gap-2 flex-shrink-0">
                    {!active && (
                      <button onClick={() => openProfile(p.id)} className={ROW_BTN}>
                        Wissel naar
                      </button>
                    )}
                    {canManage && (
                      <button onClick={() => setEditing(isEditing ? null : p.id)} className={ROW_BTN}>
                        {isEditing ? "Sluiten" : "Bewerken"}
                      </button>
                    )}
                  </div>
                </div>
                {canManage && isEditing && renderEditor(p.id)}
              </div>
            );
          })}

          {canManage && profiles.length < 10 && (
            <div>
              <button
                onClick={() => setEditing(editing === "new" ? null : "new")}
                className={`w-full flex items-center gap-4 p-4 rounded-xl border-2 border-dashed transition-colors text-left ${
                  editing === "new" ? "border-nova-accent text-nova-accent" : "border-gray-700 text-gray-400 hover:border-nova-accent hover:text-nova-accent"
                }`}
              >
                <div className="w-14 h-14 rounded-xl border border-current flex items-center justify-center text-2xl">+</div>
                <span className="font-semibold">Profiel toevoegen</span>
              </button>
              {editing === "new" && renderEditor("new")}
            </div>
          )}
        </div>

        {!canManage && (
          <p className="text-sm text-gray-500 mt-4">Alleen het hoofdprofiel kan profielen en pincodes beheren.</p>
        )}
      </Section>

      <button
        onClick={clearSelectedProfile}
        className="w-full sm:w-auto px-5 py-2.5 rounded-xl border border-gray-700 text-sm text-gray-300 hover:text-white hover:border-gray-500"
      >
        Naar het profielscherm ("Wie kijkt er?")
      </button>
    </>
  );
}

// ---------- Account ----------

function AccountSettings() {
  const { session, signOut } = useAuth();
  return (
    <Section title="Account" subtitle="Je Streamify-account, hetzelfde als op de tv.">
      <div className="flex flex-wrap items-center gap-4">
        <div className="flex-1 min-w-0">
          <div className="text-xs text-gray-500">Ingelogd als</div>
          <div className="text-white font-medium truncate">{session?.user?.email || "—"}</div>
        </div>
        <button onClick={signOut} className="px-5 py-2.5 rounded-xl bg-white/10 hover:bg-white/15 text-sm font-semibold text-white">
          Uitloggen
        </button>
      </div>
    </Section>
  );
}

// ---------- Systeemstatus (compact; handig als er iets niet afspeelt) ----------

const STATUS_ROWS = [
  { key: "rd", label: "Real-Debrid" },
  { key: "aiostreams", label: "AIOStreams" },
  { key: "tmdb", label: "TMDB (posters & info)" },
  { key: "jackett", label: "Prowlarr / Jackett" },
  { key: "media", label: "Lokale media" },
  { key: "seerr", label: "Overseerr / Jellyseerr" },
];

function SystemStatus() {
  const [status, setStatus] = useState(null);
  const [loading, setLoading] = useState(true);

  const load = async () => {
    setLoading(true);
    try {
      const r = await fetch("/api/settings/status");
      setStatus(await r.json());
    } catch {
      setStatus(null);
    }
    setLoading(false);
  };
  useEffect(() => { load(); }, []);

  return (
    <Section title="Systeemstatus" subtitle="Alleen nodig als er iets niet werkt, bv. als niets meer wil afspelen.">
      <div className="divide-y divide-white/5">
        {STATUS_ROWS.map(row => {
          const s = status?.[row.key];
          const ok = s?.ok;
          return (
            <div key={row.key} className="flex items-start gap-3 py-3">
              <span className={`mt-1.5 w-2.5 h-2.5 rounded-full flex-shrink-0 ${loading ? "bg-gray-600 animate-pulse" : ok ? "bg-green-500" : "bg-red-500"}`} />
              <div className="flex-1 min-w-0">
                <div className="text-sm font-semibold text-white">{row.label}</div>
                {!loading && s?.message && <div className={`text-xs mt-0.5 ${ok ? "text-gray-400" : "text-red-300"}`}>{s.message}</div>}
              </div>
            </div>
          );
        })}
      </div>
      <button onClick={load} disabled={loading} className="mt-4 px-4 py-2 rounded-lg bg-white/10 hover:bg-white/15 text-sm text-white disabled:opacity-50">
        {loading ? "Controleren…" : "Opnieuw controleren"}
      </button>
    </Section>
  );
}

// ---------- Pagina ----------

export default function Settings() {
  const navigate = useNavigate();
  const { selectedProfile } = useProfile();
  const [section, setSection] = useState(() => {
    try { return sessionStorage.getItem("nova.settingsSection") || "taal"; } catch { return "taal"; }
  });
  useEffect(() => {
    try { sessionStorage.setItem("nova.settingsSection", section); } catch {}
  }, [section]);

  return (
    <div className="min-h-screen bg-nova-bg pl-[var(--sbw)] transition-[padding-left] duration-200">
      <Sidebar
        onSearch={(q) => navigate(`/search?q=${encodeURIComponent(q)}`)}
        onClear={() => navigate("/")}
        onGenre={() => navigate("/")}
        mode=""
        onMode={(m) => navigate(`/?mode=${encodeURIComponent(m)}`)}
      />

      <div className="px-4 md:px-10 py-10 max-w-5xl mx-auto">
        <h1 className="text-3xl font-black text-white tracking-tight mb-8">Instellingen</h1>

        <div className="flex flex-col md:flex-row gap-6 md:gap-10">
          <nav className="flex md:flex-col gap-1 md:w-56 flex-shrink-0 overflow-x-auto pb-1 md:pb-0" style={{ scrollbarWidth: "none" }}>
            {SECTIONS.map(s => (
              <button
                key={s.key}
                onClick={() => setSection(s.key)}
                className={`flex items-center gap-3 px-4 py-3 rounded-xl text-sm font-medium whitespace-nowrap transition-colors ${
                  section === s.key ? "bg-nova-accent/15 text-nova-accent" : "text-gray-400 hover:text-white hover:bg-white/5"
                }`}
              >
                <span className="text-base">{s.icon}</span>
                {s.label}
              </button>
            ))}
          </nav>

          <main className="flex-1 min-w-0">
            {section === "taal" && <LanguageSettings profile={selectedProfile} />}
            {section === "profielen" && <ProfileSettings />}
            {section === "account" && <AccountSettings />}
            {section === "systeem" && <SystemStatus />}
          </main>
        </div>
      </div>
    </div>
  );
}
