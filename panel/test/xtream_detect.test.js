// Plain node:test harness — no new dependencies. Run with `npm test`.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { xtreamCredentialsFromPlaylistUrl } from '../src/validate.js';

test('detects a get.php link carrying credentials', () => {
  const creds = xtreamCredentialsFromPlaylistUrl(
    'http://host.example:8080/get.php?username=joe&password=hunter2&type=m3u_plus',
  );
  assert.deepEqual(creds, {
    host: 'http://host.example:8080',
    username: 'joe',
    password: 'hunter2',
  });
});

test('detects credentials in userinfo form', () => {
  const creds = xtreamCredentialsFromPlaylistUrl('http://joe:hunter2@host.example/get.php');
  assert.equal(creds.host, 'http://host.example');
  assert.equal(creds.username, 'joe');
  assert.equal(creds.password, 'hunter2');
});

test('keeps https and a non-default port', () => {
  const creds = xtreamCredentialsFromPlaylistUrl(
    'https://host.example:2096/get.php?username=a&password=b',
  );
  assert.equal(creds.host, 'https://host.example:2096');
});

test('accepts a scheme-less host the way the form does', () => {
  // `isUrl` fields elsewhere in this panel accept a bare host, so the hint has
  // to recognise one too or it would vanish mid-typing.
  const creds = xtreamCredentialsFromPlaylistUrl('host.example:8080/get.php?username=a&password=b');
  assert.equal(creds.host, 'http://host.example:8080');
});

test('percent-encoded credentials are decoded', () => {
  const creds = xtreamCredentialsFromPlaylistUrl(
    'http://host.example/get.php?username=a%40b&password=p%2Fq',
  );
  assert.equal(creds.username, 'a@b');
  assert.equal(creds.password, 'p/q');
});

test('a plain playlist is not an Xtream link', () => {
  for (const url of [
    'http://host.example/playlist.m3u8',
    'http://host.example/get.php?username=joe', // password missing
    'http://host.example/get.php?password=hunter2', // username missing
    '',
    null,
    undefined,
  ]) {
    assert.equal(xtreamCredentialsFromPlaylistUrl(url), null, `${url} must not match`);
  }
});

test('never accepts a non-http scheme', () => {
  // The same refusal `isUrl` validation makes elsewhere: a suggestion that
  // prefills fields from a javascript:/data: URL would be a way in.
  for (const url of [
    'javascript:alert(1)//?username=a&password=b',
    'data:text/plain,?username=a&password=b',
    'file:///etc/passwd?username=a&password=b',
  ]) {
    assert.equal(xtreamCredentialsFromPlaylistUrl(url), null, `${url} must not match`);
  }
});

test('garbage does not throw', () => {
  for (const url of ['not a url', '://', 'http://', '   ']) {
    assert.equal(xtreamCredentialsFromPlaylistUrl(url), null);
  }
});
