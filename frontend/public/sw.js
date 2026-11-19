// Minimale service worker zodat Streamify als app geïnstalleerd kan worden.
// Bewust GEEN caching: alles (pagina's, API, streams) gaat gewoon rechtstreeks naar de server,
// zodat updates meteen zichtbaar zijn en video-streams niet gestoord worden.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
self.addEventListener("fetch", () => {});
