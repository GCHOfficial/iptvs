# Sources — subscription expiry and the M3U→Xtream upgrade

Detail for two provider-layer areas whose rules are summarised in CLAUDE.md: how a subscription
expiry is obtained per provider, and how an M3U source that is really an Xtream panel gets
upgraded. Read this before touching `subscriptionExpiry()` on any `Source`, `lib/sources/expiry.dart`,
`lib/sources/m3u_upgrade.dart`, or the expiry cache.

## Subscription expiry

`Source.subscriptionExpiry()` feeds the sources screen's badge as an explicit
dated/unlimited/unknown value. **Never collapse unlimited into unknown** — they are different
answers and the user has a right to the first one. Shared parsing is in `expiry.dart`.

### Stalker: authorize before asking

`subscriptionExpiry()` calls `connect()` — handshake **plus `get_profile`** — before
`account_info`/`get_main_info`, then falls back to the profile `js` that call already fetched
(`_lastProfileJs`, reused rather than re-requested).

The ordering is the whole fix. A MAG session is not established by the handshake: `get_profile` is
what binds the token to the STB, and the real set-top always sends it first. `_call` only
guarantees `_resolveEndpoint` (handshake + token), so asking `account_info` straight out of a
freshly built source made it the first action on an unauthorized session, which portals answer
with an empty `js` or an error. And that was not a rare path — the sources screen builds a *fresh*
source per card, so it was the **only** path the badge ever took. Hence "unknown on every portal"
rather than on some of them.

### Field and format coverage

MAG portals put the end date in odd places, and in odd formats. Both halves matter:

- **Named fields**, in preference order: `end_date`, `expire_billing_date`,
  `subscription_expire`, `exp_date`, `expire_date`, `tariff_expired_date`, `end_date_timestamp`.
- **Stuffed fields** — free-form boxes panels render the date through: `phone` (the classic),
  `fname`, `ls`. Deliberately *not* `comment`/`description`: a date in a note is more likely about
  something else, and a wrong expiry is worse than none.
- **Nested containers**: the root map, then `tariff`, `account_info`, `info`, `data`. Root beats
  nested; named beats stuffed.
- **Every candidate field gets the lenient text extraction**, not just `phone`. Panels return
  `end_date` as `October 20, 2026` / `20.10.2026` / `expires 2026-10-20` at least as often as
  something `DateTime.parse` accepts, and only `phone` used to be read that way — so an ordinary
  `end_date` sitting in plain sight read as no answer at all.
- **Month-name dates are supported** (`October 20, 2026`, `Oct 20 2026`, `20 October 2026`),
  English only. That is PHP's default formatting, i.e. what a stock Ministra/stalker_portal skin
  emits — the single most common shape the parser used to reject outright. English only is
  deliberate: matching short words against twelve month names in a dozen languages is far more
  ways to read a date out of something that isn't one.

### The far-future sentinel, and the trap in it

A date beyond year 2100 (`9999-12-31`, `2999-01-01`) is a panel spelling "unlimited" as a date, and
is reported as **unlimited**.

**Only when written as a date, never as a bare number.** These are the same fields panels stuff a
phone number into, and a phone number read as Unix seconds lands centuries out —
`40712345678` → year 3260 — so the rule would have reported a lifetime subscription for a
customer's phone number. An out-of-range *timestamp* is garbage and stays unknown. The pre-existing
test missed this because it asserted on the parsed **date**, and unlimited carries none; the
regression test asserts on the kind.

### Diagnosing an unknown answer

When Stalker still ends up unknown, the payload is logged as key **names** plus
`expiryValueShape` masks (`dddd-dd-dd`, `aaaaaaa dd, dddd`) — never values. Key names are schema
and safe in full; values are not, because `phone`/`fname`/`ls` are customer PII and a panel that
stuffs the expiry into them is stuffing it next to the account identity. A shape answers "which
field, what format" and carries no content, which is the entire question needed to fix the next
portal that misses.

## The expiry cache

`lib/data/expiry_cache.dart`, keychain-backed like `UpdateStore`. Every sources-screen card builds
its own `Source` and asks the provider, so uncached the screen is a full portal round trip **per
card, per visit** — and for Stalker that is now handshake + `get_profile` + `get_main_info`.

**Deliberately not `SourceConfig.settings`.** That blob rides the source row into the cloud
(`push_sources`), so caching there would push a timestamp rewrite on every refresh, advance
`profiles.updated_at` through `touch_profile_snapshot_revision` on every paired device, and hand
other devices a cached answer for a portal they may not reach. An expiry reading is device-local,
disposable and derived — none of which is what `settings` is for.

**Invalidation is a fingerprint, not just the id.** `expiryConfigFingerprint` hashes `kind` +
`fields`, so an edited credential invalidates the entry while a rename doesn't. A hash rather than
the fields themselves: there is no reason for a second copy of a password to exist just to answer
"did this change?".

**Three staleness rules** (`isStale`):

| state | trusted for | why |
| --- | --- | --- |
| dated / unlimited | 12 h | a subscription end date changes on renewal and at no other time |
| unknown | 30 min | as often a briefly unreachable portal as a real absence; pinning a failure for half a day makes a recovered portal look permanently broken |
| within 48 h of the date (or past it) | not at all | the renewal window — the one time the user is watching this badge expecting it to move |

