import { createContext, useContext, useState, useEffect, useCallback } from "react";

const UserDataContext = createContext(null);

export function UserDataProvider({ children }) {
  const [watchlist, setWatchlist] = useState([]);
  const [progress, setProgress] = useState([]);

  const refreshWatchlist = useCallback(() => {
    fetch("/api/user/watchlist")
      .then(r => r.ok ? r.json() : [])
      .then(setWatchlist)
      .catch(() => setWatchlist([]));
  }, []);

  const refreshProgress = useCallback(() => {
    fetch("/api/user/progress")
      .then(r => r.ok ? r.json() : [])
      .then(setProgress)
      .catch(() => setProgress([]));
  }, []);

  useEffect(() => {
    refreshWatchlist();
    refreshProgress();
  }, []);

  async function toggleWatchlist(item) {
    const inList = watchlist.some(w => w.id === item.id);
    if (inList) {
      await fetch(`/api/user/watchlist/${item.id}`, { method: "DELETE" });
    } else {
      await fetch("/api/user/watchlist", {
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
    if (!item || !duration) return;
    await fetch("/api/user/progress", {
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
        current_time: currentTime,
        duration: duration,
      }),
    });
    refreshProgress();
  }

  async function clearContinueWatching(item) {
    if (!item) return;
    const isSeries = item.media_type === "tv" || item.media_type === "tv_episode";
    if (!isSeries) {
      await fetch(`/api/user/progress/${encodeURIComponent(String(item.id))}`, { method: "DELETE" });
      refreshProgress();
      return;
    }

    const showId = item.show_id ?? item.id;
    const showIdStr = String(showId);
    const ids = progress
      .filter(p => {
        const pid = String(p.id);
        if (p.show_id != null && String(p.show_id) === showIdStr) return true;
        if (String(p.id) === showIdStr) return true;
        if (pid.startsWith(`tv:${showId}:`)) return true;
        if (pid.startsWith(`tv:${showIdStr}:`)) return true;
        return false;
      })
      .map(p => String(p.id));

    await Promise.all(ids.map(id => fetch(`/api/user/progress/${encodeURIComponent(id)}`, { method: "DELETE" })));
    refreshProgress();
  }

  function isInList(id) {
    return watchlist.some(w => w.id === id);
  }

  function getProgress(id) {
    return progress.find(p => p.id === id) || null;
  }

  const progressMap = Object.fromEntries(progress.map(p => [p.id, p]));

  return (
    <UserDataContext.Provider value={{
      watchlist, progress, progressMap,
      toggleWatchlist, saveProgress, clearContinueWatching,
      isInList, getProgress,
    }}>
      {children}
    </UserDataContext.Provider>
  );
}

export function useUserData() {
  const ctx = useContext(UserDataContext);
  if (!ctx) throw new Error("useUserData must be used within UserDataProvider");
  return ctx;
}
