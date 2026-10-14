import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import Sidebar from "../components/Sidebar";
import Row from "../components/Row";
import { useUserData } from "../context/UserDataContext";

async function fetchRow(path) {
  const r = await fetch(path);
  if (!r.ok) return { items: [] };
  const data = await r.json();
  if (Array.isArray(data)) return { items: data };
  return { items: data.items || [] };
}

const ROWS = {
  movie: [
    { key: "popular", title: "Populaire kids-films", path: "/api/search/kids/movies" },
    { key: "toprated", title: "Best beoordeeld", path: "/api/search/kids/movies/toprated" },
    { key: "newest", title: "Nieuw", path: "/api/search/kids/movies/newest" },
  ],
  tv: [
    { key: "popular", title: "Populaire kids-series", path: "/api/search/kids/tv" },
    { key: "toprated", title: "Best beoordeeld", path: "/api/search/kids/tv/toprated" },
    { key: "newest", title: "Nieuw", path: "/api/search/kids/tv/newest" },
  ],
};

export default function Kids() {
  const navigate = useNavigate();
  const { progressMap } = useUserData();
  const [contentType, setContentType] = useState("movie");
  const [dutchOnly, setDutchOnly] = useState(false);
  const [rowData, setRowData] = useState({});
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    Promise.all(ROWS[contentType].map((row) => fetchRow(row.path).then((d) => [row.key, d]))).then((results) => {
      if (cancelled) return;
      setRowData(Object.fromEntries(results));
      setLoading(false);
    });
    return () => { cancelled = true; };
  }, [contentType]);

  function filterRow(items) {
    return dutchOnly ? items.filter((i) => i.original_language === "nl") : items;
  }

  return (
    <div className="min-h-screen bg-nova-bg pl-20 md:pl-60">
      <Sidebar
        onSearch={(q) => navigate(`/?mode=all&q=${encodeURIComponent(q)}`)}
        onClear={() => {}}
        onGenre={() => navigate("/")}
        mode="kids"
        onMode={(m) => { if (m !== "kids") navigate("/"); }}
      />

      <div className="pt-8 px-4 md:px-10 pb-16">
        <h1 className="text-2xl md:text-3xl font-black mb-6">Kids</h1>

        <div className="flex flex-wrap items-center gap-3 mb-8">
          <div className="flex items-center bg-black/30 backdrop-blur rounded-xl p-1 gap-0.5">
            <button
              onClick={() => setContentType("movie")}
              className={`px-4 py-1.5 rounded-lg text-sm font-medium transition-all ${contentType === "movie" ? "bg-nova-accent text-white" : "text-gray-400 hover:text-white"}`}
            >
              Films
            </button>
            <button
              onClick={() => setContentType("tv")}
              className={`px-4 py-1.5 rounded-lg text-sm font-medium transition-all ${contentType === "tv" ? "bg-nova-accent text-white" : "text-gray-400 hover:text-white"}`}
            >
              Series
            </button>
          </div>

          <button
            onClick={() => setDutchOnly((v) => !v)}
            className={`px-4 py-1.5 rounded-xl text-sm font-medium border transition-all ${dutchOnly ? "border-nova-accent text-nova-accent bg-nova-accent/10" : "border-gray-700 text-gray-400 hover:border-gray-400 hover:text-white"}`}
          >
            Enkel Nederlandstalig
          </button>
        </div>

        {ROWS[contentType].map((row) => (
          <Row
            key={row.key}
            title={row.title}
            items={filterRow(rowData[row.key]?.items || [])}
            loading={loading}
            progressMap={progressMap}
          />
        ))}
      </div>
    </div>
  );
}
