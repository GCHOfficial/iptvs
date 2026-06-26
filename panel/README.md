# iptvs web panel

A tiny static SPA (Vite + `@supabase/supabase-js`, no framework) for managing your
IPTV source list from a real keyboard. Devices pull the list down with no on-device
login (and can push their own list back up) — see `supabase/README.md` for the backend
and `CLAUDE.md` for the big picture.

## Develop

```bash
cd panel
cp .env.example .env.local   # fill in your Supabase URL + anon key
npm install
npm run dev
```

## Build

```bash
npm run build   # outputs panel/dist/, base path '/iptvs/' (PANEL_BASE to override)
```

GitHub Actions deploys `dist/` to GitHub Pages on push to `main`
(`.github/workflows/pages.yml`). Supabase values come from repo
**Variables** `SUPABASE_URL` / `SUPABASE_ANON_KEY` (anon/publishable only).

## What it does

- **Login** — magic-link email only (no passwords, no OAuth).
- **Sources** — CRUD over your `sources` rows; field shapes mirror
  `lib/sources/source_config.dart` per kind (Stalker / Xtream / M3U / Demo).
  Reorder with ↑/↓ — devices show sources in this order.
- **Metadata** — your TMDB/TVDB/MDBList keys + auto-enrich toggle.
- **Devices** — pair by entering a device's code (`claim_pairing` RPC), rename, revoke.
