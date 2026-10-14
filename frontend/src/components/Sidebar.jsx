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
  const genreRef = useRef(null);
  const profileRef = useRef(null);
  const searchInputRef = useRef(null);

  useEffect(() => {
    if (searchOpen) searchInputRef.current?.focus();
  }, [searchOpen]);

  useEffect(() => {
    if (!genreOpen) return;
    const handler = (e) => { if (genreRef.current && !genreRef.current.contains(e.target)) setGenreOpen(false); };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [genreOpen]);

  useEffect(() => {
    if (!profileOpen) return;
    const handler = (e) => { if (profileRef.current && !profileRef.current.contains(e.target)) setProfileOpen(false); };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [profileOpen]);

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
    <nav className="fixed left-0 top-0 bottom-0 z-50 w-20 md:w-60 bg-nova-card/95 backdrop-blur border-r border-gray-800 flex flex-col">
      {/* Logo (gepind, scrollt niet mee) */}
      <div
        onClick={() => { onClear(); setActiveGenre(null); onMode("all"); navigate("/"); }}
        className="cursor-pointer select-none flex items-center justify-center md:justify-start px-2 md:px-5 py-6 shrink-0"
      >
        <img src="/logo.png" alt="Streamify" className="h-9 w-auto drop-shadow-[0_0_10px_rgba(0,180,216,0.4)]" />
      </div>

      {/* Navigatie (scrollt indien nodig in de resterende ruimte) */}
      <div className="flex-1 overflow-y-auto px-2 md:px-3 space-y-1">
        {NAV_ITEMS.map((item) => (
          <button
            key={item.key}
            onClick={() => handleMode(item.key)}
            className={`w-full flex items-center justify-center md:justify-start gap-3 px-2 md:px-3 py-2.5 rounded-xl text-sm font-medium transition-all ${
              mode === item.key ? "bg-nova-accent text-white" : "text-gray-400 hover:text-white hover:bg-white/5"
            }`}
          >
            {item.icon}
            <span className="hidden md:inline">{item.label}</span>
          </button>
        ))}

        <div className="relative pt-2" ref={genreRef}>
          <button
            onClick={() => setGenreOpen((v) => !v)}
            className={`w-full flex items-center justify-center md:justify-start gap-3 px-2 md:px-3 py-2.5 rounded-xl text-sm font-medium transition-all border ${
              genreOpen || activeGenre ? "border-nova-accent text-nova-accent bg-nova-accent/10" : "border-transparent text-gray-400 hover:text-white hover:bg-white/5"
            }`}
          >
            <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M4 6h16M4 12h16M4 18h7" />
            </svg>
            <span className="hidden md:inline truncate">{activeGenre ? activeGenre.name : "Genres"}</span>
          </button>

          {genreOpen && (
            <div className="absolute left-full top-0 ml-2 z-50 bg-nova-card/95 backdrop-blur border border-gray-700 rounded-2xl shadow-2xl p-4 w-64">
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
                  className="mt-3 w-full text-xs text-gray-500 hover:text-white text-center py-1">
                  ✕ Filter wissen
                </button>
              )}
            </div>
          )}
        </div>

        <div className="relative pt-2">
          <button
            onClick={() => setSearchOpen((v) => !v)}
            className={`w-full flex items-center justify-center md:justify-start gap-3 px-2 md:px-3 py-2.5 rounded-xl text-sm font-medium transition-all ${searchOpen ? "text-nova-accent" : "text-gray-400 hover:text-white hover:bg-white/5"}`}
          >
            <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <circle cx="11" cy="11" r="7" /><line x1="16.5" y1="16.5" x2="22" y2="22" />
            </svg>
            <span className="hidden md:inline">Zoeken</span>
          </button>
          {searchOpen && (
            <form onSubmit={handleSubmit} className="absolute left-full top-0 ml-2 z-50 bg-nova-card/95 backdrop-blur border border-gray-700 rounded-xl shadow-2xl p-2 w-64 flex gap-2">
              <input
                ref={searchInputRef}
                className="flex-1 bg-black/30 border border-gray-700 rounded-lg px-3 py-2 text-sm text-white outline-none focus:border-nova-accent"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Zoeken..."
              />
              <button type="submit" className="px-3 rounded-lg bg-nova-accent text-white text-sm">Ga</button>
            </form>
          )}
        </div>
      </div>

      {/* Profiel + instellingen (gepind onderaan) */}
      <div className="shrink-0 border-t border-gray-800 px-2 md:px-3 py-3 space-y-1">
        <button onClick={() => navigate("/settings")}
          className="w-full flex items-center justify-center md:justify-start gap-3 px-2 md:px-3 py-2.5 rounded-xl text-sm font-medium text-gray-400 hover:text-white hover:bg-white/5 transition-all">
          <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
            <path strokeLinecap="round" strokeLinejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
          </svg>
          <span className="hidden md:inline">Instellingen</span>
        </button>

        {selectedProfile && (
          <div className="relative" ref={profileRef}>
            <button
              onClick={() => setProfileOpen((v) => !v)}
              className="w-full flex items-center justify-center md:justify-start gap-2 px-1 md:px-2 py-2 rounded-xl hover:bg-white/5 transition-colors"
            >
              <div className="w-8 h-8 shrink-0 rounded-md flex items-center justify-center text-sm font-bold text-white"
                style={{ backgroundColor: selectedProfile.avatar_color_hex || "#1E88E5" }}>
                {(selectedProfile.name || "?").charAt(0).toUpperCase()}
              </div>
              <span className="hidden md:inline text-sm text-gray-300 truncate">{selectedProfile.name}</span>
            </button>

            {profileOpen && (
              <div className="absolute left-full bottom-0 ml-2 z-50 bg-nova-card/95 backdrop-blur border border-gray-700 rounded-xl shadow-2xl py-2 w-48">
                <button onClick={() => { setProfileOpen(false); clearSelectedProfile(); }}
                  className="w-full text-left px-4 py-2 text-sm text-gray-300 hover:bg-white/10 hover:text-white">
                  Wissel van profiel
                </button>
                <button onClick={() => { setProfileOpen(false); signOut(); }}
                  className="w-full text-left px-4 py-2 text-sm text-gray-300 hover:bg-white/10 hover:text-white">
                  Uitloggen
                </button>
              </div>
            )}
          </div>
        )}
      </div>
    </nav>
  );
}
