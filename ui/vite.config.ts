import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// GitHub Pages serves the site at /<repo>/; set BASE=/ for local or custom-domain hosting.
export default defineConfig({
  base: process.env.BASE ?? "/",
  plugins: [react()],
  build: { chunkSizeWarningLimit: 1500 },
});
