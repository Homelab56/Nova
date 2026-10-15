import { createContext, useContext, useState, useEffect, useCallback, useRef } from "react";
import { useProfile } from "./ProfileContext";

const UserDataContext = createContext(null);

export function UserDataProvider({ children }) {
  const { selectedProfileId, authedFetch } = useProfile();
  const [watchlist, setWatchlist] = useState([]);
  const [progress, setProgress] = useState([]);
  const [ratings, setRatings] = useState({});
  const [suggestions, setSuggestions] = useState({ movies: [], tv: [] });

  const refreshWatchlist = useCallback(() => {
    if (!selectedProfileId) {
      setWatchlist([]);
      return;
    }
    authedFetch(`/profiles/${selectedProfileId}/watchlist`)
      .then((r) => (r.ok ? r.json() : []))
      .then(setWatchlist)
      .catch(() => setWatchlist([]));
  }, [selectedProfileId, authedFetch]);

  // Een trage, oudere respons mag een nieuwere nooit overschrijven (de lijst sprong anders
  // heen en weer terwijl er om de paar seconden voortgang werd opgeslagen), en een
  // mislukte fetch wist de lijst niet meer.
  const progressSeq = useRef(0);
  const refreshProgress = useCallback(() => {
    if (!selectedProfileId) {
      setProgress([]);
      return;
    }
    const seq = ++progressSeq.current;
    authedFetch(`/profiles/${selectedProfileId}/progress`)
      .then((r) => (r.ok ? r.json() : null))
      .then((data) => {
        if (seq === progressSeq.current && Array.isArray(data)) setProgress(data);
      })
      .catch(() => {});
  }, [selectedProfileId, authedFetch]);

  const progressRefreshTimer = useRef(null);
  const refreshProgressSoon = useCallback(() => {
    clearTimeout(progressRefreshTimer.current);
    progressRefreshTimer.current = setTimeout(refreshProgress, 20000);
  }, [refreshProgress]);

  const refreshRatings = useCallback(() => {
    if (!selectedProfileId) {
      setRatings({});
      return;
    }
    authedFetch(`/profiles/${selectedProfileId}/ratings`)
      .then((r) => (r.ok ? r.json() : {}))
      .then(setRatings)
      .catch(() => setRatings({}));
  }, [selectedProfileId, authedFetch]);

  const refreshSuggestions = useCallback(() => {
    if (!selectedProfileId) {
      setSuggestions({ movies: [], tv: [] });
      return;
    }
    authedFetch(`/profiles/${selectedProfileId}/suggestions`)
      .then((r) => (r.ok ? r.json() : { movies: [], tv: [] }))
      .then(setSuggestions)
      .catch(() => setSuggestions({ movies: [], tv: [] }));
  }, [selectedProfileId, authedFetch]);

  useEffect(() => {
    setProgress([]);
    refreshWatchlist();
    refreshProgress();
    refreshRatings();
    refreshSuggestions();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedProfileId]);

  // Terug op het tabblad (bv. na kijken op de tv): voortgang opnieuw ophalen.
  useEffect(() => {
    const onVis = () => { if (!document.hidden) refreshProgress(); };
    document.addEventListener("visibilitychange", onVis);
    return () => document.removeEventListener("visibilitychange", onVis);
  }, [refreshProgress]);

  async function toggleWatchlist(item) {
    if (!selectedProfileId) return;
    const inList = watchlist.some((w) => w.id === item.id);
    if (inList) {
      await authedFetch(`/profiles/${selectedProfileId}/watchlist/${item.id}`, { method: "DELETE" });
    } else {
      await authedFetch(`/profiles/${selectedProfileId}/watchlist`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          id: item.id,
          title: item.title || item.name || "",
          poster_path: item.poster_path || "",
          backdrop_path: item.backdrop_path || "",
          media_type: item.media_type || (item.title ? "movie" : "tv"),
          release_date: item.release_date || "",
          first_air_date: item.first_air_date || "",
          vote_average: item.vote_average || 0,
          overview: item.overview || "",
        }),
      });
    }
    refreshWatchlist();
  }

  async function saveProgress(item, currentTime, duration) {
    if (!item || !selectedProfileId) return;
    const t = Number(currentTime) || 0;
    const d = Number(duration) || 0;
    if (t <= 0) return;
    // Meteen lokaal bijwerken (de rij blijft zo staan en staat bovenaan) i.p.v. na elke
    // opslag de hele lijst opnieuw op te halen.
    const isEp = item.media_type === "tv_episode";
    const localId = isEp ? `tv:${item.show_id}:${item.season_number}:${item.episode_number}` : item.id;
    const entry = {
      id: localId,
      title: item.title || item.name || "",
      poster_path: item.poster_path || "",
      backdrop_path: item.backdrop_path || "",
      media_type: item.media_type || (item.title ? "movie" : "tv"),
      current_time: t,
      duration: d,
      show_id: isEp ? item.show_id ?? null : null,
      season_number: isEp ? item.season_number ?? null : null,
      episode_number: isEp ? item.episode_number ?? null : null,
      last_watched_at: new Date().toISOString(),
    };
    setProgress((prev) => [entry, ...prev.filter((p) => String(p.id) !== String(localId))]);
    await authedFetch(`/profiles/${selectedProfileId}/progress`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        id: item.id,
        title: item.title || item.name || "",
        poster_path: item.poster_path || "",
        backdrop_path: item.backdrop_path || "",
        media_type: item.media_type || (item.title ? "movie" : "tv"),
        release_date: item.release_date || "",
        first_air_date: item.first_air_date || "",
        vote_average: item.vote_average || 0,
        show_id: item.show_id ?? null,
        season_number: item.season_number ?? null,
        episode_number: item.episode_number ?? null,
        current_time: t,
        duration: d,
      }),
    });
    refreshProgressSoon();
  }

  async function clearContinueWatching(item) {
    if (!item || !selectedProfileId) return;
    const isSeries = item.media_type === "tv" || item.media_type === "tv_episode";
    if (!isSeries) {
      setProgress((prev) => prev.filter((p) => String(p.id) !== String(item.id)));
      await authedFetch(`/profiles/${selectedProfileId}/progress/${encodeURIComponent(String(item.id))}`, {
        method: "DELETE",
      });
      refreshProgress();
      return;
    }

    const showId = item.show_id ?? item.id;
    const showIdStr = String(showId);
    const ids = progress
      .filter((p) => {
        const pid = String(p.id);
        if (p.show_id != null && String(p.show_id) === showIdStr) return true;
        if (String(p.id) === showIdStr) return true;
        if (pid.startsWith(`tv:${showId}:`)) return true;
        if (pid.startsWith(`tv:${showIdStr}:`)) return true;
        return false;
      })
      .map((p) => String(p.id));

    setProgress((prev) =>
      prev.filter((p) => {
        const pid = String(p.id);
        if (p.show_id != null && String(p.show_id) === showIdStr) return false;
        if (String(p.id) === showIdStr) return false;
        if (pid.startsWith(`tv:${showIdStr}:`)) return false;
        return true;
      })
    );

    await Promise.all(
      ids.map((id) =>
        authedFetch(`/profiles/${selectedProfileId}/progress/${encodeURIComponent(id)}`, { method: "DELETE" })
      )
    );
    refreshProgress();
  }

  function isInList(id) {
    return watchlist.some((w) => w.id === id);
  }

  function getProgress(id) {
    return progress.find((p) => String(p.id) === String(id)) || null;
  }

  async function setRating(item, stars) {
    if (!selectedProfileId) return;
    await authedFetch(`/profiles/${selectedProfileId}/ratings`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        id: item.id,
        stars,
        media_type: item.media_type || (item.title ? "movie" : "tv"),
        title: item.title || item.name || "",
        poster_path: item.poster_path || "",
        backdrop_path: item.backdrop_path || "",
      }),
    });
    refreshRatings();
    refreshSuggestions();
  }

  async function clearRating(item) {
    if (!selectedProfileId) return;
    await authedFetch(`/profiles/${selectedProfileId}/ratings/${item.id}`, { method: "DELETE" });
    refreshRatings();
    refreshSuggestions();
  }

  function getRating(id) {
    return ratings[String(id)]?.stars || 0;
  }

  const progressMap = Object.fromEntries(progress.map((p) => [p.id, p]));

  return (
    <UserDataContext.Provider
      value={{
        watchlist,
        progress,
        progressMap,
        ratings,
        suggestions,
        toggleWatchlist,
        saveProgress,
        clearContinueWatching,
        isInList,
        getProgress,
        setRating,
        clearRating,
        getRating,
      }}
    >
      {children}
    </UserDataContext.Provider>
  );
}

export function useUserData() {
  const ctx = useContext(UserDataContext);
  if (!ctx) throw new Error("useUserData must be used within UserDataProvider");
  return ctx;
}
