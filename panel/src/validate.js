// Pure, dependency-free validation and error-safety helpers for the web panel.
//
// Deliberately has no import of @supabase/supabase-js (or anything else) so it
// can be exercised directly by a plain `node:test` file with no bundler and
// no network — see panel/test/validate.test.js. Field shapes mirror
// lib/sources/source_config.dart; `maxLength`/`isUrl` are panel-side hardening
// on top of that shared shape, not part of the persisted row.

// Field metadata per source kind. `isUrl: true` fields accept either a bare
// host/path (no scheme — e.g. an Xtream host entered without "http://") or a
// http(s) URL; any other scheme (javascript:, file:, data:, ...) is rejected.
export const KIND_FIELDS = {
  stalker: [
    { key: 'portal', label: 'Portal URL', required: true, maxLength: 2048, isUrl: true },
    { key: 'mac', label: 'MAC address', required: true, maxLength: 64 },
  ],
  xtream: [
    { key: 'host', label: 'Host', required: true, maxLength: 2048, isUrl: true },
    { key: 'username', label: 'Username', required: true, maxLength: 256 },
    { key: 'password', label: 'Password', required: true, maxLength: 256, password: true },
  ],
  m3u: [
    { key: 'playlistUrl', label: 'Playlist URL', required: true, maxLength: 4096, isUrl: true },
    { key: 'epgUrl', label: 'EPG URL (optional)', required: false, maxLength: 4096, isUrl: true },
    { key: 'userAgent', label: 'User-Agent (optional)', required: false, maxLength: 512 },
  ],
  demo: [],
};

const MAX_LABEL_LENGTH = 1024;
const MAX_FIELD_LENGTH = 8192;

// Canonical broad/secret split — mirrors lib/data/secret_keys.dart exactly. In
// the cloud a source's `fields` and a metadata config carry ONLY the broad keys;
// every secret key travels through the dedicated secret RPCs
// (set_source_secret / set_metadata_secret / the `secret` element on push), and
// is encrypted client-side when the profile has opt-in E2EE enabled. A
// server-side strip trigger drops these keys from the broad rows regardless, so
// the split here is the client half of that contract, not the only guard.
//
// The form still COLLECTS and VALIDATES the full field set together (see
// validateSource / KIND_FIELDS); the split is applied only at submission.
export const SOURCE_SECRET_KEYS = [
  'mac',
  'username',
  'password',
  'playlistUrl',
  'epgUrl',
  'epgUrls',
  'userAgent',
];
export const METADATA_SECRET_KEYS = ['tmdbApiKey', 'tvdbApiKey', 'tvdbPin', 'mdblistApiKey'];

// Splits a full field map into { broad, secret } against `secretKeys`.
// Mirrors lib/data/secret_keys.dart's splitFields: `broad` keeps every
// non-secret entry verbatim (including empties); `secret` keeps every secret
// entry whose value is NON-EMPTY — an empty secret value is dropped so it reads
// as *absent* ("this value isn't being set"), which the preserve-on-absent push
// path treats as "keep whatever the server has" rather than "blank it".
// Secret keys the edit form does not render, carried forward from what was
// already stored.
//
// `set_source_secret` REPLACES the payload wholesale, so any key the form
// omits is destroyed for every paired device on its next pull. Today that is
// `epgUrls` (extra EPG guides, editable only in the app): renaming a source in
// the panel would otherwise silently delete guides added on a TV.
//
// Only *unrendered* keys are carried — a key the form shows reflects the form,
// including a deliberate clearing — and only non-empty values, so an absent key
// still reads as "not set" rather than as a blanking instruction.
export function carryUnrenderedSecrets(secret, storedSecret, renderedKeys) {
  const rendered = new Set(renderedKeys);
  const out = { ...secret };
  for (const [k, v] of Object.entries(storedSecret ?? {})) {
    if (!rendered.has(k) && v) out[k] = v;
  }
  return out;
}

