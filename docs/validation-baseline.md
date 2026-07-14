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
| TV-Low | Android TV | TBD | TBD | Physical D-pad | Pending |
| Phone | Android phone | TBD | TBD | Touch + system Back | Pending |
| Win-SDR | Windows x64 | TBD | TBD | SDR, keyboard, mouse | Pending |
| Win-HDR | Windows x64 | TBD | TBD | HDR, keyboard, mouse | Pending |

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

Current budgets: pending representative-device measurements.

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
