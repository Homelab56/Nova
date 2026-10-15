import { useState, useRef, useEffect } from "react";
import { useNavigate } from "react-router-dom";
import { useProfile } from "../context/ProfileContext";
import { useAuth } from "../context/AuthContext";

const GENRES = [
  { id: 28, name: "Actie" }, { id: 12, name: "Avontuur" }, { id: 16, name: "Animatie" },
  { id: 35, name: "Komedie" }, { id: 80, name: "Misdaad" }, { id: 99, name: "Documentaire" },
  { id: 18, name: "Drama" }, { id: 10751, name: "Familie" }, { id: 14, name: "Fantasy" },
  { id: 27, name: "Horror" }, { id: 9648, name: "Mystery" }, { id: 10749, name: "Romantiek" },
  { id: 878, name: "Sci-Fi" }, { id: 53, name: "Thriller" }, { id: 10752, name: "Oorlog" },
  { id: 36, name: "Historisch" }, { id: 10402, name: "Muziek" }, { id: 37, name: "Western" },
  // Thema's (TMDB-keywords i.p.v. genres) - zoals "Kerstfilms"/"Halloween" op de tv
  { id: "kw-christmas", name: "Kerstfilms", keyword: "christmas" },
  { id: "kw-halloween", name: "Halloween", keyword: "halloween" },
];

const NAV_ITEMS = [
  { key: "all", label: "Home", icon: (
    <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6" />
    </svg>
  )},
  { key: "movie", label: "Films", icon: (
    <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M7 4v16M17 4v16M3 8h4m10 0h4M3 16h4m10 0h4M3 4h18v16H3V4z" />
    </svg>
  )},
  { key: "tv", label: "Series", icon: (
    <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M4 6h16v10H4V6zm4 14h8" />
    </svg>
  )},
  { key: "kids", label: "Kids", icon: (
    <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M12 14a3 3 0 100-6 3 3 0 000 6zM5.5 20a6.5 6.5 0 0113 0" />
    </svg>
  )},
  { key: "watchlist", label: "Watchlist", icon: (
    <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M5 5a2 2 0 012-2h10a2 2 0 012 2v16l-7-3.5L5 21V5z" />
    </svg>
  )},
];