export function splitFields(fields, secretKeys) {
  const set = new Set(secretKeys);
  const broad = {};
  const secret = {};
  for (const [k, v] of Object.entries(fields ?? {})) {
    const val = v == null ? '' : String(v);
    if (set.has(k)) {
      if (val.length > 0) secret[k] = val;
    } else {
      broad[k] = val;
    }
  }
  return { broad, secret };
}

// True when a source kind carries any credential-bearing (secret) field. Demo
// has none, so it never writes a secret row.
export function kindHasSecret(kind) {
  const spec = KIND_FIELDS[kind];
  if (!spec) return false;
  const set = new Set(SOURCE_SECRET_KEYS);
  return spec.some((f) => set.has(f.key));
}

// Maps one `list_device_ck` entry (the authoritative owner-side provisioning
// view — see supabase/migrations/20260726000000_e2ee.sql) to a UI state. Pure
// and dependency-free so it can be unit-tested without a backend.
//
//   { has_public_key, has_ck, stale } →
//     'no-key'      — device hasn't registered a public key yet (will on next
//                     app launch); cannot be provisioned.
//     'needs-key'   — has a key but no content key for this profile.
//     'stale'       — has a content key at an OLD ck_version (rotate happened).
//     'provisioned' — has the current content key.
//
// `stale` is precomputed server-side (always false when E2EE is off), so a
// disabled profile never yields 'stale'. Provisioning ("Send key") applies to
// 'needs-key' and 'stale'.
export function deviceProvisionState(entry) {
  if (!entry || !entry.has_public_key) return 'no-key';
  if (!entry.has_ck) return 'needs-key';
  if (entry.stale) return 'stale';
  return 'provisioned';
}

// Whether provisioning ("Send key") is meaningful for a state.
export function deviceNeedsKey(state) {
  return state === 'needs-key' || state === 'stale';
}

// Only http/https are ever allowed for a scheme'd value; a scheme-less value
// (e.g. an Xtream host like "myportal.example.com:8080") is fine — it's the
// scheme itself that's the injection vector (javascript:, file:, data:, ...).
// Not every value with a colon has a URI scheme though — "host:port" is
// syntactically indistinguishable from "scheme:rest" under RFC 3986's scheme
// grammar (letters/digits/+/-/. are all valid in both a scheme and a
// dotted hostname), so a purely-numeric port-like suffix after the colon
// (e.g. ":8080" or ":8080/path") is treated as a port, not a scheme.
function hasBadScheme(value) {
  const idx = value.indexOf(':');
  if (idx === -1) return false;
  const before = value.slice(0, idx);
  const after = value.slice(idx + 1);
  if (!/^[a-zA-Z][a-zA-Z0-9+.-]*$/.test(before)) return false;
  if (/^\d+(\/|$)/.test(after)) return false;
  const scheme = before.toLowerCase();
  return scheme !== 'http' && scheme !== 'https';
}

/// Validates a source's kind/label/fields before it's written to Supabase.
/// Returns a safe, static error message string, or null if the source is
/// valid. Never interpolates a field's *value* into the message — only the
/// field name and the configured limit, both of which are static metadata.
export function validateSource(kind, label, fields) {
  const spec = KIND_FIELDS[kind];
  if (!spec) return 'Unknown source kind.';

  if ((label ?? '').length > MAX_LABEL_LENGTH) {
    return `Label is too long (max ${MAX_LABEL_LENGTH} characters).`;
  }

  for (const f of spec) {
    const value = (fields?.[f.key] ?? '').toString();
    if (f.required && !value) {
      return `${f.label} is required.`;
    }
    if (!value) continue;
    if (value.length > (f.maxLength ?? MAX_FIELD_LENGTH)) {
      return `${f.label} is too long (max ${f.maxLength ?? MAX_FIELD_LENGTH} characters).`;
    }
    if (f.isUrl && hasBadScheme(value)) {
      return `${f.label} must be a plain host or an http/https URL.`;
    }
  }
  return null;
}

