import test from 'node:test';
import assert from 'node:assert/strict';

import {
  normalisePairingCode,
  pairingCodeFromUrl,
  urlWithoutPairingCode,
  PAIRING_CODE_ALPHABET,
  PAIRING_CODE_LENGTH,
  stashPairingCode,
  readStashedPairingCode,
  clearStashedPairingCode,
  PAIRING_CODE_KEY,
  PAIRING_CODE_TTL_MS,
} from '../src/validate.js';

// The panel's copy of the code shape has to keep matching the one the database
// actually emits (`gen_pairing_code()`), or a perfectly good scanned link would
// be refused as malformed.
test('the code shape matches gen_pairing_code', () => {
  assert.equal(PAIRING_CODE_LENGTH, 8);
  assert.equal(PAIRING_CODE_ALPHABET, 'ABCDEFGHJKMNPQRSTUVWXYZ23456789');
  // The ambiguous glyphs are excluded on purpose: a code misread off a screen
  // must fail, not silently become a different valid code.
  for (const c of 'ILO01') assert.equal(PAIRING_CODE_ALPHABET.includes(c), false);
});

test('normalisePairingCode forgives case and whitespace only', () => {
  assert.equal(normalisePairingCode('ECA6EVMU'), 'ECA6EVMU');
  assert.equal(normalisePairingCode('  eca6evmu \n'), 'ECA6EVMU');
  assert.equal(normalisePairingCode('ECA6EVM'), null); // too short
  assert.equal(normalisePairingCode('ECA6EVMUX'), null); // too long
  assert.equal(normalisePairingCode('ECA6EVM0'), null); // 0 is not in the alphabet
  assert.equal(normalisePairingCode('ECA6EV-U'), null);
  assert.equal(normalisePairingCode(null), null);
  assert.equal(normalisePairingCode(undefined), null);
});

test('pairingCodeFromUrl reads the code the device QR encodes', () => {
  assert.equal(
    pairingCodeFromUrl('https://gchofficial.github.io/iptvs/?code=ECA6EVMU'),
    'ECA6EVMU',
  );
  // A panel deployed under a sub-path, with other params already present.
  assert.equal(
    pairingCodeFromUrl('https://example.test/panel/?foo=1&code=eca6evmu#devices'),
    'ECA6EVMU',
  );
});

test('pairingCodeFromUrl fails closed on anything ambiguous', () => {
  // The value is attacker-supplied by construction (it comes off a URL), and
  // the fallback is the form the user was going to fill in anyway — so there is
  // nothing to gain by guessing.
  assert.equal(pairingCodeFromUrl('https://gchofficial.github.io/iptvs/'), null);
  assert.equal(pairingCodeFromUrl('https://example.test/?code='), null);
  assert.equal(pairingCodeFromUrl('https://example.test/?code=%3Cscript%3E'), null);
  assert.equal(pairingCodeFromUrl('https://example.test/?code=DROP+TABLE'), null);
  assert.equal(pairingCodeFromUrl(''), null);
  assert.equal(pairingCodeFromUrl(null), null);
});

test('urlWithoutPairingCode strips only the code', () => {
  assert.equal(
    urlWithoutPairingCode('https://gchofficial.github.io/iptvs/?code=ECA6EVMU'),
    '/iptvs/',
  );
  assert.equal(
    urlWithoutPairingCode('https://example.test/panel/?foo=1&code=ECA6EVMU#devices'),
    '/panel/?foo=1#devices',
  );
});

test('urlWithoutPairingCode reports nothing to strip', () => {
  // null is the signal not to touch history at all — replaceState on every
  // render would otherwise churn the address bar for no reason.
  assert.equal(urlWithoutPairingCode('https://gchofficial.github.io/iptvs/'), null);
  assert.equal(urlWithoutPairingCode(null), null);
});

// The two helpers judge independently: stripping doesn't re-validate. (The
// panel only ever strips a code it used, so a malformed one is left alone in
// practice — this pins that the helper itself doesn't care.)
test('urlWithoutPairingCode does not re-validate the code it removes', () => {
  assert.equal(pairingCodeFromUrl('https://example.test/?code=nope'), null);
  assert.equal(urlWithoutPairingCode('https://example.test/?code=nope'), '/');
});

// ── Surviving the sign-in redirect ──────────────────────────────────────────

function fakeStorage(initial = {}) {
  const map = new Map(Object.entries(initial));
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
    size: () => map.size,
  };
}

test('a stashed code is read back within its TTL', () => {
  const s = fakeStorage();
  stashPairingCode('ECA6EVMU', s, 1_000);
  assert.equal(readStashedPairingCode(s, 1_000), 'ECA6EVMU');
  assert.equal(readStashedPairingCode(s, 1_000 + PAIRING_CODE_TTL_MS - 1), 'ECA6EVMU');
});

test('a stashed code expires with the code itself', () => {
  // Matching request_pairing's 10-minute expiry: a prefill the server would
  // reject is worse than no prefill, and it stops a code resurfacing days on.
  const s = fakeStorage();
  stashPairingCode('ECA6EVMU', s, 1_000);
  assert.equal(readStashedPairingCode(s, 1_000 + PAIRING_CODE_TTL_MS + 1), null);
});

test('the stash re-validates on the way out', () => {
  // localStorage is user-writable, so what went in is not proof.
  const s = fakeStorage({ [PAIRING_CODE_KEY]: JSON.stringify({ code: '<script>', at: 1_000 }) });
  assert.equal(readStashedPairingCode(s, 1_000), null);
});

test('a malformed or missing stash reads as nothing, never throws', () => {
  assert.equal(readStashedPairingCode(fakeStorage(), 0), null);
  assert.equal(readStashedPairingCode(fakeStorage({ [PAIRING_CODE_KEY]: 'not json' }), 0), null);
  assert.equal(readStashedPairingCode(fakeStorage({ [PAIRING_CODE_KEY]: '"a string"' }), 0), null);
  assert.equal(
    readStashedPairingCode(fakeStorage({ [PAIRING_CODE_KEY]: JSON.stringify({ code: 'ECA6EVMU' }) }), 0),
    null,
    'no timestamp means no TTL, which must not read as fresh',
  );
  assert.equal(readStashedPairingCode(null, 0), null);
});

test('a timestamp far in the future is not trusted', () => {
  // A clock correction shouldn't hand a code an unbounded lifetime.
  const s = fakeStorage();
  stashPairingCode('ECA6EVMU', s, 10 * PAIRING_CODE_TTL_MS);
  assert.equal(readStashedPairingCode(s, 0), null);
});

test('stashing refuses a code that is not one', () => {
  const s = fakeStorage();
  stashPairingCode('nope', s, 0);
  assert.equal(s.size(), 0);
});

test('clearStashedPairingCode removes it', () => {
  const s = fakeStorage();
  stashPairingCode('ECA6EVMU', s, 0);
  clearStashedPairingCode(s);
  assert.equal(readStashedPairingCode(s, 0), null);
});

test('storage that throws never breaks the caller', () => {
  const hostile = {
    getItem() { throw new Error('blocked'); },
    setItem() { throw new Error('blocked'); },
    removeItem() { throw new Error('blocked'); },
  };
  assert.doesNotThrow(() => stashPairingCode('ECA6EVMU', hostile, 0));
  assert.equal(readStashedPairingCode(hostile, 0), null);
  assert.doesNotThrow(() => clearStashedPairingCode(hostile));
});