export default function Sidebar({ onSearch, onClear, onGenre, mode, onMode }) {
  const navigate = useNavigate();
  const { selectedProfile, clearSelectedProfile } = useProfile();
  const { signOut } = useAuth();
  const [searchOpen, setSearchOpen] = useState(false);
  const [genreOpen, setGenreOpen] = useState(false);
  const [profileOpen, setProfileOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [activeGenre, setActiveGenre] = useState(null);
  const searchInputRef = useRef(null);
  const [suggest, setSuggest] = useState({ items: [], people: [] });
  const [activeIdx, setActiveIdx] = useState(-1);
  const [collapsed, setCollapsed] = useState(() => {
    try { return localStorage.getItem("nova.sidebarCollapsed") === "1"; } catch { return false; }
  });

  useEffect(() => {
    document.documentElement.classList.toggle("sb-collapsed", collapsed);
    try { localStorage.setItem("nova.sidebarCollapsed", collapsed ? "1" : "0"); } catch {}
  }, [collapsed]);

  // Klassen die afhangen van in-/uitgeklapt: labels weg en icoon gecentreerd als ingeklapt.
  const lbl = collapsed ? "hidden" : "hidden md:inline";
  const just = collapsed ? "justify-center" : "${just}";

  useEffect(() => {
    if (searchOpen) searchInputRef.current?.focus();
  }, [searchOpen]);

  // Live suggesties tijdens het typen (debounced, vorige aanvraag wordt afgebroken).
  useEffect(() => {
    const q = query.trim();
    setActiveIdx(-1);
    if (!searchOpen || q.length < 2) { setSuggest({ items: [], people: [] }); return; }
    const ac = new AbortController();
    const t = setTimeout(() => {
      fetch(`/api/search/suggest?q=${encodeURIComponent(q)}`, { signal: ac.signal })
        .then(r => (r.ok ? r.json() : null))
        .then(d => { if (d) setSuggest({ items: d.items || [], people: d.people || [] }); })
        .catch(() => {});
    }, 220);
    return () => { clearTimeout(t); ac.abort(); };
  }, [query, searchOpen]);

  const flat = [
    ...suggest.items.map(item => ({ kind: "title", item })),
    ...suggest.people.map(item => ({ kind: "person", item })),
  ];

  function openSuggestion(entry) {
    setSearchOpen(false);
    setQuery("");
    if (entry.kind === "person") navigate("/person", { state: { person: entry.item } });
    else navigate("/watch", { state: { media: entry.item } });
  }

  function handleSearchKey(e) {
    if (e.key === "ArrowDown" && flat.length) {
      e.preventDefault();
      setActiveIdx(i => (i + 1) % flat.length);
    } else if (e.key === "ArrowUp" && flat.length) {
      e.preventDefault();
      setActiveIdx(i => (i <= 0 ? flat.length - 1 : i - 1));
    } else if (e.key === "Enter" && activeIdx >= 0 && flat[activeIdx]) {
      e.preventDefault();
      openSuggestion(flat[activeIdx]);
    } else if (e.key === "Escape") {
      setSearchOpen(false);
    }
  }

  function handleSubmit(e) {
    e.preventDefault();
    if (query.trim()) { onSearch(query); setSearchOpen(false); }
  }

  function handleMode(key) {
    setActiveGenre(null);
    onClear();
    if (key === "kids") navigate("/kids");
    else { navigate("/"); onMode(key); }
  }

  function handleGenre(genre) {
    setActiveGenre(genre); setGenreOpen(false);
    navigate("/");
    onGenre(genre);
  }

  return (
    <>
    <nav className="fixed left-0 top-0 bottom-0 z-50 w-[var(--sbw)] transition-[width] duration-200 bg-nova-card/95 backdrop-blur border-r border-gray-800 flex flex-col">
      {/* Logo (gepind, scrollt niet mee) */}
      <div
        onClick={() => { onClear(); setActiveGenre(null); onMode("all"); navigate("/"); }}
        className={`cursor-pointer select-none flex items-center ${just} px-2 ${collapsed ? "" : "md:px-5"} py-7 shrink-0`}
      >
        {collapsed ? (
          <img src="/favicon.png" alt="Streamify" className="h-11 w-11 rounded-xl drop-shadow-[0_0_14px_rgba(0,180,216,0.5)]" />
        ) : (
          <>
            <img src="/favicon.png" alt="Streamify" className="md:hidden h-11 w-11 rounded-xl" />
            <img src="/logo.png" alt="Streamify" className="hidden md:block h-16 w-auto drop-shadow-[0_0_14px_rgba(0,180,216,0.5)]" />
          </>
        )}
      </div>

      {/* Navigatie (scrollt indien nodig in de resterende ruimte) */}
      <div className="flex-1 overflow-y-auto px-2 md:px-3 space-y-1">
        {NAV_ITEMS.map((item) => (
          <button
            key={item.key}
            onClick={() => handleMode(item.key)}
            className={`w-full flex items-center ${just} gap-3 px-2 md:px-3 py-2.5 rounded-xl text-sm font-medium transition-all ${
              mode === item.key ? "bg-nova-accent text-white" : "text-gray-400 hover:text-white hover:bg-white/5"
            }`}
          >
            {item.icon}
            <span className={`${lbl}`}>{item.label}</span>
          </button>
        ))}

        <div className="relative pt-2">
          <button
            onClick={() => setGenreOpen((v) => !v)}
            className={`w-full flex items-center ${just} gap-3 px-2 md:px-3 py-2.5 rounded-xl text-sm font-medium transition-all border ${
              genreOpen || activeGenre ? "border-nova-accent text-nova-accent bg-nova-accent/10" : "border-transparent text-gray-400 hover:text-white hover:bg-white/5"
            }`}
          >
            <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M4 6h16M4 12h16M4 18h7" />
            </svg>
            <span className={`${lbl} truncate`}>{activeGenre ? activeGenre.name : "Genres"}</span>
          </button>
        </div>

        <div>
          <button
            onClick={() => setSearchOpen(true)}
            className={`w-full flex items-center ${just} gap-3 px-2 md:px-3 py-2.5 rounded-xl text-sm font-medium transition-all ${searchOpen ? "text-nova-accent" : "text-gray-400 hover:text-white hover:bg-white/5"}`}
          >
            <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <circle cx="11" cy="11" r="7" /><line x1="16.5" y1="16.5" x2="22" y2="22" />
            </svg>
            <span className={`${lbl}`}>Zoeken</span>
          </button>
        </div>
      </div>

      {/* Profiel + instellingen (gepind onderaan) */}
      <div className="shrink-0 border-t border-gray-800 px-2 md:px-3 py-3 space-y-1">
        <button
          onClick={() => setCollapsed((v) => !v)}
          title={collapsed ? "Menu uitklappen" : "Menu inklappen"}
          className={`hidden md:flex w-full items-center ${collapsed ? "justify-center" : "justify-start"} gap-3 px-2 md:px-3 py-2.5 rounded-xl text-sm font-medium text-gray-400 hover:text-white hover:bg-white/5 transition-all`}
        >
          <svg xmlns="http://www.w3.org/2000/svg" className={`w-5 h-5 shrink-0 transition-transform duration-200 ${collapsed ? "rotate-180" : ""}`} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M11 19l-7-7 7-7m8 14l-7-7 7-7" />
          </svg>
        </button>
        <button onClick={() => navigate("/settings")}
          className={`w-full flex items-center ${just} gap-3 px-2 md:px-3 py-2.5 rounded-xl text-sm font-medium text-gray-400 hover:text-white hover:bg-white/5 transition-all`}>
          <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
            <path strokeLinecap="round" strokeLinejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
          </svg>
          <span className={`${lbl}`}>Instellingen</span>
        </button>

        {selectedProfile && (
          <div>
            <button
              onClick={() => setProfileOpen((v) => !v)}
              className={`w-full flex items-center ${just} gap-2 px-1 md:px-2 py-2 rounded-xl hover:bg-white/5 transition-colors`}
            >
              <div className="w-8 h-8 shrink-0 rounded-md flex items-center justify-center text-sm font-bold text-white"
                style={{ backgroundColor: selectedProfile.avatar_color_hex || "#1E88E5" }}>
                {(selectedProfile.name || "?").charAt(0).toUpperCase()}
              </div>
              <span className={`${lbl} text-sm text-gray-300 truncate`}>{selectedProfile.name}</span>
            </button>
          </div>
        )}
      </div>
    </nav>

    {/* Popouts worden buiten <nav> gerenderd: backdrop-blur op <nav> maakt er anders zelf een
        "containing block" van, waardoor fixed-positioned kinderen beperkt blijven tot de smalle
        zijbalk-breedte i.p.v. het volledige scherm - dat veroorzaakte eerder horizontaal scrollen. */}
    {genreOpen && (
      <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/60 backdrop-blur-sm p-4" onClick={() => setGenreOpen(false)}>
        <div className="bg-nova-card border border-gray-700 rounded-2xl shadow-2xl p-5 w-full max-w-md max-h-[80vh] overflow-y-auto" onClick={(e) => e.stopPropagation()}>
          <div className="flex items-center justify-between mb-4">
            <h3 className="text-lg font-bold text-white">Genres</h3>
            <button onClick={() => setGenreOpen(false)} className="text-gray-400 hover:text-white text-xl leading-none">✕</button>
          </div>
          <div className="grid grid-cols-2 gap-2">
            {GENRES.map((g) => (
              <button key={g.id} onClick={() => handleGenre(g)}
                className={`text-left px-3 py-2 rounded-lg text-sm transition-colors ${activeGenre?.id === g.id ? "bg-nova-accent text-white" : "hover:bg-white/10 text-gray-300 hover:text-white"}`}>
                {g.name}
              </button>
            ))}
          </div>
          {activeGenre && (
            <button onClick={() => { setActiveGenre(null); onClear(); setGenreOpen(false); }}
              className="mt-4 w-full text-xs text-gray-500 hover:text-white text-center py-1">
              ✕ Filter wissen
            </button>
          )}
        </div>
      </div>
    )}

    {searchOpen && (
      <div className="fixed inset-0 z-[60] flex items-start justify-center pt-28 bg-black/60 backdrop-blur-sm p-4" onClick={() => setSearchOpen(false)}>
        <div className="w-full max-w-md" onClick={(e) => e.stopPropagation()}>
          <form onSubmit={handleSubmit} className="bg-nova-card border border-gray-700 rounded-2xl shadow-2xl p-3 flex gap-2">
            <input
              ref={searchInputRef}
              className="flex-1 bg-black/30 border border-gray-700 rounded-lg px-4 py-3 text-base text-white outline-none focus:border-nova-accent"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={handleSearchKey}
              placeholder="Zoeken..."
              autoComplete="off"
            />
            <button type="submit" className="px-5 rounded-lg bg-nova-accent text-white text-sm font-semibold">Ga</button>
          </form>

          {flat.length > 0 && (
            <div className="mt-2 bg-nova-card border border-gray-700 rounded-2xl shadow-2xl overflow-hidden py-1 max-h-[60vh] overflow-y-auto">
              {flat.map((entry, i) => {
                const it = entry.item;
                const active = i === activeIdx;
                if (entry.kind === "person") {
                  return (
                    <button
                      key={`p${it.id}`}
                      onClick={() => openSuggestion(entry)}
                      onMouseEnter={() => setActiveIdx(i)}
                      className={`w-full flex items-center gap-3 px-3 py-2 text-left transition-colors ${active ? "bg-white/10" : "hover:bg-white/5"}`}
                    >
                      <img src={`https://image.tmdb.org/t/p/w92${it.profile_path}`} alt="" className="w-10 h-10 rounded-full object-cover flex-shrink-0" />
                      <div className="min-w-0">
                        <p className="text-sm font-semibold truncate">{it.name}</p>
                        <p className="text-xs text-gray-500">{it.known_for_department === "Acting" ? "Acteur" : "Persoon"}</p>
                      </div>
                    </button>
                  );
                }
                const name = it.title || it.name;
                const year = (it.release_date || it.first_air_date || "").slice(0, 4);
                return (
                  <button
                    key={`${it.media_type}${it.id}`}
                    onClick={() => openSuggestion(entry)}
                    onMouseEnter={() => setActiveIdx(i)}
                    className={`w-full flex items-center gap-3 px-3 py-2 text-left transition-colors ${active ? "bg-white/10" : "hover:bg-white/5"}`}
                  >
                    {it.poster_path ? (
                      <img src={`https://image.tmdb.org/t/p/w92${it.poster_path}`} alt="" className="w-10 h-14 rounded-md object-cover flex-shrink-0" />
                    ) : (
                      <div className="w-10 h-14 rounded-md bg-black/30 flex-shrink-0" />
                    )}
                    <div className="min-w-0 flex-1">
                      <p className="text-sm font-semibold truncate">{name}</p>
                      <p className="text-xs text-gray-500">
                        {[year, it.media_type === "tv" ? "Serie" : "Film"].filter(Boolean).join(" · ")}
                      </p>
                    </div>
                    {it.vote_average > 0 && <span className="text-xs text-yellow-400 flex-shrink-0">★ {it.vote_average.toFixed(1)}</span>}
                  </button>
                );
              })}
            </div>
          )}
        </div>
      </div>
    )}

    {profileOpen && selectedProfile && (
      <div className="fixed inset-0 z-[60] bg-transparent" onClick={() => setProfileOpen(false)}>
        <div
          className="absolute bottom-20 left-[calc(var(--sbw)+0.5rem)] bg-nova-card border border-gray-700 rounded-xl shadow-2xl py-2 w-48"
          onClick={(e) => e.stopPropagation()}
        >
          <button onClick={() => { setProfileOpen(false); clearSelectedProfile(); }}
            className="w-full text-left px-4 py-2 text-sm text-gray-300 hover:bg-white/10 hover:text-white">
            Wissel van profiel
          </button>
          <button onClick={() => { setProfileOpen(false); signOut(); }}
            className="w-full text-left px-4 py-2 text-sm text-gray-300 hover:bg-white/10 hover:text-white">
            Uitloggen
          </button>
        </div>
      </div>
    )}
    </>
  );
}
