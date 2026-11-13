# Validation Baseline

This document defines the reproducible validation environment for ingestion,
persistence, playback lifecycle, and platform-input work. It records evidence;
it does not turn machine-specific timings into universal pass/fail thresholds.

## Automated checks

Run the normal correctness gate from a clean checkout:

```bash
flutter analyze
flutter test
```

The generated PowerShell updater integration tests deliberately skip on Linux
and execute in the Windows CI job, where they can exercise archive rejection and
rollback against the actual Windows PowerShell/runtime semantics.

## Network workload limits

All Dart HTTP clients use the named policies in `lib/data/net.dart`. Each
operation has both a non-resetting total deadline and an idle chunk timeout;
the reader checks the declared `Content-Length` before subscribing and checks
the actual byte count while streaming, so a missing or false length cannot
bypass the ceiling. Clients disable automatic gzip handling so compressed bytes
are bounded before `gzip` decoding. Gzip output is bounded and decoded in an
isolate for large/provider-controlled responses.

The policies are intentionally workload-specific: metadata and Stalker JSON are
small, while playlists, EPG, and Xtream catalogs allow the larger PR 0 fixtures.
Update artifacts stream to a temporary partial file, hash as they arrive, and
delete that file on cancellation, timeout, or validation failure. PR 10 replaced
the final buffered-decode-then-map-inline step for the two largest catalog
shapes with one-pass ingestion: `decodeLiveChannelsBytes`/`decodeMediaItemsBytes`
(Xtream, `lib/sources/xtream_source.dart`) and
`StalkerSource.debugIngestChannels`'s underlying `_ingestStalkerChannels` seam
(`lib/sources/stalker_source.dart`) take the raw response bytes and hand back
typed `Channel`/`MediaItem` lists directly — the intermediate dynamic JSON tree
is built and consumed entirely inside the worker isolate (`compute` for Xtream,
`Isolate.run` for Stalker) and never crosses back to the caller. XMLTV guides
get the same treatment plus streaming: `parseXmltvBatched`
(`lib/sources/xmltv.dart`) yields bounded `Programme` batches with a single
in-flight batch at a time, feeding `AppDatabase.replaceEpgStream` so a large
guide commits incrementally inside one transaction instead of holding the
entire parsed guide in memory. The guide's *source text* is bounded too: both
XMLTV workers feed `toXmlEvents()` a chunked `Stream<String>` (256 KiB pieces,
`_xmlChunkBytes`) instead of one `utf8.decode` of the whole body, which used to
materialise a UTF-16 copy roughly twice the decoded size and hold it live beside
the compressed and decoded bytes for the entire parse. Measured effect on the
100,000-programme gzip workload: **peak RSS 598 MB → 260 MB**, parse 1,024 ms →
871 ms. This is only correct because both stages buffer across chunk
boundaries — `Utf8Decoder` carries an incomplete multi-byte sequence into the
next chunk, and the `xml` package's event decoder keeps a `carry` string for a
tag split across chunks; a naive per-chunk `utf8.decode` would corrupt any
non-ASCII character straddling a boundary. Pinned by the "non-ASCII titles
survive the parser chunk boundaries" test in `test/widget_test.dart`. What is
was still not streamed was the HTTP body itself; it now is — the guide is
streamed to a file and the worker inflates and parses it from disk
(`parseXmltvFileBatched`), so a guide's size no longer costs memory at all
(`kEpgWorkload`: 512 MiB body / 4 GiB decoded — the body half now bounds
*compressed* bytes, since guide requests send `Accept-Encoding: gzip` and are
conditional; measurements in docs/sources.md "Guide size"). All three keep the existing inline path below
their isolate thresholds (256 KB for Xtream/Stalker JSON, 64 KB for XMLTV) —
isolate spawn overhead isn't worth it for the many small calls. Disk-backed M3U
parsing is explicitly deferred: `ChannelListScreen` and its controllers hold
the full decoded channel list in memory regardless of how it was parsed, so
streaming the parse alone yields no memory win without a much larger change to
how the UI consumes the list.

An oversized monolithic live catalog is not automatically a source failure.
Stalker retries through its paginated `get_ordered_list` endpoint; Xtream merges
category-scoped `get_live_streams` responses and deduplicates stable stream IDs.
If one page/category still exceeds its individual bound, the request is rejected.
M3U has no server pagination, so larger-than-memory playlists remain bounded by
the existing response-size policy; see the disk-backed-parsing deferral above.

The regression contract is in `test/net_workload_test.dart`: slow-drip total
deadlines, idle stalls, early/streamed size enforcement, hostile gzip expansion,
legitimate gzip, and partial-file cleanup.

Run the opt-in large-ingestion baseline separately so normal CI does not allocate
hundreds of megabytes for the 250,000-channel workload:

