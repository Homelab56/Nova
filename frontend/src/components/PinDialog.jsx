import { useEffect, useRef, useState } from "react";

// Pincode-venster met 4 vakjes. `onSubmit(pin)` mag een fout gooien (bv. "Verkeerde pincode");
// die verschijnt dan in het venster en de vakjes worden leeggemaakt. Lukt het, dan sluit het.
export default function PinDialog({ title, subtitle, profile, onSubmit, onCancel }) {
  const [pin, setPin] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [shake, setShake] = useState(false);
  const inputRef = useRef(null);

  useEffect(() => { inputRef.current?.focus(); }, []);

  useEffect(() => {
    const onKey = (e) => { if (e.key === "Escape") onCancel?.(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onCancel]);

  async function submit(value) {
    if (busy) return;
    setBusy(true);
    setError("");
    try {
      await onSubmit(value);
    } catch (e) {
      setError(e?.message || "Verkeerde pincode");
      setPin("");
      setShake(true);
      setTimeout(() => setShake(false), 400);
      setBusy(false);
      setTimeout(() => inputRef.current?.focus(), 0);
    }
  }

  function onChange(e) {
    const v = e.target.value.replace(/\D/g, "").slice(0, 4);
    setPin(v);
    if (error) setError("");
    if (v.length === 4) submit(v);
  }

  return (
    <div className="fixed inset-0 z-[95] flex items-center justify-center bg-black/80 backdrop-blur-sm p-4 animate-[nova-fade-in_200ms_ease-out]" onMouseDown={onCancel}>
      <div
        className="w-full max-w-sm bg-nova-card border border-white/10 rounded-2xl p-8 text-center shadow-2xl"
        onMouseDown={(e) => { e.stopPropagation(); inputRef.current?.focus(); }}
      >
        {profile && (
          <div
            className="w-16 h-16 mx-auto mb-4 rounded-xl flex items-center justify-center text-2xl font-bold text-white"
            style={{ backgroundColor: profile.avatar_color_hex || "#1E88E5" }}
          >
            {(profile.name || "?").charAt(0).toUpperCase()}
          </div>
        )}
        <h2 className="text-xl font-bold text-white">{title}</h2>
        {subtitle && <p className="text-sm text-gray-400 mt-1">{subtitle}</p>}

        <div className={`relative flex justify-center gap-3 mt-6 ${shake ? "animate-[nova-shake_400ms_ease-in-out]" : ""}`}>
          {[0, 1, 2, 3].map(i => (
            <div
              key={i}
              className={`w-12 h-14 rounded-xl border-2 flex items-center justify-center transition-colors ${
                error ? "border-red-500/70" : i === pin.length ? "border-nova-accent" : pin.length > i ? "border-white/40" : "border-gray-700"
              }`}
            >
              {pin.length > i && <span className="w-3 h-3 rounded-full bg-white" />}
            </div>
          ))}
          <input
            ref={inputRef}
            value={pin}
            onChange={onChange}
            inputMode="numeric"
            autoComplete="off"
            maxLength={4}
            aria-label="Pincode"
            className="absolute inset-0 opacity-0 cursor-default"
          />
        </div>

        <p className="h-5 mt-4 text-sm text-red-400">{error}</p>

        <button onClick={onCancel} className="mt-2 text-sm text-gray-400 hover:text-white">
          Annuleren
        </button>
      </div>
    </div>
  );
}
