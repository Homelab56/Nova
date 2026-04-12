import { useRef, useEffect, useState } from "react";
import Hls from "hls.js";

export default function Player({ url, media, onProgress }) {
  const videoRef = useRef(null);
  const saveTimer = useRef(null);
  const [error, setError] = useState(null);
  const hlsRef = useRef(null);
  const resolveRef = useRef(null);
  const fallbackTriedRef = useRef(false);

  useEffect(() => {
    return () => {
      clearInterval(saveTimer.current);
      if (hlsRef.current) {
        hlsRef.current.destroy();
        hlsRef.current = null;
      }
      if (resolveRef.current) {
        resolveRef.current.abort();
        resolveRef.current = null;
      }
    };
  }, []);

  useEffect(() => {
    const v = videoRef.current;
    if (!v || !url) return;

    setError(null);
    fallbackTriedRef.current = false;

    if (hlsRef.current) {
      hlsRef.current.destroy();
      hlsRef.current = null;
    }

    const tryPlay = async () => {
      try {
        await v.play();
      } catch (e) {
        if (e?.name === "NotAllowedError" && !v.muted) {
          v.muted = true;
          try { await v.play(); } catch {}
        }
      }
    };

    const isHls = url.includes(".m3u8") || url.includes("/api/stream/hls") || url.includes("/stream/hls/");
    if (!isHls) {
      v.src = url;
      tryPlay();
      return;
    }

    if (v.canPlayType("application/vnd.apple.mpegurl")) {
      v.src = url;
      tryPlay();
      return;
    }

    if (Hls.isSupported()) {
      const hls = new Hls({
        enableWorker: true,
        lowLatencyMode: false,
      });
      hlsRef.current = hls;
      const boot = async () => {
        let manifestUrl = url;
        try {
          if (url.includes("/api/stream/hls?")) {
            if (resolveRef.current) resolveRef.current.abort();
            resolveRef.current = new AbortController();
            const r = await fetch(url, { redirect: "follow", signal: resolveRef.current.signal });
            if (!r.ok) {
              setError(`Video fout: manifest ${r.status}`);
              return;
            }
            manifestUrl = r.url;
          }
        } catch (e) {
          setError("Video fout: manifest kan niet geladen worden.");
          return;
        }

        hls.loadSource(manifestUrl);
        hls.attachMedia(v);
      };
      boot();
      hls.on(Hls.Events.MANIFEST_PARSED, async () => {
        tryPlay();
      });
      hls.on(Hls.Events.ERROR, (_evt, data) => {
        const parts = [];
        if (data?.type) parts.push(data.type);
        if (data?.details) parts.push(data.details);
        if (data?.response?.code) parts.push(`HTTP ${data.response.code}`);
        const msg = parts.length ? `Video fout: ${parts.join(" · ")}` : "Video fout.";
        if (data?.fatal) {
          const canFallback = (url.includes("/api/stream/hls?") || url.includes("/stream/hls?")) && !fallbackTriedRef.current;
          if (canFallback) {
            fallbackTriedRef.current = true;
            try { hls.destroy(); } catch {}
            hlsRef.current = null;
            const progressiveUrl = url.replace("/stream/hls", "/stream/play");
            v.src = progressiveUrl;
            setError(null);
            tryPlay();
            return;
          }

          setError(msg);
          try { hls.destroy(); } catch {}
          hlsRef.current = null;
          return;
        }
        if (!error) setError(msg);
      });
      return;
    }

    setError("Je browser ondersteunt HLS niet.");
  }, [url]);

  function handleTimeUpdate() {
    const v = videoRef.current;
    if (!v || !media || !onProgress) return;
    if (!Number.isFinite(v.duration) || v.duration <= 0) return;
    // Sla elke 10 seconden op
    clearInterval(saveTimer.current);
    saveTimer.current = setTimeout(() => {
      onProgress(v.currentTime, v.duration);
    }, 10000);
  }

  if (!url) return null;

  return (
    <div className="w-full aspect-video bg-black rounded-2xl overflow-hidden shadow-2xl relative">
      <video
        ref={videoRef}
        controls
        autoPlay
        playsInline
        preload="metadata"
        className="w-full h-full"
        controlsList="nodownload"
        onTimeUpdate={handleTimeUpdate}
        onError={() => {
          const v = videoRef.current;
          const code = v?.error?.code;
          setError(code ? `Video fout (code ${code}).` : "Video fout.");
        }}
      >
        Je browser ondersteunt geen video afspelen.
      </video>
      {error && (
        <div className="absolute inset-0 flex items-center justify-center bg-black/70 text-white text-sm px-6 text-center">
          {error}
        </div>
      )}
    </div>
  );
}
