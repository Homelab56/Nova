import { useRef } from "react";
import { useNavigate } from "react-router-dom";
import { useUserData } from "../context/UserDataContext";

const TMDB_POSTER = "https://image.tmdb.org/t/p/w342";

function Card({ item, progressPct }) {
  const navigate = useNavigate();
  const { toggleWatchlist, isInList } = useUserData();
  const title = item.title || item.name;
  const year = (item.release_date || item.first_air_date || "").slice(0, 4);
  const rating = item.vote_average?.toFixed(1);
  const inList = isInList(item.id);

  return (
    <div className="relative flex-shrink-0 w-36 sm:w-40 md:w-44 cursor-pointer group">
      {/* Poster */}
      <div
        onClick={() => navigate("/watch", { state: { media: item } })}
        className="w-full aspect-[2/3] rounded-xl overflow-hidden bg-nova-card shadow-lg"
      >
        {item.poster_path ? (
          <img
            src={`${TMDB_POSTER}${item.poster_path}`}
            alt={title}
            className="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
          />
        ) : (
          <div className="w-full h-full flex items-center justify-center text-gray-600 text-xs p-2 text-center bg-nova-card">
            {title}
          </div>
        )}

        {/* Voortgangsbalk */}
        {progressPct > 0 && (
          <div className="absolute bottom-0 left-0 right-0 h-1 bg-gray-700 rounded-b-xl">
            <div className="h-full bg-nova-accent rounded-b-xl" style={{ width: `${progressPct}%` }} />
          </div>
        )}

        {/* Hover play overlay */}
        <div className="absolute inset-0 rounded-xl bg-black/0 group-hover:bg-black/50 transition-colors flex items-center justify-center">
          <div className="opacity-0 group-hover:opacity-100 transition-opacity bg-nova-accent/80 rounded-full p-3 shadow-lg">
            <span className="text-white text-base">▶</span>
          </div>
        </div>
      </div>

      {/* Watchlist knop */}
      <button
        onClick={(e) => { e.stopPropagation(); toggleWatchlist(item); }}
        className={`absolute top-2 right-2 w-7 h-7 rounded-full flex items-center justify-center text-xs font-bold shadow-lg transition-all opacity-0 group-hover:opacity-100 ${inList ? "bg-nova-accent text-white" : "bg-black/70 text-white hover:bg-nova-accent"}`}
        title={inList ? "Verwijder uit watchlist" : "Voeg toe aan watchlist"}
      >
        {inList ? "✓" : "+"}
      </button>

      {/* Titel + info */}
      <div className="mt-2 px-0.5">
        <p className="text-sm font-semibold truncate leading-tight">{title}</p>
        <div className="flex items-center gap-2 text-xs text-gray-400 mt-0.5">
          {year && <span>{year}</span>}
          {rating && <span className="text-yellow-400">★ {rating}</span>}
        </div>
      </div>
    </div>
  );
}

export default function Row({ title, items = [], loading = false, progressMap = {} }) {
  const rowRef = useRef(null);

  function scroll(dir) {
    rowRef.current?.scrollBy({ left: dir * 500, behavior: "smooth" });
  }

  return (
    <div className="mb-10">
      <h2 className="text-xl md:text-2xl font-bold px-4 md:px-10 mb-4 text-gray-100">{title}</h2>
      <div className="relative group/row">
        <button
          onClick={() => scroll(-1)}
          className="absolute left-1 top-1/3 -translate-y-1/2 z-10 bg-black/70 hover:bg-nova-accent/80 text-white w-10 h-10 rounded-full items-center justify-center opacity-0 group-hover/row:opacity-100 transition-all text-2xl shadow-lg hidden md:flex"
        >
          ‹
        </button>
        <div
          ref={rowRef}
          className="flex gap-3 md:gap-4 overflow-x-auto px-4 md:px-10 pb-3"
          style={{ scrollbarWidth: "none" }}
        >
          {loading
            ? Array.from({ length: 8 }).map((_, i) => (
                <div key={i} className="flex-shrink-0 w-36 sm:w-40 md:w-44 aspect-[2/3] rounded-xl bg-nova-card animate-pulse" />
              ))
            : items.map((item) => (
                <Card
                  key={item.id}
                  item={item}
                  progressPct={progressMap[item.id] ? Math.round((progressMap[item.id].current_time / progressMap[item.id].duration) * 100) : 0}
                />
              ))}
        </div>
        <button
          onClick={() => scroll(1)}
          className="absolute right-1 top-1/3 -translate-y-1/2 z-10 bg-black/70 hover:bg-nova-accent/80 text-white w-10 h-10 rounded-full items-center justify-center opacity-0 group-hover/row:opacity-100 transition-all text-2xl shadow-lg hidden md:flex"
        >
          ›
        </button>
      </div>
    </div>
  );
}
