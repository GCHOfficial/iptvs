# Sources — EPG guides, subscription expiry, the M3U→Xtream upgrade, and Stalker adult genres

Detail for the provider-layer areas whose rules are summarised in CLAUDE.md: how a subscription
expiry is obtained per provider, and how an M3U source that is really an Xtream panel gets
upgraded. Read this before touching `subscriptionExpiry()` on any `Source`,
`lib/sources/expiry.dart`, `lib/sources/m3u_upgrade.dart`, or the expiry cache. It also keeps the
record of the Stalker portal **watchdog (keep-alive)**: a falsifiable experiment that shipped in
0.1.80 and was **removed** when the next export falsified it — read that section before proposing
it again.

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

A guide that fails **mid-feed** rethrows. Completing normally would commit a *truncated* guide as
a whole one: `replaceEpgStream` would drop the previous guide and advance `epg_synced_at`, so a
network drop 80% of the way through a large guide would cost the user the complete one they had,
with no retry for the whole refresh interval. Throwing abandons the whole refresh and keeps the
last good guide.

The *reason* changed once and the rule did not. Batches used to be fed straight into the caller's
open transaction, so a mid-feed failure genuinely could not be taken back. They now go through a
[spool](#the-refresh-runs-behind-the-channel-list) first, so nothing is committed either way — but
a truncated guide is still a truncated guide, and there is no way from inside the merge to tell
how much of one arrived. Rethrowing stays correct; it is now conservative rather than forced.

If **every** guide fails without yielding, the last error is rethrown for the same reason: a
normally-completed empty stream reads as a successful *empty* guide, and clearing the cache over
a transient blip is the outcome to avoid.

### The refresh runs behind the channel list

`LibraryRepository.load` returns as soon as the channels are ready and refreshes the guide
afterwards. Awaiting it put the whole download and parse — 5–10 seconds with a single top-up guide
— between the user and a channel list that was already in hand, on every forced reload.

Backgrounding it was tried once before and reverted within the day, because it deadlocked. The
mechanism is worth stating precisely, because nothing about it is visible from the call site:
`AppDatabase.replaceEpgStream` holds **one write transaction** for the whole ingest (that is its
atomicity contract, and it is right), and the batches it consumed were produced lazily — the first
thing each guide does when the transaction pulls on it is an HTTP download. So the transaction
stayed open across the network, on the single sqflite connection the entire app shares, and
sqflite serialises *everything* on it: not just other writes but channel reads, now/next queries
and favorite toggles too. Awaited, that was hidden behind the spinner the user was already
watching. Unawaited it became a multi-second freeze, and switching source mid-ingest hung outright
— `channel_list_focus_test` sat for ten minutes on sqflite's own
`database has been locked for 0:00:10` warning. The lock also had **no upper bound**: a guide
server that accepts a connection and then stalls held the whole application's database until the
read timeout fired.

Two pieces make it safe, and neither is optional on its own:

* **`ProgrammeSpool` (`lib/data/programme_spool.dart`)** drains the merged guide to a temporary
  file *before* any transaction opens. Fetch, decompress and parse happen with nothing blocked;
  the transaction then spans local inserts only — bounded, deterministic, and with no network
  inside it. Peak memory is one batch, the same bound the streaming parser already works to, so
  this trades transient disk for a lock window rather than for RAM. Frames are length-prefixed
  precisely so a truncated spool throws instead of replaying as a shorter guide, which
  `replaceEpgStream` would commit as a complete one.
* **`EpgIngestCoordinator` (`lib/data/epg_ingest.dart`)**, held on `AppDatabase` because the
  contended resource is *that connection*, keeps one refresh at a time app-wide. Starting one
  cancels its predecessor and **waits for it to actually stop** — cancellation is cooperative, so
  "cancelled" and "no longer touching the database" are different moments and only the second is
  safe to build on. `AppDatabase.close` **awaits** `shutdown()`, and that is not optional: an
  ingest mid-transaction does not stop because the connection closed, so skipping the wait merely
  moves it into `_db.close()`, which has no cancellation and logs nothing. A widget test that ended
  while a guide was still being written hung there for its full ten-minute timeout, with only
  sqflite's `database has been locked for 0:00:10` warning to go on. Waiting costs milliseconds —
  the transaction is local, and the token has already stopped it feeding further batches.

Because the list is now on screen before the guide, two things had to follow it. `AppDatabase`
announces a replaced guide on `epgChanged` (carrying the source id — a background refresh for the
source the user just *left* reaches the same stream, and re-reading for that one would blank the
current source's now/next), which `LiveController` subscribes to; without it the new guide would
sit in the database, unread, until the one-minute poll came round. And `LibraryRepository.load`
decides staleness *before* scheduling rather than inside the refresh, so a load with nothing to do
leaves `pendingEpgRefresh` null — the live status line reads that to append `· updating guide…`,
and an already-fresh guide would otherwise flash the message for a frame on every load.

### Two things the user can now see that they could not before

**The rows are sized from what the source *says*, not only from what has arrived.** A channel row
is 72 px without an EPG line and 112 px with one, and the guide now lands after the list is built —
so a source's very first load would draw short rows and jump. `LiveController.expectsEpg` takes the
source at its word while a refresh is running: Stalker and Xtream always report `supported`, M3U
does when it has an EPG URL, and anything reporting `unknown` keeps the old wait-and-see behaviour
rather than sizing rows tall for a guide that may never come. `_settleEpgRefresh` re-reads now/next
*before* clearing the flag, or the rows would drop to 72 px for the frames between the two and rise
again. `_resyncLiveRowExtent` still re-reveals the selection whenever the extent does change
(docs/tv-navigation.md) — this reduces how often that happens rather than replacing it.

**A guide that fails with nothing behind it says so.** A failed refresh retains the cached guide and
is otherwise silent, which is right — except when there is no cached guide to retain, where "this
source has no EPG" and "every guide URL is broken" look identical and only the second is actionable.
`LibraryRepository.lastEpgRefreshFailed` records the verdict (a *superseded* refresh sets neither —
it is not an outcome), and `LiveController.epgUnavailable` pairs it with an empty guide so the live
status line reads `· guide unavailable`. Deliberately both conditions: a failure standing behind a
cached guide is the retain policy working, not something to alarm anyone about.

### Saving the list forces a refetch

`load` skips the fetch while the cached guide is younger than its max age — right for a
periodic refresh, wrong when the *set of guides* just changed, where it would leave a newly added
guide invisible for hours and reading as a broken feature. So saving calls
`AppDatabase.invalidateEpg`, which clears `epg_synced_at` and deliberately **keeps** the cached
programmes: dropping them would blank every channel's EPG until the refetch lands, and for the
whole retry interval if it fails, where keeping them means the worst case is the guide the user
already had.

The running `Source` still holds the old URL list, so the guides take effect when the source is
next built — the same "applies on next load" contract the catch-up overrides have, and what the
save confirmation says.

### Guide size: disk and parse time, not memory

Every downloaded XMLTV guide — provider and user-added alike — is **streamed to a file**
(`xmltvGuideFeed` → each source's `_downloadGuide` → the shared `downloadXmltvGuide` →
`HttpOperation.readToFile`) and parsed from there on the worker isolate
(`parseXmltvFileBatched`), which inflates gzip as it reads. Only the file *path* crosses the
isolate boundary. The guide used to be held whole — compressed body, then decompressed body —
which is why `kEpgWorkload` stopped at 128 MiB / 512 MiB: an "all countries" guide (~192 MB
compressed, ~1.7 GB decompressed) was ~1.9 GB of heap on a 2 GiB TV box. The limits are now
**512 MiB body / 4 GiB decoded (a bound on parse work)**, 30-minute download deadline, 20 s idle
timeout unchanged. The body ceiling bounds the bytes **as transmitted**, i.e. compressed ones
since the request now asks for gzip; the decoded ceiling is enforced on every inflation pass.

### Compression and conditional GET

Both live in `downloadXmltvGuide` (`sources/epg_guides.dart`), which M3U, Xtream and Stalker all
call — three byte-identical copies of the old fetch, and conditional-request handling is not
something that may drift between them. Each source still supplies its own `HttpClient` and its
own `User-Agent`; Stalker's still deliberately bypasses the portal transport, so no MAC cookie or
Bearer token reaches a user-supplied guide host.

**`Accept-Encoding: gzip` is sent explicitly.** Every one of those clients sets
`autoUncompress = false` — on purpose, so the bounded isolate-decoded gzip path in `net.dart`
stays the only decoder and never `dart:io`'s unbounded one — but that *also* suppresses the
default `Accept-Encoding` `dart:io` would have sent. The result, visible in a real diagnostics
export, was a third-party guide arriving as a **196,725,492-byte uncompressed body on every
refresh**, competing with a 4K live stream for bandwidth at app start. The body is written to
disk exactly as received and inflated later from its magic bytes, never from a header — which is
what lets one path serve a transport-compressed body and a `.xml.gz` served as-is alike. The two
can now arrive **together** (a server that compresses an already-compressed file), so
`_decodedGuideBytes` takes a second inflation pass when the first one's output is itself gzip;
two passes and no more, each bounded, because a third would be a crafted file rather than a
guide. A server that ignores the header is unaffected.

**Each guide is then revalidated rather than re-downloaded.** `downloadXmltvGuide` sends
`If-None-Match`/`If-Modified-Since` from the last body's validators, and **a 304 is fed to the
parser exactly as a fresh download would have been** — the same `parseXmltvFileBatched` over the
same kind of file — so `mergeEpgGuides` and `replaceEpgStream` see precisely the programmes a 200
would have produced. None of the EPG contract moves: a 304 is never an empty guide, a guide that
fails before yielding is still skipped, one that fails mid-feed still rethrows, and a cancelled
feed still ends in `LoadCancelledException`. It is **per guide**, because the merge is rebuilt
whole on every refresh and one guide being unchanged says nothing about the others.
`ingestion compressed_bytes=…` sums reused bodies alongside downloaded ones (what the guide
*cost on disk*, not what crossed the wire); the per-guide
`[http:epg] status=200|304 content_encoding=… body_bytes=…` line is what separates the two in an
export.

**The cache** (`data/epg_guide_cache.dart`) lives in `getApplicationCacheDirectory()/epg_guides`
— app-private, and deliberately **not** `getTemporaryDirectory()`, which every platform here
reaps behind the app's back and which would turn conditional GETs into full downloads at random.
A body is downloaded straight into its slot and parsed from there, so a reuse costs no copy.
Three things are load-bearing:

* **File names are `sha256(url)`, never the URL.** A guide URL routinely carries the provider's
  credentials (`xmltv.php?username=…&password=…`), and a cache directory is readable by anything
  that can read the app's storage, lands in device backups, and is the first thing a support
  request screenshots. The sidecar (`<hash>.meta`) holds `etag`, `last_modified` and `bytes` and
  nothing else — no URL. It is device-local and must **never** move into `SourceConfig.settings`,
  which rides the source row into the cloud.
* **Nothing here can fail a refresh.** No cache directory, an unreadable sidecar, a body whose
  length disagrees with its sidecar (the corruption test, which also covers the crash window
  between writing the sidecar and renaming the new body over the old), a 304 answered to a
  request that carried no validator — each one degrades to an unconditional download. A guide
  whose response carried neither validator is not cached at all: it could never be revalidated,
  so the body would be pure disk cost.
* **Eviction is a size cap with LRU** (`kEpgGuideCacheMaxBytes`, 256 MiB — roughly ten times the
  realistic working set of a provider guide plus one or two gzipped top-ups), sweeping stale
  `.part` files from killed processes as it goes. Chosen over the two alternatives on purpose.
  Nothing here can see the *configured* set — sources are built per card and per profile, a cloud
  pull rewrites `fields['epgUrls']` with no local event, and two sources can share a URL — so
  "delete what nobody references" would need a global enumeration of every profile's sources to
  reach the conclusion a cap reaches by itself: an entry nobody revalidates stops being touched
  and ages out. And `AppDatabase.invalidateEpg` is the *wrong* hook: it fires when the guide
  **list** is saved, and its job is to redo the merge (the claim order changed), not to dispute
  the bytes — the body for a URL that is still configured is still exactly what the server would
  send, so clearing it there would throw away the one download the user's edit did not
  invalidate. Only a cap also bounds the disk a 200 MB guide can take, which is the number that
  matters on a 2 GiB TV box. A body larger than the whole cap is parsed but never stored, and a
  set of guides that jointly exceeds the cap simply re-downloads across refreshes — today's
  behaviour, never worse.

`.part` names are unique per attempt: refreshes are serialised by `AppDatabase.epgIngest`, but
two sources can be configured with the same guide URL and `readToFile` deletes its destination
before writing, so a shared name would let one download truncate the other's.

The total across every guide reaches `LibraryRepository._ensureEpg`'s
`ingestion compressed_bytes=…` line through the optional `EpgByteReporting` capability —
`xmltvGuideFeed`'s `onDownloaded` callback (a cheap `file.length()` stat on the body in hand,
downloaded or reused, never on a guide that could not be obtained) sums into each source's own
`lastEpgCompressedBytes`, reset at the top of `_guideFeeds`. `decoded_bytes` stays `unknown`:
nothing tracks a true decompressed-XML byte total end to end (the parser inflates and discards as
it goes), and `ProgrammeSpool.bytes` is a different, smaller quantity — the re-serialized
programme rows, not the source guide — so it would be a misleading stand-in. Stalker's own portal
guide (`get_epg_info`) reports nothing here either, since it isn't a single HTTP body; only its
XMLTV top-ups contribute.

The parse itself is event-level (`_GuideExtractor` in `xmltv.dart`): a programme's channel,
start and stop are read off its start tag, and one that can't contribute is skipped by depth
counting without building — or even entity-decoding — its subtree. That matters because a
user-added guide is mostly *other people's* channels. It is also what makes the early decision
sound: `XmltvChannelResolver` freezes its claims at the first `resolve` and must have seen every
`<channel>` by then, and a `selectSubtreeEvents` predicate evaluates a whole event list before any
node from it reaches the handler — so resolving from a predicate could freeze before the last
declarations in the same chunk. `toXmlEvents(validateNesting: true)` keeps a truncated body an
error rather than a short guide.

Measured (dev box, 400 MB decompressed synthetic guide, 400 of 20,000 channels matched): old
path 26.3 s and 1.19 GB peak RSS, new path 13.4 s and 198 MB, identical output; 1.2 GB
decompressed parses in ~38 s at the same ~200 MB. Parse time still scales with the guide — expect
several minutes for an all-countries guide on a TV-box CPU — and it runs off the main isolate and
outside the ingest transaction (`ProgrammeSpool`), so it costs a background core, not the UI.

### Stalker

The portal's guide comes from `get_epg_info`, not XMLTV, so it joins the merge as a plain feed
wrapping that call; only the top-ups go through `xmltvGuideFeed`. `epgBatched` returns null when
there are no top-ups, keeping a portal-only source on the code path it has always taken.

`get_epg_info` is decode+map in one pass, off the main isolate once the body crosses the same
256 KiB threshold `get_all_channels` uses: `_portalEpg` fetches raw bytes via `_requestBytes`
(never `_call`, which decodes on the calling isolate) and hands them to the top-level
`_ingestStalkerEpg` worker, run inline below the threshold and under `Isolate.run` above it —
the same split `_fetchAllChannelsFromBytes`/`_ingestStalkerChannels` already used (CLAUDE.md
"Large provider payloads"). A portal-wide EPG answer decoded and mapped inline was a shipped ANR
(`LinkedHashMap.from` under `StalkerSource._portalEpg` in a GC on the UI isolate). The `debugApi`
test seam still returns decoded `js` directly — there's no raw body to offload there — so
`_mapPortalEpg` keeps that path's original inline mapping, byte-for-byte the same logic
`_ingestStalkerEpg` applies from bytes (`StalkerSource._epochToDate` is `static` so both share
it). `_fetchPortalEpgFromBytes` mirrors `_fetchAllChannelsFromBytes`'s auth/retry shape exactly:
a token-invalid result re-handshakes once and retries, a portal-error result throws
`StalkerException` (redacted via `redactStalkerDiagnostic`), and neither ever lets the raw
response skip that check.

Two more Stalker-specific points. Its channels carry **no `tvg-id`**, so an extra guide reaches
them purely through name matching — on this provider that path is not a fallback, it is the only
one. And third-party downloads use a separate `_downloadGuide`, never `_requestBytes`: the latter
is the portal transport and sends the MAC cookie and the portal Bearer token, which must never
reach an arbitrary user-supplied host. Only the emulated profile's `User-Agent` carries over,
since some guide hosts reject a default one.

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

The load-time path costs more than one request when the source is a **large playlist**, and it is
worth knowing why. On success it saves and re-runs `_loadActive`, which builds a new
`LibraryRepository`; `ChannelListScreen.didUpdateWidget` then disposes the old controllers, which
cancels the in-flight load's `LoadToken`. A 66 MB playlist on a low-end TV box takes ~55 s to fetch
and parse, so the probe reliably kills the very first load of exactly the source it is trying to
improve. That is survivable only because a superseded load now **seeds an empty cache** rather than
discarding its catalog (CLAUDE.md, "Async publishes are generation-guarded"); before that, such a
source could never obtain a first cache at all.

The same-id upgrade is also why a superseded load may never *overwrite* a populated cache. The
converted config deliberately keeps the source id, so an M3U load still in flight can outlive the
conversion — and writing playlist-shaped rows under a source that is now Xtream leaves
`XtreamSource.resolve` falling back to `channel.id` for the stream id, i.e. every channel silently
unplayable with a fresh `synced_at` and no age check to heal it.

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

**"Until the user asks" is doing more work than it looks, and the panel now says so.** For a source
managed from the panel, nothing on the device converts it on its own, so the panel's own suggestion
is realistically the only prompt the user ever sees. It shipped as a muted `.hint` with a ghost
button and read as decoration; a field report is what showed the cost. A panel-managed playlist
pointed at a provider that answered `HTTP 884` on `get.php` while its `player_api.php`
authenticated normally seconds earlier stayed an M3U indefinitely — the one conversion that would
have routed around the refused endpoint was the one nothing was allowed to perform. It is now a
`.callout` (accent-tinted box, real heading, `primary` button) that states both the gain and the
fact that devices will not do this for a managed source. The panel still only ever *suggests* — it
cannot verify a provider, for the reasons in "Why the web panel suggests and the app proves" — so the
caveat about setting Kind back to `m3u` stays beside it.

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

## Stalker adult ("censored") genres

Ministra marks adult genres `censored: 1` in `get_genres`, and many portals
leave those genres' channels **out of `get_all_channels`** — a MAG box keeps
them behind its parental PIN and fetches them per genre. The same portals
answer `get_ordered_list` for that genre normally. Reading `get_all_channels`
alone therefore produced a source whose adult categories were silently empty
(a user report: "why don't the adult channels show on my Stalker source?").

`StalkerSource._withCensoredGenres` runs after a successful `get_all_channels`
and fetches, through `get_ordered_list`, exactly the genres that are adult
**and** came back with no channels. A genre is adult when the portal flags it
(`censored` as `1`/`"1"`/`true`) or when its title says so
(`isCensoredStalkerGenre`: adult/xxx/porn/erotic/18+) — portals that never set
the flag still name the genre. Properties worth keeping:

- **No cost when the portal already included them**: a populated genre is never
  re-asked, so a portal that does return its adult channels makes zero extra
  requests.
- **Fails soft**: a refused `get_genres` or `get_ordered_list` keeps the catalog
  already fetched; losing every channel over the adult genres would be worse.
- **Diagnostics** log `censored_genres=N backfilled_channels=M` under
  `parse:stalker`, so an export shows whether the backfill ran and found
  anything.
- The paginated fallback (`_fetchChannelsWithOrderedList`) needs none of this —
  it already walks every genre with `get_ordered_list`.

Hiding them again is the user's call, through the per-source category toggles
in `source_settings_screen` — the app does not filter adult content itself.

Pinned by `test/stalker_censored_genres_test.dart`.

## The portal watchdog (keep-alive) — tried in 0.1.80 and removed

**This section is a record of a falsified hypothesis.** The keep-alive shipped in
0.1.80 as a one-variable experiment and the next export falsified it, so the
whole thing — the `PlaybackKeepAlive` capability, `playback_keep_alive.dart`,
`stalker_watchdog.dart`, the `StalkerSource` timer, the `quiet:` transport flag
and their tests — is gone. The MAG behaviour it was built from is kept below
because it was sourced rather than guessed and is the thing a future attempt
would start from; nothing in the app polls it today.

### What it was built from, and what it did

A Stalker portal on Android TV, ExoPlayer native: a live channel playing at a
steady 50 fps with zero dropped frames, whose connection ended cleanly
(`kind=ended`) every ~26–29 s of wall clock for ~24–27 s of media, re-resolved
through `itv:create_link` each time. This app imposes no such timeout and
`kind=ended` is a *clean* end of stream, so something on the provider's side was
closing the body. The one thing a real MAG set-top box does on that cadence and
this app did not is poll the portal's watchdog, so 0.1.80 polled it:
`type=watchdog&action=get_events` with `cur_play_type=1`, on the profile's
`watchdog_timeout` clamped to the documented 30–300 s (else the STB client's own
30 s), armed by a successful live `LibraryRepository.resolve` and released
through a single-slot, token-checked coordinator.

### What falsified it

The 0.1.80 export, from the same portal and the same box. Two independent
findings, either of which is fatal on its own:

1. **The server was not closing the body at ~26 s at all.** The `stream source
   eof` line added alongside the watchdog (docs/player.md "Live auto-reconnect")
   reads `sinceLoadMs=6032 ahead=21011 played=4580 bytes=8649536`: the provider
   delivers ~25.6 s of media in ~6 s — a connect backlog, sent far faster than
   real time — and then closes. Playback then runs on from the buffer for
   another ~20 s, which is the entire reason the drop *looked* like a ~30 s
   timeout. A ~6 s close is not a session expiry, and no keep-alive cadence
   between 30 and 300 s could have been relevant to it. The ~26 s period was the
   **buffer's** period, not the server's.
2. **Every poll failed, and failed in the worst possible way.** On this portal
   `get_events` answered with a null / missing `js`, which
   `StalkerSource._looksTokenInvalid` reads as "the token went bad" — so each
   poll **re-handshook mid-playback**, re-authorizing the portal on a 30 s
   cadence underneath a running stream. The experiment therefore did not test
   the hypothesis; it added a periodic re-authorization to a session that was
   otherwise fine.

Finding (1) is also what the open-source middleware predicted all along, and
that argument is recorded in full below: nothing in `stalker_portal` kills a
running body when the polls stop.

### What replaced it

Nothing on the provider side. The real cost of the drop was never the drop — it
was the ~4 s of frozen picture the recovery spent afterwards, which the Android
player now removes by **pre-resolving the next locator at the source's EOF**,
while the picture is still running on the buffer: docs/player.md "Live
auto-reconnect" → "The pre-resolved reconnect". The ~26 s cycle itself is a
property of this provider's delivery and is not something a client can change.

### The MAG behaviour, kept for reference

Sourced from the open-source Stalker middleware (`azhurb/stalker_portal`; the
upstream repository was stripped when it was archived, so the files below were
read through a complete fork, `tzpeng/stalker_portal`, whose tree matches the
published layout).

| | |
| --- | --- |
| **Request** | `type=watchdog`, `action=get_events`, `cur_play_type`, `event_active_id`, `init` (`c/watchdog.js:71-105`) |
| **Transport** | the ordinary authorized portal call — same MAC cookie, `Bearer` token and `JsHttpRequest=1-xml` as every other action (`c/xpcom.common.js:698-721,797-821`) |
| **Interval** | `watchdog_timeout` seconds from the profile (`c/xpcom.common.js:1172`, handed to `watchdog.run` at `:1399`) |
| **Interval fallback** | **30 s** — the client's own `this.request_timeout = 30000` (`c/watchdog.js:8`), reached through `timeout*1000 \|\| this.request_timeout` (`c/watchdog.js:23`), so an absent or zero portal value leaves a real box polling every 30 s |
| **Portal-side default** | `watchdog_timeout = 120`, documented as "Timeout for polling the server in seconds. Set between 30 and 300." (`server/config.ini:196-197`) |
| **First poll** | immediate, with `init=1`, *before* the interval is scheduled (`c/watchdog.js:59-68`) |
| **`cur_play_type`** | `1` live TV, `11` TV archive, `14` timeshift, `2` VOD, `0` when nothing is playing or playback is paused (`c/xpcom.common.js:2065+`, `c/watchdog.js:76-80`) |

And what the server does with it (`server/lib/watchdog.class.php:20-85`): one
`UPDATE users SET keep_alive = NOW(), ip = …, now_playing_type = …,
just_started = …, last_watchdog = NOW()`, then any pending event for this box.
`init` is "the box just started", not "playback just started" — the portal
stores it as `users.just_started` and uses `init == 0` to gate MAC-clone
detection (`:22-31`).

**What the open-source server does *not* do is kill a stream when the polls
stop.** `keep_alive` drives "is this box online" in the admin UI
(`server/lib/user.class.php:686`: `keep_alive >= NOW() - watchdog_timeout`) and
the streamer-session counts used for load balancing and statistics
(`server/lib/streamserver.class.php:195-200`, `server/lib/func.php:164,189,203`,
all `keep_alive > now - watchdog_timeout*2`). Nothing in that code path
terminates a running body. That was recorded as the strongest argument *against*
the hypothesis while it was live, and the export above is what turned it from an
argument into a result.

### If it is ever revisited

Three things that attempt would have to do differently, and they are the three
reasons this one proved nothing:

- **Find a portal whose `get_events` actually answers.** A null/missing `js`
  must not be read as a bad token on this endpoint — it is the ordinary "no
  pending event" reply from panels that implement the write and not the event
  queue. A watchdog that re-handshakes on every poll is strictly worse than no
  watchdog.
- **Pick a session whose drop is not explained by the buffer.** `stream source
  eof sinceLoadMs=` is now in the export, so "the server closed at N seconds" is
  directly readable; a keep-alive hypothesis only has a subject when N is near a
  plausible session timeout rather than near the connect backlog.
- **Say up front what would falsify it.** That part worked: the experiment was
  written to be killed by the next export, and it was.