That last rule is why there is no manual refresh control: the case that would need one is the case
that never caches.

**A cache that can hide a diagnostic has to say when it is doing so.** Serving from cache is
logged (`expiry from cache source=… kind=… ageMin=…`), and saving a source forces a re-check
(`canServeCachedExpiry(force:)`, from `didUpdateWidget`). Both exist because of a real
investigation: a source whose lookup once returned unknown served that from cache on every later
visit *without calling the provider*, so the provider's own "here is why" logging never ran either
— producing an exported log with a stubbornly unknown badge and, correctly but uselessly, nothing
at all about it. Nothing else could dislodge it, since an edit that leaves the credentials alone
keeps the same fingerprint.

## M3U → Xtream upgrade

A very large share of M3U sources are an Xtream panel's `get.php` link. As a flat playlist such a
source works — live channels play — but it is strictly worse than the Xtream config the same
credentials support: **no Movies, no Series, no subscription expiry**, because none of that is in a
playlist. The panel would answer all three on request.

`upgradeM3uToXtream` (`lib/sources/m3u_upgrade.dart`) is the one implementation, with a pure
`couldBeXtreamPanel` pre-check and a `debugApi` seam so the whole path is testable without HTTP.

**It fails closed.** The panel must actually authenticate (`player_api.php`); anything else —
refused, unreachable, not a panel — leaves the source exactly as it was. This rewrites a saved
source, so a guess is not good enough.

**It keeps the same source id**, so the SQLite cache, favorites and playback positions carry over.
That is what makes it an upgrade rather than a new source that happens to look the same.

### Where it runs

- **Edit-save** (`EditSourceScreen`) — the original path.
- **Load time** (`HomeShell._loadActive`), `unawaited` and after the UI is up. It ends in a network
  round trip, and putting that on the boot path would let a slow or dead panel hold the app on a
  spinner. It exists because the save-only path meant a source added once and never touched again
  stayed a flat playlist forever. Terminates by construction: the saved config is `xtream`, so
  `couldBeXtreamPanel` rejects it on the second pass. Costs one small background request per app
  start, and nothing at all for a plain playlist.
- **`source_settings_screen`'s "Upgrade to Xtream" tile** — shown when `couldBeXtreamPanel`, probes
  on tap (never on screen open), converts only on a real authentication, then prompts to push.

### Cloud-managed sources are skipped at load time

`pullSources` replaces every cloud-managed source wholesale from its cloud row (`store.setAll`),
and a pull runs on **profile switch** as well as on demand. Converting one on this device would be
undone by the next pull and re-attempted on the load after it: the source flipping kind
indefinitely, one panel probe plus one `_loadActive` (repository rebuild + library reload) per
cycle — and the change would never reach the cloud anyway, because pushing is a deliberate user
action this must not take on the user's behalf.

So the load-time path checks `CloudSync.managedSourceIds` and **fails closed to skip**: the cost of
skipping is a source that stays M3U until the user asks; the cost of guessing wrong is that loop.
The settings-screen tile is how a managed source gets there, explicitly, followed by a push.

The push side needs nothing: `sources.kind` is a plain `check (kind in (...))` column with no
immutability trigger, `splitFields` sends `host` broad and `username`/`password` as secrets, and
the stale `playlistUrl` secret is preserved server-side (absent secret → preserve) but inert, since
`build()` switches on kind.

### Why the web panel suggests and the app proves

**Only the device can verify; only the panel can make it stick for every device.**

The panel detects the same shape (`xtreamCredentialsFromPlaylistUrl` in `panel/src/validate.js`,
mirroring the Dart `xtreamCredentialsFromUrl`) and offers "Switch to Xtream" with the fields
prefilled — but it must **never** convert on its own, because it cannot verify what it detects:

- The panel is served over HTTPS, so an `http://` provider URL is blocked as **mixed content**
  before CORS is even consulted. Most IPTV panels are http-only.
- Cross-origin `fetch` without `Access-Control-Allow-Origin` can't be read, and IPTV panels don't
  send it.
- `mode: 'no-cors'` issues the request but returns an **opaque** response — status reported as 0,
  body and headers unreadable — so a 200 with `auth:1`, a 404 and a 500 are indistinguishable. It
  rejects only on a network-level failure. "Something answered" is already true of a get.php link
  that works fine as a playlist, so it answers nothing.

Panel-side detection is therefore a guess about a URL *shape*, and some resellers proxy `get.php`
while serving no `player_api.php` at all — converting one of those blind turns a working source
into a broken one. Hence: the panel asks, the app proves.

Server-side verification (a Supabase Edge Function, which has no CORS problem) was scoped and
**deferred**. Two reasons, the second being the strong one: outbound HTTP to a user-supplied URL is
an SSRF surface whose sharp edge is DNS rebinding — Deno's `fetch` gives no way to pin a connection
to a validated IP — and, more fundamentally, it means sending provider credentials to the backend
in cleartext, which directly contradicts what E2EE exists to guarantee for a profile that has it
enabled. If it is ever built it needs its own threat model and an explicit decision for E2EE
profiles, not a rider on a source-handling change.
