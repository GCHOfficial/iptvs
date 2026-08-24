import test from 'node:test';
import assert from 'node:assert/strict';

import {
  hashPin,
  isPinVerifier,
  isValidPin,
  PIN_ITERATIONS,
} from '../src/pin.js';

// These are the same two triples `test/profile_pin_test.dart` asserts. They are
// what proves the panel and the app derive byte-identical verifiers: a PIN set
// here has to open the profile on a television that has never talked to this
// panel, and there is no way to find out later that it does not.
test('the derivation matches the app, byte for byte', async () => {
  const b64 = (v) => v.split('$')[3];
  const hex = (s) =>
    [...atob(s)].map((c) => c.charCodeAt(0).toString(16).padStart(2, '0')).join('');

  const one = await hashPin('1234', new TextEncoder().encode('salt'), 1);
  assert.equal(
    hex(b64(one)),
    'd0bc3a5e5fb06f3cb892c741febf58b7d40d22e79e60125e29bc0e4f354ba842',
  );

  const production = await hashPin(
    '4821',
    new TextEncoder().encode('0123456789abcdef'),
    PIN_ITERATIONS,
  );
  assert.equal(
    hex(b64(production)),
    '0a658136fbe7b98473c96f81c7d49908a8468ecf8066f4884f11b3c180e78193',
  );
});

test('the production parameters are the ones the app expects', () => {
  // Not a style preference: an iteration count that drifts on one side alone
  // produces verifiers the other side derives differently and rejects.
  assert.equal(PIN_ITERATIONS, 10000);
});

test('a fresh verifier has the shape Postgres accepts', async () => {
  const verifier = await hashPin('4821');
  assert.ok(isPinVerifier(verifier));
  assert.ok(verifier.startsWith('pbkdf2-sha256$10000$'));
  assert.ok(verifier.length <= 256, 'fits the column bound');
  // Two derivations of one PIN differ: the salt is fresh each time.
  assert.notEqual(verifier, await hashPin('4821'));
});

test('isValidPin takes four digits and nothing else', () => {
  assert.ok(isValidPin('0000'));
  assert.ok(isValidPin('4821'));
  for (const bad of ['', '123', '12345', '12a4', '12 4', null, 4821]) {
    assert.equal(isValidPin(bad), false, String(bad));
  }
});

test('isPinVerifier rejects anything else', () => {
  for (const bad of [
    '',
    'hunter2',
    '4821',
    'pbkdf2-sha512$10000$MDEyMzQ1Njc4OWFiY2RlZg==$CmWBNvvnuYRzyW+Bx9SZCKhGjs+AZvSITxGzwYDngZM=',
    'pbkdf2-sha256$10000$short$nope',
    null,
  ]) {
    assert.equal(isPinVerifier(bad), false, String(bad));
  }
});

test('hashing a non-PIN throws rather than storing something unopenable', async () => {
  await assert.rejects(() => hashPin('12345'));
  await assert.rejects(() => hashPin('abcd'));
});
