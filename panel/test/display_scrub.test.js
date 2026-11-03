// Plain node:test harness — no new dependencies. Run with `npm test`
// (wired to `node --test test/` in package.json).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { scrubForDisplay } from '../src/validate.js';

const FFFD = '�';

// ------------------------------------------------------- what survives

test('scrubForDisplay keeps newlines and tabs', () => {
  assert.equal(scrubForDisplay('a\nb\tc'), 'a\nb\tc');
  assert.equal(scrubForDisplay('\n\t\n'), '\n\t\n');
});

test('scrubForDisplay passes ordinary text, CJK and emoji through unchanged', () => {
  const text = 'HTTP 403 — resolve failed (tv) 日本語テスト 📺 ok';
  assert.equal(scrubForDisplay(text), text);
});

test('scrubForDisplay leaves the word joiner alone (not a bidi control)', () => {
  // U+2060 sits just below the isolate block and is not in the list.
  assert.equal(scrubForDisplay('a⁠b'), 'a⁠b');
});

// ------------------------------------------------------- what is replaced

test('scrubForDisplay replaces CR, NUL, ESC, DEL and the 8-bit CSI', () => {
  for (const c of ['\r', '\u0000', '\u001B', '\u007F', '\u009B']) {
    assert.equal(scrubForDisplay(c), FFFD, `expected ${JSON.stringify(c)} to be replaced`);
  }
});

test('scrubForDisplay replaces every bidi override and isolate', () => {
  const bidi = ['\u202A', '\u202B', '\u202C', '\u202D', '\u202E', '\u2066', '\u2067', '\u2068', '\u2069'];
  for (const c of bidi) {
    assert.equal(scrubForDisplay(c), FFFD, `expected U+${c.codePointAt(0).toString(16)} to be replaced`);
  }
  assert.equal(scrubForDisplay(bidi.join('')), FFFD.repeat(bidi.length));
});

test('scrubForDisplay strips only the ESC bytes of an ANSI sequence', () => {
  const out = scrubForDisplay('\u001B[31mred\u001B[0m');
  assert.equal(out, `${FFFD}[31mred${FFFD}[0m`);
  // Exactly two replacements: the printable payload is kept, it just can no
  // longer colour (or move) anything.
  assert.equal([...out].filter((c) => c === FFFD).length, 2);
  assert.ok(out.includes('red'));
});

test('scrubForDisplay preserves length — one replacement per character', () => {
  const text = 'a\u0000b\u001Bc\r\nd\u202Ee';
  assert.equal(scrubForDisplay(text).length, text.length);
});

// ------------------------------------------------------- coercion

test('scrubForDisplay coerces null/undefined to an empty string', () => {
  assert.equal(scrubForDisplay(null), '');
  assert.equal(scrubForDisplay(undefined), '');
});

test('scrubForDisplay coerces a non-string', () => {
  assert.equal(scrubForDisplay(42), '42');
  assert.equal(scrubForDisplay(0), '0');
});
