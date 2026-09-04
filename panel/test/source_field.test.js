// Plain node:test harness — no new dependencies, and no DOM. Run with `npm test`.
//
// Covers the pure halves of the source form's password reveal: the markup a
// field renders, and the state transition the toggle applies. The panel masks
// the Xtream password, and the moment a user most needs to read it back is the
// moment it was filled in for them by "Switch to Xtream".
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { esc, KIND_FIELDS, passwordFieldHtml, setPasswordReveal, sourceFieldHtml, togglePasswordReveal } from '../src/validate.js';

const xtreamField = (key) => KIND_FIELDS.xtream.find((f) => f.key === key);

test('a password field renders a reveal toggle', () => {
  const html = sourceFieldHtml(xtreamField('password'), 'p');
  assert.match(html, /type="password"/);
  assert.match(html, /class="pw"/);
  assert.match(html, /class="ghost reveal"/);
  assert.match(html, /aria-pressed="false"/);
  assert.match(html, /aria-label="Show Password"/);
  // type=button, or clicking it would submit the form.
  assert.match(html, /<button type="button"/);
});

test('a non-password field renders no toggle and stays a plain input', () => {
  const html = sourceFieldHtml(xtreamField('username'), 'joe');
  assert.match(html, /type="text"/);
  assert.doesNotMatch(html, /reveal/);
  assert.doesNotMatch(html, /class="pw"/);
});

test('required is emitted only for required fields', () => {
  assert.match(sourceFieldHtml(xtreamField('host'), ''), / required /);
  const optional = KIND_FIELDS.m3u.find((f) => f.key === 'epgUrl');
  assert.doesNotMatch(sourceFieldHtml(optional, ''), /required/);
});

test('values and labels are escaped into the markup', () => {
  const html = sourceFieldHtml({ key: 'k', label: 'A "B" <c>', password: false }, '"><script>');
  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /&quot;&gt;&lt;script&gt;/);
  assert.match(html, /A &quot;B&quot; &lt;c&gt;/);
});

test('esc leaves ordinary text alone and escapes the four dangerous characters', () => {
  assert.equal(esc('plain text'), 'plain text');
  assert.equal(esc('&<>"'), '&amp;&lt;&gt;&quot;');
  assert.equal(esc(null), '');
});

test('the toggle flips type, label and aria state both ways', () => {
  const input = { type: 'password' };
  const attrs = {};
  const button = {
    textContent: 'Show',
    setAttribute: (k, v) => { attrs[k] = v; },
  };

  assert.equal(togglePasswordReveal(input, button, 'Password'), true);
  assert.equal(input.type, 'text');
  assert.equal(button.textContent, 'Hide');
  assert.equal(attrs['aria-pressed'], 'true');
  assert.equal(attrs['aria-label'], 'Hide Password');

  assert.equal(togglePasswordReveal(input, button, 'Password'), false);
  assert.equal(input.type, 'password');
  assert.equal(button.textContent, 'Show');
  assert.equal(attrs['aria-pressed'], 'false');
  assert.equal(attrs['aria-label'], 'Show Password');
});

test('a passphrase field keeps its autocomplete hint and gets a toggle', () => {
  // The Security tab's fields must stay offerable to a password manager.
  const html = passwordFieldHtml({
    name: 'p1',
    label: 'Sync passphrase',
    autocomplete: 'new-password',
  });
  assert.match(html, /autocomplete="new-password"/);
  assert.match(html, /name="p1"/);
  assert.match(html, /class="pw"/);
  assert.match(html, /aria-label="Show Sync passphrase"/);
  assert.doesNotMatch(html, /required/);
});

test('setPasswordReveal is an absolute set, not a flip', () => {
  // wirePassphraseGenerator reveals a generated passphrase without a click, so
  // setting the same state twice must be a no-op rather than a toggle — the
  // desync this exists to prevent is a button reading "Show" over a visible
  // field, whose next click then hides it while announcing the opposite.
  const input = { type: 'password' };
  const attrs = {};
  const button = { textContent: 'Show', setAttribute: (k, v) => { attrs[k] = v; } };

  setPasswordReveal(input, button, 'Sync passphrase', true);
  setPasswordReveal(input, button, 'Sync passphrase', true);
  assert.equal(input.type, 'text');
  assert.equal(button.textContent, 'Hide');
  assert.equal(attrs['aria-pressed'], 'true');

  // A click from there must mask it, not reveal it again.
  togglePasswordReveal(input, button, 'Sync passphrase');
  assert.equal(input.type, 'password');
  assert.equal(button.textContent, 'Show');
});

test('setPasswordReveal tolerates an input with no toggle beside it', () => {
  const input = { type: 'password' };
  assert.equal(setPasswordReveal(input, null, 'Sync passphrase', true), true);
  assert.equal(input.type, 'text');
});
