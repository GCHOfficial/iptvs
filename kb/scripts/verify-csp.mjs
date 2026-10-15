// Post-build gate: every inline <script> and <style> in the built site must be
// allowed by the <meta> CSP on its own page.
//
// Astro computes those hashes itself, and a blocked block is not a build error
// — the browser just drops it. Starlight 0.42.6 shipped exactly that: the
// landing page's Card/CardGrid styles were inline but unhashed, so the cards
// silently lost their boxes in production while every check stayed green.
// This reads the *artifact*, the only place such a mismatch is visible.
//
// Usage: node scripts/verify-csp.mjs [distDir]   (default: dist)

import { createHash } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const dist = process.argv[2] ?? 'dist';

function* htmlFiles(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) yield* htmlFiles(path);
    else if (entry.name.endsWith('.html')) yield path;
  }
}

const decode = (s) =>
  s
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

const sha256 = (text) =>
  `'sha256-${createHash('sha256').update(text, 'utf8').digest('base64')}'`;

// The sources a directive lists, falling back the way a browser does
// (`script-src-elem` → `script-src` → `default-src`).
function sourcesFor(policy, chain) {
  for (const name of chain) {
    if (policy.has(name)) return policy.get(name);
  }
  return [];
}

let pages = 0;
const failures = [];

for (const file of htmlFiles(dist)) {
  pages++;
  const html = readFileSync(file, 'utf8');
  const meta = html.match(
    /<meta\s+http-equiv="content-security-policy"\s+content="([^"]*)"/i,
  );
  if (!meta) {
    failures.push(`${file}: no CSP <meta> tag`);
    continue;
  }
  const policy = new Map(
    decode(meta[1])
      .split(';')
      .map((d) => d.trim().split(/\s+/))
      .filter((d) => d[0])
      .map(([name, ...sources]) => [name.toLowerCase(), sources]),
  );

  const checks = [
    {
      kind: 'style',
      pattern: /<style\b([^>]*)>([\s\S]*?)<\/style>/gi,
      chain: ['style-src-elem', 'style-src', 'default-src'],
    },
    {
      // Only inline scripts; `src=` ones are governed by 'self'.
      kind: 'script',
      pattern: /<script\b(?![^>]*\bsrc=)([^>]*)>([\s\S]*?)<\/script>/gi,
      chain: ['script-src-elem', 'script-src', 'default-src'],
    },
  ];

  for (const { kind, pattern, chain } of checks) {
    const allowed = sourcesFor(policy, chain);
    if (allowed.includes("'unsafe-inline'")) continue;
    for (const [, attrs, body] of html.matchAll(pattern)) {
      // A JSON data island is never executed, so CSP does not govern it.
      if (kind === 'script' && /\btype="application\/(ld\+)?json"/i.test(attrs)) continue;
      if (!allowed.includes(sha256(body))) {
        const preview = body.slice(0, 70).replace(/\s+/g, ' ');
        failures.push(`${file}: inline ${kind} not in CSP — ${preview}…`);
      }
    }
  }
}

if (pages === 0) {
  console.error(`verify-csp: no HTML found under ${dist}`);
  process.exit(1);
}
if (failures.length > 0) {
  console.error(`verify-csp: ${failures.length} inline block(s) the browser would block:`);
  for (const f of failures) console.error(`  ${f}`);
  process.exit(1);
}
console.log(`verify-csp: ${pages} page(s), every inline script and style is allowed by its CSP`);
