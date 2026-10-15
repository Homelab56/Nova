import { useEffect, useRef } from "react";

// Stille, bedieningsloze YouTube-trailer die het hele vlak vult (zoals de trailer-achtergrond
// op de tv). Meldt via de YouTube iframe-API wanneer het eerste beeld speelt (onPlaying), de
// trailer afloopt (onEnded) of niet embedbaar is (onError).
export default function TrailerFrame({ videoKey, visible = true, onPlaying, onEnded, onError, className = "" }) {
  const ref = useRef(null);
  const cb = useRef({});
  cb.current = { onPlaying, onEnded, onError };

  useEffect(() => {
    const handler = (e) => {
      if (!ref.current || e.source !== ref.current.contentWindow) return;
      let d = e.data;
      if (typeof d === "string") {
        try { d = JSON.parse(d); } catch { return; }
      }
      if (!d || typeof d !== "object") return;
      if (d.event === "onError") cb.current.onError?.();
      if (d.event === "onStateChange") {
        if (d.info === 1) cb.current.onPlaying?.();
        if (d.info === 0) cb.current.onEnded?.();
      }
      if (d.event === "infoDelivery" && d.info?.playerState === 1) cb.current.onPlaying?.();
      if (d.event === "infoDelivery" && d.info?.playerState === 0) cb.current.onEnded?.();
    };
    window.addEventListener("message", handler);
    return () => window.removeEventListener("message", handler);
  }, []);

  const src =
    `https://www.youtube.com/embed/${encodeURIComponent(videoKey)}` +
    `?autoplay=1&mute=1&controls=0&modestbranding=1&rel=0&playsinline=1&iv_load_policy=3` +
    `&disablekb=1&fs=0&enablejsapi=1&origin=${encodeURIComponent(window.location.origin)}`;

  return (
    <div
      className={`absolute inset-0 overflow-hidden pointer-events-none transition-opacity duration-[800ms] ${visible ? "opacity-100" : "opacity-0"} ${className}`}
    >
      <iframe
        ref={ref}
        src={src}
        title="Trailer"
        allow="autoplay; encrypted-media"
        onLoad={() => {
          ref.current?.contentWindow?.postMessage(JSON.stringify({ event: "listening", id: 1, channel: "widget" }), "*");
        }}
        className="absolute left-1/2 top-1/2 border-0"
        style={{
          width: "max(100%, calc(100vh * 16 / 9))",
          height: "max(100%, calc(100vw * 9 / 16))",
          transform: "translate(-50%, -50%) scale(1.15)",
        }}
      />
    </div>
  );
}
