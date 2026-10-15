// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import { createHash } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Astro hashes the scripts it bundles, but not `<script is:inline>` ones, and
// Starlight ships several of those on purpose — they run before first paint
// to restore the stored theme, the synced tab, the sidebar scroll position
// (a deferred module would flash the wrong state first). Unhashed, the CSP
// blocks every one of them. Hashing them here, from the installed Starlight's
// own sources, keeps the list in step with whatever version npm resolved;
// scripts/verify-csp.mjs then proves against the build that it matched.
function starlightInlineScriptHashes() {
  const root = dirname(fileURLToPath(import.meta.resolve('@astrojs/starlight')));
  const hashes = new Set();
  const visit = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) visit(path);
      else if (entry.name.endsWith('.astro')) {
        const source = readFileSync(path, 'utf8');
        for (const [, body] of source.matchAll(
          /<script\b[^>]*\bis:inline\b[^>]*>([\s\S]*?)<\/script>/g,
        )) {
          hashes.add(`sha256-${createHash('sha256').update(body).digest('base64')}`);
        }
      }
    }
  };
  visit(root);
  return [...hashes];
}

// The public site: landing page, store badges, and the knowledge base.
//
// It is deliberately NOT the panel. The panel handles an authenticated Supabase
// session, an unwrapped content key, and provider credentials, and it lives on
// its own origin (panel.<domain>) with a one-dependency tree so that an XSS
// anywhere in *this* site — a Starlight dependency, a community docs PR, a
// plugin added later — cannot reach any of it. See docs/cloud-sync.md.
//
// `site` feeds canonical URLs and the sitemap, so it has to be the real origin.
// Set SITE_URL in CI; the fallback only keeps a local `npm run build` working.
const site = process.env.SITE_URL ?? 'https://iptvs.click';

export default defineConfig({
  site,
  // Every component stylesheet ships as a file under /_astro, which `'self'`
  // already allows — never as an inline <style> that the CSP has to hash.
  // Astro's hashing has proven unable to follow its own inlining: Starlight
  // 0.42.6 changed one import in its Footer, the page's component CSS split
  // into different inline blocks, and the emitted policy hashed a block that
  // was never written while omitting the Card/CardGrid one. The browser then
  // dropped that block and the landing page's cards lost their boxes and grid
  // with no build error. `npm run build` runs scripts/verify-csp.mjs, which
  // fails if any inline style or script is ever left unhashed again.
  build: {
    inlineStylesheets: 'never',
  },
  security: {
    // Astro emits a per-build <meta> CSP, hashing every inline script it and
    // Starlight ship (a docs page carries ~16 of them — the theme selector,
    // the search UI, the sidebar state). Hand-maintaining those hashes is not
    // realistic, which is precisely why the panel is a separate origin: there
    // the policy is a flat `script-src 'self'` with nothing inline at all.
    csp: {
      scriptDirective: {
        hashes: starlightInlineScriptHashes(),
      },
      styleDirective: {
        // Shiki colours code blocks with inline `style=` attributes — 80 of
        // them on a single page here — and a style *attribute* cannot be
        // hashed. Scoping the exemption to `kind: 'attribute'` puts
        // 'unsafe-inline' in `style-src-attr` only, so real stylesheets stay
        // hash-pinned under `style-src-elem`. Dropping the scope would relax
        // both and, per Astro's docs, suppress hash emission entirely.
        resources: ["'self'", { resource: "'unsafe-inline'", kind: 'attribute' }],
      },
    },
  },
  integrations: [
    starlight({
      title: 'iptvs',
      description:
        'A cross-platform IPTV player for Windows, Android, Android TV and Linux. Manage your sources from the web; your devices pull them down.',
      logo: {
        src: './src/assets/icon.png',
        alt: '',
      },
      favicon: '/icon.png',
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/GCHOfficial/iptvs',
        },
        // Community first: someone reading a guide that did not answer their
        // question wants a person, and these are the two places to find one.
        {
          icon: 'discord',
          label: 'Discord',
          href: 'https://discord.gg/Eh2BMVRJT',
        },
        {
          icon: 'telegram',
          label: 'Telegram',
          href: 'https://t.me/+l_fENZkpwDw4MTU0',
        },
        // In the header rather than only on the landing page, so it is reachable
        // from a knowledge-base article too — which is where someone the app has
        // just helped actually is.
        {
          icon: 'heart',
          label: 'Support on Ko-fi',
          href: 'https://ko-fi.com/georgecosminhanta',
        },
      ],
      customCss: ['./src/styles/brand.css'],
      // Wraps Starlight's own Footer to append the site-wide legal line; see
      // the component. Everything Starlight puts there is preserved.
      components: {
        Footer: './src/components/Footer.astro',
      },
      // Matches the app and the panel rather than Starlight's defaults; the
      // palette is the single source in brand.css.
      sidebar: [
        {
          label: 'Start here',
          items: [
            { label: 'Installing', slug: 'guides/installing' },
            { label: 'Adding a source', slug: 'guides/adding-a-source' },
          ],
        },
        {
          label: 'Guides',
          items: [
            { label: 'Cloud sync and pairing', slug: 'guides/cloud-sync' },
            { label: 'Profiles and PINs', slug: 'guides/profiles' },
            { label: 'TV remote controls', slug: 'guides/remote' },
            { label: 'Favorites, catch-up and resuming', slug: 'guides/favorites' },
          ],
        },
        {
          label: 'Help',
          items: [{ label: 'Troubleshooting', slug: 'help/troubleshooting' }],
        },
      ],
    }),
  ],
});
