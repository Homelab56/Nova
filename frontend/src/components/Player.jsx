import { useEffect, useMemo, useRef, useState } from "react";

function formatTime(sec) {
  const s = Math.max(0, Math.floor(sec || 0));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = s % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(r).padStart(2, "0")}`;
  return `${m}:${String(r).padStart(2, "0")}`;
}

export default function Player({ url, media, onProgress, startAt = 0, durationHint = 0, onEnded, onNext }) {
  const containerRef = useRef(null);
  const videoRef = useRef(null);
  const saveTimer = useRef(null);
  const controlsTimer = useRef(null);
  const subsAbortRef = useRef(null);
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
  const [subtitleTracks, setSubtitleTracks] = useState([]);
  const [subtitleSelected, setSubtitleSelected] = useState(null);
  const [subtitleLabel, setSubtitleLabel] = useState("");
  const [subMenuOpen, setSubMenuOpen] = useState(false);
  const [prefs, setPrefs] = useState({
    default_audio_lang: "en",
    default_sub_lang_1: "nl",
    default_sub_lang_2: "nl-be",
    subtitles_enabled: true,
  });
  const [derivedTotal, setDerivedTotal] = useState(0);

  const total = useMemo(() => {
    const hint = Number(durationHint) || 0;
    return hint > 0 ? hint : 0;
  }, [durationHint]);

  const effectiveTotal = useMemo(() => {
    if (total > 0) return total;
    const d = Number(derivedTotal) || 0;
    return d > 0 ? d : 0;
  }, [total, derivedTotal]);

  useEffect(() => {
    totalRef.current = effectiveTotal;
  }, [effectiveTotal]);

  useEffect(() => {
    const onDoc = () => setSubMenuOpen(false);
    document.addEventListener("click", onDoc);
    return () => document.removeEventListener("click", onDoc);
  }, []);

  useEffect(() => {
    fetch("/api/user/prefs")
      .then(r => (r.ok ? r.json() : null))
      .then(data => {
        if (!data || typeof data !== "object") return;
        setPrefs(p => ({ ...p, ...data }));
      })
      .catch(() => {});
  }, []);

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
      if (subsAbortRef.current) subsAbortRef.current.abort();
      reportProgress();
    };
  }, []);

  const buildSubtitlesListUrl = () => {
    const u = new URL(url, window.location.origin);
    u.searchParams.delete("start");
    if (u.pathname.endsWith("/api/stream/hls") || u.pathname.endsWith("/api/stream/play")) {
      u.pathname = "/api/stream/subtitles";
    } else {
      u.pathname = "/api/stream/subtitles";
    }
    return u.toString();
  };

  const buildSubtitleVttUrl = (streamIndex) => {
    const u = new URL(url, window.location.origin);
    u.searchParams.delete("start");
    u.pathname = "/api/stream/subtitle.vtt";
    u.searchParams.set("stream_index", String(streamIndex));
    return u.toString();
  };

  const chooseDefaultSubtitle = (tracks) => {
    if (!tracks || tracks.length === 0) return null;
    if (!prefs.subtitles_enabled) return null;
    const prefer = [
      prefs.default_sub_lang_1,
      prefs.default_sub_lang_2,
      "nl",
      "nld",
      "dut",
      "vla",
      "nl-be",
      "nl_be",
    ].filter(Boolean);
    const norm = (s) => String(s || "").toLowerCase().trim().replaceAll("_", "-");
    const prefNorm = prefer.map(norm);
    const byLang = tracks.find(t => prefNorm.includes(norm(t.language)));
    if (byLang) return byLang;
    const byTitle = tracks.find(t => prefNorm.some(p => norm(t.title).includes(p)));
    if (byTitle) return byTitle;
    return tracks[0];
  };

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
    if (!url) return;
    if (subsAbortRef.current) subsAbortRef.current.abort();
    const ac = new AbortController();
    subsAbortRef.current = ac;
    setSubtitleTracks([]);
    setSubtitleSelected(null);
    setSubtitleLabel("");
    fetch(buildSubtitlesListUrl(), { signal: ac.signal })
      .then(r => r.ok ? r.json() : null)
      .then(data => {
        const tracks = Array.isArray(data?.tracks) ? data.tracks : [];
        if (ac.signal.aborted) return;
        setSubtitleTracks(tracks);
        const def = chooseDefaultSubtitle(tracks);
        if (def) {
          setSubtitleSelected(def.stream_index);
          setSubtitleLabel(def.language || def.title || "Subtitles");
        } else {
          setSubtitleSelected(null);
          setSubtitleLabel("");
        }
      })
      .catch(() => {});
    return () => ac.abort();
  }, [url, prefs.default_sub_lang_1, prefs.default_sub_lang_2, prefs.subtitles_enabled]);

  useEffect(() => {
    const v = videoRef.current;
    if (!v) return;
    const apply = () => {
      try {
        const tracks = v.textTracks || [];
        for (let i = 0; i < tracks.length; i++) tracks[i].mode = "disabled";
        if (subtitleSelected !== null && tracks.length > 0) {
          tracks[0].mode = "showing";
        }
      } catch {}
    };
    const t = setTimeout(apply, 500);
    return () => clearTimeout(t);
  }, [subtitleSelected, url]);

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
      if (effectiveTotal <= 0) {
        const d = Number(v.duration) || 0;
        if (Number.isFinite(d) && d > 0) {
          const guess = startOffsetRef.current + d;
          if (Math.abs((derivedTotal || 0) - guess) > 1) setDerivedTotal(guess);
        }
        return;
      }
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
    const onEndedEvent = () => {
      setPlaying(false);
      reportProgress();
      if (onEnded) onEnded();
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
    v.addEventListener("ended", onEndedEvent);
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
      v.removeEventListener("ended", onEndedEvent);
    };
  }, [media, onProgress, effectiveTotal, derivedTotal]);

  useEffect(() => {
    const onVis = () => {
      if (document.hidden) reportProgress();
    };
    document.addEventListener("visibilitychange", onVis);
    return () => document.removeEventListener("visibilitychange", onVis);
  }, []);

  const progress = effectiveTotal > 0 ? Math.min(1, Math.max(0, absTime / effectiveTotal)) : 0;
  const sliderValue = dragValue !== null ? dragValue : Math.round(progress * 1000);
  const showNextButton = onNext && effectiveTotal > 0 && (effectiveTotal - absTime) < 90;

  const selectedTrackObj = subtitleSelected !== null
    ? subtitleTracks.find(t => t.stream_index === subtitleSelected) || null
    : null;
  const vttSrc = selectedTrackObj ? buildSubtitleVttUrl(selectedTrackObj.stream_index) : null;

  const commitSeek = async () => {
    if (effectiveTotal <= 0 || dragValue === null) return;
    const target = (dragValue / 1000) * effectiveTotal;
    setDragValue(null);
    await seekTo(target);
  };

  const setDragFromClientX = (el, clientX) => {
    if (!el || effectiveTotal <= 0) return;
    const rect = el.getBoundingClientRect();
    const ratio = rect.width > 0 ? (clientX - rect.left) / rect.width : 0;
    const v = Math.round(Math.min(1, Math.max(0, ratio)) * 1000);
    setDragValue(v);
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
        {vttSrc && (
          <track
            key={vttSrc}
            src={vttSrc}
            kind="subtitles"
            srcLang={(selectedTrackObj?.language || "und")}
            label={(selectedTrackObj?.language || selectedTrackObj?.title || subtitleLabel || "Subtitles")}
            default
          />
        )}
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
            {formatTime(absTime)}{effectiveTotal > 0 ? ` / ${formatTime(effectiveTotal)}` : ""}
          </div>

          <input
            type="range"
            min={0}
            max={1000}
            value={sliderValue}
            onChange={(e) => setDragValue(Number(e.target.value))}
            onMouseDown={(e) => setDragFromClientX(e.currentTarget, e.clientX)}
            onTouchStart={(e) => {
              const t = e.touches?.[0];
              if (!t) return;
              setDragFromClientX(e.currentTarget, t.clientX);
            }}
            onMouseUp={commitSeek}
            onTouchEnd={commitSeek}
            disabled={effectiveTotal <= 0}
            className="flex-1"
          />

          {subtitleTracks.length > 0 && (
            <div className="relative" onClick={(e) => e.stopPropagation()}>
              <button
                onClick={() => setSubMenuOpen(v => !v)}
                className="bg-white/10 hover:bg-white/20 border border-white/20 text-white rounded-lg px-2.5 py-2 text-sm font-semibold"
                title="Ondertitels"
              >
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                  <path
                    d="M4 5.5h16A2.5 2.5 0 0 1 22.5 8v8A2.5 2.5 0 0 1 20 18.5H8l-4 3v-3H4A2.5 2.5 0 0 1 1.5 16V8A2.5 2.5 0 0 1 4 5.5Z"
                    stroke="currentColor"
                    strokeWidth="1.6"
                  />
                  <path
                    d="M7.5 10.25h3.5M13 10.25h3.5M7.5 13.75h3.5M13 13.75h3.5"
                    stroke="currentColor"
                    strokeWidth="1.6"
                    strokeLinecap="round"
                  />
                </svg>
              </button>

              {subMenuOpen && (
                <div className="absolute right-0 bottom-12 w-56 bg-black/90 border border-white/10 rounded-xl shadow-2xl overflow-hidden z-50">
                  <button
                    onClick={() => { setSubtitleSelected(null); setSubtitleLabel(""); setSubMenuOpen(false); }}
                    className={`w-full text-left px-4 py-2 text-sm ${subtitleSelected === null ? "bg-white/15 text-white" : "text-white/90 hover:bg-white/10"}`}
                  >
                    Ondertitels uit
                  </button>
                  {subtitleTracks.map((t) => {
                    const idx = t.stream_index;
                    const label = t.language || t.title || `Track ${idx}`;
                    const active = subtitleSelected === idx;
                    return (
                      <button
                        key={idx}
                        onClick={() => { setSubtitleSelected(idx); setSubtitleLabel(label); setSubMenuOpen(false); }}
                        className={`w-full text-left px-4 py-2 text-sm ${active ? "bg-white/15 text-white" : "text-white/90 hover:bg-white/10"}`}
                      >
                        {label}
                      </button>
                    );
                  })}
                </div>
              )}
            </div>
          )}

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

      {showNextButton && (
        <div className="absolute bottom-24 right-8 z-50">
          <button 
            onClick={(e) => { e.stopPropagation(); onNext(); }} 
            className="bg-white text-black font-bold px-6 py-3 rounded-xl shadow-2xl hover:scale-105 transition-transform flex items-center gap-2"
          >
            Volgende aflevering ▶
          </button>
        </div>
      )}
    </div>
  );
}
