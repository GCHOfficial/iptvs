// Plain node:test harness — no new dependencies. Run with `npm test`
// (wired to `node --test test/` in package.json).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  validateSource,
  scrubUrls,
  friendlyError,
  KIND_FIELDS,
  splitFields,
  kindHasSecret,
  deviceProvisionState,
  deviceNeedsKey,
  SOURCE_SECRET_KEYS,
  METADATA_SECRET_KEYS,
} from '../src/validate.js';

// ---------------------------------------------------------- validateSource

test('validateSource accepts a well-formed xtream source', () => {
  const err = validateSource('xtream', 'My provider', {
    host: 'http://portal.example.com:8080',
    username: 'alice',
    password: 'secret',
  });
  assert.equal(err, null);
});

test('validateSource allows a scheme-less host (bare hostname is fine)', () => {
  const err = validateSource('xtream', 'My provider', {
    host: 'portal.example.com:8080',
    username: 'alice',
    password: 'secret',
  });
  assert.equal(err, null);
});

test('validateSource rejects a javascript: scheme', () => {
  const err = validateSource('m3u', 'Bad', {
    playlistUrl: 'javascript:alert(1)',
  });
  assert.match(err, /must be a plain host or an http\/https URL/);
});

test('validateSource rejects a data: scheme', () => {
  const err = validateSource('m3u', 'Bad', {
    playlistUrl: 'data:text/html,<script>alert(1)</script>',
  });
  assert.match(err, /must be a plain host or an http\/https URL/);
});

test('validateSource rejects a file: scheme', () => {
  const err = validateSource('stalker', 'Bad', {
    portal: 'file:///etc/passwd',
    mac: '00:1A:79:00:00:00',
  });
  assert.match(err, /must be a plain host or an http\/https URL/);
});

test('validateSource flags a missing required field', () => {
  const err = validateSource('stalker', 'Portal', { portal: 'http://x.example.com' });
  assert.match(err, /MAC address is required/);
});

test('validateSource rejects a label over 1024 characters', () => {
  const err = validateSource('demo', 'x'.repeat(1025), {});
  assert.match(err, /Label is too long/);
});

test('validateSource rejects an over-length field without echoing the value', () => {
  const longHost = 'h'.repeat(3000);
  const err = validateSource('xtream', 'ok', {
    host: longHost,
    username: 'alice',
    password: 'secret',
  });
  assert.match(err, /Host is too long \(max \d+ characters\)/);
  assert.ok(!err.includes(longHost), 'error must never interpolate the field value');
});

test('validateSource rejects an unknown kind', () => {
  const err = validateSource('bogus', 'x', {});
  assert.match(err, /Unknown source kind/);
});

test('KIND_FIELDS marks URL-bearing fields with isUrl', () => {
  assert.equal(KIND_FIELDS.xtream.find((f) => f.key === 'host').isUrl, true);
  assert.equal(KIND_FIELDS.m3u.find((f) => f.key === 'playlistUrl').isUrl, true);
  assert.equal(KIND_FIELDS.m3u.find((f) => f.key === 'epgUrl').isUrl, true);
  assert.equal(KIND_FIELDS.stalker.find((f) => f.key === 'portal').isUrl, true);
});

// ------------------------------------------------------ secret-key registry

test('secret-key registries mirror lib/data/secret_keys.dart', () => {
  assert.deepEqual(
    [...SOURCE_SECRET_KEYS].sort(),
    ['epgUrl', 'mac', 'password', 'playlistUrl', 'userAgent', 'username'],
  );
  assert.deepEqual(
    [...METADATA_SECRET_KEYS].sort(),
    ['mdblistApiKey', 'tmdbApiKey', 'tvdbApiKey', 'tvdbPin'],
  );
});

test('splitFields keeps broad fields verbatim and moves non-empty secrets', () => {
  const { broad, secret } = splitFields(
    { host: 'portal.example.com', username: 'alice', password: 'hunter2' },
    SOURCE_SECRET_KEYS,
  );
  assert.deepEqual(broad, { host: 'portal.example.com' });
  assert.deepEqual(secret, { username: 'alice', password: 'hunter2' });
});

test('splitFields drops empty secret values so they read as absent (preserve)', () => {
  const { broad, secret } = splitFields(
    { host: 'portal.example.com', username: 'alice', password: '' },
    SOURCE_SECRET_KEYS,
  );
  assert.deepEqual(broad, { host: 'portal.example.com' });
  assert.deepEqual(secret, { username: 'alice' });
  assert.ok(!('password' in secret), 'an empty secret must not be sent');
});

test('splitFields keeps a broad field even when empty', () => {
  const { broad } = splitFields({ host: '' }, SOURCE_SECRET_KEYS);
  assert.deepEqual(broad, { host: '' });
});

test('splitFields never leaks a source secret key into the broad map', () => {
  const { broad } = splitFields(
    { portal: 'http://p.example.com', mac: '00:1A:79:00:00:00' },
    SOURCE_SECRET_KEYS,
  );
  for (const k of SOURCE_SECRET_KEYS) assert.ok(!(k in broad), `${k} must not be broad`);
});

