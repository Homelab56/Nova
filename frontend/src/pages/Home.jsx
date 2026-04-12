import { useState, useEffect, useRef } from "react";import Navbar from "../components/Navbar";
import HeroBanner from "../components/HeroBanner";
import Row from "../components/Row";
import MediaCard from "../components/MediaCard";
import { useUserData } from "../context/UserDataContext";

async function fetchRow(path) {
  const r = await fetch(path);
  if (!r.ok) return [];
  return r.json();
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

export default function Home() {
  const [mode, setMode] = useState("all");
  const [rowData, setRowData] = useState({});
  const [loadingFixed, setLoadingFixed] = useState(true);
  const [genreRows, setGenreRows] = useState([]);
  const [loadingGenre, setLoadingGenre] = useState(false);
  const [searchResults, setSearchResults] = useState(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [genreResults, setGenreResults] = useState(null);
  const [activeGenre, setActiveGenre] = useState(null);
  const [overlayPage, setOverlayPage] = useState(1);
  const [overlayTotalPages, setOverlayTotalPages] = useState(1);
  const [overlayTotal, setOverlayTotal] = useState(0);
  const [loadingMore, setLoadingMore] = useState(false);
  const overlayType = useRef(null); // "search" | "genre"
  const overlayMeta = useRef({});  // query of genre id+type
  const genreCache = useRef({});
  const sessionSeed = useRef(Math.floor(Math.random() * 1e9));

  const { watchlist, progress, progressMap } = useUserData();
  const inProgress = progress.filter(p => p.duration > 0 && (p.current_time / p.duration) < 0.95);

  // Laad vaste rijen
  useEffect(() => {
    if (mode === "watchlist") return;
    setLoadingFixed(true);
    const configs = FIXED_ROWS[mode];
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
      if (mode === "movie") {
        return fetch(`/api/search/movie?q=${encodeURIComponent(q)}&page=${page}`).then(r => r.json());
      } else if (mode === "tv") {
        return fetch(`/api/search/tv?q=${encodeURIComponent(q)}&page=${page}`).then(r => r.json());
      } else {
        const [m, t] = await Promise.all([
          fetch(`/api/search/movie?q=${encodeURIComponent(q)}&page=${page}`).then(r => r.json()),
          fetch(`/api/search/tv?q=${encodeURIComponent(q)}&page=${page}`).then(r => r.json()),
        ]);
        return { items: [...m.items, ...t.items], total_pages: Math.max(m.total_pages, t.total_pages), total_results: m.total_results + t.total_results, page };
      }
    };

    const data = await fetchSearch(query, 1);
    setSearchResults(data.items);
    setOverlayTotalPages(data.total_pages);
    setOverlayTotal(data.total_results);
    setOverlayPage(data.page ?? 1);
  }

  async function handleGenre(genre) {
    setActiveGenre(genre);
    setSearchResults(null);
    setSearchQuery("");
    setOverlayPage(1);
    overlayType.current = "genre";
    overlayMeta.current = { genre };

    const fetchGenre = async (g, page) => {
      if (mode === "movie") {
        return fetch(`/api/search/genre/${g.id}?type=movie&page=${page}`).then(r => r.json());
      } else if (mode === "tv") {
        return fetch(`/api/search/genre/${g.id}?type=tv&page=${page}`).then(r => r.json());
      } else {
        const [m, t] = await Promise.all([
          fetch(`/api/search/genre/${g.id}?type=movie&page=${page}`).then(r => r.json()),
          fetch(`/api/search/genre/${g.id}?type=tv&page=${page}`).then(r => r.json()),
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
      let items;
      if (mode === "movie") {
        items = await fetchPages(p => `/api/search/movie?q=${encodeURIComponent(query)}&page=${p}`);
      } else if (mode === "tv") {
        items = await fetchPages(p => `/api/search/tv?q=${encodeURIComponent(query)}&page=${p}`);
      } else {
        const [m, t] = await Promise.all([
          fetchPages(p => `/api/search/movie?q=${encodeURIComponent(query)}&page=${p}`),
          fetchPages(p => `/api/search/tv?q=${encodeURIComponent(query)}&page=${p}`),
        ]);
        items = [...m, ...t];
      }
      setSearchResults(prev => [...prev, ...items]);
    } else {
      const { genre } = overlayMeta.current;
      let items;
      if (mode === "movie") {
        items = await fetchPages(p => `/api/search/genre/${genre.id}?type=movie&page=${p}`);
      } else if (mode === "tv") {
        items = await fetchPages(p => `/api/search/genre/${genre.id}?type=tv&page=${p}`);
      } else {
        const [m, t] = await Promise.all([
          fetchPages(p => `/api/search/genre/${genre.id}?type=movie&page=${p}`),
          fetchPages(p => `/api/search/genre/${genre.id}?type=tv&page=${p}`),
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
    setOverlayPage(1);
    setOverlayTotalPages(1);
    setOverlayTotal(0);
  }

  function handleMode(key) {
    setMode(key);
    handleClear();
  }

  const showOverlay = searchResults || genreResults;
  const overlayItems = searchResults || genreResults || [];
  const modeLabel = mode === "movie" ? "Films" : mode === "tv" ? "Series" : "";
  const overlayTitle = searchResults ? `Resultaten voor "${searchQuery}"` : activeGenre?.name || "";

  const heroItems = mode === "movie"
    ? (rowData.popularMovies || [])
    : mode === "tv"
    ? (rowData.popularTv || [])
    : (rowData.trending || []);

  // Watchlist pagina
  if (mode === "watchlist") {
    return (
      <div className="min-h-screen bg-nova-bg">
        <Navbar onSearch={handleSearch} onClear={handleClear} hasResults={false} onGenre={handleGenre} mode={mode} onMode={handleMode} />
        <div className="pt-24 px-4 md:px-10 pb-16">
          <h1 className="text-2xl md:text-3xl font-black mb-2">Mijn Watchlist</h1>
          <p className="text-gray-500 text-sm mb-8">{watchlist.length} {watchlist.length === 1 ? "titel" : "titels"}</p>
          {inProgress.length > 0 && (
            <div className="mb-10">
              <h2 className="text-xl font-bold mb-4 text-gray-100">Verder kijken</h2>
              <div className="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8 gap-3">
                {inProgress.map(item => <MediaCard key={item.id} item={item} />)}
              </div>
            </div>
          )}
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
    <div className="min-h-screen bg-nova-bg">
      <Navbar onSearch={handleSearch} onClear={handleClear} hasResults={!!showOverlay} onGenre={handleGenre} mode={mode} onMode={handleMode} />

      {showOverlay ? (
        <div className="pt-24 px-4 md:px-10 pb-16">
          <div className="flex items-baseline gap-3 mb-6">
            <h2 className="text-xl md:text-2xl font-bold">{overlayTitle}</h2>
            {modeLabel && <span className="text-sm text-nova-accent border border-nova-accent/40 px-2 py-0.5 rounded-full">{modeLabel}</span>}
            <span className="text-gray-500 text-sm">
              {overlayItems.length} van {overlayTotal > 0 ? overlayTotal.toLocaleString() : "?"} resultaten
            </span>
          </div>
          {overlayItems.length === 0
            ? <p className="text-gray-500">Geen resultaten gevonden.</p>
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
              <Row title="Verder kijken" items={inProgress} progressMap={progressMap} />
            )}

            {/* Vaste rijen */}
            {(() => {
              const used = new Set();
              return FIXED_ROWS[mode].map((row) => {
                const raw = rowData[row.key] || [];
                const shuffled = _shuffle(raw, sessionSeed.current ^ _hashString(`${mode}:${row.key}`));
                const items = shuffled
                  .filter(_isReleased)
                  .filter(item => {
                    const id = item?.id;
                    if (id == null) return false;
                    if (used.has(id)) return false;
                    used.add(id);
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
                  FIXED_ROWS[mode].forEach(r => (rowData[r.key] || []).forEach(it => used.add(it?.id)));
                  return genreRows.map(row => {
                    const shuffled = _shuffle(row.items || [], sessionSeed.current ^ _hashString(`${mode}:genre:${row.key}`));
                    const items = shuffled
                      .filter(_isReleased)
                      .filter(item => {
                        const id = item?.id;
                        if (id == null) return false;
                        if (used.has(id)) return false;
                        used.add(id);
                        return true;
                      });
                    if (items.length === 0) return null;
                    return (
                      <Row
                        key={row.key}
                        title={row.title}
                        items={items}
                        progressMap={progressMap}
                      />
                    );
                  });
                })()
            }
          </div>
        </>
      )}
    </div>
  );
}
