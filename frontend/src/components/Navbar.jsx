import { useState, useEffect, useRef } from "react";
import { useNavigate } from "react-router-dom";

const GENRES = [
  { id: 28, name: "Actie" }, { id: 12, name: "Avontuur" }, { id: 16, name: "Animatie" },
  { id: 35, name: "Komedie" }, { id: 80, name: "Misdaad" }, { id: 99, name: "Documentaire" },
  { id: 18, name: "Drama" }, { id: 10751, name: "Familie" }, { id: 14, name: "Fantasy" },
  { id: 27, name: "Horror" }, { id: 9648, name: "Mystery" }, { id: 10749, name: "Romantiek" },
  { id: 878, name: "Sci-Fi" }, { id: 53, name: "Thriller" }, { id: 10752, name: "Oorlog" },
];

const MODES = [
  { key: "all", label: "Home", icon: (
    <svg xmlns="http://www.w3.org/2000/svg" className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6" />
    </svg>
  )},
  { key: "movie", label: "Films" },
  { key: "tv", label: "Series" },
  { key: "watchlist", label: "Watchlist" },
];

export default function Navbar({ onSearch, onClear, hasResults, onGenre, mode, onMode }) {
  const navigate = useNavigate();
  const [scrolled, setScrolled] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const [genreOpen, setGenreOpen] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [activeGenre, setActiveGenre] = useState(null);
  const genreRef = useRef(null);

  useEffect(() => {
    const handler = () => setScrolled(window.scrollY > 20);
    window.addEventListener("scroll", handler);
    return () => window.removeEventListener("scroll", handler);
  }, []);

  useEffect(() => {
    if (!genreOpen) return;
    const handler = (e) => {
      if (genreRef.current && !genreRef.current.contains(e.target)) setGenreOpen(false);
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [genreOpen]);

  function handleSubmit(e) {
    e.preventDefault();
    if (query.trim()) { onSearch(query); setActiveGenre(null); setMobileOpen(false); }
  }

  function handleClear() {
    setQuery(""); setSearchOpen(false); setActiveGenre(null); onClear();
  }

  function handleGenre(genre) {
    setActiveGenre(genre); setGenreOpen(false); setMobileOpen(false);
    onGenre(genre); setQuery("");
  }

  function handleMode(key) {
    onMode(key); setActiveGenre(null); onClear(); setMobileOpen(false);
  }

  return (
    <>
      <nav className={`fixed top-0 left-0 right-0 z-50 transition-all duration-300 ${scrolled ? "bg-nova-bg/95 backdrop-blur shadow-lg" : "bg-gradient-to-b from-black/70 to-transparent"}`}>
        <div className="flex items-center justify-between px-4 md:px-10 py-3">

          {/* Links: logo + desktop tabs */}
          <div className="flex items-center gap-3 md:gap-5">
            <div onClick={() => { handleClear(); onMode("all"); navigate("/"); }} className="cursor-pointer select-none">
              <img src="/logo.png" alt="Nova" className="h-10 md:h-14 w-auto drop-shadow-[0_0_12px_rgba(0,180,216,0.8)]" />
            </div>

            {/* Desktop tabs */}
            <div className="hidden md:flex items-center bg-black/30 backdrop-blur rounded-xl p-1 gap-0.5">
              {MODES.map(m => (
                <button key={m.key} onClick={() => handleMode(m.key)}
                  className={`flex items-center gap-1.5 px-4 py-1.5 rounded-lg text-sm font-medium transition-all ${mode === m.key ? "bg-nova-accent text-white shadow" : "text-gray-400 hover:text-white"}`}
                >
                  {m.icon && m.icon}
                  {m.label}
                </button>
              ))}
            </div>

            {/* Desktop genre knop */}
            <div className="hidden md:block relative" ref={genreRef}>
              <button
                onClick={() => setGenreOpen(v => !v)}
                className={`flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium transition-all border ${genreOpen || activeGenre ? "border-nova-accent text-nova-accent bg-nova-accent/10" : "border-gray-700 text-gray-400 hover:border-gray-400 hover:text-white"}`}
              >
                <svg xmlns="http://www.w3.org/2000/svg" className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M4 6h16M4 12h16M4 18h7" />
                </svg>
                <span>{activeGenre ? activeGenre.name : "Genres"}</span>
              </button>

              {genreOpen && (
                <div className="absolute top-12 left-0 z-50 bg-nova-card/95 backdrop-blur border border-gray-700 rounded-2xl shadow-2xl p-4 w-64">
                  <p className="text-xs text-gray-500 uppercase tracking-widest mb-3 px-1">
                    {mode === "tv" ? "Genre — Series" : mode === "movie" ? "Genre — Films" : "Kies een genre"}
                  </p>
                  <div className="grid grid-cols-2 gap-2">
                    {GENRES.map(g => (
                      <button key={g.id} onClick={() => handleGenre(g)}
                        className={`text-left px-3 py-2 rounded-lg text-sm transition-colors ${activeGenre?.id === g.id ? "bg-nova-accent text-white" : "hover:bg-white/10 text-gray-300 hover:text-white"}`}
                      >
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
          </div>

          {/* Rechts: zoek + settings + hamburger */}
          <div className="flex items-center gap-2">
            {/* Zoek */}
            <form onSubmit={handleSubmit} className="flex items-center gap-2">
              <input
                className={`bg-nova-bg/80 backdrop-blur border border-gray-600 rounded-lg px-4 py-2 text-sm focus:outline-none focus:border-nova-accent transition-all duration-300 ${searchOpen ? "w-40 md:w-72 opacity-100" : "w-0 opacity-0 px-0 border-0"}`}
                value={query}
                onChange={e => setQuery(e.target.value)}
                placeholder="Zoeken..."
              />
              <button type={searchOpen ? "submit" : "button"} onClick={() => !searchOpen && setSearchOpen(true)}
                className="text-gray-300 hover:text-nova-accent p-2 rounded-lg hover:bg-white/10 transition-colors">
                <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <circle cx="11" cy="11" r="7" /><line x1="16.5" y1="16.5" x2="22" y2="22" />
                </svg>
              </button>
              {(searchOpen || hasResults) && (
                <button type="button" onClick={handleClear} className="text-gray-400 hover:text-white text-sm px-1">✕</button>
              )}
            </form>

            {/* Settings (desktop) */}
            <button onClick={() => navigate("/settings")}
              className="hidden md:flex text-gray-300 hover:text-nova-accent p-2 rounded-lg hover:bg-white/10 transition-colors">
              <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
                <path strokeLinecap="round" strokeLinejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
              </svg>
            </button>

            {/* Hamburger (mobile) */}
            <button onClick={() => setMobileOpen(v => !v)}
              className="md:hidden text-gray-300 hover:text-white p-2 rounded-lg hover:bg-white/10 transition-colors">
              <svg xmlns="http://www.w3.org/2000/svg" className="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                {mobileOpen
                  ? <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                  : <path strokeLinecap="round" strokeLinejoin="round" d="M4 6h16M4 12h16M4 18h16" />
                }
              </svg>
            </button>
          </div>
        </div>

        {/* Mobile menu */}
        {mobileOpen && (
          <div className="md:hidden bg-nova-bg/98 backdrop-blur border-t border-gray-800 px-4 py-4 space-y-1">
            {MODES.map(m => (
              <button key={m.key} onClick={() => handleMode(m.key)}
                className={`w-full flex items-center gap-3 px-4 py-3 rounded-xl text-sm font-medium transition-all ${mode === m.key ? "bg-nova-accent text-white" : "text-gray-300 hover:bg-white/10"}`}
              >
                {m.icon && m.icon}
                {m.label}
              </button>
            ))}
            <div className="border-t border-gray-800 pt-3 mt-3">
              <p className="text-xs text-gray-600 uppercase tracking-widest px-4 mb-2">Genres</p>
              <div className="grid grid-cols-3 gap-2">
                {GENRES.map(g => (
                  <button key={g.id} onClick={() => handleGenre(g)}
                    className={`px-3 py-2 rounded-lg text-sm transition-colors text-left ${activeGenre?.id === g.id ? "bg-nova-accent text-white" : "bg-nova-card text-gray-300 hover:text-white"}`}
                  >
                    {g.name}
                  </button>
                ))}
              </div>
            </div>
            <div className="border-t border-gray-800 pt-3 mt-3">
              <button onClick={() => { navigate("/settings"); setMobileOpen(false); }}
                className="w-full flex items-center gap-3 px-4 py-3 rounded-xl text-sm text-gray-300 hover:bg-white/10">
                ⚙ Instellingen
              </button>
            </div>
          </div>
        )}
      </nav>
    </>
  );
}
