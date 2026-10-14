import { useState } from "react";
import { useUserData } from "../context/UserDataContext";

/** 1-3 sterren, zelfde schaal als de tv-app (geen 5-sterren TMDB-stijl, dit is de
 * persoonlijke "hoe goed vond ik dit"-rating). Klik dezelfde ster nog eens om te wissen. */
export default function StarRating({ item, size = "text-2xl" }) {
  const { getRating, setRating, clearRating } = useUserData();
  const [hover, setHover] = useState(0);
  const current = getRating(item.id);
  const display = hover || current;

  function handleClick(stars) {
    if (stars === current) clearRating(item);
    else setRating(item, stars);
  }

  return (
    <div className="flex items-center gap-1" onMouseLeave={() => setHover(0)}>
      {[1, 2, 3].map((n) => (
        <button
          key={n}
          onClick={() => handleClick(n)}
          onMouseEnter={() => setHover(n)}
          className={`${size} leading-none transition-colors ${n <= display ? "text-yellow-400" : "text-gray-600 hover:text-gray-400"}`}
          aria-label={`${n} ster${n > 1 ? "ren" : ""}`}
        >
          ★
        </button>
      ))}
    </div>
  );
}
