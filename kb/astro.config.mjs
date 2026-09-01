// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

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
  security: {
    // Astro emits a per-build <meta> CSP, hashing every inline script it and
    // Starlight ship (a docs page carries ~16 of them — the theme selector,
    // the search UI, the sidebar state). Hand-maintaining those hashes is not
    // realistic, which is precisely why the panel is a separate origin: there
    // the policy is a flat `script-src 'self'` with nothing inline at all.
    csp: {
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
