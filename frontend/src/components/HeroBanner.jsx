import { useState, useEffect } from "react";
import { useNavigate } from "react-router-dom";
import { useUserData } from "../context/UserDataContext";

const TMDB_ORIG = "https://image.tmdb.org/t/p/original";
const INTERVAL = 8000;

export default function HeroBanner({ items = [] }) {
  const navigate = useNavigate();
  const { toggleWatchlist, isInList } = useUserData();
  const [index, setIndex] = useState(0);
  const [fading, setFading] = useState(false);

  // Filter items met backdrop
  const valid = items.filter(i => i.backdrop_path).slice(0, 8);
  const item = valid[index];

  useEffect(() => {
    if (valid.length < 2) return;
    const t = setInterval(() => {
      setFading(true);
      setTimeout(() => {
        setIndex(i => (i + 1) % valid.length);
        setFading(false);
      }, 500);
    }, INTERVAL);
    return () => clearInterval(t);
  }, [valid.length]);

  if (!item) return <div className="w-full h-[55vh] bg-nova-card animate-pulse rounded-none" />;

  const title = item.title || item.name;
  const year = (item.release_date || item.first_air_date || "").slice(0, 4);
  const rating = item.vote_average?.toFixed(1);
  const overview = item.overview?.length > 180 ? item.overview.slice(0, 180) + "…" : item.overview;
  const inList = isInList(item.id);

  return (
    <div className="relative w-full h-[55vh] md:h-[62vh] overflow-hidden">
      {/* Backdrop met fade */}
      <img
        key={item.id}
        src={`${TMDB_ORIG}${item.backdrop_path}`}
        alt={title}
        className={`absolute inset-0 w-full h-full object-cover object-top transition-opacity duration-500 ${fading ? "opacity-0" : "opacity-100"}`}
      />

      {/* Gradients */}
      <div className="absolute inset-0 bg-gradient-to-r from-nova-bg via-nova-bg/50 to-transparent" />
      <div className="absolute inset-0 bg-gradient-to-t from-nova-bg via-transparent to-black/20" />

      {/* Dot indicators */}
      <div className="absolute bottom-24 left-6 md:left-10 flex gap-1.5">
        {valid.map((_, i) => (
          <button
            key={i}
            onClick={() => { setFading(true); setTimeout(() => { setIndex(i); setFading(false); }, 300); }}
            className={`h-1 rounded-full transition-all duration-300 ${i === index ? "w-6 bg-nova-accent" : "w-2 bg-gray-500 hover:bg-gray-300"}`}
          />
        ))}
      </div>

      {/* Content */}
      <div className={`absolute bottom-0 left-0 px-6 md:px-10 pb-10 max-w-xl md:max-w-2xl transition-opacity duration-500 ${fading ? "opacity-0" : "opacity-100"}`}>
        <h1 className="text-3xl md:text-5xl font-black mb-2 leading-tight drop-shadow-lg">{title}</h1>
        <div className="flex items-center gap-3 mb-3 text-sm text-gray-300">
          {rating && <span className="text-yellow-400 font-semibold">★ {rating}</span>}
          {year && <span>{year}</span>}
          {item.media_type && (
            <span className="border border-gray-500 px-2 py-0.5 rounded text-xs uppercase tracking-wide">
              {item.media_type === "movie" ? "Film" : "Serie"}
            </span>
          )}
        </div>
        <p className="hidden md:block text-gray-300 text-sm leading-relaxed mb-5">{overview}</p>
        <div className="flex gap-3 flex-wrap">
          <button
            onClick={() => navigate("/watch", { state: { media: item } })}
            className="flex items-center gap-2 bg-white text-black font-bold px-6 py-2.5 rounded-xl hover:bg-gray-200 transition-colors shadow-lg"
          >
            ▶ Afspelen
          </button>
          <button
            onClick={() => toggleWatchlist(item)}
            className={`flex items-center gap-2 px-5 py-2.5 rounded-xl font-semibold border transition-colors ${inList ? "bg-nova-accent/20 border-nova-accent text-nova-accent" : "bg-black/40 border-gray-500 text-white hover:border-white"}`}
          >
            {inList ? "✓ In watchlist" : "+ Watchlist"}
          </button>
        </div>
      </div>
    </div>
  );
}
