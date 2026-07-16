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

/// Turns a Supabase error into a safe string to display to the user. Always
/// call `console.error(error)` at the call site first for debugging — this
/// function intentionally never surfaces `error.details` or `error.hint`,
/// which can carry internal schema/query detail.
export function friendlyError(error) {
  const message = (error && typeof error.message === 'string') ? error.message : '';
  let out;
  if (message.startsWith('iptvs: ')) {
    out = message; // server-controlled, safe to show verbatim
  } else if (PERMISSION_ERROR_RE.test(message)) {
    out = 'Not allowed.';
  } else {
    out = 'Something went wrong.';
  }
  return scrubUrls(out);
}
