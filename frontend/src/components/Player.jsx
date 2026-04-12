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
  const controlsTimer = useRef(null);
  const startOffsetRef = useRef(0);
  const baseUrlRef = useRef(null);
  const absTimeRef = useRef(0);
  const totalRef = useRef(0);
  const lastReportRef = useRef({ t: 0, d: 0, ts: 0 });
  const [error, setError] = useState(null);
  const [playing, setPlaying] = useState(false);
  const [buffering, setBuffering] = useState(false);
  const [absTime, setAbsTime] = useState(0);
  const [dragValue, setDragValue] = useState(null);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [showControls, setShowControls] = useState(true);
  const [flashIcon, setFlashIcon] = useState(null);

  const total = useMemo(() => {
    const hint = Number(durationHint) || 0;
    return hint > 0 ? hint : 0;
  }, [durationHint]);

  useEffect(() => {
    totalRef.current = total;
  }, [total]);

  const reportProgress = (tOverride = null) => {
    if (!media || !onProgress) return;
    const d = totalRef.current;
    if (!Number.isFinite(d) || d <= 0) return;
    const t = Number.isFinite(tOverride) ? tOverride : absTimeRef.current;
    if (!Number.isFinite(t) || t < 0) return;

    const now = Date.now();
    const last = lastReportRef.current;
    if (Math.abs((last.t || 0) - t) < 0.5 && (now - (last.ts || 0)) < 2000) return;

    lastReportRef.current = { t, d, ts: now };
    onProgress(t, d);
  };

  useEffect(() => {
    return () => {
      clearTimeout(saveTimer.current);
      clearTimeout(controlsTimer.current);
      reportProgress();
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
    absTimeRef.current = t;
    const src = buildSrc(t);
    baseUrlRef.current = src;
    v.src = src;
    v.load();
    setError(null);
    setAbsTime(t);
    reportProgress(t);
    await tryPlay();
  };

  const showControlsTemporarily = () => {
    if (!isFullscreen) return;
    setShowControls(true);
    clearTimeout(controlsTimer.current);
    if (playing) {
      controlsTimer.current = setTimeout(() => {
        setShowControls(false);
      }, 2000);
    }
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
    absTimeRef.current = startOffsetRef.current;
    setBuffering(true);
    setShowControls(true);
    tryPlay();
  }, [url, startAt]);

  useEffect(() => {
    const v = videoRef.current;
    if (!v) return;
    const onPlay = () => {
      setPlaying(true);
      setBuffering(false);
      showControlsTemporarily();
    };
    const onPause = () => {
      setPlaying(false);
      setBuffering(false);
      setShowControls(true);
      reportProgress();
    };
    const onTime = () => {
      const t = startOffsetRef.current + (v.currentTime || 0);
      setAbsTime(t);
      absTimeRef.current = t;
      if (!media || !onProgress) return;
      if (total <= 0) return;
      clearTimeout(saveTimer.current);
      saveTimer.current = setTimeout(() => {
        reportProgress(t);
      }, 5000);
    };
    const onWaiting = () => setBuffering(true);
    const onPlaying = () => setBuffering(false);
    const onStalled = () => setBuffering(true);
    const onSeeking = () => setBuffering(true);
    const onSeeked = () => {
      setBuffering(false);
      reportProgress();
    };
    const onCanPlay = () => setBuffering(false);
    const onErr = () => {
      const code = v?.error?.code;
      setError(code ? `Video fout (code ${code}).` : "Video fout.");
    };
    v.addEventListener("play", onPlay);
    v.addEventListener("pause", onPause);
    v.addEventListener("timeupdate", onTime);
    v.addEventListener("waiting", onWaiting);
    v.addEventListener("playing", onPlaying);
    v.addEventListener("stalled", onStalled);
    v.addEventListener("seeking", onSeeking);
    v.addEventListener("seeked", onSeeked);
    v.addEventListener("canplay", onCanPlay);
    v.addEventListener("error", onErr);
    return () => {
      v.removeEventListener("play", onPlay);
      v.removeEventListener("pause", onPause);
      v.removeEventListener("timeupdate", onTime);
      v.removeEventListener("waiting", onWaiting);
      v.removeEventListener("playing", onPlaying);
      v.removeEventListener("stalled", onStalled);
      v.removeEventListener("seeking", onSeeking);
      v.removeEventListener("seeked", onSeeked);
      v.removeEventListener("canplay", onCanPlay);
      v.removeEventListener("error", onErr);
    };
  }, [media, onProgress, total]);

  useEffect(() => {
    const onVis = () => {
      if (document.hidden) reportProgress();
    };
    document.addEventListener("visibilitychange", onVis);
    return () => document.removeEventListener("visibilitychange", onVis);
  }, []);

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
      setFlashIcon("pause");
      clearTimeout(controlsTimer.current);
      controlsTimer.current = setTimeout(() => setFlashIcon(null), 600);
      return;
    }
    setFlashIcon("play");
    clearTimeout(controlsTimer.current);
    controlsTimer.current = setTimeout(() => setFlashIcon(null), 600);
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
    const onFs = () => {
      const fs = !!document.fullscreenElement;
      setIsFullscreen(fs);
      setShowControls(true);
      clearTimeout(controlsTimer.current);
      if (fs && playing) {
        controlsTimer.current = setTimeout(() => setShowControls(false), 2000);
      }
    };
    document.addEventListener("fullscreenchange", onFs);
    return () => document.removeEventListener("fullscreenchange", onFs);
  }, []);

  if (!url) return null;

  return (
    <div
      ref={containerRef}
      className="w-full aspect-video bg-black rounded-2xl overflow-hidden shadow-2xl relative"
      onMouseMove={showControlsTemporarily}
      onTouchStart={showControlsTemporarily}
    >
      <video
        ref={videoRef}
        autoPlay
        playsInline
        preload="metadata"
        className="w-full h-full"
        onDoubleClick={toggleFullscreen}
        onClick={toggle}
      >
        Je browser ondersteunt geen video afspelen.
      </video>

      {(showControls || !isFullscreen || !playing) && (
      <div
        className="absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/70 to-transparent px-4 pb-4 pt-10"
        onClick={(e) => e.stopPropagation()}
      >
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
      )}

      {buffering && !error && (
        <div className="absolute inset-0 flex items-center justify-center pointer-events-none">
          <div className="bg-black/60 border border-white/10 rounded-2xl px-5 py-4 flex items-center gap-3">
            <div className="w-6 h-6 border-2 border-white/30 border-t-white rounded-full animate-spin" />
            <div className="text-white text-sm font-semibold">Laden...</div>
          </div>
        </div>
      )}

      {!buffering && !error && !playing && (
        <div className="absolute inset-0 flex items-center justify-center">
          <button
            onClick={(e) => { e.stopPropagation(); toggle(); }}
            className="bg-black/50 hover:bg-black/60 border border-white/15 text-white rounded-full w-20 h-20 flex items-center justify-center text-3xl"
            title="Afspelen"
          >
            ▶
          </button>
        </div>
      )}

      {!buffering && !error && playing && flashIcon && (
        <div className="absolute inset-0 flex items-center justify-center pointer-events-none">
          <div className="bg-black/45 border border-white/10 text-white rounded-full w-20 h-20 flex items-center justify-center text-3xl">
            {flashIcon === "pause" ? "⏸" : "▶"}
          </div>
        </div>
      )}

      {error && (
        <div className="absolute inset-0 flex items-center justify-center bg-black/70 text-white text-sm px-6 text-center">
          {error}
        </div>
      )}
    </div>
  );
}
