// Plain node:test harness — no new dependencies. Run with `npm test`.
//
// The wordlist assertions are not style checks: a non-power-of-two length makes
// the masked index selection biased, and a duplicate entry silently reduces the
// entropy of every passphrase generated afterwards. Both are invisible at
// runtime, so they are pinned here.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { WORDS } from '../src/wordlist.js';
import {
  generatePassphrase,
  passphraseStrength,
  validatePassphrase,
  GENERATED_WORD_COUNT,
  GENERATED_BITS,
  MIN_PASSPHRASE_LENGTH,
  SEPARATOR,
} from '../src/passphrase.js';

// ------------------------------------------------------------- the wordlist

test('the wordlist length is a power of two', () => {
  assert.ok(WORDS.length > 0);
  assert.equal(
    Math.log2(WORDS.length) % 1,
    0,
    `length ${WORDS.length} is not a power of two — masked selection would be biased`,
  );
});

test('the wordlist has no duplicates', () => {
  const seen = new Map();
  const dupes = [];
  for (const w of WORDS) {
    if (seen.has(w)) dupes.push(w);
    seen.set(w, true);
  }
  assert.deepEqual(dupes, [], 'duplicates silently reduce passphrase entropy');
  assert.equal(new Set(WORDS).size, WORDS.length);
});

test('every word is lowercase a-z, 3 to 8 characters', () => {
  const bad = WORDS.filter((w) => !/^[a-z]{3,8}$/.test(w));
  assert.deepEqual(bad, []);
});

test('no word contains the separator', () => {
  assert.deepEqual(WORDS.filter((w) => w.includes(SEPARATOR)), []);
});

// ------------------------------------------------------------- generation

test('generatePassphrase produces the advertised shape', () => {
  const p = generatePassphrase();
  const parts = p.split(SEPARATOR);
  assert.equal(parts.length, GENERATED_WORD_COUNT);
  for (const part of parts) assert.ok(WORDS.includes(part), `${part} not in wordlist`);
});

test('the advertised bit count matches the wordlist and word count', () => {
  assert.equal(GENERATED_BITS, Math.round(GENERATED_WORD_COUNT * Math.log2(WORDS.length)));
  assert.ok(GENERATED_BITS >= 50, 'below the offline-attack target this exists to meet');
});

test('generatePassphrase does not repeat itself', () => {
  const seen = new Set();
  for (let i = 0; i < 200; i++) seen.add(generatePassphrase());
  assert.equal(seen.size, 200, 'generated passphrases must be unique in practice');
});

test('generatePassphrase draws across the whole wordlist', () => {
  // A masking bug that lost the high bits would confine output to a prefix of
  // the list. Sample enough words that a halved range is statistically obvious.
  const used = new Set();
  for (let i = 0; i < 4000; i++) {
    for (const w of generatePassphrase().split(SEPARATOR)) used.add(w);
  }
  const maxIndex = Math.max(...[...used].map((w) => WORDS.indexOf(w)));
  assert.ok(
    maxIndex > WORDS.length * 0.95,
    `highest index drawn was ${maxIndex} of ${WORDS.length} — selection looks truncated`,
  );
});

test('a generated passphrase passes its own validation', () => {
  const p = generatePassphrase();
  assert.equal(validatePassphrase(p, p), null);
});

// ------------------------------------------------------------- the gate

test('validatePassphrase enforces the length floor', () => {
  const short = 'a'.repeat(MIN_PASSPHRASE_LENGTH - 1);
  assert.match(validatePassphrase(short, short), /at least/);
  const ok = 'a'.repeat(MIN_PASSPHRASE_LENGTH);
  assert.equal(validatePassphrase(ok, ok), null);
});

test('validatePassphrase rejects the old 8-character floor', () => {
  // Regression guard: 8 characters was the pre-audit floor and falls to an
  // offline attack in minutes.
  assert.ok(MIN_PASSPHRASE_LENGTH >= 16);
  assert.match(validatePassphrase('password', 'password'), /at least/);
});

test('validatePassphrase requires both entries to match', () => {
  const a = 'a'.repeat(MIN_PASSPHRASE_LENGTH);
  assert.match(validatePassphrase(a, a + 'b'), /do not match/);
});

test('validatePassphrase handles null and undefined without throwing', () => {
  assert.match(validatePassphrase(null, null), /at least/);
  assert.match(validatePassphrase(undefined, undefined), /at least/);
});

// ------------------------------------------------------------- the meter

test('passphraseStrength rates a generated phrase strongest', () => {
  assert.equal(passphraseStrength(generatePassphrase()).score, 4);
});

