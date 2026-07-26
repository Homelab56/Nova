import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Docker Compose: zet VITE_DEV_PROXY_TARGET=http://backend:8000 (servicenaam + interne poort).
// Lokaal (npm run dev op je PC): backend op host-poort, bv. http://127.0.0.1:8002
const devProxyTarget =
  process.env.VITE_DEV_PROXY_TARGET || "http://127.0.0.1:8002";

export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      "/api": {
        target: devProxyTarget,
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ""),
      },
    },
  },
});
