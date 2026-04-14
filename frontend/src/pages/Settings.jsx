import { useState, useEffect } from "react";
import { useNavigate } from "react-router-dom";

function StatusCard({ title, description, status, loading }) {
  const ok = status?.ok;
  const message = status?.message;

  return (
    <div className={`bg-nova-card rounded-xl p-6 border transition-all ${
      loading ? "border-gray-800 opacity-50" :
      ok ? "border-green-900/50 shadow-[0_0_15px_rgba(22,101,52,0.1)]" : "border-red-900/50 shadow-[0_0_15px_rgba(153,27,27,0.1)]"
    }`}>
      <div className="flex items-center justify-between mb-2">
        <h2 className="font-bold text-lg text-white">{title}</h2>
        {loading ? (
          <div className="w-4 h-4 border-2 border-nova-accent border-t-transparent rounded-full animate-spin" />
        ) : (
          <span className={`text-xs font-bold px-3 py-1 rounded-full uppercase tracking-wider ${
            ok ? "bg-green-900/50 text-green-400" : "bg-red-900/50 text-red-400"
          }`}>
            {ok ? "✓ Actief" : "✗ Fout"}
          </span>
        )}
      </div>
      <p className="text-gray-400 text-sm mb-4 leading-relaxed">{description}</p>
      
      {!loading && message && (
        <div className={`text-sm p-3 rounded-lg font-medium ${
          ok ? "bg-green-950/30 text-green-300" : "bg-red-950/30 text-red-300"
        }`}>
          {message}
        </div>
      )}
    </div>
  );
}

export default function Settings() {
  const navigate = useNavigate();
  const [status, setStatus] = useState(null);
  const [loading, setLoading] = useState(true);
  const [copied, setCopied] = useState(false);

  const fetchStatus = async () => {
    setLoading(true);
    try {
      const r = await fetch("/api/settings/status");
      const data = await r.json();
      setStatus(data);
    } catch (e) {
      console.error("Status check mislukt", e);
    }
    setLoading(false);
  };

  useEffect(() => {
    fetchStatus();
  }, []);

  const serverUrl = typeof window !== "undefined" ? window.location.origin : "";

  const copyServerUrl = async () => {
    if (!serverUrl) return;
    try {
      if (navigator?.clipboard?.writeText) {
        await navigator.clipboard.writeText(serverUrl);
      } else {
        const el = document.createElement("textarea");
        el.value = serverUrl;
        el.setAttribute("readonly", "");
        el.style.position = "absolute";
        el.style.left = "-9999px";
        document.body.appendChild(el);
        el.select();
        document.execCommand("copy");
        document.body.removeChild(el);
      }
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {}
  };

  return (
    <div className="min-h-screen bg-nova-bg px-6 py-10 max-w-3xl mx-auto">
      <div className="flex items-center justify-between mb-10">
        <div className="flex items-center gap-4">
          <button 
            onClick={() => navigate("/")} 
            className="w-10 h-10 flex items-center justify-center rounded-full bg-nova-card hover:bg-gray-800 transition-colors text-gray-400 hover:text-white shadow-lg"
          >
            ←
          </button>
          <div>
            <h1 className="text-3xl font-black text-white tracking-tight">Status & Instellingen</h1>
            <p className="text-gray-500 text-sm">Configuratie via Docker Environment (.env)</p>
          </div>
        </div>
        <button 
          onClick={fetchStatus}
          disabled={loading}
          className="bg-nova-accent hover:bg-nova-hover disabled:opacity-50 px-5 py-2.5 rounded-xl text-sm font-bold text-white transition-all shadow-lg active:scale-95"
        >
          {loading ? "Verversen..." : "Nu verversen"}
        </button>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        <StatusCard
          title="TMDB Metadata"
          description="Gebruikt voor posters, trailers, beschrijvingen en zoekresultaten van films en series."
          status={status?.tmdb}
          loading={loading}
        />

        <StatusCard
          title="Real-Debrid"
          description="De stream provider die magnet links omzet naar snelle directe downloads."
          status={status?.rd}
          loading={loading}
        />

        <StatusCard
          title="Prowlarr / Jackett"
          description="De zoekmachine die torrents vindt op verschillende trackers als ze niet in je bibliotheek staan."
          status={status?.jackett}
          loading={loading}
        />

        <StatusCard
          title="Dumbarr Mount"
          description="De lokale verbinding met je Real-Debrid bestanden via /media in de container."
          status={status?.media}
          loading={loading}
        />

        <StatusCard
          title="Overseerr / Jellyseerr"
          description="Hiermee kun je verzoeken indienen voor nieuwe films en series via sonarr/radarr."
          status={status?.seerr}
          loading={loading}
        />
      </div>

      <div className="mt-10 p-6 bg-nova-card/50 rounded-2xl border border-gray-800/50">
        <h3 className="text-lg font-bold text-white mb-2">Nova App</h3>
        <p className="text-gray-400 text-sm leading-relaxed">
          Download de Android app en verbind met dezelfde Nova server als deze web UI.
        </p>

        <div className="mt-4 flex flex-col sm:flex-row gap-3">
          <a
            href="/nova.apk"
            download="nova.apk"
            className="bg-nova-accent hover:bg-nova-hover px-5 py-2.5 rounded-xl text-sm font-bold text-white transition-all shadow-lg active:scale-95 text-center"
          >
            Download Android app (APK)
          </a>
          <a
            href={serverUrl ? `nova://connect?url=${encodeURIComponent(serverUrl)}` : "#"}
            onClick={(e) => { if (!serverUrl) e.preventDefault(); }}
            className="bg-white/10 hover:bg-white/15 border border-white/10 px-5 py-2.5 rounded-xl text-sm font-bold text-white transition-all shadow-lg active:scale-95 text-center"
          >
            Open Nova app
          </a>
          <button
            onClick={copyServerUrl}
            className="bg-white/10 hover:bg-white/15 border border-white/10 px-5 py-2.5 rounded-xl text-sm font-bold text-white transition-all shadow-lg active:scale-95"
          >
            {copied ? "Gekopieerd" : "Kopieer server adres"}
          </button>
        </div>

        <div className="mt-4 bg-black/50 p-4 rounded-xl font-mono text-xs text-gray-300 border border-white/5 break-all">
          {serverUrl || "-"}
        </div>
      </div>

      <div className="mt-12 p-6 bg-nova-card/50 rounded-2xl border border-gray-800/50">
        <h3 className="text-lg font-bold text-white mb-2">Hoe pas ik instellingen aan?</h3>
        <p className="text-gray-400 text-sm leading-relaxed">
          Omdat Nova in Docker draait, worden alle API keys en paden beheerd in je <code className="bg-black/50 px-1.5 py-0.5 rounded text-nova-accent font-mono text-xs">.env</code> bestand op de server. 
          Na een wijziging in de <code className="bg-black/50 px-1.5 py-0.5 rounded text-nova-accent font-mono text-xs">.env</code> moet je de containers herstarten met:
        </p>
        <div className="mt-4 bg-black/50 p-4 rounded-xl font-mono text-xs text-gray-300 border border-white/5">
          docker compose up -d
        </div>
      </div>
    </div>
  );
}
