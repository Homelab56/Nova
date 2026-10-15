import { useState, useEffect, useRef } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import Sidebar from "../components/Sidebar";
import MediaCard from "../components/MediaCard";

const FILTERS = [
  { key: "all", label: "Alles" },
  { key: "movie", label: "Films" },
  { key: "tv", label: "Series" },
];

// Zoekpagina: begint leeg; zodra je typt verschijnen live alle films en series met die
// woorden/namen (titels die ermee beginnen eerst, daarna op populariteit).
export default function Search() {
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const [query, setQuery] = useState(params.get("q") || "");
  const [data, setData] = useState({ items: [], people: [] });
  const [loading, setLoading] = useState(false);
  const [searched, setSearched] = useState("");
  const [filter, setFilter] = useState("all");
  const inputRef = useRef(null);

  useEffect(() => { inputRef.current?.focus(); }, []);

  useEffect(() => {
    const q = query.trim();
    setParams(q ? { q } : {}, { replace: true });
    if (q.length < 2) {
      setData({ items: [], people: [] });
      setSearched("");
      setLoading(false);
      return;
    }
    setLoading(true);
    const ac = new AbortController();
    const t = setTimeout(() => {
      fetch(`/api/search/find?q=${encodeURIComponent(q)}`, { signal: ac.signal })
        .then(r => (r.ok ? r.json() : null))
        .then(d => {
          if (!d) return;
          setData({ items: d.items || [], people: d.people || [] });
          setSearched(q);
          setLoading(false);
        })
        .catch(e => { if (e.name !== "AbortError") setLoading(false); });
    }, 300);
    return () => { clearTimeout(t); ac.abort(); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [query]);

  const movies = data.items.filter(i => i.media_type === "movie");
  const series = data.items.filter(i => i.media_type === "tv");
  const shown = filter === "movie" ? movies : filter === "tv" ? series : data.items;
  const counts = { all: data.items.length, movie: movies.length, tv: series.length };
  const hasQuery = query.trim().length >= 2;

  return (
    <div className="min-h-screen bg-nova-bg pl-[var(--sbw)] transition-[padding-left] duration-200">
      <Sidebar
        onSearch={() => {}}
        onClear={() => navigate("/")}
        onGenre={() => navigate("/")}
        mode=""
        onMode={(m) => navigate(`/?mode=${encodeURIComponent(m)}`)}
      />

      <div className="px-4 md:px-10 pt-8 pb-16">
        {/* Zoekveld */}
        <div className="max-w-3xl mx-auto relative">
          <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5 absolute left-4 top-1/2 -translate-y-1/2 text-gray-500 pointer-events-none" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <circle cx="11" cy="11" r="7" /><line x1="16.5" y1="16.5" x2="22" y2="22" />
          </svg>
          <input
            ref={inputRef}
            value={query}
            onChange={(e) => { setQuery(e.target.value); setFilter("all"); }}
            placeholder="Zoek een film, serie of acteur..."
            autoComplete="off"
            className="w-full bg-nova-card border border-gray-700 focus:border-nova-accent rounded-2xl pl-12 pr-12 py-4 text-lg text-white outline-none transition-colors"
          />
          {query && (
            <button
              onClick={() => { setQuery(""); inputRef.current?.focus(); }}
              className="absolute right-4 top-1/2 -translate-y-1/2 text-gray-500 hover:text-white text-xl leading-none"
              title="Wissen"
            >
              ✕
            </button>
          )}
        </div>

        {/* Leeg: nog niets getypt */}
        {!hasQuery && (
          <div className="flex flex-col items-center justify-center text-center py-32 text-gray-600">
            <svg xmlns="http://www.w3.org/2000/svg" className="w-16 h-16 mb-5 opacity-40" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
              <circle cx="11" cy="11" r="7" /><line x1="16.5" y1="16.5" x2="22" y2="22" />
            </svg>
            <p className="text-lg">Begin met typen om te zoeken</p>
            <p className="text-sm mt-1">Alle films en series met die woorden of namen verschijnen meteen.</p>
          </div>
        )}

        {hasQuery && (
          <div className="mt-8">
            {/* Filters + teller */}
            <div className="flex flex-wrap items-center gap-2 mb-6">
              {FILTERS.map(f => (
                <button
                  key={f.key}
                  onClick={() => setFilter(f.key)}
                  className={`px-4 py-1.5 rounded-full text-sm font-medium border transition-colors ${
                    filter === f.key
                      ? "border-nova-accent text-nova-accent bg-nova-accent/10"
                      : "border-gray-700 text-gray-400 hover:text-white hover:border-gray-500"
                  }`}
                >
                  {f.label} <span className="opacity-60">{counts[f.key]}</span>
                </button>
              ))}
              {loading && <span className="ml-2 text-sm text-gray-500 animate-pulse">Zoeken…</span>}
            </div>

            {/* Personen */}
            {data.people.length > 0 && filter === "all" && (
              <div className="mb-8">
                <h3 className="text-sm font-bold text-gray-400 mb-3">Personen</h3>
                <div className="flex gap-4 overflow-x-auto pb-3" style={{ scrollbarWidth: "none" }}>
                  {data.people.map(person => (
                    <div
                      key={person.id}
                      onClick={() => navigate("/person", { state: { person } })}
                      className="flex-shrink-0 w-20 md:w-24 text-center cursor-pointer group"
                    >
                      <div className="w-20 h-20 md:w-24 md:h-24 rounded-full overflow-hidden bg-nova-card mx-auto mb-2 border-2 border-gray-700 group-hover:border-nova-accent transition-colors">
                        <img src={`https://image.tmdb.org/t/p/w185${person.profile_path}`} alt={person.name} className="w-full h-full object-cover" />
                      </div>
                      <p className="text-xs font-semibold leading-tight truncate">{person.name}</p>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {/* Resultaten */}
            {shown.length > 0 ? (
              <div className="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-5 lg:grid-cols-7 xl:grid-cols-9 gap-3">
                {shown.map(item => <MediaCard key={`${item.media_type}${item.id}`} item={item} />)}
              </div>
            ) : (
              !loading && searched === query.trim() && (
                <p className="text-gray-500 text-center py-16">Niets gevonden voor “{searched}”.</p>
              )
            )}
          </div>
        )}
      </div>
    </div>
  );
}
