import { useEffect, useMemo, useRef, useState } from "react";

function formatTime(sec) {
  const s = Math.max(0, Math.floor(sec || 0));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = s % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(r).padStart(2, "0")}`;
  return `${m}:${String(r).padStart(2, "0")}`;
}

export default function Player({ url, media, onProgress, startAt = 0, durationHint = 0 }) {
  const containerRef = useRef(null);
  const videoRef = useRef(null);
  const saveTimer = useRef(null);
  const startOffsetRef = useRef(0);
  const baseUrlRef = useRef(null);
  const [error, setError] = useState(null);
  const [playing, setPlaying] = useState(false);
  const [absTime, setAbsTime] = useState(0);
  const [dragValue, setDragValue] = useState(null);
  const [isFullscreen, setIsFullscreen] = useState(false);

  const total = useMemo(() => {
    const hint = Number(durationHint) || 0;
    return hint > 0 ? hint : 0;
  }, [durationHint]);

  useEffect(() => {
    return () => {
      clearTimeout(saveTimer.current);
    };
  }, []);

  const buildSrc = (startSeconds) => {
    const isHls = url.includes("/stream/hls") || url.includes(".m3u8");
    const progressiveUrl = isHls ? url.replace("/stream/hls", "/stream/play") : url;
    const u = new URL(progressiveUrl, window.location.origin);
    if (startSeconds && startSeconds > 0) {
      u.searchParams.set("start", String(startSeconds.toFixed(3)));
    } else {
      u.searchParams.delete("start");
    }
    return u.toString();
  };

  const tryPlay = async () => {
    const v = videoRef.current;
    if (!v) return;
    try {
      await v.play();
    } catch (e) {
      if (e?.name === "NotAllowedError" && !v.muted) {
        v.muted = true;
        try { await v.play(); } catch {}
      }
    }
  };

  const seekTo = async (seconds) => {
    const v = videoRef.current;
    if (!v) return;
    const t = Math.max(0, Number(seconds) || 0);
    startOffsetRef.current = t;
    const src = buildSrc(t);
    baseUrlRef.current = src;
    v.src = src;
    v.load();
    setError(null);
    setAbsTime(t);
    await tryPlay();
  };

  useEffect(() => {
    const v = videoRef.current;
    if (!v || !url) return;
    setError(null);
    startOffsetRef.current = Math.max(0, Number(startAt) || 0);
    const src = buildSrc(startOffsetRef.current);
    baseUrlRef.current = src;
    v.src = src;
    v.load();
    setAbsTime(startOffsetRef.current);
    tryPlay();
  }, [url, startAt]);

  useEffect(() => {
    const v = videoRef.current;
    if (!v) return;
    const onPlay = () => setPlaying(true);
    const onPause = () => setPlaying(false);
    const onTime = () => {
      const t = startOffsetRef.current + (v.currentTime || 0);
      setAbsTime(t);
      if (!media || !onProgress) return;
      if (total <= 0) return;
      clearTimeout(saveTimer.current);
      saveTimer.current = setTimeout(() => {
        onProgress(t, total);
      }, 5000);
    };
    const onErr = () => {
      const code = v?.error?.code;
      setError(code ? `Video fout (code ${code}).` : "Video fout.");
    };
    v.addEventListener("play", onPlay);
    v.addEventListener("pause", onPause);
    v.addEventListener("timeupdate", onTime);
    v.addEventListener("error", onErr);
    return () => {
      v.removeEventListener("play", onPlay);
      v.removeEventListener("pause", onPause);
      v.removeEventListener("timeupdate", onTime);
      v.removeEventListener("error", onErr);
    };
  }, [media, onProgress, total]);

  const progress = total > 0 ? Math.min(1, Math.max(0, absTime / total)) : 0;
  const sliderValue = dragValue !== null ? dragValue : Math.round(progress * 1000);

  const commitSeek = async () => {
    if (total <= 0 || dragValue === null) return;
    const target = (dragValue / 1000) * total;
    setDragValue(null);
    await seekTo(target);
  };

  const toggle = async () => {
    const v = videoRef.current;
    if (!v) return;
    if (playing) {
      v.pause();
      return;
    }
    await tryPlay();
  };

  const toggleFullscreen = async () => {
    const el = containerRef.current;
    if (!el) return;
    try {
      if (document.fullscreenElement) {
        await document.exitFullscreen();
      } else {
        await el.requestFullscreen();
      }
    } catch {}
  };

  useEffect(() => {
    const onFs = () => setIsFullscreen(!!document.fullscreenElement);
    document.addEventListener("fullscreenchange", onFs);
    return () => document.removeEventListener("fullscreenchange", onFs);
  }, []);

  if (!url) return null;

  return (
    <div ref={containerRef} className="w-full aspect-video bg-black rounded-2xl overflow-hidden shadow-2xl relative">
      <video
        ref={videoRef}
        autoPlay
        playsInline
        preload="metadata"
        className="w-full h-full"
        onDoubleClick={toggleFullscreen}
      >
        Je browser ondersteunt geen video afspelen.
      </video>

      <div className="absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/70 to-transparent px-4 pb-4 pt-10">
        <div className="flex items-center gap-3">
          <button
            onClick={toggle}
            className="bg-white/10 hover:bg-white/20 border border-white/20 text-white rounded-lg px-3 py-1.5 text-sm font-semibold"
          >
            {playing ? "⏸" : "▶"}
          </button>

          <div className="text-xs text-white/80 w-24 tabular-nums">
            {formatTime(absTime)}{total > 0 ? ` / ${formatTime(total)}` : ""}
          </div>

          <input
            type="range"
            min={0}
            max={1000}
            value={sliderValue}
            onChange={(e) => setDragValue(Number(e.target.value))}
            onMouseUp={commitSeek}
            onTouchEnd={commitSeek}
            disabled={total <= 0}
            className="flex-1"
          />

          <button
            onClick={toggleFullscreen}
            className="bg-white/10 hover:bg-white/20 border border-white/20 text-white rounded-lg px-3 py-1.5 text-sm font-semibold"
            title="Fullscreen"
          >
            {isFullscreen ? "⤢" : "⤢"}
          </button>
        </div>
      </div>

      {error && (
        <div className="absolute inset-0 flex items-center justify-center bg-black/70 text-white text-sm px-6 text-center">
          {error}
        </div>
      )}
    </div>
  );
}