```bash
IPTVS_RUN_BASELINE=1 flutter test test/performance_baseline_test.dart --reporter expanded
```

The test emits one `IPTVS_BASELINE` JSON record per workload. Retain those lines
with the device/host description and commit being tested. The measurements cover
fixture construction, parse/decode time, input size, and process RSS change.

The workloads are generated deterministically by
`test/support/workload_fixtures.dart`. They contain only reserved `.invalid`
hosts and synthetic metadata; do not replace them with captured provider data.

## Public database history

Repository tags establish the database versions that need public upgrade
fixtures:

| Tags | Schema version |
|---|---:|
| `v0.1.0`–`v0.1.7` | 8 |
| `v0.1.8`–`v0.1.10` | 9 |
| `v0.1.11`–`v0.1.15` | 10 |
| `v0.1.16`–`v0.1.34` | 11 |
| `v0.1.35`+ | 12 |
| unreleased | 13 (current) |

The supported upgrade claim covers exactly these released schemas (8–12 → 13).
Versions 1 and 7 remain useful regression fixtures because they cover the full
upgrade chain and the historical missing-`external_metadata` repair, but they
never shipped in a tagged release and sit outside the supported claim. The
reviewable v8–v11 fixture builders live in
`test/support/historical_database_fixtures.dart`; PR 12 re-verified them
against their tagged source (fresh-install DDL at each range's first tag, plus
a normalized-DDL diff across each range confirming no intra-range drift) and
pinned the contract in `test/released_schema_fixtures_test.dart`: every fixture
is migrated and compared with a fresh installation over tables, columns,
indexes, and foreign keys (pragma-based, so `ALTER`-added columns compare
structurally), seeded favorites/positions/EPG/metadata are validated after the
upgrade, and each migrated fixture is opened a second time to prove stable
startup. Re-run that suite before changing the migration contract.

Schema 13 adds `idx_prog_now(source_id, start, stop, channel_id)`. It is an
index-only addition — no table, column, or row semantics change — so the v12
fixture is the v11 fixture plus `idx_prog_source_start`, and the v12→13 upgrade
is a single `CREATE INDEX IF NOT EXISTS`. Because the app opens the database
without an `onDowngrade` handler, running an older build against a newer file
re-stamps the version down without reverting anything; every `onUpgrade` branch
must therefore be safe to re-run, and `persistence_test.dart` covers that for
the v13 branch specifically.

### now/next query cost

The `sqlite-library-epg` workload seeds exactly two programmes per channel, so
both halves of `nowNext` match nearly every row they scan — the best case for
any query plan, and blind to the scan cost the live tab actually pays every 60
seconds. `sqlite-nownext-realistic` (5000 channels x 48 programmes, ~2 days of
guide) exists to measure that, and reports the pre-change SQL alongside the
current implementation so the comparison stays reproducible:

| Metric | Legacy plan | Current |
|---|---:|---:|
| "now" query | 109 ms | — |
| "next" query | 127 ms | — |
| `nowNext` (both halves, incl. `Programme` construction) | — | 66 ms |

The gap widens with guide size: on a 960k-programme guide the same comparison
measured 296 ms → 49 ms for "now" (covering index) and 962 ms → 96 ms for
"next" (`INDEXED BY idx_prog_lookup`, which removes a `USE TEMP B-TREE FOR
GROUP BY` over every future programme).

The cost side is EPG ingestion: a third `programmes` index makes
`sqlite-library-epg`'s `epgWriteMs` rise from ~668 ms to ~750 ms (+12%) at
100k programmes, and grows the cache file proportionally. Accepted — the write
happens on a refresh schedule, the read happens every minute.

## Reference environments

Fill one row per actual run. Do not mark native lifecycle or input gates complete
from a Linux unit-test run.

| ID | Target | Hardware/OS | Memory | Display/input | Status |
|---|---|---|---:|---|---|
| CI-Linux | Analyze/unit tests | GitHub-hosted Ubuntu | Runner-dependent | None | Existing |
| DEV-Linux-1 | Host ingestion baseline | Linux 7.1.3, Ryzen 7 7840HS | 14 GiB | None | Captured 2026-07-14 |
| TV-Low-AVD-1 | Android TV API 36 emulator | 2 virtual cores | 2 GiB | 1920×1080, 320 dpi, D-pad | Captured 2026-07-15 |
| CI-TV-AVD-36 | `android-tv;x86_64` API 36 emulator (CI) | 2 virtual cores | 2 GiB | `tv_1080p`, D-pad only | Automated — see below |
| CI-TV-AVD-28 | `google_apis;x86_64` API 28 emulator (CI) | 2 virtual cores | 2 GiB | `tv_1080p`, D-pad only | Automated — see below |
| Phone-AVD-1 | Android phone | Pixel-class emulator, 4 virtual cores | 2 GiB | Touch + system Back | Captured 2026-07-15 |
| Win-SDR | Windows x64 | Owner development devices | Not recorded | SDR, keyboard, mouse | Extensively exercised before PR 0 |
| Win-HDR | Windows x64 | Owner development devices | Not recorded | HDR, keyboard, mouse | Extensively exercised before PR 0 |

