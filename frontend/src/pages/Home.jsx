import { useState, useEffect, useRef } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import Sidebar from "../components/Sidebar";
import HeroBanner from "../components/HeroBanner";
import Row from "../components/Row";
import MediaCard from "../components/MediaCard";
import { useUserData } from "../context/UserDataContext";

async function fetchRow(path) {
  const r = await fetch(path);
  if (!r.ok) return { items: [], page: 1, total_pages: 1, total_results: 0 };
  const data = await r.json();
  if (Array.isArray(data)) return { items: data, page: 1, total_pages: 1, total_results: data.length };
  return {
    items: data.items || [],
    page: data.page || 1,
    total_pages: data.total_pages || 1,
    total_results: data.total_results || 0,
  };
}

function _hashString(str) {
  let h = 2166136261;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

function _shuffle(items, seed) {
  const a = [...items];
  let x = seed >>> 0;
  for (let i = a.length - 1; i > 0; i--) {
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    const j = x % (i + 1);
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

function _isReleased(item) {
  const dateStr = item?.release_date || item?.first_air_date;
  if (!dateStr) return true;
  const t = Date.parse(dateStr);
  if (!Number.isFinite(t)) return true;
  return t <= Date.now();
}

// Vaste rijen per mode (snel te laden)
const FIXED_ROWS = {
  all: [
    { key: "trending",      title: "Trending deze week",      path: "/api/search/trending" },
    { key: "popularMovies", title: "Populaire films",         path: "/api/search/popular/movies" },
    { key: "popularTv",     title: "Populaire series",        path: "/api/search/popular/tv" },
    { key: "onAir",         title: "Nu op tv",                path: "/api/search/onair/tv" },
    { key: "topMovies",     title: "Best beoordeelde films",  path: "/api/search/toprated/movies" },
    { key: "topTv",         title: "Best beoordeelde series", path: "/api/search/toprated/tv" },
  ],
  movie: [
    { key: "popularMovies", title: "Populaire films",         path: "/api/search/popular/movies" },
    { key: "trendMovies",   title: "Trending films",          path: "/api/search/trending/movies" },
    { key: "topMovies",     title: "Best beoordeeld",         path: "/api/search/toprated/movies" },
  ],
  tv: [
    { key: "popularTv",     title: "Populaire series",        path: "/api/search/popular/tv" },
    { key: "trendTv",       title: "Trending series",         path: "/api/search/trending/tv" },
    { key: "onAir",         title: "Nu op tv",                path: "/api/search/onair/tv" },
    { key: "airingToday",   title: "Vanavond te zien",        path: "/api/search/airingtoday/tv" },
    { key: "topTv",         title: "Best beoordeeld",         path: "/api/search/toprated/tv" },
  ],
};

const KIDS_ROWS = {
  all: [
    { key: "kidsMovies", title: "Kids films", path: "/api/search/kids/movies" },
    { key: "kidsTv", title: "Kids series", path: "/api/search/kids/tv" },
  ],
  movie: [{ key: "kidsMovies", title: "Kids films", path: "/api/search/kids/movies" }],
  tv: [{ key: "kidsTv", title: "Kids series", path: "/api/search/kids/tv" }],
};

function _mediaKey(item) {
  const id = item?.id;
  if (id == null) return null;
  const t = item?.media_type || (item?.title ? "movie" : "tv");
  return `${t}:${id}`;
}

function _mergeUnique(prev = [], next = []) {
  const seen = new Set();
  const out = [];
  prev.forEach((it) => {
    const k = _mediaKey(it);
    if (!k || seen.has(k)) return;
    seen.add(k);
    out.push(it);
  });
  next.forEach((it) => {
    const k = _mediaKey(it);
    if (!k || seen.has(k)) return;
    seen.add(k);
    out.push(it);
  });
  return out;
}

const SORT_OPTIONS = [
  { key: "", label: "Aanbevolen" },
  { key: "popularity", label: "Populair" },
  { key: "rating", label: "Beste score" },
  { key: "newest", label: "Nieuwste" },
  { key: "oldest", label: "Oudste" },
  { key: "az", label: "A-Z" },
];

// Sortering loopt via /discover (optioneel gecombineerd met het gekozen genre/thema).
function browseUrl(g, type, page, sort) {
  let u = `/api/search/discover?type=${type}&sort=${sort}&page=${page}`;
  if (g?.keyword) u += `&keyword=${g.keyword}`;
  else if (g?.id) u += `&genre=${g.id}`;
  return u;
}

function genreUrl(g, type, page) {
  if (g.keyword) return `/api/search/keyword/${g.keyword}?type=${type}&page=${page}`;
  return `/api/search/genre/${g.id}?type=${type}&page=${page}`;
}

function _withPage(path, page) {
  const u = new URL(path, window.location.origin);
  u.searchParams.set("page", String(page));
  return u.pathname + u.search;
}

export default function Home() {
  const navigate = useNavigate();
  const location = useLocation();
  const [mode, setMode] = useState("all");
  const [rowData, setRowData] = useState({});
  const [loadingFixed, setLoadingFixed] = useState(true);
  const [genreRows, setGenreRows] = useState([]);
  const [loadingGenre, setLoadingGenre] = useState(false);
  const [searchResults, setSearchResults] = useState(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [personResults, setPersonResults] = useState([]);
  const [genreResults, setGenreResults] = useState(null);
  const [activeGenre, setActiveGenre] = useState(null);
  const [sortKey, setSortKey] = useState("");
  const [overlayPage, setOverlayPage] = useState(1);
  const [overlayTotalPages, setOverlayTotalPages] = useState(1);
  const [overlayTotal, setOverlayTotal] = useState(0);
  const [loadingMore, setLoadingMore] = useState(false);
  const overlayType = useRef(null); // "search" | "genre"
  const overlayMeta = useRef({});  // query of genre id+type
  const genreCache = useRef({});
  const sessionSeed = useRef(Math.floor(Math.random() * 1e9));
  const initFromUrlRef = useRef(false);

  const { watchlist, progress, progressMap, suggestions } = useUserData();
  // "Verder kijken": nieuwste eerst, één kaart per serie (de laatst bekeken aflevering) en
  // geen titels die (bijna) uit zijn. Sorteren gebeurt expliciet op last_watched_at - de
  // volgorde uit de database is niet gegarandeerd.
  const inProgress = (() => {
    const when = (p) => Date.parse(p?.last_watched_at || 0) || 0;
    const sorted = progress
      .filter(p => {
        const t = Number(p?.current_time) || 0;
        const d = Number(p?.duration) || 0;
        if (t <= 10) return false;
        if (d > 0) return (t / d) < 0.95;
        return true;
      })
      .sort((a, b) => when(b) - when(a));
    const seen = new Set();
    const out = [];
    for (const p of sorted) {
      const isEp = p.media_type === "tv_episode";
      const key = isEp ? `tv:${p.show_id}` : `${p.media_type}:${p.id}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push(isEp
        ? { ...p, id: p.show_id, media_type: "tv", name: (p.title || "").split(" S")[0], title: undefined }
        : p);
    }
    return out;
  })();

  useEffect(() => {
    if (initFromUrlRef.current) return;
    initFromUrlRef.current = true;
    try {
      const params = new URLSearchParams(location.search || "");
      const m = (params.get("mode") || "").toLowerCase().trim();
      const q = (params.get("q") || "").trim();
      if (m && ["all", "movie", "tv", "watchlist"].includes(m)) setMode(m);
      if (q) {
        navigate(`/search?q=${encodeURIComponent(q)}`, { replace: true });
        return;
      }
      if (m) navigate("/", { replace: true });
    } catch {}
  }, []);

  function findRowConfig(key) {
    const rows = [...(FIXED_ROWS[mode] || []), ...(KIDS_ROWS[mode] || [])];
    return rows.find(r => r.key === key) || null;
  }

  async function loadMoreRow(key) {
    const cfg = findRowConfig(key);
    if (!cfg) return;

    let nextPage;
    setRowData(prev => {
      const current = prev[key];
      if (!current || current.loadingMore) return prev;
      if ((current.page || 1) >= (current.total_pages || 1)) return prev;
      nextPage = (current.page || 1) + 1;
      return { ...prev, [key]: { ...current, loadingMore: true } };
    });
    if (!nextPage) return;

    try {
      const data = await fetchRow(_withPage(cfg.path, nextPage));
      setRowData(prev => {
        const current = prev[key];
        if (!current) return prev;
        const merged = _mergeUnique(current.items || [], data.items || []);
        return {
          ...prev,
          [key]: {
            ...current,
            items: merged,
            page: data.page || nextPage,
            total_pages: data.total_pages || current.total_pages || 1,
            total_results: data.total_results || current.total_results || 0,
            loadingMore: false,
          },
        };
      });
    } catch {
      setRowData(prev => {
        const current = prev[key];
        if (!current) return prev;
        return { ...prev, [key]: { ...current, loadingMore: false } };
      });
    }
  }

  async function loadMoreGenreRow(rowKey) {
    let target;
    setGenreRows(prev => {
      target = prev.find(r => r.key === rowKey);
      if (!target) return prev;
      if (target.loadingMore) return prev;
      if ((target.page || 1) >= (target.total_pages || 1)) return prev;
      return prev.map(r => r.key === rowKey ? { ...r, loadingMore: true } : r);
    });
    if (!target) return;
    const nextPage = (target.page || 1) + 1;
    try {
      const data = await fetch(`/api/search/genre/${target.genre_id}?type=${encodeURIComponent(target.media_type)}&page=${nextPage}`).then(r => r.json());
      setGenreRows(prev => {
        const next = prev.map(r => {
          if (r.key !== rowKey) return r;
          const merged = _mergeUnique(r.items || [], data.items || []);
          return {
            ...r,
            items: merged,
            page: data.page || nextPage,
            total_pages: data.total_pages || r.total_pages || 1,
            loadingMore: false,
          };
        });
        genreCache.current[mode] = next;
        return next;
      });
    } catch {
      setGenreRows(prev => {
        const next = prev.map(r => r.key === rowKey ? { ...r, loadingMore: false } : r);
        genreCache.current[mode] = next;
        return next;
      });
    }
  }

  // Laad vaste rijen
  useEffect(() => {
    if (mode === "watchlist") return;
    setLoadingFixed(true);
    const configs = [...(FIXED_ROWS[mode] || []), ...(KIDS_ROWS[mode] || [])];
    const toLoad = configs.filter(c => !rowData[c.key]);
    if (toLoad.length === 0) { setLoadingFixed(false); return; }

    Promise.all(toLoad.map(c => fetchRow(c.path).then(data => ({ key: c.key, data }))))
      .then(results => {
        setRowData(prev => {
          const next = { ...prev };
          results.forEach(r => { next[r.key] = r.data; });
          return next;
        });
        setLoadingFixed(false);
      });
  }, [mode]);

  // Laad genre rijen (lazy, gecached)
  useEffect(() => {
    if (mode === "watchlist") return;
    const cacheKey = mode;
    if (genreCache.current[cacheKey]) {
      setGenreRows(genreCache.current[cacheKey]);
      return;
    }
    setLoadingGenre(true);
    const type = mode === "all" ? "all" : mode;
    fetch(`/api/search/genre-rows?type=${type}`)
      .then(r => r.json())
      .then(rows => {
        genreCache.current[cacheKey] = rows;
        setGenreRows(rows);
        setLoadingGenre(false);
      })
      .catch(() => setLoadingGenre(false));
  }, [mode]);

  async function handleSearch(query) {
    setSearchQuery(query);
    setGenreResults(null);
    setActiveGenre(null);
    setOverlayPage(1);
    overlayType.current = "search";
    overlayMeta.current = { query };

    const fetchSearch = async (q, page) => {
      return fetch(`/api/search/multi?q=${encodeURIComponent(q)}&page=${page}`).then(r => r.json());
    };

    const data = await fetchSearch(query, 1);
    setSearchResults(data.items);
    setOverlayTotalPages(data.total_pages);
    setOverlayTotal(data.total_results);
    setOverlayPage(data.page ?? 1);

    fetch(`/api/search/person?q=${encodeURIComponent(query)}`)
      .then(r => r.json())
      .then(d => setPersonResults((d.items || []).filter(p => p.profile_path).slice(0, 10)))
      .catch(() => setPersonResults([]));
  }

  async function loadOverlay(genre, sort) {
    setActiveGenre(genre);
    setSearchResults(null);
    setSearchQuery("");
    setPersonResults([]);
    setOverlayPage(1);
    overlayType.current = "genre";
    overlayMeta.current = { genre, sort };

    const urlFor = (g, type, page) => (sort ? browseUrl(g, type, page, sort) : genreUrl(g, type, page));
    const fetchGenre = async (g, page) => {
      if (mode === "movie") {
        return fetch(urlFor(g, "movie", page)).then(r => r.json());
      } else if (mode === "tv") {
        return fetch(urlFor(g, "tv", page)).then(r => r.json());
      } else {
        const [m, t] = await Promise.all([
          fetch(urlFor(g, "movie", page)).then(r => r.json()),
          fetch(urlFor(g, "tv", page)).then(r => r.json()),
        ]);
        return { items: [...m.items, ...t.items], total_pages: Math.max(m.total_pages, t.total_pages), total_results: m.total_results + t.total_results, page };
      }
    };

    const data = await fetchGenre(genre, 1);
    setGenreResults(data.items);
    setOverlayTotalPages(data.total_pages);
    setOverlayTotal(data.total_results);
    setOverlayPage(data.page ?? 1);
  }

  function handleGenre(genre) {
    return loadOverlay(genre, (mode === "movie" || mode === "tv") ? sortKey : "");
  }

  function applySort(key) {
    setSortKey(key);
    if (!key && !activeGenre) { handleClear(); return; }
    loadOverlay(activeGenre, key);
  }

  async function loadMore() {
    setLoadingMore(true);
    const nextPage = overlayPage + 1;
    const endPage = nextPage + 4; // 5 pagina's = ~100 items

    const fetchPages = async (urlFn) => {
      const pages = await Promise.all(
        Array.from({ length: 5 }, (_, i) => fetch(urlFn(nextPage + i)).then(r => r.json()))
      );
      const items = [], seen = new Set();
      pages.forEach(p => (p.items || []).forEach(item => {
        if (!seen.has(item.id)) { seen.add(item.id); items.push(item); }
      }));
      return items;
    };

    if (overlayType.current === "search") {
      const { query } = overlayMeta.current;
      const items = await fetchPages(p => `/api/search/multi?q=${encodeURIComponent(query)}&page=${p}`);
      setSearchResults(prev => [...prev, ...items]);
    } else {
      const { genre, sort } = overlayMeta.current;
      const urlFor = (g, type, p) => (sort ? browseUrl(g, type, p, sort) : genreUrl(g, type, p));
      let items;
      if (mode === "movie") {
        items = await fetchPages(p => urlFor(genre, "movie", p));
      } else if (mode === "tv") {
        items = await fetchPages(p => urlFor(genre, "tv", p));
      } else {
        const [m, t] = await Promise.all([
          fetchPages(p => urlFor(genre, "movie", p)),
          fetchPages(p => urlFor(genre, "tv", p)),
        ]);
        items = [...m, ...t];
      }
      setGenreResults(prev => [...prev, ...items]);
    }

    setOverlayPage(endPage);
    setLoadingMore(false);
  }

  function handleClear() {
    setSearchResults(null);
    setGenreResults(null);
    setSearchQuery("");
    setActiveGenre(null);
    setSortKey("");
    setOverlayPage(1);
    setOverlayTotalPages(1);
    setOverlayTotal(0);
    setPersonResults([]);
  }

  function handleMode(key) {
    setMode(key);
    handleClear();
  }

  const showOverlay = searchResults || genreResults;
  const overlayItems = searchResults || genreResults || [];
  const modeLabel = searchResults ? "" : (mode === "movie" ? "Films" : mode === "tv" ? "Series" : "");
  const sortLabel = SORT_OPTIONS.find(o => o.key === sortKey)?.label || "";
  const overlayTitle = searchResults
    ? `Resultaten voor "${searchQuery}"`
    : [activeGenre?.name, sortKey ? sortLabel : ""].filter(Boolean).join(" · ");
  const showSortBar = (mode === "movie" || mode === "tv") && !searchResults;
  const sortBar = showSortBar ? (
    <div className="px-4 md:px-10 pt-6 pb-2 flex flex-wrap items-center gap-2 relative z-20">
      <span className="text-sm text-gray-500 mr-1">Sorteer op:</span>
      {SORT_OPTIONS.map(o => (
        <button
          key={o.key || "default"}
          onClick={() => applySort(o.key)}
          title={o.key === "rating" ? "TMDB-gebruikersscore (min. aantal stemmen)" : undefined}
          className={`px-3 py-1.5 rounded-lg text-sm font-medium border transition-colors ${
            sortKey === o.key
              ? "border-nova-accent text-nova-accent bg-nova-accent/10"
              : "border-gray-700 text-gray-400 hover:text-white hover:border-gray-500"
          }`}
        >
          {o.label}
        </button>
      ))}
    </div>
  ) : null;

  const heroItems = mode === "movie"
    ? (rowData.popularMovies?.items || [])
    : mode === "tv"
    ? (rowData.popularTv?.items || [])
    : (rowData.trending?.items || []);

  // Watchlist pagina
  if (mode === "watchlist") {
    return (
      <div className="min-h-screen bg-nova-bg pl-[var(--sbw)] transition-[padding-left] duration-200">
        <Sidebar onSearch={handleSearch} onClear={handleClear} onGenre={handleGenre} mode={mode} onMode={handleMode} />
        <div className="pt-8 px-4 md:px-10 pb-16">
          <h1 className="text-2xl md:text-3xl font-black mb-2">Mijn Watchlist</h1>
          <p className="text-gray-500 text-sm mb-8">{watchlist.length} {watchlist.length === 1 ? "titel" : "titels"}</p>
          {watchlist.length === 0 ? (
            <div className="flex flex-col items-center justify-center py-24 text-center">
              <p className="text-5xl mb-4">🎬</p>
              <p className="text-gray-400 text-lg">Je watchlist is leeg.</p>
              <p className="text-gray-600 text-sm mt-2">Druk op <span className="text-nova-accent">+</span> bij een film of serie om hem toe te voegen.</p>
            </div>
          ) : (
            <div className="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8 gap-3">
              {watchlist.map(item => <MediaCard key={item.id} item={item} />)}
            </div>
          )}
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-nova-bg pl-[var(--sbw)] transition-[padding-left] duration-200">
      <Sidebar onSearch={handleSearch} onClear={handleClear} onGenre={handleGenre} mode={mode} onMode={handleMode} />

      {sortBar}
      {showOverlay ? (
        <div className="pt-4 px-4 md:px-10 pb-16">
          <div className="flex items-baseline gap-3 mb-6">
            <h2 className="text-xl md:text-2xl font-bold">{overlayTitle}</h2>
            {modeLabel && <span className="text-sm text-nova-accent border border-nova-accent/40 px-2 py-0.5 rounded-full">{modeLabel}</span>}
            <span className="text-gray-500 text-sm">
              {overlayItems.length} van {overlayTotal > 0 ? overlayTotal.toLocaleString() : "?"} resultaten
            </span>
          </div>
          {searchResults && personResults.length > 0 && (
            <div className="mb-8">
              <h3 className="text-sm font-bold text-gray-400 mb-3">Personen</h3>
              <div className="flex gap-4 overflow-x-auto pb-3" style={{ scrollbarWidth: "none" }}>
                {personResults.map(person => (
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
          {overlayItems.length === 0
            ? (personResults.length === 0 && <p className="text-gray-500">Geen resultaten gevonden.</p>)
            : <>
                <div className="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-5 lg:grid-cols-7 xl:grid-cols-9 gap-3">
                  {overlayItems.map(item => <MediaCard key={item.id} item={item} />)}
                </div>
                {overlayPage < overlayTotalPages && (
                  <div className="flex justify-center mt-10">
                    <button
                      onClick={loadMore}
                      disabled={loadingMore}
                      className="bg-nova-card hover:bg-nova-accent border border-gray-700 hover:border-nova-accent text-white px-10 py-3 rounded-xl font-medium transition-all disabled:opacity-50"
                    >
                      {loadingMore ? "Laden..." : `Laad meer  (pagina ${overlayPage + 1} van ${overlayTotalPages})`}
                    </button>
                  </div>
                )}
                {overlayPage >= overlayTotalPages && overlayItems.length > 0 && (
                  <p className="text-center text-gray-600 text-sm mt-8">Alle {overlayItems.length} resultaten geladen</p>
                )}
              </>
          }
        </div>
      ) : (
        <>
          <HeroBanner items={heroItems} />
          <div className="relative z-10 -mt-6 pb-16">
            {/* Persoonlijke rijen bovenaan */}
            {inProgress.length > 0 && (
              <Row title="Verder kijken" items={inProgress} progressMap={progressMap} dismissable={true} />
            )}

            {/* "Voor jou" op basis van je sterrenbeoordelingen */}
            {(mode === "all" || mode === "movie") && suggestions.movies.length > 0 && (
              <Row title="Films voor jou" items={suggestions.movies} progressMap={progressMap} />
            )}
            {(mode === "all" || mode === "tv") && suggestions.tv.length > 0 && (
              <Row title="Series voor jou" items={suggestions.tv} progressMap={progressMap} />
            )}

            {/* Vaste rijen */}
            {(() => {
              const used = new Set();
              return FIXED_ROWS[mode].map((row) => {
                const raw = rowData[row.key]?.items || [];
                const shuffled = _shuffle(raw, sessionSeed.current ^ _hashString(`${mode}:${row.key}`));
                const items = shuffled
                  .filter(_isReleased)
                  .filter(item => {
                    const k = _mediaKey(item);
                    if (!k) return false;
                    if (used.has(k)) return false;
                    used.add(k);
                    return true;
                  });
              if (!loadingFixed && items.length === 0) return null;
              return (
                <div key={row.key}>
                  <Row
                    title={row.title}
                    items={items}
                    loading={loadingFixed && !rowData[row.key]}
                    progressMap={progressMap}
                    hasMore={(rowData[row.key]?.page || 1) < (rowData[row.key]?.total_pages || 1)}
                    loadingMore={!!rowData[row.key]?.loadingMore}
                    onLoadMore={() => loadMoreRow(row.key)}
                  />
                </div>
              );
              });
            })()}

            {/* Genre rijen */}
            {loadingGenre && !genreRows.length
              ? Array.from({ length: 4 }).map((_, i) => (
                  <Row key={`skel-${i}`} title="" items={[]} loading={true} />
                ))
              : (() => {
                  const used = new Set();
                  FIXED_ROWS[mode].forEach(r => (rowData[r.key]?.items || []).forEach(it => {
                    const k = _mediaKey(it);
                    if (k) used.add(k);
                  }));
                  return genreRows.map(row => {
                    const shuffled = _shuffle(row.items || [], sessionSeed.current ^ _hashString(`${mode}:genre:${row.key}`));
                    const items = shuffled
                      .filter(_isReleased)
                      .filter(item => {
                        const k = _mediaKey(item);
                        if (!k) return false;
                        if (used.has(k)) return false;
                        used.add(k);
                        return true;
                      });
                    if (items.length === 0) return null;
                    return (
                      <Row
                        key={row.key}
                        title={row.title}
                        items={items}
                        progressMap={progressMap}
                        hasMore={(row.page || 1) < (row.total_pages || 1)}
                        loadingMore={!!row.loadingMore}
                        onLoadMore={() => loadMoreGenreRow(row.key)}
                      />
                    );
                  });
                })()
            }

            {(KIDS_ROWS[mode] || []).length > 0 && (
              <div className="mt-10">
                <div className="px-4 md:px-10 mb-4">
                  <h2 className="text-2xl md:text-3xl font-black text-gray-100">Kids</h2>
                </div>
                {(KIDS_ROWS[mode] || []).map((row) => {
                  const raw = rowData[row.key]?.items || [];
                  const items = raw.filter(_isReleased);
                  if (!loadingFixed && items.length === 0) return null;
                  return (
                    <Row
                      key={row.key}
                      title={row.title}
                      items={items}
                      loading={loadingFixed && !rowData[row.key]}
                      progressMap={progressMap}
                      hasMore={(rowData[row.key]?.page || 1) < (rowData[row.key]?.total_pages || 1)}
                      loadingMore={!!rowData[row.key]?.loadingMore}
                      onLoadMore={() => loadMoreRow(row.key)}
                    />
                  );
                })}
              </div>
            )}
          </div>
        </>
      )}
    </div>
  );
}
