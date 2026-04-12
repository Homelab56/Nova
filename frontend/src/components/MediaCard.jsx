import { useNavigate } from "react-router-dom";
import { useUserData } from "../context/UserDataContext";

const TMDB_POSTER = "https://image.tmdb.org/t/p/w342";

export default function MediaCard({ item }) {
  const navigate = useNavigate();
  const { toggleWatchlist, isInList } = useUserData();
  const title = item.title || item.name;
  const year = (item.release_date || item.first_air_date || "").slice(0, 4);
  const rating = item.vote_average?.toFixed(1);
  const inList = isInList(item.id);

  return (
    <div className="cursor-pointer group relative rounded-xl overflow-hidden bg-nova-card">
      <div
        onClick={() => navigate("/watch", { state: { media: item } })}
        className="aspect-[2/3] overflow-hidden"
      >
        {item.poster_path ? (
          <img
            src={`${TMDB_POSTER}${item.poster_path}`}
            alt={title}
            className="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
          />
        ) : (
          <div className="w-full h-full flex items-center justify-center text-gray-600 text-xs p-2 text-center">
            {title}
          </div>
        )}
        
        {/* Voortgangsbalk */}
        {item.current_time > 0 && item.duration > 0 && (
          <div className="absolute bottom-0 left-0 right-0 h-1 bg-gray-700 rounded-b-xl">
            <div className="h-full bg-nova-accent rounded-b-xl" style={{ width: `${Math.round((item.current_time / item.duration) * 100)}%` }} />
          </div>
        )}

        <div className="absolute inset-0 bg-black/0 group-hover:bg-black/40 transition-colors rounded-xl" />
      </div>

      {/* Watchlist knop */}
      <button
        onClick={(e) => { e.stopPropagation(); toggleWatchlist(item); }}
        className={`absolute top-2 right-2 w-7 h-7 rounded-full flex items-center justify-center text-xs font-bold shadow-lg transition-all opacity-0 group-hover:opacity-100 ${inList ? "bg-nova-accent text-white" : "bg-black/70 text-white hover:bg-nova-accent"}`}
      >
        {inList ? "✓" : "+"}
      </button>

      <div className="mt-2 px-1 pb-1">
        <p className="text-sm font-semibold truncate">{title}</p>
        <div className="flex items-center gap-2 text-xs text-gray-400 mt-0.5">
          {year && <span>{year}</span>}
          {rating && <span className="text-yellow-400">★ {rating}</span>}
        </div>
      </div>
    </div>
  );
}