// Query parameter names that commonly carry a credential/secret value.
const CREDENTIAL_QUERY_KEYS =
  /^(user|username|user_?name|pass|password|pwd|token|access_?token|key|api_?key|apikey|secret|mac|auth)$/i;

// Path prefixes after which the following two segments are, by IPTV
// convention (Xtream-style stream URLs), the username and password —
// e.g. /live/<user>/<pass>/12345.ts, /movie/<user>/<pass>/1.mp4.
const CREDENTIAL_PATH_PREFIXES = /^(live|movie|series|timeshift|play)$/i;

// A path segment that isn't in one of the recognized credential positions
// above but still *looks* like a token/secret (mirrors the heuristic in
// lib/data/net.dart's `_redactUrlPath`: long, or opaque token-shaped).
function looksLikeSecretSegment(segment) {
  return segment.length > 18 || /^[A-Za-z0-9_-]{12,}$/.test(segment);
}

function scrubPath(pathname) {
  const segments = pathname.split('/');
  for (let i = 0; i < segments.length; i++) {
    if (!segments[i]) continue;
    if (CREDENTIAL_PATH_PREFIXES.test(segments[i]) && i + 2 < segments.length) {
      segments[i + 1] = '<redacted>';
      segments[i + 2] = '<redacted>';
      i += 2;
      continue;
    }
    if (looksLikeSecretSegment(segments[i])) segments[i] = '<redacted>';
  }
  return segments.join('/');
}

function scrubOneUrl(match) {
  let url;
  try {
    url = new URL(match);
  } catch {
    // Not a fully parseable URL (e.g. trailing punctuation caught by the
    // regex) — fall back to a conservative userinfo-only strip.
    return match.replace(/\/\/[^/@\s]+@/, '//');
  }
  url.username = '';
  url.password = '';
  for (const key of url.searchParams.keys()) {
    if (CREDENTIAL_QUERY_KEYS.test(key)) url.searchParams.set(key, '<redacted>');
  }
  url.pathname = scrubPath(url.pathname);
  return url.toString();
}

/// Strips credentials out of free text that may embed one or more URLs:
/// `user:pass@` userinfo, password/username/token-style query values, and
/// credential-shaped path segments (e.g. Xtream-style `/live/<user>/<pass>/1.ts`).
/// Mirrors the intent of `redactText`/`redactUrl` in lib/data/net.dart.
export function scrubUrls(str) {
  const text = (str ?? '').toString();
  return text.replace(/https?:\/\/\S+/gi, scrubOneUrl);
}

// Supabase/PostgREST surface permission and RLS denials this way; never show
// the raw message (it can include table/policy names) — just say "not allowed".
const PERMISSION_ERROR_RE = /permission denied|row-level security|not allowed|rls/i;

// ── rate limits ───────────────────────────────────────────────────────────────
//
// A 429 is the one failure class on this screen the user can actually act on,
// and it is the *only* thing that reaches the sign-in form in normal operation:
// magic-link sends are throttled twice over — a per-address cooldown
// ("For security purposes, you can only request this after N seconds") and the
// project-wide email send quota ("email rate limit exceeded"), which is shared
// by every address, and is why someone who tries a second mailbox to work
// around it sees exactly the same failure.
//
// Both used to land in the "Something went wrong." bucket, which reads as a bug
// in the panel rather than as "wait". A real user took it that way and
// re-submitted ~60 times in eleven minutes, burning the very quota that was
// blocking them — so this says which kind it is and that waiting is the fix.
//
// Matched on the message *and* on `status`/`code`, because GoTrue's wording is
// not a contract. `code` values are `over_email_send_rate_limit` /
// `over_request_rate_limit`; both are server-controlled enum-ish strings, never
// payload data, so keying off them leaks nothing.
const RATE_LIMIT_ERROR_RE = /rate limit|too many requests|only request this after/i;

