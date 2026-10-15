import { useState, useEffect } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import Sidebar from "../components/Sidebar";
import MediaCard from "../components/MediaCard";

const TMDB_PROFILE = "https://image.tmdb.org/t/p/w342";

const SORT_OPTIONS = [
  { key: "year", label: "Jaar" },
  { key: "rating", label: "IMDB Rating" },
  { key: "title", label: "A-Z" },
];

function sortCredits(items, sortKey) {
  const sorted = [...items];
  if (sortKey === "title") {
    sorted.sort((a, b) => (a.title || a.name || "").toLowerCase().localeCompare((b.title || b.name || "").toLowerCase()));
  } else if (sortKey === "rating") {
    sorted.sort((a, b) => (b.vote_average ?? -1) - (a.vote_average ?? -1));
  } else {
    sorted.sort((a, b) => {
      const yearOf = (it) => (it.release_date || it.first_air_date || "").slice(0, 4);
      return (Number(yearOf(b)) || 0) - (Number(yearOf(a)) || 0);
    });
  }
  return sorted;
}

export default function Person() {
  const { state } = useLocation();
  const navigate = useNavigate();
  const person = state?.person;

  const [detail, setDetail] = useState(null);
  const [credits, setCredits] = useState([]);
  const [loading, setLoading] = useState(true);
  const [sortKey, setSortKey] = useState("year");

  useEffect(() => {
    if (!person?.id) { navigate("/"); return; }
    setLoading(true);
    setDetail(null);
    setCredits([]);
    Promise.all([
      fetch(`/api/search/person/${person.id}`).then(r => r.ok ? r.json() : null).catch(() => null),
      fetch(`/api/search/person/${person.id}/credits`).then(r => r.ok ? r.json() : []).catch(() => []),
    ]).then(([d, c]) => {
      setDetail(d);
      setCredits(Array.isArray(c) ? c : []);
      setLoading(false);
    });
  }, [person?.id]);

  if (!person?.id) return null;

  const name = detail?.name || person.name;
  const photo = detail?.profile_path || person.profile_path;
  const sorted = sortCredits(credits, sortKey);

  return (
    <div className="min-h-screen bg-nova-bg pl-[var(--sbw)] transition-[padding-left] duration-200">
      <Sidebar
        onSearch={(q) => navigate(`/?mode=all&q=${encodeURIComponent(q)}`)}
        onClear={() => navigate("/")}
        onGenre={() => navigate("/")}
        mode=""
        onMode={(m) => navigate(`/?mode=${encodeURIComponent(m)}`)}
      />

      <div className="pt-8 px-4 md:px-10 pb-16 max-w-6xl mx-auto">
        <div className="flex flex-col sm:flex-row gap-6 mb-10">
          <div className="w-32 h-32 sm:w-40 sm:h-40 shrink-0 rounded-full overflow-hidden bg-nova-card border-2 border-gray-700 mx-auto sm:mx-0">
            {photo ? (
              <img src={`${TMDB_PROFILE}${photo}`} alt={name} className="w-full h-full object-cover" />
            ) : (
              <div className="w-full h-full flex items-center justify-center text-5xl text-gray-600">👤</div>
            )}
          </div>
          <div className="text-center sm:text-left">
            <h1 className="text-2xl md:text-4xl font-black mb-2">{name}</h1>
            {detail && (
              <p className="text-sm text-gray-500 mb-3">
                {[detail.birthday, detail.place_of_birth].filter(Boolean).join(" · ")}
              </p>
            )}
            {detail?.biography && (
              <p className="text-sm text-gray-300 leading-relaxed max-w-2xl whitespace-pre-line">{detail.biography}</p>
            )}
          </div>
        </div>

        <div className="flex items-center justify-between mb-5">
          <h2 className="text-xl md:text-2xl font-bold">Filmografie</h2>
          <div className="flex gap-2">
            {SORT_OPTIONS.map((opt) => (
              <button
                key={opt.key}
                onClick={() => setSortKey(opt.key)}
                className={`px-3 py-1.5 rounded-lg text-xs md:text-sm font-medium border transition-colors ${
                  sortKey === opt.key
                    ? "border-nova-accent text-nova-accent bg-nova-accent/10"
                    : "border-gray-700 text-gray-400 hover:text-white hover:border-gray-500"
                }`}
              >
                {opt.label}
              </button>
            ))}
          </div>
        </div>

        {loading ? (
          <p className="text-gray-500">Laden...</p>
        ) : sorted.length === 0 ? (
          <p className="text-gray-500">Geen filmografie gevonden.</p>
        ) : (
          <div className="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-5 lg:grid-cols-7 xl:grid-cols-9 gap-3">
            {sorted.map((item) => (
              <MediaCard key={`${item.media_type}:${item.id}`} item={item} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
