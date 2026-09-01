// Asserts a *configured* build actually ships the Supabase client.
//
// `supabase.js` throws at module top-level when VITE_SUPABASE_URL /
// VITE_SUPABASE_ANON_KEY are absent, before `createClient(url, key)` is ever
// reached. A good bundler proves the call unreachable from that and drops
// `@supabase/supabase-js` entirely — correctly, because a build with no
// Supabase config is already a build that only renders "set these variables".
// Vite 8.2 does exactly this; 8.1 did not. So bundle size alone means nothing
// unless the config is present, and this script refuses to judge without it.
//
// What it does catch, on a build that IS configured: the client silently
// vanishing from the output. `npm test` cannot see that — the panel's suite
// exercises `validate.js`, which is deliberately dependency-free and never
// imports `supabase.js` — and a bundler can drop working code without failing.
// The artifact needs its own smoke test; this is it.

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const dist = join(import.meta.dirname, '..', 'dist');
const assets = join(dist, 'assets');

// A floor, not a target: a configured bundle is ~265 kB. Kept well under that
// so an ordinary dependency trim doesn't trip it, and well over the ~10 kB an
// unconfigured build produces.
const MIN_ENTRY_BYTES = 120_000;

function fail(message) {
  console.error(`check-bundle: ${message}`);
  process.exit(1);
}

// Mirrors what `vite build` itself reads, including a `.env` file if present.
const configured =
  (process.env.VITE_SUPABASE_URL ?? '') !== '' &&
  (process.env.VITE_SUPABASE_ANON_KEY ?? '') !== '';

if (!configured) {
  // Not a failure. An unconfigured build legitimately has no client in it, and
  // developers build the panel this way all the time.
  console.log(
    'check-bundle: skipped — VITE_SUPABASE_URL/VITE_SUPABASE_ANON_KEY are not set, ' +
      'so this build has no Supabase client to look for.',
  );
  process.exit(0);
}

let entries;
try {
  entries = readdirSync(assets).filter((f) => f.endsWith('.js'));
} catch {
  fail(`no ${assets} — run \`npm run build\` first`);
}

if (entries.length === 0) fail('no JS emitted into dist/assets');

const sizes = entries.map((f) => ({ f, bytes: statSync(join(assets, f)).size }));
const entry = sizes.reduce((a, b) => (b.bytes > a.bytes ? b : a));
const source = readFileSync(join(assets, entry.f), 'utf8');

// `createClient` survives minification: it is a named import off a bare
// specifier, so the bundler keeps the identifier in the module factory even
// when local bindings are renamed. Its absence in a configured build means the
// module was dropped.
if (!source.includes('createClient')) {
  fail(
    `${entry.f} does not contain the Supabase client, even though this build ` +
      'is configured. `@supabase/supabase-js` was dropped from the bundle.',
  );
}

if (entry.bytes < MIN_ENTRY_BYTES) {
  fail(
    `${entry.f} is ${entry.bytes} bytes, below the ${MIN_ENTRY_BYTES} floor for ` +
      'a configured build. A dependency was almost certainly tree-shaken out.',
  );
}

console.log(`check-bundle: ok — ${entry.f}, ${entry.bytes} bytes, Supabase client present`);