/// Seconds named by GoTrue's per-address cooldown message, when it names one.
/// Bounded to something a person would wait out — a wild number means the
/// wording changed under us, and a wrong countdown is worse than none.
function retryAfterSeconds(message) {
  const m = /only request this after (\d{1,4}) seconds?/i.exec(message);
  if (!m) return null;
  const seconds = Number(m[1]);
  return Number.isInteger(seconds) && seconds > 0 && seconds <= 3600 ? seconds : null;
}

function isRateLimited(error, message) {
  if (RATE_LIMIT_ERROR_RE.test(message)) return true;
  const status = error?.status ?? error?.statusCode;
  if (status === 429 || status === '429') return true;
  return typeof error?.code === 'string' && error.code.includes('rate_limit');
}

/// Turns a Supabase error into a safe string to display to the user. Always
/// call `console.error(error)` at the call site first for debugging — this
/// function intentionally never surfaces `error.details` or `error.hint`,
/// which can carry internal schema/query detail.
export function friendlyError(error) {
  const message = (error && typeof error.message === 'string') ? error.message : '';
  let out;
  if (message.startsWith('iptvs: ')) {
    out = message; // server-controlled, safe to show verbatim
  } else if (isRateLimited(error, message)) {
    const seconds = retryAfterSeconds(message);
    out = seconds
      ? `Too many attempts. Try again in ${seconds} second${seconds === 1 ? '' : 's'}.`
      : 'Too many sign-in emails have been requested. Wait a few minutes and try again — sending more now will not help.';
  } else if (PERMISSION_ERROR_RE.test(message)) {
    out = 'Not allowed.';
  } else {
    out = 'Something went wrong.';
  }
  return scrubUrls(out);
}

// ── sticky E2EE state ─────────────────────────────────────────────────────────
//
// The server is NOT trusted on whether a profile is encrypted. `get_crypto_state`
// decides whether the write path encrypts, so a backend answering
// `{ enabled: false }` — or suddenly 404-ing the crypto RPCs, which is
// indistinguishable from a legitimate pre-migration backend — would get this
// panel to write every provider credential and API key back as plaintext
// `format` 0. The server-side format gate is the stated defence, but it lives in
// the same trust domain as the attacker.
//
// So: once a profile is *seen* encrypted, that fact is remembered here, and only
// an explicit local action can forget it. localStorage is the right store — it
// is per-origin, survives reloads, and is exactly as trustworthy as the panel
// code itself (an XSS'd panel is already outside the threat boundary).
//
// A legitimate `disableE2ee` clears the mark for the browser that performed it;
// any OTHER browser sees the same signal as an attack and must clear it through
// `acknowledgeDowngrade` (wired to a Security-tab button).
//
// These live HERE rather than in secrets.js purely so they can be tested:
// secrets.js transitively imports supabase.js, which needs Vite's
// `import.meta.env` and a DOM and therefore cannot load under `node:test`. The
// `storage` parameter is the seam — production callers omit it and get
// localStorage; tests pass a fake. Without that, the one piece of state standing
// between a lying backend and plaintext credentials would be unpinned.

export const E2EE_SEEN_KEY = 'iptvs_e2ee_seen';

