// The panel used to rebuild itself on every `onAuthStateChange` event. supabase-js
// re-emits `SIGNED_IN` on each hidden -> visible transition and `TOKEN_REFRESHED`
// on its refresh ticker, so switching browser tabs or minimising the window
// dropped whatever sub-view was open (the source editor, the metadata form, a
// half-typed pairing code) back to the tab's list. `sessionIdentityChanged` is the
// gate; these cases are the ones that must keep working either way.
//
// Run with `npm test` (node --test over test/*.test.js).
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { sessionIdentityChanged } from '../src/validate.js';

const sessionFor = (id, extra = {}) => ({
  access_token: 'a',
  expires_at: 1,
  ...extra,
  user: { id, email: `${id}@example.test` },
});

test('a re-announced session is not an identity change', () => {
  const s = sessionFor('user-1');
  // SIGNED_IN re-emitted by `_recoverAndRefresh` on a hidden -> visible switch:
  // the same session object, or an equal one read back from storage.
  assert.equal(sessionIdentityChanged(s, s), false);
  assert.equal(sessionIdentityChanged(s, sessionFor('user-1')), false);
});

test('a rotated token for the same user is not an identity change', () => {
  const before = sessionFor('user-1', { access_token: 'old', expires_at: 100 });
  const after = sessionFor('user-1', { access_token: 'new', expires_at: 200 });
  assert.equal(sessionIdentityChanged(before, after), false);
});

test('signing in, signing out and switching accounts are identity changes', () => {
  assert.equal(sessionIdentityChanged(null, sessionFor('user-1')), true);
  assert.equal(sessionIdentityChanged(sessionFor('user-1'), null), true);
  // Another tab signing a different account into the same storage.
  assert.equal(sessionIdentityChanged(sessionFor('user-1'), sessionFor('user-2')), true);
});

test('signed out stays signed out', () => {
  // INITIAL_SESSION with no session, before `getSession()` resolves: nothing to
  // reset, and the login screen is rendered by that path anyway.
  assert.equal(sessionIdentityChanged(null, null), false);
  assert.equal(sessionIdentityChanged(undefined, null), false);
});

test('a session with no user reads as signed out rather than as a new identity', () => {
  assert.equal(sessionIdentityChanged(null, { access_token: 'a' }), false);
  assert.equal(sessionIdentityChanged(sessionFor('user-1'), { access_token: 'a' }), true);
});
