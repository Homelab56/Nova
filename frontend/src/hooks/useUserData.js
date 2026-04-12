import { useState, useEffect, useCallback } from "react";

export function useWatchlist() {
  const [watchlist, setWatchlist] = useState([]);

  const refresh = useCallback(() => {
    fetch("/api/user/watchlist").then(r => r.json()).then(setWatchlist).catch(() => {});
  }, []);

  useEffect(() => { refresh(); }, []);

  async function toggle(item) {
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
    refresh();
  }

  return { watchlist, toggle, refresh, isInList: (id) => watchlist.some(w => w.id === id) };
}

export function useProgress() {
  const [progress, setProgress] = useState([]);

  const refresh = useCallback(() => {
    fetch("/api/user/progress").then(r => r.json()).then(setProgress).catch(() => {});
  }, []);

  useEffect(() => { refresh(); }, []);

  async function saveProgress(item, currentTime, duration) {
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
        current_time: currentTime,
        duration: duration,
      }),
    });
    refresh();
  }

  async function clearProgress(id) {
    await fetch(`/api/user/progress/${id}`, { method: "DELETE" });
    refresh();
  }

  return { progress, saveProgress, clearProgress, refresh };
}