test('passphraseStrength rates short and empty input lowest', () => {
  assert.equal(passphraseStrength('').score, 0);
  assert.equal(passphraseStrength('short').score, 0);
  assert.equal(passphraseStrength(null).score, 0);
});

// ------------------------------------------------------- generator UI wiring

// `wirePassphraseGenerator` finds its controls by `data-` attribute. A typo on
// either side fails silently — `querySelector` returns null and the Generate
// button simply never works — and there is no DOM here to catch it at runtime
// (`main.js` transitively imports `supabase.js`, which needs Vite's
// `import.meta.env`). So assert the two sides agree on the attribute names.
test('the generator markup and its wiring use the same data- hooks', () => {
  const main = readFileSync(fileURLToPath(new URL('../src/main.js', import.meta.url)), 'utf8');

  const wiring = main.slice(main.indexOf('function wirePassphraseGenerator'));
  assert.ok(wiring.length > 0, 'expected wirePassphraseGenerator to exist');

  const queried = new Set(
    [...wiring.matchAll(/querySelector\('\[data-([a-z]+)\]'\)/g)].map((m) => m[1]),
  );
  // Emitted hooks come from the markup anywhere in main.js — the generator
  // block emits most of them, but `data-strength` lives in each form template.
  // Strip the lookup expressions first so a hook is never counted as emitted
  // just because it is queried.
  const emitted = new Set(
    [...main.replace(/querySelector\('\[data-[a-z]+\]'\)/g, '').matchAll(/\bdata-([a-z]+)\b/g)]
      .map((m) => m[1]),
  );
  assert.ok(queried.size >= 5, `expected several data- lookups, found ${queried.size}`);

  for (const hook of queried) {
    assert.ok(emitted.has(hook), `wiring looks up [data-${hook}] but the markup never emits it`);
  }
});

test('both passphrase forms include the generator and a strength meter', () => {
  const main = readFileSync(fileURLToPath(new URL('../src/main.js', import.meta.url)), 'utf8');
  for (const id of ['enable', 'rotpass']) {
    const start = main.indexOf(`<form id="${id}"`);
    assert.ok(start !== -1, `form #${id} not found`);
    const form = main.slice(start, main.indexOf('</form>', start));
    assert.match(form, /passphraseGeneratorMarkup\(\)/, `#${id} is missing the generator`);
    assert.match(form, /data-strength/, `#${id} is missing the strength meter`);
    // Rendered through the shared helper rather than as a literal
    // `<input type="password">`, which is what gives the field its reveal
    // toggle. See the "no raw masked input" test below.
    assert.match(
      form,
      /passwordFieldHtml\(\{[^}]*name: 'p1'/,
      `#${id} is missing the passphrase field`,
    );
  }
  // Both submit handlers must consult the "I have saved this" gate, or a
  // generated phrase could be committed before the user has written it down.
  assert.match(main, /enableCanSubmit\(\)/);
  assert.match(main, /rotpassCanSubmit\(\)/);
});

test('passphraseStrength scores rise monotonically with quality', () => {
  const scores = [
    passphraseStrength('abc').score,
    passphraseStrength('a'.repeat(MIN_PASSPHRASE_LENGTH)).score,
    passphraseStrength(`a1!${'b'.repeat(MIN_PASSPHRASE_LENGTH)}`).score,
    passphraseStrength(generatePassphrase()).score,
  ];
  for (let i = 1; i < scores.length; i++) {
    assert.ok(scores[i] >= scores[i - 1], `score dropped at step ${i}: ${scores}`);
  }
});

test('every masked field in the panel goes through passwordFieldHtml', () => {
  // The reveal toggle is part of the renderer, so a hand-rolled
  // `<input type="password">` is a field the user cannot read back — which is
  // exactly what the passphrase forms were before. Pinning the absence of the
  // literal is what stops the next masked field being added without one.
  const main = readFileSync(fileURLToPath(new URL('../src/main.js', import.meta.url)), 'utf8');
  assert.doesNotMatch(main, /type="password"/);
  // And the helper is genuinely in use for them.
  assert.ok(
    [...main.matchAll(/passwordFieldHtml\(\{/g)].length >= 6,
    'expected every passphrase field to render through passwordFieldHtml',
  );
});

test('the generator reveals through setPasswordReveal, never a raw type flip', () => {
  // A direct `p1.type = "text"` leaves the toggle beside it reading "Show"
  // over a visible field, and the next click then hides it while announcing
  // the opposite.
  const main = readFileSync(fileURLToPath(new URL('../src/main.js', import.meta.url)), 'utf8');
  assert.doesNotMatch(main, /\.type = 'text'/);
  assert.match(main, /forcePasswordReveal\(p1\)/);
  assert.match(main, /forcePasswordReveal\(p2\)/);
});
