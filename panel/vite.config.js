import { defineConfig, loadEnv } from 'vite';

// Served from GitHub Pages at https://<user>.github.io/iptvs/.
// Override with PANEL_BASE when deploying elsewhere (e.g. a custom domain at '/').
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');
  const supabaseUrl = (env.VITE_SUPABASE_URL || '').replace(/\/+$/, '');
  // The panel only ever connects to itself and to the project's Supabase origin
  // (PostgREST/auth over https; realtime wss is included for completeness even
  // though the panel doesn't subscribe to channels). Nothing third-party.
  const connectSrc = ["'self'", supabaseUrl, supabaseUrl.replace(/^https:/, 'wss:')]
    .filter(Boolean)
    .join(' ');

  // Strict CSP (adversarial amendment M3): default-deny, no inline scripts, no
  // third-party origins. Injected into the built index.html only — the dev
  // server (with its inline HMR client + websocket) is intentionally left
  // unconstrained. `vite preview` serves the built output, so it carries the CSP.
  //
  // No `frame-ancestors` here on purpose. GitHub Pages serves static files and
  // cannot set response headers, so this policy can only be delivered by a
  // <meta http-equiv> — and `frame-ancestors` is ignored by spec when delivered
  // that way (browsers log a console warning and enforce nothing). Listing it
  // advertised clickjacking protection the panel did not actually have;
  // `src/framebust.js` provides the real thing. If the panel ever moves to a
  // host that can send headers, serve this same policy as a real
  // Content-Security-Policy header and add `frame-ancestors 'none'` back there.
  const csp = [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self'",
    "font-src 'self'",
    `connect-src ${connectSrc}`,
    "base-uri 'self'",
    "form-action 'self'",
    "object-src 'none'",
  ].join('; ');

  return {
    base: process.env.PANEL_BASE ?? '/iptvs/',
    plugins: [
      {
        name: 'iptvs-inject-csp',
        apply: 'build',
        transformIndexHtml(html) {
          return html.replace(
            '</title>',
            `</title>\n    <meta http-equiv="Content-Security-Policy" content="${csp}" />`,
          );
        },
      },
    ],
  };
});
