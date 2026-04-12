import { useState, useEffect, useRef } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import Player from "../components/Player";
import Row from "../components/Row";
import { useUserData } from "../context/UserDataContext";

const TMDB_POSTER = "https://image.tmdb.org/t/p/w342";
const TMDB_PROFILE = "https://image.tmdb.org/t/p/w185";
const TMDB_BACKDROP = "https://image.tmdb.org/t/p/original";
const TMDB_STILL = "https://image.tmdb.org/t/p/w300";

export default function Watch() {
  const { state } = useLocation();
  const navigate = useNavigate();
  const media = state?.media;

  const type = media?.media_type || (media?.name ? "tv" : "movie");
  const isMovie = type === "movie";

  const [streamUrl, setStreamUrl] = useState(null);
  const [loading, setLoading] = useState(false);
  const [status, setStatus] = useState("");
  const [cast, setCast] = useState([]);
  const [similar, setSimilar] = useState([]);
  const [detail, setDetail] = useState(null);
  const [isAvailable, setIsAvailable] = useState(null); // null = checking, true/false = result

  // Serie: seizoen/aflevering
  const [selectedSeason, setSelectedSeason] = useState(1);
  const [seasonData, setSeasonData] = useState(null);
  const [loadingSeason, setLoadingSeason] = useState(false);
  const [selectedEpisode, setSelectedEpisode] = useState(null);
  const [requestStatus, setRequestStatus] = useState(null); // null, "loading", "waiting", "done", "error"
  const [requestMessage, setRequestMessage] = useState("");
  const [startAt, setStartAt] = useState(0);
  const [durationHint, setDurationHint] = useState(0);
  const [progressItem, setProgressItem] = useState(null);
  const pollRef = useRef(null);
  const searchAbortRef = useRef(null);
  const requestKeyRef = useRef(null);

  const { toggleWatchlist, isInList, saveProgress, progress, progressMap } = useUserData();
  const inList = isInList(media?.id);
  const savedProgress = progress.find(p => p.id === media?.id);

  const title = media?.title || media?.name;
  const year = (media?.release_date || media?.first_air_date || "").slice(0, 4);
  const rating = media?.vote_average?.toFixed(1);
  const backdrop = media?.backdrop_path ? `${TMDB_BACKDROP}${media.backdrop_path}` : null;

  useEffect(() => {
    if (!media) return;
    
    // Als we alleen een filename hebben (RD item), eerst zoeken naar TMDB match
    if (!media.id || typeof media.id === 'string') {
      const name = media.filename || media.title || media.name;
      fetch(`/api/search/movie?q=${encodeURIComponent(name)}`)
        .then(r => r.json())
        .then(data => {
          if (data.items?.length > 0) {
            navigate("/watch", { state: { media: data.items[0] }, replace: true });
          } else {
            setStatus("Geen metadata gevonden.");
          }
        })
        .catch(() => setStatus("Fout bij laden van metadata."));
      return;
    }

    fetch(`/api/search/${type}/${media.id}/credits`).then(r => r.json()).then(setCast).catch(() => {});
    fetch(`/api/search/${type}/${media.id}/similar`).then(r => r.json()).then(setSimilar).catch(() => {});
    fetch(`/api/search/${type}/${media.id}`).then(r => r.json()).then(setDetail).catch(() => {});
    
    // Check RD availability
    const searchTitle = `${title} ${year}`;
    fetch(`/api/debrid/check?q=${encodeURIComponent(searchTitle)}`)
      .then(r => r.json())
      .then(data => setIsAvailable(data.available))
      .catch(() => setIsAvailable(false));
  }, [media?.id]);

  useEffect(() => {
    return () => {
      if (pollRef.current) clearInterval(pollRef.current);
      if (searchAbortRef.current) searchAbortRef.current.abort();
    };
  }, []);

  // Laad seizoendata als serie
  useEffect(() => {
    if (isMovie || !media) return;
    setLoadingSeason(true);
    setSelectedEpisode(null);
    fetch(`/api/search/tv/${media.id}/season/${selectedSeason}`)
      .then(r => r.json())
      .then(d => { setSeasonData(d); setLoadingSeason(false); })
      .catch(() => setLoadingSeason(false));
  }, [media?.id, selectedSeason, isMovie]);

  useEffect(() => {
    if (!streamUrl) return;
    const metaUrl = streamUrl
      .replace("/stream/hls", "/stream/meta")
      .replace("/stream/play", "/stream/meta");
    fetch(metaUrl)
      .then(r => r.ok ? r.json() : null)
      .then(data => {
        const d = Number(data?.duration) || 0;
        if (d > 0) setDurationHint(d);
      })
      .catch(() => {});
  }, [streamUrl]);

  if (!media) { navigate("/"); return null; }

  const episodeKey = (seasonNumber, episodeNumber) => `tv:${media.id}:S${seasonNumber}E${episodeNumber}`;
  const getEpisodeProgress = (seasonNumber, episodeNumber) => progressMap?.[episodeKey(seasonNumber, episodeNumber)] || null;

  const getLatestEpisode = () => {
    if (isMovie) return null;
    const eps = progress.filter(p => p.show_id === media.id && p.media_type === "tv_episode");
    if (eps.length === 0) return null;
    const latest = eps[eps.length - 1]; // Assume last is the most recent
    if ((latest.current_time / latest.duration) >= 0.95) {
      // Return next episode theoretically, but we don't know it here without seasonData.
      // So let's just return it or nothing.
      return null;
    }
    return {
      season_number: latest.season_number,
      episode_number: latest.episode_number,
      episode: { id: latest.id, episode_number: latest.episode_number } // Minimal object needed for handlePlay
    };
  };

  async function handlePlay(episodeInfo = null, overrideSeason = null) {
    if (pollRef.current) clearInterval(pollRef.current);
    if (searchAbortRef.current) searchAbortRef.current.abort();
    searchAbortRef.current = new AbortController();

    const targetSeason = overrideSeason !== null ? overrideSeason : selectedSeason;

    const reqKey = episodeInfo ? `${type}:${media.id}:S${targetSeason}` : `${type}:${media.id}`;
    if (requestKeyRef.current !== reqKey) {
      setRequestStatus(null);
      setRequestMessage("");
    }
    setLoading(true);
    const searchTitle = episodeInfo
      ? `${title} S${String(targetSeason).padStart(2,"0")}E${String(episodeInfo.episode_number).padStart(2,"0")}`
      : `${title} ${year}`;
    
    setStatus(`Zoeken naar "${searchTitle}"...`);

    try {
      // Stap 1: Zoek stream (Backend doet nu library + scraper check)
      const r = await fetch(`/api/debrid/search?q=${encodeURIComponent(searchTitle)}`, { signal: searchAbortRef.current.signal });
      const data = await r.json();
      
      if (!data.stream_url) {
        setStatus("Niet meteen beschikbaar. Ik vraag dit automatisch aan en wacht tot het klaar is...");
        const alreadyRequesting = (requestStatus === "loading" || requestStatus === "waiting") && requestKeyRef.current === reqKey;
        const requested = alreadyRequesting ? true : await handleRequest(reqKey);
        if (!requested) {
          setStatus(data.message || "Geen stream gevonden.");
          setLoading(false);
          return;
        }

        const startedAt = Date.now();
        const poll = async () => {
          try {
            const ms = await fetch(`/api/seerr/media-status?tmdb_id=${media.id}&media_type=${type}`).then(r => r.json());
            if (ms.ok) {
              const dl = ms.download_status ? ` · ${ms.download_status}` : "";
              setRequestMessage(`${ms.status_label || "Seerr status"}${dl}`);
            }
          } catch {}

          try {
            const rr = await fetch(`/api/debrid/search?q=${encodeURIComponent(searchTitle)}`).then(r => r.json());
            if (rr.stream_url) {
              let finalUrl = rr.stream_url;
              if (finalUrl.startsWith("/")) finalUrl = window.location.origin + finalUrl;
              let resumeTime = 0;
              let resumeDuration = 0;
              let nextProgressItem = media;
              if (!isMovie && episodeInfo) {
                const epProg = getEpisodeProgress(targetSeason, episodeInfo.episode_number);
                resumeTime = epProg?.current_time || 0;
                resumeDuration = epProg?.duration || 0;
                nextProgressItem = {
                  ...media,
                  id: episodeKey(targetSeason, episodeInfo.episode_number),
                  media_type: "tv_episode",
                  show_id: media.id,
                  season_number: targetSeason,
                  episode_number: episodeInfo.episode_number,
                  title: `${title} S${String(targetSeason).padStart(2,"0")}E${String(episodeInfo.episode_number).padStart(2,"0")}`,
                };
              } else if (isMovie) {
                resumeTime = savedProgress?.current_time || 0;
                resumeDuration = savedProgress?.duration || 0;
                nextProgressItem = media;
              }

              const doResume = resumeTime > 10;
              const urlWithStart = doResume
                ? `${finalUrl}${finalUrl.includes("?") ? "&" : "?"}start=${encodeURIComponent(resumeTime)}`
                : finalUrl;
              setStartAt(doResume ? resumeTime : 0);
              setDurationHint(resumeDuration || 0);
              setStreamUrl(urlWithStart);
              setProgressItem(nextProgressItem);
              setStatus("");
              setLoading(false);
              if (pollRef.current) clearInterval(pollRef.current);
            } else {
              const minutes = Math.floor((Date.now() - startedAt) / 60000);
              setStatus(`Wachten op download... (${minutes} min)`);
              if (Date.now() - startedAt > 45 * 60000) {
                setStatus(rr.message || "Duurt langer dan verwacht. Probeer later opnieuw.");
                setLoading(false);
                if (pollRef.current) clearInterval(pollRef.current);
              }
            }
          } catch {}
        };

        await poll();
        pollRef.current = setInterval(poll, 8000);
        return;
      }

      if (data.source === "scraper") {
        setStatus(`Gevonden op internet: ${data.title || searchTitle}. Laden...`);
      } else if (data.source === "local") {
        setStatus(`Gevonden op Dumbarr mount: ${data.title || searchTitle}. Starten...`);
      } else {
        setStatus("Gevonden in bibliotheek. Starten...");
      }

      let finalUrl = data.stream_url;
      // Als de URL relatief is, maak hem absoluut zodat de speler hem beter snapt
      if (finalUrl.startsWith("/")) {
        finalUrl = window.location.origin + finalUrl;
      }
      let resumeTime = 0;
      let resumeDuration = 0;
      let nextProgressItem = media;
      if (!isMovie && episodeInfo) {
        const epProg = getEpisodeProgress(targetSeason, episodeInfo.episode_number);
        resumeTime = epProg?.current_time || 0;
        resumeDuration = epProg?.duration || 0;
        nextProgressItem = {
          ...media,
          id: episodeKey(targetSeason, episodeInfo.episode_number),
          media_type: "tv_episode",
          show_id: media.id,
          season_number: targetSeason,
          episode_number: episodeInfo.episode_number,
          title: `${title} S${String(targetSeason).padStart(2,"0")}E${String(episodeInfo.episode_number).padStart(2,"0")}`,
        };
      } else if (isMovie) {
        resumeTime = savedProgress?.current_time || 0;
        resumeDuration = savedProgress?.duration || 0;
        nextProgressItem = media;
      }

      const doResume = resumeTime > 10;
      const urlWithStart = doResume
        ? `${finalUrl}${finalUrl.includes("?") ? "&" : "?"}start=${encodeURIComponent(resumeTime)}`
        : finalUrl;
      setStartAt(doResume ? resumeTime : 0);
      setDurationHint(resumeDuration || 0);
      setStreamUrl(urlWithStart);
      setProgressItem(nextProgressItem);
      setStatus("");
    } catch (e) {
      console.error(e);
      setStatus("Fout bij het zoeken naar streams. Controleer je verbinding.");
    }
    setLoading(false);
  }

  async function handleRequest(reqKey) {
    setRequestStatus("loading");
    setRequestMessage("Aanvragen via Seerr...");
    requestKeyRef.current = reqKey || null;
    try {
      const payload = {
        media_id: media.id,
        media_type: type,
        seasons: !isMovie ? [selectedSeason] : []
      };
      const r = await fetch("/api/seerr/request", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload)
      });
      const data = await r.json();
      if (data.ok) {
        setRequestStatus("waiting");
        setRequestMessage(data.message || "Aangevraagd. Download start binnenkort...");
        return true;
      } else {
        setRequestStatus("error");
        setRequestMessage(data.message || "Fout bij indienen verzoek.");
        return false;
      }
    } catch (e) {
      setRequestStatus("error");
      setRequestMessage("Kon geen verbinding maken met Seerr.");
      return false;
    }
  }

  const runtime = detail?.runtime ? `${Math.floor(detail.runtime / 60)}u ${detail.runtime % 60}m` : null;
  const seasons = detail?.seasons?.filter(s => s.season_number > 0) || [];

  const handleNext = async () => {
    if (isMovie) return;

    const currentSeasonNum = progressItem?.season_number ?? selectedSeason;
    const currentEpisodeNum = progressItem?.episode_number ?? selectedEpisode?.episode_number;
    if (!currentSeasonNum || !currentEpisodeNum) return;

    let activeSeasonData = seasonData;
    if (!activeSeasonData?.episodes?.length || selectedSeason !== currentSeasonNum) {
      try {
        const r = await fetch(`/api/search/tv/${media.id}/season/${currentSeasonNum}`);
        const d = await r.json();
        activeSeasonData = d;
        setSeasonData(d);
        setSelectedSeason(currentSeasonNum);
      } catch (e) {
        activeSeasonData = null;
      }
    }

    if (!activeSeasonData?.episodes?.length) return;

    const currentIdx = activeSeasonData.episodes.findIndex(ep => ep.episode_number === currentEpisodeNum);
    if (currentIdx >= 0 && currentIdx < activeSeasonData.episodes.length - 1) {
      const nextEp = activeSeasonData.episodes[currentIdx + 1];
      setSelectedSeason(currentSeasonNum);
      setSelectedEpisode(nextEp);
      handlePlay(nextEp, currentSeasonNum);
      return;
    }

    const nextSeasonNum = currentSeasonNum + 1;
    const hasNextSeason = seasons.some(s => s.season_number === nextSeasonNum);
    if (!hasNextSeason) {
      setStreamUrl(null);
      return;
    }

    setStatus("Volgende seizoen laden...");
    setSelectedSeason(nextSeasonNum);
    try {
      const r = await fetch(`/api/search/tv/${media.id}/season/${nextSeasonNum}`);
      const d = await r.json();
      if (d.episodes && d.episodes.length > 0) {
        const nextEp = d.episodes[0];
        setSeasonData(d);
        setSelectedEpisode(nextEp);
        handlePlay(nextEp, nextSeasonNum);
      } else {
        setStreamUrl(null);
      }
    } catch (e) {
      setStreamUrl(null);
    }
  };

  const handleEnded = async () => {
    await handleNext();
  };

  const currentSeasonNum = progressItem?.season_number ?? selectedSeason;
  const currentEpisodeNum = progressItem?.episode_number ?? selectedEpisode?.episode_number;
  const maxSeasonNum = seasons.reduce((m, s) => Math.max(m, s.season_number), 0);
  const idxInSeason = (!isMovie && currentEpisodeNum && seasonData?.episodes?.length && selectedSeason === currentSeasonNum)
    ? seasonData.episodes.findIndex(ep => ep.episode_number === currentEpisodeNum)
    : -1;
  const hasNext = !isMovie && !!currentSeasonNum && !!currentEpisodeNum && (
    currentSeasonNum < maxSeasonNum ||
    (idxInSeason >= 0 && idxInSeason < (seasonData?.episodes?.length || 0) - 1)
  );

  return (
    <div className="min-h-screen bg-nova-bg">
      {backdrop && !streamUrl && (
        <div className="relative w-full h-[45vh] md:h-[55vh] overflow-hidden">
          <img src={backdrop} alt={title} className="w-full h-full object-cover object-top" />
          <div className="absolute inset-0 bg-gradient-to-t from-nova-bg via-nova-bg/40 to-black/30" />
          <div className="absolute inset-0 bg-gradient-to-r from-nova-bg/60 to-transparent" />
        </div>
      )}

      <div className={`px-4 md:px-10 pb-20 ${streamUrl ? "pt-6" : "-mt-32 relative z-10"}`}>
        <button onClick={() => navigate(-1)} className="text-gray-400 hover:text-white text-sm mb-6 flex items-center gap-1">
          ← Terug
        </button>

        {streamUrl && (
          <div className="mb-10">
            <Player url={streamUrl} media={progressItem || media} startAt={startAt} durationHint={durationHint} onProgress={(t, d) => saveProgress(progressItem || media, t, d)} onEnded={handleEnded} onNext={hasNext ? handleNext : null} />
            <div className="mt-4 flex flex-wrap items-center gap-4">
              <button onClick={() => { setStreamUrl(null); setStatus(""); setStartAt(0); setDurationHint(0); }} className="text-sm text-gray-500 hover:text-white flex items-center gap-1">
                ← Terug naar info
              </button>
            </div>

            {!isMovie && seasons.length > 0 && (
              <div className="mt-8">
                <div className="flex items-center gap-4 mb-5 flex-wrap">
                  <h2 className="text-lg font-bold">Afleveringen</h2>
                  <div className="relative">
                    <select
                      value={selectedSeason}
                      onChange={e => setSelectedSeason(Number(e.target.value))}
                      className="appearance-none bg-nova-card border border-gray-700 text-white px-4 py-2 pr-8 rounded-xl text-sm font-medium focus:outline-none focus:border-nova-accent cursor-pointer"
                    >
                      {seasons.map(s => (
                        <option key={s.season_number} value={s.season_number}>
                          Seizoen {s.season_number}{s.episode_count ? ` (${s.episode_count} afl.)` : ""}
                        </option>
                      ))}
                    </select>
                    <span className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 text-gray-400 text-xs">▼</span>
                  </div>
                </div>

                {loadingSeason ? (
                  <div className="space-y-3">
                    {Array.from({ length: 5 }).map((_, i) => (
                      <div key={i} className="h-24 rounded-xl bg-nova-card animate-pulse" />
                    ))}
                  </div>
                ) : (
                  <div className="space-y-2">
                    {(seasonData?.episodes || []).map(ep => {
                      const epProg = getEpisodeProgress(selectedSeason, ep.episode_number);
                      const progressPct = epProg && epProg.duration > 0 ? (epProg.current_time / epProg.duration) * 100 : 0;
                      const watched = progressPct >= 95;
                      return (
                        <div
                          key={ep.id}
                          onClick={() => { setSelectedEpisode(ep); handlePlay(ep); }}
                          className={`flex gap-4 p-3 rounded-xl cursor-pointer transition-all border group ${
                            selectedEpisode?.id === ep.id ? "border-nova-accent bg-nova-accent/10" : "border-transparent hover:border-gray-700 hover:bg-nova-card"
                          } ${watched ? "opacity-70" : ""}`}
                        >
                          <div className={`flex-shrink-0 w-10 flex items-center justify-center font-bold text-lg group-hover:text-white transition-colors ${watched ? "text-green-400" : "text-gray-500"}`}>
                            {watched ? "✓" : ep.episode_number}
                          </div>

                          <div className="flex-shrink-0 w-36 aspect-video rounded-lg overflow-hidden bg-nova-bg relative">
                            {ep.still_path ? (
                              <img src={`${TMDB_STILL}${ep.still_path}`} alt={ep.name} className={`w-full h-full object-cover group-hover:scale-105 transition-transform duration-300 ${watched ? "grayscale" : ""}`} />
                            ) : (
                              <div className={`w-full h-full flex items-center justify-center text-2xl group-hover:text-nova-accent transition-colors ${watched ? "text-gray-600" : "text-gray-700"}`}>▶</div>
                            )}
                            {watched && (
                              <div className="absolute inset-0 bg-black/30 flex items-center justify-center pointer-events-none">
                                <div className="text-green-400 text-5xl font-black drop-shadow">✓</div>
                              </div>
                            )}
                            {progressPct > 0 && (
                              <div className="absolute bottom-0 left-0 right-0 h-1 bg-gray-700">
                                <div className="h-full bg-nova-accent" style={{ width: `${progressPct}%` }} />
                              </div>
                            )}
                          </div>

                          <div className="flex-1 min-w-0 py-1">
                            <div className="flex items-start justify-between gap-2 mb-1">
                              <p className="font-semibold text-sm leading-tight">{ep.name}</p>
                              {ep.runtime && <span className="flex-shrink-0 text-xs text-gray-500">{ep.runtime}m</span>}
                            </div>
                            <p className="text-xs text-gray-500 line-clamp-2 leading-relaxed">{ep.overview}</p>
                          </div>

                          <div className="flex-shrink-0 flex items-center pr-1">
                            <div className="w-9 h-9 rounded-full bg-white/0 group-hover:bg-nova-accent/20 border border-transparent group-hover:border-nova-accent flex items-center justify-center transition-all">
                              <span className="text-white/0 group-hover:text-nova-accent text-sm transition-colors">▶</span>
                            </div>
                          </div>
                        </div>
                      );
                    })}
                  </div>
                )}
              </div>
            )}
          </div>
        )}

        {/* Info sectie */}
        {!streamUrl && (
          <>
            <div className="flex gap-5 md:gap-8 mb-10">
              {media.poster_path && (
                <img src={`${TMDB_POSTER}${media.poster_path}`} alt={title} className="w-28 md:w-40 rounded-xl flex-shrink-0 shadow-2xl" />
              )}
              <div className="flex-1 min-w-0">
                <h1 className="text-2xl md:text-4xl font-black mb-2 leading-tight">{title}</h1>
                <div className="flex flex-wrap items-center gap-2 md:gap-3 mb-4 text-sm text-gray-400">
                  {year && <span className="text-gray-300">{year}</span>}
                  {rating && <span className="text-yellow-400 font-semibold">★ {rating}</span>}
                  {runtime && <span>{runtime}</span>}
                  {seasons.length > 0 && (
                    <span className="text-gray-300">{seasons.length} seizoen{seasons.length > 1 ? "en" : ""}</span>
                  )}
                  {detail?.genres?.map(g => (
                    <span key={g.id} className="border border-gray-600 px-2 py-0.5 rounded-full text-xs text-gray-300">{g.name}</span>
                  ))}
                </div>
                <p className="text-gray-300 text-sm md:text-base leading-relaxed mb-6 max-w-2xl">{media.overview}</p>

                {/* Knoppen voor films en series */}
                <div className="flex flex-wrap gap-3 items-center">
                  {(isMovie || getLatestEpisode()) && (
                    <button
                      onClick={() => {
                        if (isMovie) {
                          handlePlay();
                        } else {
                          const latest = getLatestEpisode();
                          if (latest) {
                            setSelectedSeason(latest.season_number);
                            setSelectedEpisode(latest.episode);
                            handlePlay(latest.episode, latest.season_number);
                          }
                        }
                      }}
                      disabled={loading}
                      className={`flex items-center gap-3 font-bold px-8 py-3 rounded-xl transition-all disabled:opacity-60 ${isAvailable || !isMovie ? "bg-nova-accent text-white shadow-lg shadow-nova-accent/20" : "bg-white text-black hover:bg-gray-200"}`}
                    >
                      {loading ? <span className="animate-spin">⟳</span> : "▶"}
                      {loading ? "Laden..." : (isMovie ? (savedProgress ? "Hervatten" : "Afspelen") : `Hervatten S${getLatestEpisode()?.season_number}E${getLatestEpisode()?.episode_number}`)}
                    </button>
                  )}
                  <button
                    onClick={() => toggleWatchlist(media)}
                    className={`flex items-center gap-2 px-5 py-3 rounded-xl font-semibold border transition-colors ${inList ? "bg-nova-accent/20 border-nova-accent text-nova-accent" : "bg-nova-card border-gray-600 text-white hover:border-white"}`}
                  >
                    {inList ? "✓ In watchlist" : "+ Watchlist"}
                  </button>
                  {isMovie && savedProgress && (
                    <span className="text-sm text-gray-400">
                      Gestopt op {Math.floor(savedProgress.current_time / 60)}:{String(Math.floor(savedProgress.current_time % 60)).padStart(2, "0")}
                    </span>
                  )}
                </div>
                
                {isMovie && isAvailable !== null && (
                  <div className={`mt-4 flex flex-col gap-3 text-sm`}>
                    <div className={`flex items-center gap-2 ${isAvailable ? "text-nova-accent" : "text-orange-400"}`}>
                      <span>{isAvailable ? "✓" : "!"}</span>
                      <span>{isAvailable ? "Beschikbaar in je Real-Debrid bibliotheek" : "Niet gevonden in je bibliotheek."}</span>
                    </div>
                    {requestMessage && (
                      <p className={`text-xs p-2 rounded bg-nova-card border ${
                        requestStatus === "done" ? "text-green-400 border-green-900/50" : 
                        requestStatus === "error" ? "text-red-400 border-red-900/50" : "text-gray-400 border-gray-800"
                      }`}>
                        {requestMessage}
                      </p>
                    )}
                  </div>
                )}
                {status && <p className="text-sm text-nova-accent animate-pulse mt-3">{status}</p>}
              </div>
            </div>

            {/* Seizoenen & afleveringen */}
            {!isMovie && seasons.length > 0 && (
              <div className="mb-10">
                {/* Seizoen dropdown + afleveringen */}
                <div className="flex items-center gap-4 mb-5 flex-wrap">
                  <h2 className="text-xl font-bold">Afleveringen</h2>
                  <div className="relative">
                    <select
                      value={selectedSeason}
                      onChange={e => setSelectedSeason(Number(e.target.value))}
                      className="appearance-none bg-nova-card border border-gray-700 text-white px-4 py-2 pr-8 rounded-xl text-sm font-medium focus:outline-none focus:border-nova-accent cursor-pointer"
                    >
                      {seasons.map(s => (
                        <option key={s.season_number} value={s.season_number}>
                          Seizoen {s.season_number}{s.episode_count ? ` (${s.episode_count} afl.)` : ""}
                        </option>
                      ))}
                    </select>
                    <span className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 text-gray-400 text-xs">▼</span>
                  </div>
                </div>

                {/* Afleveringen lijst */}
                {loadingSeason ? (
                  <div className="space-y-3">
                    {Array.from({ length: 5 }).map((_, i) => (
                      <div key={i} className="h-24 rounded-xl bg-nova-card animate-pulse" />
                    ))}
                  </div>
                ) : (
                  <div className="space-y-2">
                    {(seasonData?.episodes || []).map(ep => {
                      const epProg = getEpisodeProgress(selectedSeason, ep.episode_number);
                      const progressPct = epProg && epProg.duration > 0 ? (epProg.current_time / epProg.duration) * 100 : 0;
                      const watched = progressPct >= 95;
                      return (
                      <div
                        key={ep.id}
                        onClick={() => { setSelectedEpisode(ep); handlePlay(ep); }}
                        className={`flex gap-4 p-3 rounded-xl cursor-pointer transition-all border group ${selectedEpisode?.id === ep.id ? "border-nova-accent bg-nova-accent/10" : "border-transparent hover:border-gray-700 hover:bg-nova-card"} ${watched ? "opacity-70" : ""}`}
                      >
                        {/* Nummer */}
                        <div className={`flex-shrink-0 w-10 flex items-center justify-center font-bold text-lg group-hover:text-white transition-colors ${watched ? "text-green-400" : "text-gray-500"}`}>
                          {watched ? "✓" : ep.episode_number}
                        </div>

                        {/* Thumbnail */}
                        <div className="flex-shrink-0 w-36 aspect-video rounded-lg overflow-hidden bg-nova-bg relative">
                          {ep.still_path ? (
                            <img src={`${TMDB_STILL}${ep.still_path}`} alt={ep.name} className={`w-full h-full object-cover group-hover:scale-105 transition-transform duration-300 ${watched ? "grayscale" : ""}`} />
                          ) : (
                            <div className={`w-full h-full flex items-center justify-center text-2xl group-hover:text-nova-accent transition-colors ${watched ? "text-gray-600" : "text-gray-700"}`}>▶</div>
                          )}
                          {watched && (
                            <div className="absolute inset-0 bg-black/30 flex items-center justify-center pointer-events-none">
                              <div className="text-green-400 text-5xl font-black drop-shadow">✓</div>
                            </div>
                          )}
                          {progressPct > 0 && (
                            <div className="absolute bottom-0 left-0 right-0 h-1 bg-gray-700">
                              <div className="h-full bg-nova-accent" style={{ width: `${progressPct}%` }} />
                            </div>
                          )}
                        </div>

                        {/* Info */}
                        <div className="flex-1 min-w-0 py-1">
                          <div className="flex items-start justify-between gap-2 mb-1">
                            <p className="font-semibold text-sm leading-tight">{ep.name}</p>
                            {ep.runtime && <span className="flex-shrink-0 text-xs text-gray-500">{ep.runtime}m</span>}
                          </div>
                          <p className="text-xs text-gray-500 line-clamp-2 leading-relaxed">{ep.overview}</p>
                        </div>

                        {/* Play knop */}
                        <div className="flex-shrink-0 flex items-center pr-1">
                          <div className="w-9 h-9 rounded-full bg-white/0 group-hover:bg-nova-accent/20 border border-transparent group-hover:border-nova-accent flex items-center justify-center transition-all">
                            <span className="text-white/0 group-hover:text-nova-accent text-sm transition-colors">▶</span>
                          </div>
                        </div>
                      </div>
                      );
                    })}
                  </div>
                )}
                {status && <p className="text-sm text-nova-accent animate-pulse mt-4">{status}</p>}
                {!isMovie && requestMessage && (
                  <p className={`mt-4 text-xs p-2 rounded bg-nova-card border w-fit ${
                    requestStatus === "done" ? "text-green-400 border-green-900/50" : 
                    requestStatus === "error" ? "text-red-400 border-red-900/50" : "text-gray-400 border-gray-800"
                  }`}>
                    {requestMessage}
                  </p>
                )}
              </div>
            )}
          </>
        )}

        {/* Cast */}
        {cast.length > 0 && (
          <div className="mb-10">
            <h2 className="text-xl md:text-2xl font-bold mb-4">Cast</h2>
            <div className="flex gap-4 overflow-x-auto pb-3" style={{ scrollbarWidth: "none" }}>
              {cast.map(person => (
                <div key={person.id} className="flex-shrink-0 w-24 md:w-28 text-center">
                  <div className="w-24 h-24 md:w-28 md:h-28 rounded-full overflow-hidden bg-nova-card mx-auto mb-2 border-2 border-gray-700">
                    {person.profile_path ? (
                      <img src={`${TMDB_PROFILE}${person.profile_path}`} alt={person.name} className="w-full h-full object-cover" />
                    ) : (
                      <div className="w-full h-full flex items-center justify-center text-2xl text-gray-600">👤</div>
                    )}
                  </div>
                  <p className="text-xs md:text-sm font-semibold leading-tight">{person.name}</p>
                  <p className="text-xs text-gray-500 mt-0.5 leading-tight truncate">{person.character}</p>
                </div>
              ))}
            </div>
          </div>
        )}

        {similar.length > 0 && <Row title="Meer zoals dit" items={similar} />}
      </div>
    </div>
  );
}
