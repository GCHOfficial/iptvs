// Plain node:test harness — no new dependencies. Run with `npm test`.
//
// Covers the two hardening changes made after the E2EE security audit:
//   1. `decodeCkUnderKek` bounds the envelope's `iter` (it was unbounded, and
//      the documented >= 100k floor validated a column no read path consults —
//      the same "documented but inert" pattern as the meta CSP frame-ancestors).
//   2. `rotateContentKey` verifies the typed passphrase before minting a new CK.
//      That one cannot be exercised end-to-end here: `secrets.js` transitively
//      imports `supabase.js`, which needs Vite's `import.meta.env` and a DOM, so
//      it will not load under node (the same reason `validate.js` was kept
//      dependency-free). The guard is therefore pinned structurally, on source
//      order — weaker than a behavioural test, and labelled as such.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import * as cc from '../src/crypto.js';

const b64 = (n, fill = 7) => Buffer.alloc(n, fill).toString('base64');

// A header-valid envelope; only `iter` varies per test. Decryption would fail
// on the garbage ciphertext, but the range check must reject before that.
const envelopeWithIter = (iter) => ({
  v: 1,
  alg: 'A256GCM',
  kdf: 'PBKDF2-SHA256',
  ckv: 1,
  salt: b64(16),
  iter,
  iv: b64(12),
  ct: b64(48),
});

const decode = (iter) =>
  cc.decodeCkUnderKek({
    envelope: envelopeWithIter(iter),
    passphrase: 'correct horse battery staple',
    ckVersion: 1,
    aad: new Uint8Array(),
  });

// ------------------------------------------------------------ iter bounds

test('decodeCkUnderKek rejects an iteration count below the floor', async () => {
  await assert.rejects(() => decode(1), /iteration count out of range/);
  await assert.rejects(
    () => decode(cc.PBKDF2_MIN_ITERATIONS - 1),
    /iteration count out of range/,
  );
});

test('decodeCkUnderKek rejects an absurdly high iteration count', async () => {
  await assert.rejects(() => decode(2147483647), /iteration count out of range/);
  await assert.rejects(
    () => decode(cc.PBKDF2_MAX_ITERATIONS + 1),
    /iteration count out of range/,
  );
});

test('the out-of-range rejection happens before any key derivation', async () => {
  // The DoS this closes is a huge `iter` wedging the tab. If the check ran
  // after PBKDF2 it would take hours, so the assertion is that it is instant.
  const started = Date.now();
  await assert.rejects(() => decode(2147483647), /iteration count out of range/);
  assert.ok(
    Date.now() - started < 1000,
    'rejection must not derive the key first (took too long)',
  );
});

test('the production iteration count is inside the accepted range', () => {
  assert.ok(cc.PBKDF2_PRODUCTION_ITERATIONS >= cc.PBKDF2_MIN_ITERATIONS);
  assert.ok(cc.PBKDF2_PRODUCTION_ITERATIONS <= cc.PBKDF2_MAX_ITERATIONS);
});

test('the JS and Dart iteration bounds stay in lockstep', () => {
  const dart = readFileSync(
    fileURLToPath(new URL('../../lib/data/cloud_crypto.dart', import.meta.url)),
    'utf8',
  );
  const read = (name) => {
    const m = dart.match(new RegExp(`const int ${name} = (\\d+);`));
    assert.ok(m, `${name} not found in cloud_crypto.dart`);
    return Number(m[1]);
  };
  assert.equal(read('kPbkdf2MinIterations'), cc.PBKDF2_MIN_ITERATIONS);
  assert.equal(read('kPbkdf2MaxIterations'), cc.PBKDF2_MAX_ITERATIONS);
  assert.equal(read('kPbkdf2ProductionIterations'), cc.PBKDF2_PRODUCTION_ITERATIONS);
});

// ------------------------------------------------------- constantTimeEqual

test('constantTimeEqual matches only identical byte arrays', () => {
  const a = new Uint8Array([1, 2, 3, 4]);
  assert.equal(cc.constantTimeEqual(a, new Uint8Array([1, 2, 3, 4])), true);
  assert.equal(cc.constantTimeEqual(a, new Uint8Array([1, 2, 3, 5])), false);
  assert.equal(cc.constantTimeEqual(a, new Uint8Array([1, 2, 3])), false);
  assert.equal(cc.constantTimeEqual(a, new Uint8Array([])), false);
});

test('constantTimeEqual rejects non-byte-array inputs rather than coercing', () => {
  const a = new Uint8Array([1]);
  assert.equal(cc.constantTimeEqual(a, null), false);
  assert.equal(cc.constantTimeEqual(a, undefined), false);
  assert.equal(cc.constantTimeEqual(a, [1]), false);
  assert.equal(cc.constantTimeEqual('a', 'a'), false);
});

// -------------------------------------------- rotateContentKey guard (source)

test('rotateContentKey verifies the passphrase before minting a new key', () => {
  const src = readFileSync(
    fileURLToPath(new URL('../src/secrets.js', import.meta.url)),
    'utf8',
  );
  const body = src.slice(src.indexOf('export async function rotateContentKey'));
  const fnEnd = body.indexOf('\nexport ', 1);
  const fn = fnEnd === -1 ? body : body.slice(0, fnEnd);

  const verifyAt = fn.indexOf('decodeCkUnderKek');
  const compareAt = fn.indexOf('constantTimeEqual');
  const mintAt = fn.indexOf('randomBytes(32)');
  const rpcAt = fn.indexOf("supabase.rpc('rotate_content_key'");

  assert.ok(verifyAt !== -1, 'rotateContentKey must re-derive the KEK to verify the passphrase');
  assert.ok(compareAt !== -1, 'rotateContentKey must compare the re-derived key to the session key');
  assert.ok(mintAt !== -1 && rpcAt !== -1, 'expected the mint + rpc calls to still be present');

  // Order is the whole point: verifying after minting or after the RPC would
  // still overwrite the stored wrapped_ck and lock the user out permanently.
  assert.ok(verifyAt < mintAt, 'passphrase must be verified BEFORE the new CK is minted');
  assert.ok(compareAt < mintAt, 'key comparison must happen BEFORE the new CK is minted');
  assert.ok(verifyAt < rpcAt, 'passphrase must be verified BEFORE rotate_content_key is called');
});
