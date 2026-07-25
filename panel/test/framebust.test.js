// Plain node:test harness — no new dependencies. Run with `npm test`
// (wired to `node --test test/` in package.json).
//
// `framebust.js` is the panel's only clickjacking defence: the CSP cannot carry
// `frame-ancestors` because GitHub Pages can't send headers and the directive is
// ignored when delivered via <meta> (see docs/cloud-sync.md). Its protection is
// entirely positional — it works by throwing during module evaluation, before
// the rest of the entry graph runs — so the thing worth pinning is that it stays
// the *first* import of `main.js` and that it still refuses rather than
// navigating the top frame. There is no DOM here, so this asserts on source.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const read = (rel) => readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8');

const main = read('../src/main.js');
const framebust = read('../src/framebust.js');

test('framebust is the first import of main.js', () => {
  const imports = [...main.matchAll(/^\s*import\s.*?['"](.+?)['"];?\s*$/gm)].map((m) => m[1]);
  assert.ok(imports.length > 1, 'expected main.js to have several imports');
  assert.equal(
    imports[0],
    './framebust.js',
    'framebust.js must stay the first import — a later position lets the modules ' +
      'before it evaluate (and attach listeners) inside a framing page',
  );
});

test('framebust aborts module evaluation by throwing', () => {
  assert.match(
    framebust,
    /\bthrow new Error\(/,
    'the guard must throw: returning early would let main.js evaluate anyway',
  );
});

test('framebust does not navigate the top frame', () => {
  // A `top.location = ...` escape would turn the panel into an open-redirect
  // gadget for any page that frames it. Refusing to render is the chosen fix.
  const code = framebust.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
  assert.doesNotMatch(code, /\b(top|parent)\s*\.\s*location\s*=/);
  assert.doesNotMatch(code, /\blocation\s*\.\s*(replace|assign)\s*\(/);
});

test('framebust fails closed when window.top is unreadable', () => {
  // Cross-origin `window.top` access throws; that throw proves we are framed, so
  // the catch must report framed (true), never fall through to false.
  const code = framebust.replace(/\/\/.*$/gm, '');
  assert.match(code, /catch\s*\{[\s\S]*?return true;/);
});
