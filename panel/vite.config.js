import { defineConfig } from 'vite';

// Served from GitHub Pages at https://<user>.github.io/iptvs/.
// Override with PANEL_BASE when deploying elsewhere (e.g. a custom domain at '/').
export default defineConfig({
  base: process.env.PANEL_BASE ?? '/iptvs/',
});
