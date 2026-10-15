import { useState } from "react";
import TrailerFrame from "./TrailerFrame";

const TMDB_BACKDROP = "https://image.tmdb.org/t/p/w1280";
const TMDB_LOGO = "https://image.tmdb.org/t/p/w500";

// Laadscherm zoals op de tv (LoadingOverlay.kt): donkere achtergrond met backdrop + scrim,
// gecentreerd clear-logo dat zacht inzoomt/pulseert en de statusmelding eronder. Extra: de
// backdrop zoomt langzaam (Ken Burns) en - als er een trailer is - speelt die stil en
// gedimd op de achtergrond: de "licht geanimeerde versie van de film" tijdens het laden.
export default function StreamLoadingOverlay({ backdropPath, logoPath, title, message, trailerKey, onCancel, leaving = false }) {
  const [trailerReady, setTrailerReady] = useState(false);
  const [trailerFailed, setTrailerFailed] = useState(false);
  const [logoFailed, setLogoFailed] = useState(false);
  const showTrailer = trailerKey && !trailerFailed;

  return (
    <div className={`fixed inset-0 z-[80] bg-black animate-[nova-fade-in_250ms_ease-out] transition-opacity duration-300 ${leaving ? "opacity-0 pointer-events-none" : ""}`}>
      {backdropPath && (
        <img
          src={`${TMDB_BACKDROP}${backdropPath}`}
          alt=""
          className={`absolute inset-0 w-full h-full object-cover animate-[nova-kenburns_24s_ease-out_forwards] transition-opacity duration-[1200ms] ${trailerReady ? "opacity-0" : "opacity-100"}`}
        />
      )}
      {showTrailer && (
        <TrailerFrame
          videoKey={trailerKey}
          visible={trailerReady}
          onPlaying={() => setTrailerReady(true)}
          onError={() => setTrailerFailed(true)}
        />
      )}
      <div
        className="absolute inset-0"
        style={{
          background:
            "linear-gradient(to bottom, rgba(0,0,0,.30) 0%, rgba(0,0,0,.60) 35%, rgba(0,0,0,.80) 70%, rgba(0,0,0,.90) 100%)",
        }}
      />

      <div className="absolute inset-0 flex flex-col items-center justify-center px-6">
        <div className="w-80 max-w-full h-44 flex items-center justify-center animate-[nova-logo-pulse_4s_linear_infinite]">
          {logoPath && !logoFailed ? (
            <img
              src={`${TMDB_LOGO}${logoPath}`}
              alt={title}
              onError={() => setLogoFailed(true)}
              className="max-w-full max-h-full object-contain opacity-0 animate-[nova-fade-in_700ms_linear_400ms_forwards] drop-shadow-[0_4px_24px_rgba(0,0,0,0.6)]"
            />
          ) : title ? (
            <h2 className="text-2xl font-semibold text-white text-center line-clamp-2 opacity-0 animate-[nova-fade-in_700ms_linear_400ms_forwards]">
              {title}
            </h2>
          ) : (
            <div className="w-16 h-16 border-2 border-white/30 border-t-white rounded-full animate-spin" />
          )}
        </div>
        <p key={message} className="mt-3 h-10 text-xs text-white/70 text-center max-w-md line-clamp-2 animate-[nova-fade-in_260ms_ease-out]">
          {message}
        </p>
      </div>

      {onCancel && (
        <button
          onClick={onCancel}
          className="absolute bottom-10 left-1/2 -translate-x-1/2 px-5 py-2 rounded-full text-sm text-white/80 hover:text-white bg-white/10 hover:bg-white/20 border border-white/15 transition-colors"
        >
          Annuleren
        </button>
      )}
    </div>
  );
}