test('splitFields separates metadata API keys from broad config', () => {
  const { broad, secret } = splitFields(
    { provider: 'tmdb', autoEnrich: 'on', tmdbApiKey: 'abc', tvdbPin: '' },
    METADATA_SECRET_KEYS,
  );
  assert.deepEqual(broad, { provider: 'tmdb', autoEnrich: 'on' });
  assert.deepEqual(secret, { tmdbApiKey: 'abc' });
});

test('kindHasSecret is true for credential kinds and false for demo', () => {
  assert.equal(kindHasSecret('stalker'), true); // mac
  assert.equal(kindHasSecret('xtream'), true); // username/password
  assert.equal(kindHasSecret('m3u'), true); // playlistUrl
  assert.equal(kindHasSecret('demo'), false);
  assert.equal(kindHasSecret('bogus'), false);
});

// -------------------------------------------------- deviceProvisionState

test('deviceProvisionState maps the four provisioning states', () => {
  assert.equal(
    deviceProvisionState({ has_public_key: false, has_ck: false, stale: false }),
    'no-key',
  );
  assert.equal(
    deviceProvisionState({ has_public_key: true, has_ck: false, stale: false }),
    'needs-key',
  );
  assert.equal(
    deviceProvisionState({ has_public_key: true, has_ck: true, stale: true }),
    'stale',
  );
  assert.equal(
    deviceProvisionState({ has_public_key: true, has_ck: true, stale: false }),
    'provisioned',
  );
});

test('deviceProvisionState treats a missing entry as no-key (fail safe)', () => {
  assert.equal(deviceProvisionState(undefined), 'no-key');
  assert.equal(deviceProvisionState(null), 'no-key');
});

test('deviceProvisionState ignores stale when the device has no CK', () => {
  // The server only sets stale when has_ck; guard against a malformed entry.
  assert.equal(
    deviceProvisionState({ has_public_key: true, has_ck: false, stale: true }),
    'needs-key',
  );
});

test('deviceNeedsKey is true only for needs-key and stale', () => {
  assert.equal(deviceNeedsKey('needs-key'), true);
  assert.equal(deviceNeedsKey('stale'), true);
  assert.equal(deviceNeedsKey('provisioned'), false);
  assert.equal(deviceNeedsKey('no-key'), false);
});

// ---------------------------------------------------------------- scrubUrls

test('scrubUrls strips user:pass@ userinfo', () => {
  const out = scrubUrls('see http://myuser:mypass@example.com/status for details');
  assert.ok(!out.includes('myuser'));
  assert.ok(!out.includes('mypass'));
  assert.ok(out.includes('example.com'));
});

test('scrubUrls redacts credential-shaped query values but keeps other params', () => {
  const out = scrubUrls('http://example.com/api?username=alice&password=hunter2&format=json');
  assert.ok(!out.includes('alice'));
  assert.ok(!out.includes('hunter2'));
  assert.ok(out.includes('format=json'));
});

test('scrubUrls redacts Xtream-style /live/<user>/<pass>/ path segments', () => {
  const out = scrubUrls('http://portal.example.com/live/johndoe123/s3cretPW/12345.ts');
  assert.ok(!out.includes('johndoe123'));
  assert.ok(!out.includes('s3cretPW'));
  assert.ok(out.includes('/live/'));
  assert.ok(out.includes('12345.ts'));
});

test('scrubUrls redacts opaque long token-shaped segments outside known prefixes', () => {
  const out = scrubUrls('http://example.com/download/aVeryLongOpaqueToken123456789/file.zip');
  assert.ok(!out.includes('aVeryLongOpaqueToken123456789'));
});

test('scrubUrls leaves plain text without URLs untouched', () => {
  const msg = 'Something went wrong while saving.';
  assert.equal(scrubUrls(msg), msg);
});

// -------------------------------------------------------------- friendlyError

test('friendlyError passes through a server-controlled "iptvs: " message verbatim', () => {
  const err = { message: 'iptvs: profile limit reached' };
  assert.equal(friendlyError(err), 'iptvs: profile limit reached');
});

test('friendlyError generalizes RLS/permission errors', () => {
  const err = { message: 'new row violates row-level security policy for table "sources"' };
  assert.equal(friendlyError(err), 'Not allowed.');
});

test('friendlyError falls back to a generic message for anything else', () => {
  const err = { message: 'relation "sources" does not exist', details: 'internal schema detail', hint: 'check the table name' };
  const out = friendlyError(err);
  assert.equal(out, 'Something went wrong.');
  assert.ok(!out.includes('internal schema detail'));
  assert.ok(!out.includes('check the table name'));
});

test('friendlyError never surfaces error.details or error.hint even alongside an iptvs: message', () => {
  const err = { message: 'iptvs: not allowed', details: 'secret internal detail', hint: 'secret hint' };
  const out = friendlyError(err);
  assert.ok(!out.includes('secret internal detail'));
  assert.ok(!out.includes('secret hint'));
});

test('friendlyError scrubs any embedded URL credentials as a last resort', () => {
  const err = { message: 'iptvs: failed to reach http://user:pass@example.com/portal' };
  const out = friendlyError(err);
  assert.ok(!out.includes('user:pass'));
});