## Android TV emulator CI

The owner has no Android TV box. The emulator job is therefore the **only**
automated place the television-only flows are exercised at all, and the only
reason a D-pad regression in them can fail a check rather than a user report.

- Workflow: [`.github/workflows/android-tv-emulator.yml`](../.github/workflows/android-tv-emulator.yml)
- Driver: [`tool/android_tv_emulator_check.sh`](../tool/android_tv_emulator_check.sh) — plain
  `adb`, runnable locally against any attached device or AVD
  (`tool/android_tv_emulator_check.sh --serial … --apk …`).
- Triggers: PRs touching `android/**`, `lib/player/**`, `lib/screens/**`, the script or the
  workflow; `workflow_dispatch`; a weekly cron. **Keep it non-required**: an emulator that fails
  to boot, or a briefly unreachable public demo stream, must not block a merge.

### Which system image, and why not API 28 on a TV image

API 28 is the level that matters most (the SurfaceTexture finalizer crash lived there), but
Google ships **no x86_64 Android TV system image below API 36** — the `android-tv` repository
(`dl.google.com/android/repository/sys-img/android-tv/sys-img2-1.xml`) carries 32-bit `x86` only
for API 21–34, and Flutter has not shipped a 32-bit x86 Android engine for years, so an
`android-28;android-tv;x86` AVD cannot run this app at all. The matrix therefore splits the two
things an "Android TV emulator" was wanted for:

| Leg | Image | What only this leg gives |
|---|---|---|
| API 28 | `system-images;android-28;google_apis;x86_64`, `tv_1080p` profile, D-pad-only input | The API-28 runtime/texture path. `isTelevision` is **false** here — it is not a TV image — so the two-pane layout comes from the window-size branch of `isWideLayout`, not the TV branch. The script asserts `wide=true` from the app's own `layout window=…` line rather than assuming it. |
| API 36 | `system-images;android-36;android-tv;x86_64` | A genuine TV image: `UiModeManager`/leanback detection (`device class television=true`), the TV layout and the leanback launcher category. |
| API 36, Skia GL | `system-images;android-36;android-tv;x86_64`, launched with `--force-skia-gl` | The **non-default renderer**. The app ships Impeller except on a one-entry SoC denylist (docs/player.md "The Flutter renderer"); this leg forces Skia OpenGL with the debug-only `--ez iptvsForceSkiaGl true` extra, hard-fails unless the app reports `renderer=skia-gl reason=forced-debug`, and then drives the whole TV flow on it. A renderer dimension on one level, not on both: the cost is one extra emulator boot on a non-required job, and API 36 is the leg worth doubling because it is the genuine TV image. No emulator carries the denylisted SoC, so this proves the mechanism, never the match. |

### Live-cut stitched handover (opt-in)

