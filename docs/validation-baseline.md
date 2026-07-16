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
entire parsed guide in memory. All three keep the existing inline path below
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
| `v0.1.16`–`v0.1.30` | 11 |

Versions 1 and 7 remain useful regression fixtures because they cover the full
upgrade chain and the historical missing-`external_metadata` repair. They are
not currently claimed as publicly tagged release schemas. Reviewable v8–v11
fixture builders live in `test/support/historical_database_fixtures.dart`. PR 12
must compare each upgraded schema with a fresh installation and re-check the
fixtures against their tagged source before changing the migration contract.

## Reference environments

Fill one row per actual run. Do not mark native lifecycle or input gates complete
from a Linux unit-test run.

| ID | Target | Hardware/OS | Memory | Display/input | Status |
|---|---|---|---:|---|---|
| CI-Linux | Analyze/unit tests | GitHub-hosted Ubuntu | Runner-dependent | None | Existing |
| DEV-Linux-1 | Host ingestion baseline | Linux 7.1.3, Ryzen 7 7840HS | 14 GiB | None | Captured 2026-07-14 |
| TV-Low-AVD-1 | Android TV API 36 emulator | 2 virtual cores | 2 GiB | 1920×1080, 320 dpi, D-pad | Captured 2026-07-15 |
| Phone-AVD-1 | Android phone | Pixel-class emulator, 4 virtual cores | 2 GiB | Touch + system Back | Captured 2026-07-15 |
| Win-SDR | Windows x64 | Owner development devices | Not recorded | SDR, keyboard, mouse | Extensively exercised before PR 0 |
| Win-HDR | Windows x64 | Owner development devices | Not recorded | HDR, keyboard, mouse | Extensively exercised before PR 0 |

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
| XMLTV gzip | 100,000 programmes | 0.93 MB compressed | 1,024 ms | 598 MB |
| Xtream live JSON | 50,000 | 9.60 MB | 58 ms | Cumulative |
| Xtream VOD JSON | 50,000 | 8.25 MB | 55 ms | Cumulative |
| Xtream series JSON | 50,000 | 6.65 MB | 47 ms | Cumulative |
| Stalker channel JSON | 50,000 | 10.63 MB | 57 ms | Cumulative |

SQLite baseline with 50,000 channels and 100,000 programmes:

| Operation | Duration |
|---|---:|
| Replace channel library | 540 ms |
| Read and map channels | 195 ms |
| Replace EPG | 708 ms |
| Current/next query | 469 ms |

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