// Some embedders throw on `localStorage` access rather than returning undefined
// (private mode, blocked third-party storage), so the read itself is guarded.
function defaultStorage() {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

function readSeen(storage) {
  try {
    const raw = storage?.getItem(E2EE_SEEN_KEY);
    const parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed.filter((x) => typeof x === 'string') : [];
  } catch {
    // Corrupt or unavailable storage restarts from "nothing known". That fails
    // OPEN by design: a device that has never seen encryption cannot distinguish
    // a downgrade from a profile that was simply never encrypted, and refusing
    // to sync at all on unreadable storage would be a worse failure than the
    // protection lapsing back to per-session.
    return [];
  }
}

function writeSeen(ids, storage) {
  try {
    storage?.setItem(E2EE_SEEN_KEY, JSON.stringify(ids));
  } catch {
    // Private-mode / quota failure: the sticky protection degrades to
    // per-session only. Never fail the surrounding operation over it.
  }
}

/// Whether this browser has ever seen `profileId` end-to-end encrypted.
export function wasE2eeSeen(profileId, storage = defaultStorage()) {
  return readSeen(storage).includes(profileId);
}

export function markE2eeSeen(profileId, storage = defaultStorage()) {
  const ids = readSeen(storage);
  if (ids.includes(profileId)) return;
  ids.push(profileId);
  writeSeen(ids, storage);
}

// Forget the mark. Called by `disableE2ee` (this browser just turned it off, so
// the state change is authenticated by the user's own action) and by the
// Security tab's explicit acknowledgement.
export function acknowledgeDowngrade(profileId, storage = defaultStorage()) {
  const ids = readSeen(storage);
  const next = ids.filter((id) => id !== profileId);
  if (next.length !== ids.length) writeSeen(next, storage);
}

// ---------------------------------------------------------------------------
// Xtream-panel detection for M3U playlist URLs.
//
// A very large share of M3U sources are an Xtream panel's `get.php` link. As a
// flat playlist such a source works — live channels play — but it is strictly
// worse than the Xtream config the same credentials support: no Movies, no
// Series, no subscription expiry, none of which a playlist carries.
//
// **Shape only — this never verifies.** The app converts a source only after
// `player_api.php` actually authenticates, and the panel cannot make that call:
// the panel is served over HTTPS, so an `http://` provider URL is blocked as
// mixed content before CORS is even consulted, and IPTV panels send no
// `Access-Control-Allow-Origin` anyway. So this is a *suggestion the user
// confirms*, never an automatic rewrite: some resellers proxy `get.php` without
// serving `player_api.php` at all, and converting one of those would turn a
// working source into a broken one.
//
// Mirrors `xtreamCredentialsFromUrl` in lib/sources/xtream_source.dart.
export function xtreamCredentialsFromPlaylistUrl(playlistUrl) {
  const raw = (playlistUrl ?? '').trim();
  if (!raw) return null;
  let url;
  try {
    url = new URL(/^[a-z][a-z0-9+.-]*:\/\//i.test(raw) ? raw : `http://${raw}`);
  } catch {
    return null;
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
  if (!url.hostname) return null;
  // Either `http://user:pass@host/...` or `?username=…&password=…`.
  let username = url.username ? decodeURIComponent(url.username) : '';
  let password = url.password ? decodeURIComponent(url.password) : '';
  if (!username) username = url.searchParams.get('username') ?? '';
  if (!password) password = url.searchParams.get('password') ?? '';
  if (!username || !password) return null;
  const port = url.port ? `:${url.port}` : '';
  return { host: `${url.protocol}//${url.hostname}${port}`, username, password };
}

// ── Pairing links ───────────────────────────────────────────────────────────
//
// The device's Cloud sync screen shows its pairing code as a QR encoding
// `<panel>/?code=ABCD2345` (Dart: `pairingPanelLink` in
// lib/data/cloud_config.dart). Scanning it lands the user here with the code
// already in hand, which removes the slowest step of pairing: reading eight
// characters off a television and typing them into a phone.

/// The alphabet `gen_pairing_code()` emits — no I/L/O/0/1, so a code read off a
/// screen can't be mistyped into a *different* valid one. Length is fixed at 8
/// by the same function (supabase/migrations/…_cloud_sync_init.sql).
export const PAIRING_CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
export const PAIRING_CODE_LENGTH = 8;

const PAIRING_CODE_RE = new RegExp(
  `^[${PAIRING_CODE_ALPHABET}]{${PAIRING_CODE_LENGTH}}$`,
);

/// A pairing code in canonical form, or null when it isn't one.
///
/// Case and surrounding whitespace are forgiven (a scanned or pasted link may
/// carry either); anything else is refused rather than repaired. The value
/// comes off a URL, so it is attacker-supplied by construction — everything
/// downstream treats it as a code, and it reaches `claim_pairing` as one, so
/// the shape check is the boundary.
export function normalisePairingCode(raw) {
  const code = String(raw ?? '').trim().toUpperCase();
  return PAIRING_CODE_RE.test(code) ? code : null;
}

/// The pairing code carried by a panel link, or null when there isn't a
/// well-formed one.
///
/// Fails closed in every ambiguous case — a missing parameter, a malformed URL,
/// a code of the wrong shape — because the fallback is simply the form the user
/// was going to fill in anyway. There is nothing to be gained by guessing.
export function pairingCodeFromUrl(href) {
  let url;
  try {
    // The base makes a relative href parseable; it is never read back out.
    url = new URL(String(href ?? ''), 'https://panel.invalid');
  } catch {
    return null;
  }
  return normalisePairingCode(url.searchParams.get('code'));
}

/// [href] with its `code` parameter removed, as a path+query+hash suitable for
/// `history.replaceState`, or null when there was nothing to remove.
///
/// The code is stripped once it has been *used*, not on arrival: a magic-link
/// sign-in can return in a fresh tab, and that tab re-reads the code from the
/// URL it was handed. Cleaning earlier would drop it exactly for the users who
/// aren't signed in yet — which is most people scanning this.
export function urlWithoutPairingCode(href) {
  let url;
  try {
    url = new URL(String(href ?? ''), 'https://panel.invalid');
  } catch {
    return null;
  }
  if (!url.searchParams.has('code')) return null;
  url.searchParams.delete('code');
  const query = url.searchParams.toString();
  return `${url.pathname}${query ? `?${query}` : ''}${url.hash}`;
}

// The scanned code has to survive a magic-link sign-in, which is the whole
// point of the feature: the person scanning a television's QR on their phone is
// exactly the person least likely to be signed in already.
// `signInWithOtp`'s `emailRedirectTo` carries no query string (and widening it
// would risk the project's redirect allow-list), and the link commonly opens in
// a *different tab* — so `sessionStorage` is not enough either. It is stashed in
// `localStorage` instead, under the same short TTL the server gives the code.
export const PAIRING_CODE_KEY = 'iptvs_pair_code';

/// Matches `request_pairing`'s 10-minute expiry. A stash older than the code it
/// holds is worse than useless — the claim would fail and the prefill would
/// only mislead — and it keeps a code from resurfacing days later.
export const PAIRING_CODE_TTL_MS = 10 * 60 * 1000;

function pairingStorage() {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

/// Remember [code] across a sign-in redirect. Silently does nothing when
/// storage is unavailable (private mode, blocked third-party storage) — the
/// signed-in path never needs the stash, and the fallback is a typed code.
export function stashPairingCode(code, storage = pairingStorage(), now = Date.now()) {
  const valid = normalisePairingCode(code);
  if (!valid) return;
  try {
    storage?.setItem(PAIRING_CODE_KEY, JSON.stringify({ code: valid, at: now }));
  } catch {
    // Quota/private-mode failure: the shortcut degrades to same-tab only.
  }
}

/// The stashed code if there is a live one, else null. Re-validates the shape on
/// the way out: storage is user-writable, so what went in is not proof.
export function readStashedPairingCode(storage = pairingStorage(), now = Date.now()) {
  let parsed;
  try {
    const raw = storage?.getItem(PAIRING_CODE_KEY);
    parsed = raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== 'object') return null;
  if (typeof parsed.at !== 'number' || now - parsed.at > PAIRING_CODE_TTL_MS) return null;
  // A clock that moved backwards (timezone/NTP correction) shouldn't extend the
  // TTL indefinitely, but it also shouldn't invalidate a code that is genuinely
  // fresh — treat only the future beyond one TTL as nonsense.
  if (parsed.at - now > PAIRING_CODE_TTL_MS) return null;
  return normalisePairingCode(parsed.code);
}

export function clearStashedPairingCode(storage = pairingStorage()) {
  try {
    storage?.removeItem(PAIRING_CODE_KEY);
  } catch {
    // Nothing to do: an unremovable stash still expires on its own TTL.
  }
}