A fourth, separate leg (`build-apk-livecut` + `drive-live-cut`, API 36 android-tv x86_64 only)
exercises the Android "stitched handover" live splice (docs/player.md "The stitched handover
(Android)") against a synthetic burst/hold/close provider, `tool/live_cut_server.py` — a
stdlib-only Python server that reproduces the Stalker shape this feature targets: single-use
`play_token`s, single-connection accounts, a 20–30s backlog burst at several times real time,
6–18s of real-time delivery, then a clean close. The APK for this leg alone is built with
`--dart-define=IPTVS_LIVE_CUT_URL=http://10.0.2.2:8765`, which turns on two otherwise-nonexistent
`DemoSource` channels ("Live cut (rotating)" — a fresh single-use URL every resolve, exactly like
a Stalker `create_link`; "Live cut (stable URL)" — a static URL, the control case).
`tool/android_tv_emulator_check.sh --live-cut` plays the rotating channel and asserts ≥3 `native
live handover … mechanism=splice` lines with `repeatedMs=0` and no `native live reconnect` after
the first splice, then plays the stable-URL control and asserts the inverse: zero splices (the
mechanism must never arm for a static URL) but ≥1 reconnect (proving the connection really was
cut). Like the other behavioural checks, these are reported but non-fatal outside `--strict`. The
server's own `--self-test` (a synthetic in-process TS fixture, no ffmpeg) gates the job before the
real 900s ffmpeg-generated fixture is built and served.

Note: an emulator proves ExoPlayer/`TsExtractor`/software-decoder acceptance of the spliced
stream, never the Realtek hardware decoder — see docs/player.md "The stitched handover (Android)"
"What's unproven".

### What the run actually asserts

Everything is observed through logcat; the app already prints each of these in a debug build
(`DiagnosticsLog.addAndPrint`, `_logPlayback`, the native `logNative` relay), and none of them
carries a URL, header or credential:

| Scenario | Assertion |
|---|---|
| First run reaches a playable catalogue | `[iptvs.library] device class television=…`, then `[iptvs.library] layout window=… wide=… tv=…`. `DemoSource` is selectable with no provider and no credentials (profile picker → Skip → "Use demo streams"), which is what makes a catalogue possible at all. |
| OK on a channel starts a preview (×5, with Home + relaunch between) | `[iptvs.library] preview live source=… channel=… id=…`, plus `preview native engine open` for the shared engine. |
| Preview → fullscreen → Back (×5) | `HdrPlayerActivity` becomes the resumed activity (`dumpsys`), `iptvs.shared: fullscreen adopted the shared preview engine` once per cycle, and ≤4 Back presses leave the player. |
| Pause ≥35 s, resume, "Go to live" | `native live latency behind drift=…` (the one-shot crossing of `LiveLatency.WARN_MS`), the chip reachable by D-pad, `native live latency reset reason=golive drift=…` with `drift ≥ 30000`, and — the invariant with no other observable effect — focus landing on play/pause afterwards. OK is pressed the moment the chip takes focus, and the focus check counts only **after** the go-live reload: the live chrome auto-hides after 4.5 s, and a late OK merely re-reveals it with default focus on play/pause, which once read as a passing hand-back. |
| Channel up/down | `[iptvs.player] zap play source=… channel=… id=…` per settled zap. |
| The renderer in use | `[iptvs.library] renderer=<impeller\|skia-gl> reason=<why>`, reported on every leg. On the Skia GL leg the value is asserted and a mismatch is a **hard** failure — a leg that silently fell back to Impeller would be worse than no leg. |
| Throughout | `FATAL EXCEPTION` attributed to the package, `ANR in <pkg>`, a tombstone naming the package (`>>> <pkg> <<<`), and any unexpected pid change all fail the run. |

Artifacts per leg: full logcat, a crash excerpt, screenshots at every step, `meminfo`, and a
`run-as` listing of the app data directory.

**Assertion strength.** The health checks (crash / ANR / native crash / process death / reaching
the channel list / escaping the player with Back) always fail the run. The *behavioural* checks
additionally depend on the runner reaching and decoding the public demo streams, so they report
loudly but set the exit status only under `--strict` (`workflow_dispatch` input, or
`IPTVS_TVEMU_STRICT=1` locally). Promote them to strict once a first green run has shown the
mechanisms work on the hosted runner.

### What it does not validate

An emulator is a software renderer on a server. It has:

- **no hardware HEVC/AV1/Dolby-Vision decoders and no vendor codecs** — nothing here says anything
  about decoder selection, the ExoPlayer→mpv fallback on undecodable video, or the libdovi path;
- **no HDR output path** — no PQ/HLG signalling, no embedded→native escalation decision, no
  panel mode switch;
- **no real memory pressure** — the ANR/OOM classes that produced the shipped regressions
  (`DartAesGcm._ghash`, the 250k-channel `StandardMessageCodec` message) need a real low-end box;
- **no passthrough audio** — the catch-up audibility and AC-3/E-AC-3 checks are unaffected by it;
- **no real remote** — `adb shell input keyevent` injects the same key codes, but not a vendor
  remote's repeat timing, its extra keys, or its IME behaviour.

Those remain owner-run on hardware, as does
`integration_test/player_soak_test.dart` (see docs/player.md).

## Metrics to retain

For ingestion:

- Commit and Flutter/Dart versions
- Fixture and decoded sizes
- Item count
- Total parse/decode/import duration
- Longest measured main-isolate stall on an application profile build
- Peak resident memory
- Time to first usable channel and first usable EPG result
- Rejected or malformed row count

For SQLite:

- Fresh or migrated schema origin
- Replacement transaction duration
- Now/next query duration and `EXPLAIN QUERY PLAN`
- Peak resident memory during replacement and row conversion

For native playback:

- Platform/device and stream type
- Preview/fullscreen/fallback/PiP or mini-player transition sequence
- Active player, surface, timer, and channel-owner counters before and after
- Result of the 100-cycle open/close soak

## Threshold policy

Do not set limits from a fast development workstation alone. Capture the first
complete baseline on the low-memory Android TV device, then record explicit
budgets in this section. A performance PR must report both its before and after
records and explain any material memory or latency regression.

Current budgets: intentionally unset before closed testing. The recorded values
are regression comparison points; optimize concrete slow paths without blocking
early user feedback on emulator-derived limits.

## Recorded host baseline

This run used the PR 0 working tree based on commit
`966418fec7a07646163073377c6a3a1013b93dd0`, Flutter 3.44.5, and Dart 3.12.2 on
`DEV-Linux-1`. Values are rounded from the emitted JSON. `Max RSS` is the
cumulative process high-water mark, so later rows include memory retained by
earlier workloads in the same test process.

| Workload | Items | Input | Parse/decode | Max RSS |
|---|---:|---:|---:|---:|
| M3U | 10,000 | 1.63 MB | 42 ms | 167 MB |
| M3U | 50,000 | 8.35 MB | 124 ms | 215 MB |
| M3U | 250,000 | 42.51 MB | 493 ms | 460 MB |
| XMLTV gzip | 100,000 programmes | 0.93 MB compressed | 871 ms | 260 MB |
| Xtream live JSON | 50,000 | 9.60 MB | 58 ms | Cumulative |
| Xtream VOD JSON | 50,000 | 8.25 MB | 55 ms | Cumulative |
| Xtream series JSON | 50,000 | 6.65 MB | 47 ms | Cumulative |
| Stalker channel JSON | 50,000 | 10.63 MB | 57 ms | Cumulative |

### Field data point: M3U on a low-end television

The host numbers above understate the M3U cold path by two orders of magnitude on
real set-top hardware, which is worth recording because a design decision rests on
it. From a user's exported diagnostics (2026-09-03), on an Android TV box
reporting `television=true`, `960x540 dpr 2.00`:

| Stage | Evidence in the export | Duration |
|---|---|---:|
| Playlist download | `[http:playlist] compressed_bytes=66418882 decoded_bytes=66418882` (uncompressed) | ~29 s |
| `compute()` decode + parse | gap to `[parse:m3u] rejected_rows=0` | 22–26 s |
| **Total cold load** | | **~55 s** |

Compare the 250k-channel host row: 42.51 MB parsed in 493 ms. The same class of
work here is a ~53x larger wall-clock cost for a 1.6x larger input — the parse is
CPU-bound on a slow SoC, and the isolate hop copies the whole buffer.

This is the measurement behind the "a superseded load still seeds an empty cache"
rule (CLAUDE.md, "Async publishes are generation-guarded"): at 55 s, essentially
any repository rebuild — including the once-per-app-start M3U→Xtream probe —
cancels the load, and discarding the catalog meant the cache never got populated
and the next attempt paid the 55 s again.

Not yet measured on that device, and worth a soak: peak RSS while the 66 MB
buffer, the isolate's copy of it, and the resulting channel list are all live at
once.

SQLite baseline with 50,000 channels and 100,000 programmes:

| Operation | Duration (as recorded) | After sealed locators |
|---|---:|---:|
| Replace channel library | 1,848 ms | 1,856 ms |
| Read and map channels | 3,433 ms | 143 ms |
| Replace EPG | 666 ms | 669 ms |
| Current/next query | 428 ms | 421 ms |

**`channelReadMs` no longer includes any crypto.** `readChannels` returns models
whose playback locator is still *sealed* (`extra['secretLocator']`);
`LibraryRepository` reveals exactly the one model that is about to reach a
`Source` (CLAUDE.md "Sealed playback locators"). So the right-hand column
measures SQLite + `jsonDecode` + model construction only — it is **not**
comparable to the left-hand column as a like-for-like crypto measurement, and a
future change that reintroduces read-time decryption will not show up as a
number regression here but as a failure of the counting assertion in
`test/persistence_test.dart` ("a bulk read decrypts nothing").

### Write side: bulk locator sealing + chunked batches

Two Play-vitals ANRs ("Input dispatching timed out") landed on this write path,
and both were fixed together:

- **`DartAesGcm._ghash` on top of the stack.** `replaceLibrary` sealed one
  locator per channel with an `await`ed `protectSecretLocators`, *inside* the
  write transaction, on the UI isolate. `cryptography`'s pure-Dart `AesGcm`
  completes synchronously behind its `Future`, so 50k–250k of those never yield
  to the event loop — and they held the single shared sqflite connection's
  write transaction (which serialises every read in the app) for the whole
  catalog's crypto. `protectSecretLocatorsBulk`
  (`lib/data/secret_locator_vault.dart`) now splits the maps on the calling
  isolate (no crypto) and hands only the *locator* submaps to a worker in
  chunks of `kLocatorSealChunkRows` (10,000), skipping the hop entirely below
  `kInlineLocatorSealRows` (256) where the spawn would dominate. The raw 32-byte
  key crosses into the worker so it can rebuild the key with
  `newSecretKeyFromBytes` and keep the round-key memoization described above;
  key material is never logged. The channel path also seals **before** the
  transaction opens, as the media paths always did. On-disk format is unchanged
  (same nonce||ct||mac concatenation), including the preserve-existing-ciphertext
  branch `resetEnrichedMediaDisplayFields` relies on.
- **`StandardMessageCodec.writeValue` on top of the stack.** On Android sqflite
  is a MethodChannel, and `replaceLibrary`/`replaceMediaLibrary`/
  `appendMediaItems` each built ONE batch holding every category and row —
  a single giant message encoded on the UI isolate and decoded into the Java
  heap. They now flush in `_libraryInsertChunk` (1,000) row chunks, the same
  trick the EPG paths already used: `batch.commit` inside a transaction does not
  COMMIT, so atomicity, the `onlyIfAbsent` predicate's evaluation inside the
  transaction, and ascending rowids along the list (categories are read back by
  rowid — CLAUDE.md "Category order") are all preserved. Categories are flushed
  before the first row chunk so their rowids still lead.

The same `DartAesGcm._ghash` shape existed in a second, rarer write path:
`AppDatabase._migrateLegacyCacheSecrets`, the one-time repair that runs only
when `SecretLocatorVault.generatedNewKey` is true (a pre-sealing-build
upgrade, or a backup-restored install whose key didn't survive). It queried
the whole `channels`/`media_items` tables and then sealed one row at a time
with an `await`ed `protectSecretLocators`, inside a transaction, exactly like
the old `replaceLibrary` — on a 250k-channel cache restored from a backup
with no key, a guaranteed ANR on first launch. It now seals via
`protectSecretLocatorsBulk` before the transaction opens and flushes its
UPDATEs in the same `_libraryInsertChunk` (1,000) batches (order doesn't
matter here — these are UPDATEs against rows that already exist, not inserts
whose rowids something reads back by position). Not covered by the
re-measurement below (it runs once per install and the host harness doesn't
drive it), but exercised at a scale past `kInlineLocatorSealRows` (the
worker-isolate path) by `test/persistence_test.dart` ("AppDatabase legacy
cache secret migration").

Re-measured on `DEV-Linux-1` (Flutter 3.47.7 / Dart 3.13.5, sqflite_common_ffi),
same 50,000-channel / 100,000-programme fixture, three runs each:

| | `libraryWriteMs` | `channelReadMs` | `epgWriteMs` | `nowNextMs` |
|---|---:|---:|---:|---:|
| Before (per-row seal inside the txn, one giant batch) | 1,725 / 1,736 / 1,761 | 143 | 648–693 | 359–385 |
| After (bulk seal before the txn, 1,000-row chunks) | 973 / 976 / 977 | 128–141 | 663–701 | 373–378 |

Caveats on that number. The host runs sqflite through FFI, so **none** of the
improvement can be the MethodChannel chunking — that half of the fix is
unmeasurable here and needs an on-device Android run to confirm. What the host
run does show is that moving the seals out of the transaction and off the
per-row `await` treadmill roughly halves the wall clock on its own; the
decomposition between "crypto in a worker" and "no event-loop ping-pong against
the open transaction" was not isolated. The ANR fix is about *where* the work
runs, not about this number.

**Still to verify on hardware:** the two ANR clusters disappearing from Play
vitals, and `libraryWriteMs` / main-thread stall on the low-end Android TV box
for a 250k-channel catalog (where the Java-heap decode of the old single batch,
not the crypto, was likely the larger half).

The 3,433 → 143 ms drop came in two independently revertable steps, both
measured on the same host and fixture:

| Step | `channelReadMs` |
|---|---:|
| As recorded above (re-measured on the current tree) | 4,188 ms |
| Sequential read loop, single model construction, memoizable AES key | 1,436 ms |
| Sealed locators (no read-time decryption) | 143 ms |

The first step changed no contract: `Future.wait` over one future per row was
the largest single component (dropping it also cut the baseline process's peak
RSS from ~983 MB to ~292 MB), `_readChannelRow` was building each `Channel`
twice, and `SecretLocatorVault` was wrapping its key bytes in a bare `SecretKey`
that `cryptography`'s AES round-key expansion cannot memoize against. That last
one is invisible to host tests — their secure-storage-less fallback branch
already built the key through `newSecretKey()` and got the memoization — so it
only pays off on device, and the 4,188 ms figure understates what production was
paying before it.

**Superseded numbers — read before comparing against anything older.** Until the
fixture was corrected, the channel rows carried only `extra: {'tvgId': …}`. No
`extra` key matched `_secretLocatorFields`, so `protectSecretLocators` produced an
empty locator map, `SecretLocatorVault.encrypt` returned `''` on the empty-input
short-circuit, and `restoreSecretLocators` returned early on the way back — the
run measured **zero AES-GCM operations**. That is not what any real source does:
M3U stores `extra['url']` and Stalker stores `extra['cmd']`, both locator fields,
so both encrypt on write and decrypt on read, once per row. (Xtream live stores
only `{streamId, tvgId}` and genuinely is exempt, which is why the gap stayed
invisible.) The fixture now seeds a `url`, and the previously recorded
**540 ms replace / 195 ms read** became **1,848 ms / 3,433 ms** — the read
regressing 17.6×. Treat the old figures as measuring an unrepresentative
workload rather than as evidence of a regression since.

The read cost was larger than per-row crypto alone accounted for: `readChannels`
resolved `Future.wait` over one future per row, so 50,000 concurrent futures'
scheduling compounded the per-row `jsonDecode` + AES-GCM open. Both halves ran on
the UI isolate and on the *common* cold-start path (`LibraryRepository` serves
from cache whenever it is fresh) — which is why this path was worth the two-step
rework recorded above. Measured decomposition at the time: AES-GCM was only
~11% of the 3.4 s, the `Future.wait` fan-out ~40%, and the double model
construction plus decrypt-wrapper churn most of the remainder. No schema change
was needed or made (`schemaVersion` stays 12); the on-disk `extra` format is
byte-identical before and after.

These are comparison values, not release budgets. In particular, the parser
tests call synchronous parsing functions directly and therefore do not measure
the production isolate handoff, frame scheduling, or isolate data-copy cost.

### One-pass isolate ingestion baseline (PR 10)

Recorded on the same `DEV-Linux-1` host (Flutter 3.44.5, Dart 3.12.2) against
the PR 10 working tree. `Inline` calls the worker function directly with no
isolate spawn; `Isolate round trip` goes through the same routing production
uses (`compute` for Xtream, `Isolate.run` for Stalker) so the spawn/copy
overhead is visible on its own. **Recorded on dev host only; TV-device
stall/RSS capture is pending** — the low-memory Android TV device run is
owner-run, same as the rest of this document's TV rows.

| Workload | Items | Input | Inline | Isolate round trip |
|---|---:|---:|---:|---:|
| Xtream live one-pass (`decodeLiveChannelsBytes`) | 250,000 | 48.76 MB | 512 ms | 695 ms |
| Xtream VOD one-pass (`decodeMediaItemsBytes`) | 250,000 | 41.82 MB | 548 ms | 803 ms |
| Stalker one-pass (`debugIngestChannels`) — no prior baseline existed for this seam | 250,000 | 54.14 MB | 545 ms | 824 ms |

XMLTV batched vs. single-list, same 100,000-programme/0.93 MB-compressed
fixture as the `XMLTV gzip` row above:

| Workload | Items | Batches | Parse |
|---|---:|---:|---:|
| `parseXmltv` (single list, existing) | 100,000 | — | 908 ms |
| `parseXmltvBatched` (drained end to end) | 100,000 | 100 | 850 ms |

Draining the streamed batches was slightly faster than building one big list,
consistent with never materializing the full result twice. As with the table
above, these are dev-host comparison points, not release budgets, and the
isolate round trip numbers still don't capture production frame-scheduling or
UI-thread contention.

## Recorded Android profile baseline

`Phone-AVD-1` ran a Flutter 3.44.5 profile build on a Pixel-class emulator with
2 GiB RAM and four virtual CPU cores. The exported DevTools performance capture
contained 1,375 frames at 60 Hz. Excluding the first 100 startup frames:

| Metric | Result |
|---|---:|
| Median frame time | 9.7 ms |
| p95 frame time | 19.9 ms |
| p99 frame time | 63.3 ms |
| Frames over 33.3 ms | 37 / 1,275 (2.9%) |
| Frames over 100 ms | 8 / 1,275 (0.6%) |
| Maximum build time | 39.7 ms |
| Maximum raster time | 90.4 ms |

The interaction felt responsive, but a real Stalker portal exposed that the
initial 16 MiB Stalker response ceiling was too low. PR 3 raises only that named
policy to 64 MiB encoded / 128 MiB decoded and retains a generated 80,000-row
catalog regression above the old limit. This capture does not include a
successful completion of that catalog load, so time-to-first-channel, peak RSS,
and ingestion stall evidence remain pending for the follow-up run.

`TV-Low-AVD-1` ran the same Flutter profile build on an API 36 Android TV
emulator configured with 2 GiB RAM, two virtual cores, and a 1920×1080 display
at 320 dpi. Excluding the first 100 startup frames from 3,675 captured frames:

| Metric | Result |
|---|---:|
| Median frame time | 3.9 ms |
| p95 frame time | 19.1 ms |
| p99 frame time | 31.5 ms |
| Frames over 33.3 ms | 33 / 3,575 (0.9%) |
| Frames over 100 ms | 6 / 3,575 (0.2%) |
| Maximum build time | 157.8 ms |
| Maximum raster time | 70.9 ms |

The run felt responsive and loaded the 28.6 MB Stalker live catalog plus a
10.2 MB EPG response. Movie/series cards initially failed before image loading:
the grid intentionally passed `double.infinity` to `_Poster`, which forwarded
it to `imageCacheSize` and threw while converting infinity to an integer.
The card now derives finite cache dimensions from its layout constraints, and
the shared helper defensively handles non-finite/invalid metrics. Peak RSS was
not captured before the profile process exited and remains pending.

## Play vitals clusters recorded as not app-fixable

Recorded so they aren't re-investigated each round. Source: the Play Developer Reporting API
(`errorIssues:search` / `errorReports:search`), 5 Sep – 2 Nov 2026. Play version codes are the
Google Play workflow's run number (vc10 = v0.1.61, vc12 = v0.1.70).

- **TCL G10_4K_GB_NF** (Realtek RTD2875P, 2 GB, armeabi-v7a, Android 12; the owner believes it
  is a tablet). Issues `8a71db94…`, `9f7864ed…`, `a7eece6f…`, `abf2077e…`, `bf7bf02c…`: 5 crashes,
  one user each, vc12.
  - Three are `scudo::reportHeaderCorruption` aborts: the allocator metadata before a live chunk
    was overwritten, i.e. a stray write, not a double free.
  - The other two are SIGSEGVs in libflutter and in ART's concurrent-copying GC, the latter two
    in the same process in the same hour.
  - So the victims span three separate memory managers on one device. That reads as hardware or
    a vendor driver, with the app as victim.
  - The Skia frames (`ParagraphImpl`, `TArray<…>::~TArray`) are Impeller's text layout, not a Skia
    backend: Flutter 3.47 has none on Android, and identical-code folding makes the printed
    `TArray` type arbitrary.
  - There is no on-device instrumentation path, since HWASan and MTE are arm64-only. **Owner
    decision 2026-11-03: leave as is.**
  - **Reopened 2026-11-05 on Sentry evidence: one user, one TV (`fushan_euT`, same chipset), seven
    native crashes across 0.1.76 and 0.1.78** (IPTVS-5 to -9, IPTVS-A, -B): SIGILL in Skia text
    layout, a scudo `corrupted chunk header` inside BoringSSL's free during Dart's TLS teardown, and
    aborts. No playback thread is running in any of them, and they're unrelated to that user's
    Stalker EPG 503s. The tombstones carry none of Impeller's Vulkan worker threads, so the TV is
    most likely already on Impeller's OpenGLES backend. The test is therefore **Impeller off**
    (`renderer-test-apk.yml`, Skia OpenGL), not `ImpellerBackend=opengles`:
    - crashes stop → they follow the Impeller renderer on this device;
    - same signatures continue → the renderer is ruled out and "not app-fixable" stands.
  - **Outcome: the renderer-test APK stopped them**, across several sources and streams. **Fixed
    by targeted Skia GL in 0.1.79, pending on-device confirmation**: `player/RendererPolicy.kt`
    denylists the SoC model `RTD2875P` and `MainActivity.getFlutterShellArgs()` adds
    `--enable-impeller=false` for that model alone, so every other device keeps Impeller
    (docs/player.md "The Flutter renderer"). Still owed on the TV itself:
    - that `Build.SOC_MODEL` really reads `RTD2875P` there. Sentry reports the *chipset* as
      "Realtek RTD2875P", most likely `SOC_MANUFACTURER` + `SOC_MODEL`, so the model half is
      inferred rather than observed — the shipped build prints what it matched as
      `renderer=… reason=…` in the exportable log, so one Diagnostics export settles it;
    - that the runtime shell argument produces the same engine the manifest-opt-out build did;
    - that the crashes stay gone on an ordinary (non-dispatch) build. Watch IPTVS-5…-B and this
      Play cluster on 0.1.79+; a recurrence on an event tagged `renderer=skia-gl` means the
      renderer is ruled out after all and this entry reverts to "not app-fixable".
    An emulator leg (API 36 `android-tv`, `--force-skia-gl`) proves the override mechanism and
    that the TV flow runs on Skia GL — no emulator carries this SoC, so it proves nothing about
    the match.
- **DNA Hubi Soundbox** (Broadcom BCM72180), `0a0f1ee6…`: `std::terminate` thrown out of
  `/vendor/lib/libbcmvulkan_icd.so` (`vkCreateImageView`) while Impeller allocates a texture.
  It's a vendor Vulkan driver; the only lever is an app-wide `ImpellerBackend=opengles`, which is
  not worth it for one report.
- **TCL G07**, `311b2206…` (vc10): `HandleUsingDestroyedMutex` inside `libGLES_mali.so`, with no
  app frames.
- **System binder stalls:** `popSystemNavigator` → `finishActivity` (`19e2673e…`) and
  `activityTopResumedStateLost` (`5e3d58fb…`). Main is waiting on system_server.
