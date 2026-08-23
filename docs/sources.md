# Sources — EPG guides, subscription expiry, and the M3U→Xtream upgrade

Detail for two provider-layer areas whose rules are summarised in CLAUDE.md: how a subscription
expiry is obtained per provider, and how an M3U source that is really an Xtream panel gets
upgraded. Read this before touching `subscriptionExpiry()` on any `Source`, `lib/sources/expiry.dart`,
`lib/sources/m3u_upgrade.dart`, or the expiry cache.

## Multiple EPG guides per source

A source has one guide by default — the provider's own (`xmltv.php` for Xtream, `get_epg_info`
for Stalker, an explicit `epgUrl` or the playlist's `url-tvg` header for M3U). A user can add
more in **Source settings → EPG guides**: extra XMLTV URLs that fill in the channels the guides
above them do not cover.

Storage is `fields['epgUrls']`, newline-separated, holding **only the additional** guides. The
primary keeps its existing key, which is the whole reason for a new one: `epgUrl` is read as a
single URL by every already-published build, and those builds pull this source from the cloud.
Widening it in place would hand them a blob they would fetch as one URL and lose their guide
over. It is a **secret** key (`secret_keys.dart`, and the strip in
`20260823000000_epg_urls_secret.sql`) — a guide URL carries provider credentials as often as a
playlist does.

### Merging is per channel, not a row union

`mergeEpgGuides` (`sources/epg_guides.dart`) consumes the guides in order and lets **the first
guide that carries a channel own it**; later guides are filtered against those claims. Claims
accumulate per guide and are merged in only once that guide is exhausted, so a guide is never
filtered against itself.

Concatenating the guides instead would be wrong, and quietly so. `programmes` rows are keyed by
`(source_id, channel_id)` with no record of which guide wrote them, and `AppDatabase.nowNext`'s
"now" half is a bare `start <= t AND stop > t` scan whose rows are folded into a map by channel
id — **last row wins, arbitrarily**. Two guides covering one channel would therefore make its
now-playing programme nondeterministic, flipping between them across refreshes, and would draw
overlapping cells in the EPG grid.

### Failure policy turns on whether the guide had yielded

A guide that fails **before yielding anything** — refused, 404, unreadable gzip — has written
nothing, so it is logged and skipped and the merge goes on. That matters more than it sounds: the
case that motivates the whole feature is a *provider* guide that is broken or thin, with the
top-up added to replace it. A hard-failing primary would block exactly that.

A guide that fails **mid-feed** rethrows. Its batches are already inside the caller's transaction
and cannot be taken back, so completing normally would commit a *truncated* guide as a whole one:
`replaceEpgStream` would drop the previous guide and advance `epg_synced_at`, so a network drop
80% of the way through a large guide would cost the user the complete one they had, with no retry
for the whole refresh interval. Throwing rolls the transaction back and keeps the last good guide.

If **every** guide fails without yielding, the last error is rethrown for the same reason: a
normally-completed empty stream reads as a successful *empty* guide, and clearing the cache over
a transient blip is the outcome to avoid.

### Saving the list forces a refetch

`_ensureEpg` skips the fetch while the cached guide is younger than its max age — right for a
periodic refresh, wrong when the *set of guides* just changed, where it would leave a newly added
guide invisible for hours and reading as a broken feature. So saving calls
`AppDatabase.invalidateEpg`, which clears `epg_synced_at` and deliberately **keeps** the cached
programmes: dropping them would blank every channel's EPG until the refetch lands, and for the
whole retry interval if it fails, where keeping them means the worst case is the guide the user
already had.

The running `Source` still holds the old URL list, so the guides take effect when the source is
next built — the same "applies on next load" contract the catch-up overrides have, and what the
save confirmation says.

### Stalker

The portal's guide comes from `get_epg_info`, not XMLTV, so it joins the merge as a plain feed
wrapping that call; only the top-ups go through `xmltvGuideFeed`. `epgBatched` returns null when
there are no top-ups, keeping a portal-only source on the code path it has always taken.

Two Stalker-specific points. Its channels carry **no `tvg-id`**, so an extra guide reaches them
purely through name matching — on this provider that path is not a fallback, it is the only one.
And third-party downloads use a separate `_downloadGuide`, never `_requestBytes`: the latter is
the portal transport and sends the MAC cookie and the portal Bearer token, which must never reach
an arbitrary user-supplied host. Only the emulated profile's `User-Agent` carries over, since
some guide hosts reject a default one.

### Matching: ids first, then names

`sources/epg_matching.dart`. The historical path is exact — a guide's `<programme channel="…">`
id looked up in a `tvg-id → channel id` map — and it is correct and cheap for a provider's own
guide, where both sides come from the same panel. It contributes close to nothing for a
**third-party** guide, which numbers its channels its own way: almost every id misses and the
extra guide lands empty. So names fill the gap.

**Name matching is for user-added guides only** (`epgNameIndexFor`); a provider's own guide stays
on exact `tvg-id` matching. Its guide and its playlist come from the same panel, so their ids
agree by construction and names would add only guesses — while turning it on there would silently
change the EPG of every existing install on upgrade (a channel that had no guide can acquire one
from a same-normalised-name channel, and since programmes are stored per `channel_id`, one guide
entry claiming several rows multiplies the ingest). It would also put an O(channels) index build
on the main isolate on every EPG refresh for users who added no guide at all, against a
250k-channel baseline. Gated, that cost is paid only by those who opted in.

`XmltvChannelResolver` settles claims over one streaming pass, which is enough because the XMLTV
DTD fixes document order as `(channel*, programme*)`: every `<channel>` declaration is seen
before the first `<programme>`, so the resolver can freeze a *globally* correct mapping on the
first `resolve` call rather than re-reading a multi-hundred-MB guide. Rules, in order:

1. A guide channel whose id is one of our `tvg-id`s claims that channel, outright.
2. A guide channel whose *name* normalises onto one of ours claims it — but only if rule 1 left
   it unclaimed, so a channel the guide already covers properly is never second-guessed.
3. A channel contested by two guide channels goes to **neither**. Two names that normalise alike
   are genuinely ambiguous, and picking by document order would be a coin flip rendered as fact.

Matching is **exact after normalisation, never fuzzy**. Edit-distance matching would paint a
channel with another channel's schedule, and wrong programme data is worse than none: the row
looks authoritative, the catch-up window is computed from it, and nothing about it reads as a
guess.

Normalisation (`normalizeChannelName`) folds case, punctuation and diacritics — including the
Romanian comma-below vs cedilla forms of `ș`/`ț`, which are distinct code points a playlist and
a guide routinely disagree on — drops stream-quality tokens as whole words (`hd`, `fhd`, `4k`,
`backup`, …, so `HDNet` and `Sharjah` survive intact), and strips a leading `RO:`/`UK |` country
tag, which is ubiquitous in playlists and absent from every real guide. Parenthesised content is
deliberately **kept**: `HBO (RO)` and `HBO (HU)` must not collapse into one key.

One guide channel can claim **several** of ours — a playlist routinely carries the same channel
as separate HD and SD entries, which share a schedule — but no more than `kMaxNameMatchGroup`
(8). Beyond that a name is a generic label rather than a channel identity, and since programmes
are stored per `channel_id`, an uncapped fan-out multiplies a ~10^6-programme guide into a
multi-million-row ingest. The whole group is dropped rather than the first few kept: there is no
principled way to pick the winners, and rule 3 already says an ambiguous match goes to nobody.
Name matching is purely additive over the exact path, so the cap only ever limits what it
*adds* — it can never take a guide away from a channel that had one.

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
