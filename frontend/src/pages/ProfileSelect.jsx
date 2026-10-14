import { useState } from "react";
import { useProfile } from "../context/ProfileContext";
import { useAuth } from "../context/AuthContext";

const COLORS = ["#1E88E5", "#E53935", "#43A047", "#FB8C00", "#8E24AA", "#00897B"];

export default function ProfileSelect() {
  const { profiles, loading, selectProfile, createProfile } = useProfile();
  const { signOut } = useAuth();
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [color, setColor] = useState(COLORS[0]);
  const [saving, setSaving] = useState(false);

  async function handleCreate(e) {
    e.preventDefault();
    if (!name.trim() || saving) return;
    setSaving(true);
    try {
      await createProfile(name.trim(), color);
      setCreating(false);
      setName("");
    } finally {
      setSaving(false);
    }
  }

  if (loading) {
    return (
      <div className="min-h-screen bg-nova-bg flex items-center justify-center">
        <div className="w-8 h-8 border-2 border-nova-accent border-t-transparent rounded-full animate-spin" />
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-nova-bg flex flex-col items-center justify-center p-4">
      <h1 className="text-2xl font-bold text-white mb-8">Wie kijkt er?</h1>

      <div className="flex flex-wrap justify-center gap-6 max-w-3xl">
        {profiles.map((p) => (
          <button
            key={p.id}
            onClick={() => selectProfile(p.id)}
            className="flex flex-col items-center gap-2 group"
          >
            <div
              className="w-24 h-24 rounded-xl flex items-center justify-center text-3xl font-bold text-white group-hover:ring-4 ring-nova-accent transition-all"
              style={{ backgroundColor: p.avatar_color_hex || "#1E88E5" }}
            >
              {(p.name || "?").charAt(0).toUpperCase()}
            </div>
            <span className="text-gray-300 text-sm">{p.name}</span>
          </button>
        ))}

        {!creating && profiles.length < 10 && (
          <button onClick={() => setCreating(true)} className="flex flex-col items-center gap-2 group">
            <div className="w-24 h-24 rounded-xl border-2 border-dashed border-gray-700 flex items-center justify-center text-3xl text-gray-500 group-hover:border-nova-accent group-hover:text-nova-accent transition-all">
              +
            </div>
            <span className="text-gray-500 text-sm">Nieuw profiel</span>
          </button>
        )}
      </div>

      {creating && (
        <form onSubmit={handleCreate} className="mt-8 bg-nova-card rounded-xl p-6 border border-gray-800 w-full max-w-sm">
          <label className="block text-sm text-gray-400 mb-1">Naam</label>
          <input
            autoFocus
            value={name}
            onChange={(e) => setName(e.target.value)}
            className="w-full bg-black/30 border border-gray-700 rounded-lg px-3 py-2 text-white mb-4 outline-none focus:border-nova-accent"
          />
          <div className="flex gap-2 mb-4">
            {COLORS.map((c) => (
              <button
                type="button"
                key={c}
                onClick={() => setColor(c)}
                className={`w-8 h-8 rounded-full ${color === c ? "ring-2 ring-white" : ""}`}
                style={{ backgroundColor: c }}
              />
            ))}
          </div>
          <div className="flex gap-2">
            <button
              type="submit"
              disabled={saving}
              className="flex-1 bg-nova-accent hover:bg-nova-hover disabled:opacity-60 text-white font-semibold rounded-lg py-2"
            >
              {saving ? "Bezig..." : "Aanmaken"}
            </button>
            <button
              type="button"
              onClick={() => setCreating(false)}
              className="px-4 text-gray-400 hover:text-white"
            >
              Annuleren
            </button>
          </div>
        </form>
      )}

      <button onClick={signOut} className="mt-10 text-gray-500 hover:text-gray-300 text-sm">
        Uitloggen
      </button>
    </div>
  );
}
