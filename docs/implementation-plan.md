# Implementation Plan

> Temporary execution ledger for the technical-audit remediation programme.
>
> Remove this file after every required release gate is complete and the lasting
> architecture, security, database, playback, and navigation documentation has
> been updated in its canonical location.

## How to use this document

- Keep this file on `main` and update it in every related pull request.
- Check an item only when its stated verification has passed.
- Put evidence beside completed items: PR number, test name, benchmark, or device.
- Record scope or design changes in the decision log before implementing them.
- Do not mark device-dependent work complete from code inspection alone.
- Keep permanent design details in the relevant document under `docs/`; this file
  records execution state rather than replacing those documents.

Status convention:

- `[ ]` Not started or not verified
- `[x]` Implemented and verified
- `BLOCKED:` Cannot proceed until the stated dependency is resolved
- `DEFERRED:` Explicitly moved out of the current release, with a reason

## Current status

- Last updated: 2026-07-17
- Active phase: Phase 4 — Diagnostics and distribution gates
- Active PR: PR 17 repository-controlled MSIX packaging and submission material
  implemented; Windows certification/flight/device gates remain explicitly open
- Previous PRs: PR 13–16 merged as #113–#116; PR 11 released as v0.1.36
  with live verification passed 2026-07-16. PR 10's on-device TV-Low stall/RSS
  capture and PR 15's physical input/accessibility matrix remain outstanding.
- Plan baseline commit: `966418fec7a07646163073377c6a3a1013b93dd0`
- Baseline branch: `main`
- Baseline working tree: clean
- CI Flutter version: 3.44.5
- Declared Dart SDK constraint: `^3.12.2`
- Documentation Flutter version: README and CI declare 3.44.5
- Baseline `flutter analyze`: passed
- Baseline `flutter test`: passed, 204 tests
- Current PR 0 `flutter analyze`: passed on 2026-07-14
- Current implementation `flutter test`: passed, 371 tests with 14 expected
  skips
  baselines and 3 Windows-only updater integration tests skipped on Linux
- Android native builds: development, GitHub-direct, and Google Play debug APKs
  plus a disposable-key Play release AAB pass locally; the development flavor's
  TV live layout and native player Back behavior passed direct API-36 emulator
  validation, and Play accepted two internal builds as an update chain
- Windows x64 SDR and HDR playback paths: extensively owner-tested before and
  during development; PR 3 did not change the Windows player/rendering path

## Non-negotiable sequencing

- [x] Do not publish another normal release before Android signing recovery is
  decided and update artifacts are authenticated. v0.1.32 was published only
  after PRs 1–3 merged and the protected signing/artifact gates passed.
- [x] Do not migrate credential-derived channel/source IDs without an atomic
  preservation path for favorites, EPG, and playback positions. PR 4 migrates
  every related table in one SQLite transaction before the stable IDs are used.
- [x] Do not split the large player or browsing widgets before async-race and
  MethodChannel ownership regression tests exist. PR 6's controller race
  suites and PR 8's `channel_owner_test.dart` now pin both; PR 13 is unblocked
  on this gate.
- [ ] Do not describe Android or Windows lifecycle work as fixed until the relevant
  native build and device tests pass.
- [x] Do not begin optional feature work while a Phase 0 release blocker remains.
  Phase 0 release blockers are complete; the remaining open items are Phase 1–4
  device/performance/distribution gates.

## Pull-request overview

| PR | Phase | Outcome | Effort | Dependencies | Status |
|---|---|---|---:|---|---|
| 0 | Foundation | Fixtures, benchmarks, and device matrix | M | None | Complete; deeper profiling deferred |
| 1 | Phase 0 | Recover Android signing trust | L | PR 0 | Complete; v0.1.32 verified |
| 2 | Phase 0 | Authenticate update artifacts | L | PR 1 | Complete; v0.1.32 verified |
| 3 | Phase 0 | Bound HTTP and decompression workloads | M | PR 0 | Complete; #101/#102 |
| 4 | Phase 0 | Introduce stable source and cache identities | M | PR 0 | Complete; #103/v0.1.33 |
| 5 | Phase 0 | Remove credentials from SQLite, cloud, UI, and logs | L | PR 4 | Complete; #105/v0.1.34 |
| 6 | Phase 1 | Guard controllers against stale async results | M | PR 0 | Complete; #106 |
| 7 | Phase 1 | Make EPG refresh atomic and indexed | M | PR 4 | Complete; #107 |
| 8 | Phase 1 | Give MethodChannel handlers explicit ownership | M | PR 0 | Complete; #108 |
| 9 | Phase 1 | Harden and validate native player lifecycle | L | PR 8 | Merged; #109/v0.1.35 — device matrices outstanding |
| 10 | Phase 2 | Build bounded one-pass isolate ingestion | L | PR 3 | Complete; #110 |
| 11 | Phase 2 | Harden cloud sync, RLS, RPCs, and panel input | M | PR 5 | Complete; #111/v0.1.36 |
| 12 | Phase 2 | Test every supported historical migration | M | PRs 5 and 7 | Complete; #112 |
| 13 | Phase 2 | Split oversized UI files along tested boundaries | M | PRs 6 and 8 | Implemented; #113 |
| 14 | Phase 3 | Model catch-up capabilities and timezone | M | PR 4 | Implemented; timezone/M3U fixes included |
| 15 | Phase 3 | Complete TV focus, accessibility, and input parity | L | PR 9 | Implemented; device matrix open |
| 16 | Phase 4 | Add diagnostics and conflict/capability UX | M/L | Stable release | Implemented; #116 fixes included |
| 17 | Phase 4 | Publish a channel-safe Microsoft Store MSIX | M | PRs 2 and 9 | Implemented; certification/flight gates open |

Effort guide:

- S: approximately 0.5–2 days
- M: approximately 3–7 days
- L: approximately 1–3 weeks for one developer

## PR 0 — Reproducible validation baseline

### Implementation

- [x] Add sanitized 10k, 50k, and 250k-entry M3U fixtures. Generated
  deterministically by `test/support/workload_fixtures.dart`.
- [x] Add large Xtream live, VOD, and series fixtures. Generated deterministically
  by `test/support/workload_fixtures.dart`.
- [x] Add large and malformed Stalker fixtures. Generated deterministically by
  `test/support/workload_fixtures.dart`.
- [x] Add plain and gzip XMLTV fixtures, including a hostile compression ratio.
  Generated deterministically by `test/support/workload_fixtures.dart`.
- [x] Add fixture databases for every schema version that was publicly released.
  `test/support/historical_database_fixtures.dart` builds seeded v8–v11 schemas
  in reviewable SQL and `test/released_schema_fixtures_test.dart` exercises them.
- [x] Define and exercise the supported device matrix:
  - [x] Low-memory Android TV device
  - [x] Current Android phone
  - [x] Windows x64 SDR display
  - [x] Windows x64 HDR display
- [x] Add reproducible host-side measurements for fixture size, parse/decode time,
  and process RSS change in `test/performance_baseline_test.dart`.
- [x] Add application-profile responsiveness measurements on 2 GiB Android phone
  and TV emulators, including frame percentiles and worst captured build/raster
  times.
- DEFERRED: Add import phase timings, peak process memory, SQLite timings, and
  time-to-first-channel/EPG only when closed testing or a reported regression
  gives a representative workload. Do not delay early testing to manufacture
  hard budgets from emulators.
- [x] Correct permanent documentation to Flutter 3.44.5.

### Verification

- [x] Fixtures have been checked for real URLs, usernames, passwords, MAC addresses,
  API keys, tokens, and programme-viewing history. They use reserved `.invalid`
  hosts and generated identifiers.
- [x] Baselines can be reproduced from commands in `docs/validation-baseline.md`.
- DEFERRED: Treat the recorded host and emulator values as comparison baselines,
  not release thresholds, until closed-testing devices provide representative
  data.
- [x] `flutter analyze` passes on 2026-07-14.
- [x] `flutter test` passes on 2026-07-14 (236 passed, 10 platform/opt-in
  skips on Linux).

## PR 1 — Recover Android signing trust

### Decision checkpoint

- [x] Inspect the signing certificate of a genuinely distributed APK. GitHub
  release v0.1.30 uses certificate SHA-256 `CF:3C:C3:53:...:3E:EC`.
- [x] Compare it with the committed debug certificate. It is an exact match.
- [x] Document every current distribution channel. The owner confirmed GitHub
  direct distribution only; Google Play is planned but has never shipped.
- [x] Determine whether Play App Signing controls any installed population. It does not.
- [x] Choose and record one transition:
  - [ ] Play-managed signing-key upgrade
  - [x] New application IDs installed side-by-side: Play
    `com.gchofficial.iptvs.player`, GitHub direct `.player.direct`, development
    `.player.dev`
  - [ ] Explicit manual migration with documented data consequences

Do not rely on signing lineage alone to recover trust if the installed APK was
signed with a publicly available private key. Anyone with that key could create
their own lineage.

### Implementation

- [x] Generate a private release key outside the repository. Permanent
  certificate SHA-256 is
  `6E:36:3B:97:B8:5A:D9:99:20:CC:56:0D:5D:BF:6E:CD:94:80:9E:3D:84:F4:F1:3A:65:5A:15:00:4A:50:D5:3B`.
- [x] Add `tool/setup_android_signing.sh` to generate the permanent key outside
  the repository and optionally configure protected GitHub values without
  writing base64/plaintext secret files.
- [x] Configure the workflow to read keystore material and passwords only from a
  protected GitHub `release` environment.
- [x] Make release builds fail when signing material is missing.
- [x] Preserve normal local debug signing for non-distributable debug builds only.
- [x] Remove committed release use of `android/app/debug.keystore`.
- [x] Publish the permanent SHA-256 release-certificate fingerprint in
  `docs/android-signing.md` and configure the expected GitHub environment value.
- [x] Add a separate Play upload-key helper and protected manual AAB workflow;
  neither can access the GitHub-direct signing or update-manifest keys.
- [x] Make CI verify the Play AAB identity, absence of self-update capabilities,
  archive signature, and expected upload certificate before artifact upload.
- [x] Generate the separate Play upload key and configure its protected GitHub
  secrets. Certificate SHA-256 is
  `51:3E:75:95:25:81:15:09:1E:5C:EB:44:87:87:97:35:35:D3:90:02:20:15:FE:D0:AD:B9:C4:3C:99:A9:34:41`.
- [x] Confirm two AES-256 password-protected backups of the Play upload key and
  password in separate local and personal-cloud locations.
- [x] Enroll in Play App Signing through the first AAB upload and run the
  protected workflow with the permanent upload certificate. Play accepted the
  initial internal build and a second build as its update on 2026-07-15.
- [x] Record the Play-managed app-signing certificate SHA-256
  `F4:D9:F8:2B:A1:DB:51:94:19:D4:9C:2B:7D:39:AA:A5:F0:10:A8:92:CB:F0:37:1A:AE:01:30:41:6E:DB:37:53`
  and confirm Android developer verification registered the Play package with
  that key on 2026-07-16.
- [x] Register `com.gchofficial.iptvs.player.direct` as an outside-Play package
  with its permanent direct-distribution certificate on 2026-07-16.
- [x] Design a safe profile migration for each new application ID using the
  existing authenticated cloud push/pull path; exact steps and exclusions are
  recorded in `docs/android-signing.md`.
- [x] Avoid plaintext source exports during migration. Users who decline cloud
  sync re-enter sources manually; no credential-bearing export was added.

### Verification

- [x] A release build without signing secrets fails. Verified locally on
  2026-07-14 with an explicit missing-variable error.
- [x] A debug build still succeeds. Verified locally on 2026-07-14.
- [x] CI verifies the permanent APK certificate fingerprint. The protected
  v0.1.32 release workflow verified the signed GitHub-direct APK on 2026-07-15.
- [x] Run a minimum-SDK (API 26) install/start smoke test. A 1 GiB, four-core
  x86_64 phone emulator loaded the large Stalker source, played SDR/HDR/4K via
  the supported fallback paths, and exercised PiP on 2026-07-15; the resulting
  PiP return-stack defect was fixed in #102. The signed v0.1.32 APK also
  installed and started successfully on the owner's phone.
- [x] Profile/source/favorite retention or loss is explicitly documented and
  the authenticated cloud migration was exercised with the Play internal build
  on 2026-07-15. Sources/favorites restored and documented device-local
  exclusions started fresh.
- [x] The Play-installed internal-track base APK was pulled from an SM-S938B and
  verified against the recorded Play-managed app-signing certificate with
  `apksigner` on 2026-07-16.
- [x] `flutter analyze` and `flutter test` pass on 2026-07-14.

## PR 2 — Authenticate update artifacts

### Implementation

- [x] Define a canonical signed release manifest containing version, minimum
  version, platform, exact filename, byte size, and SHA-256 digest.
- [x] Sign the exact manifest bytes with an offline or protected CI key. The
  permanent encrypted private key/password secrets and public repository variable
  were configured on 2026-07-14; the protected v0.1.32 release run verified the
  signed metadata and artifacts end to end on 2026-07-15.
- [x] Embed only the public verification key in the application.
- [x] Verify manifest signature before trusting any artifact metadata.
- [x] Require HTTPS and an approved artifact host.
- [x] Verify exact platform, filename, received length, digest, and maximum size.
- [x] Reject downgrades outside an explicitly labelled, non-product developer
  override.
- [x] Android: verify APK package name and signing certificate before installation.
- [x] Windows: extract into a new staging directory.
- [x] Windows: reject absolute paths, `..`, links, and escaped paths.
- [x] Windows: validate the expected executable at the archive top level.
- [x] Windows: back up, swap, confirm launch, and roll back on failure.
- [x] Pin all third-party workflow actions to immutable commit SHAs, retaining
  readable major-version comments.
- [x] Reduce workflow token permissions to the minimum required per job.

### Verification

- [x] Protected v0.1.32 CI generated and verified the signed manifest plus exact
  Android/Windows artifacts before publishing the GitHub release; the signed
  APK installed successfully on owner hardware on 2026-07-15.
- [x] Altered manifest is rejected.
- [x] Altered APK or ZIP digest is rejected by the shared artifact gate.
- [x] Wrong byte size is rejected.
- [x] Wrong platform or filename is rejected.
- [x] Downgrade is rejected.
- [x] Redirect to an unapproved host is rejected before connection by
  `resolveApprovedUpdateRedirect`; regression coverage includes HTTP, lookalike,
  user-info, and non-default-port destinations.
- [x] Oversized artifact is rejected before installation.
- [x] Zip-slip and unexpected Windows layouts are rejected. Runtime PowerShell
  tests in `test/windows_update_script_test.dart` passed in PR #98's Windows CI
  job on 2026-07-14.
- [x] Failed Windows replacement restores the previous installation. The
  runtime rollback test passed in PR #98's Windows CI job on 2026-07-14.
- [x] `flutter analyze` and `flutter test` pass on 2026-07-14 (236 passed,
  7 opt-in baselines and 3 Windows-only tests skipped on Linux).

## PR 3 — Bound HTTP and decompression workloads

### Implementation

- [x] Add a shared response reader with idle and cancellation-safe timeouts.
- [x] Add a separate total operation deadline.
- [x] Add maximum compressed and decoded byte limits.
- [x] Reject excessive `Content-Length` values early.
- [x] Enforce the actual streamed-byte limit when length is missing or false.
- [x] Add reusable temporary-file streaming and use it for update artifacts;
  provider ingestion remains byte-based until PR 10's one-pass parser boundary.
- [x] Delete partial files after cancellation or failure.
- [x] Decode gzip with an output ceiling.
- [x] Move gzip decompression off the UI isolate.
- [x] Apply policies to M3U, XMLTV, Xtream, Stalker, metadata, and updates.
- [x] Fall back from oversized monolithic Stalker/Xtream live catalogs to
  paginated ordered lists or category-scoped retrieval with ID deduplication.
- [x] Make workload limits named and testable rather than scattered constants.

### Verification

- [x] Slow-drip response reaches the total deadline (`test/net_workload_test.dart`).
- [x] Missing and false `Content-Length` values cannot bypass the limit.
- [x] A response exceeding the limit mid-stream is aborted.
- [x] A high-ratio gzip payload is aborted at the decoded-byte limit.
- [x] Cancellation/failure removes partial files; clients remain explicitly
  closeable by each owning source/service.
- [x] Representative legitimate fixtures remain accepted.
- [x] `flutter analyze` and `flutter test` pass on 2026-07-15 (258 passed,
  10 platform/opt-in skips).
- [x] A real 28.6 MB Stalker live catalog and 9.7 MB EPG response loaded on the
  2 GiB Android TV emulator; movie/series posters and tested sources render.

## PR 4 — Stable source and cache identities

### Implementation

- [x] Use `SourceConfig.id` as the repository/cache source namespace.
- [x] Stop deriving source identity from URLs, credentials, or MAC addresses.
- [x] Generate deterministic opaque M3U channel IDs from normalized locators.
- [x] Retain provider channel IDs when they are already opaque and stable.
- [x] Make favorites, positions, EPG, metadata, and cloud records use the same IDs.
- [x] Specify normalization rules and collision behavior in tests and
  `docs/source-identities.md`.

### Verification

- [x] Credential changes do not create an unrelated cache namespace.
- [x] Equivalent normalized M3U locators produce the same channel ID.
- [x] Distinct locators do not merge accidentally in the 1,000-locator corpus.
- [x] Provider-specific ID construction remains inside the owning Source.
- [x] `flutter analyze` and `flutter test` pass on 2026-07-15 (269 passed,
  10 platform/opt-in skips); Android development Kotlin compilation also passes.

## PR 5 — Remove persisted and displayed credentials

### Implementation

- [x] Add a provider-neutral encrypted secret-locator field where playback requires
  persistence of a URL or provider secret.
- [x] Store its per-install encryption key in `flutter_secure_storage`.
- [x] Keep non-secret provider metadata in the normal `extra` field.
- [x] If an existing encryption key is missing, invalidate encrypted regenerable
  cache; legacy plaintext cache rows are migrated once into the encrypted field.
- [x] Atomically migrate source IDs, channel IDs, favorites, positions, EPG, and
  related metadata. Covered by PR 4's stable-identity transaction and
  `stable identity migration` persistence tests.
- [x] Ensure cloud item IDs contain no raw URLs, MAC addresses, or credentials.
- [x] Ensure encrypted playback locators are never uploaded to cloud sync; source
  and metadata payloads contain only non-secret fields, while an existing device
  retains its local credentials during cloud pulls.
- [x] Redact URL user-info, paths, queries, and fragments in UI and diagnostics.
- [x] Redact source summaries in the Flutter UI; the JavaScript panel receives
  only cloud-safe source/metadata payloads.
- [x] Render credential inputs as password fields with explicit reveal controls.

### Verification

- [x] Existing M3U favorites survive migration. The persistence suite rewrites a
  legacy M3U URL key without losing its favorite, and the owner opened and played
  a pre-update favorite successfully after installing v0.1.34.
- [x] Continue Watching survives migration. The stable-identity persistence test
  migrates and reads the playback-position row in the destination namespace.
- [x] Existing EPG links survive migration. The stable-identity and M3U migration
  tests resolve the migrated now/next programme under the new identifiers.
- DEFERRED: Explicit migration-failure injection and rollback verification belongs
  to PR 12's supported-historical-migration matrix.
- [x] No fixture credential appears in newly written SQLite cache text values.
- [x] No fixture credential appears in cloud source or metadata payloads.
- [x] No fixture credential appears in diagnostics or rendered summaries;
  `net_test.dart` and `widget_test.dart` cover URL/text and Stalker redaction.
- [x] Missing encryption-key behavior is deterministic and recoverable.
- DEFERRED: Fresh-versus-migrated schema equivalence belongs to PR 12's complete
  supported-historical-migration matrix.
- [x] `flutter analyze` and `flutter test` pass (282 tests, 10 expected skips);
  Android Kotlin compilation and PR #105 Build/CodeQL checks also pass.

## PR 6 — Async generation and disposal guards

### Implementation

- [x] Add generation tokens to `MediaTabController` category loads and pagination.
  `_loadGeneration` gates `load`, `loadMore`, and `search` publish paths.
- [x] Add generation tokens to `LiveController` loads and refreshes.
  `_loadGeneration` gates `load` and `refreshNowNext` publish paths.
- [x] Guard source/profile loading in `HomeShell`. `_loadActiveGeneration` makes
  a superseded `_loadActive` dispose its freshly built source/providers and
  bail; `_loadProfileInfo` drops stale profile info the same way.
- [x] Guard asynchronous metadata enrichment. The pre-existing
  `_enrichGeneration` was audited as sufficient and is now pinned by a test.
- [x] Publish results only if controller, generation, source, profile, and category
  still match the request. Cross-source/profile staleness is enforced by
  key-driven controller disposal (`ValueKey(config.id)` on `ChannelListScreen`)
  plus `_disposed`; generation checks cover same-controller races.
- [x] Define refresh versus `loadMore` precedence explicitly. Dataset-replacing
  ops (`load`, `setCategory`) bump the generation and publish only if still
  current; subordinate ops (`loadMore`, `search`, `clearSearch`,
  `refreshNowNext`) read it without bumping and abandon superseded results;
  `loadMore` refuses to start while `loading`. See the decision log.
- [x] Prevent notification after controller disposal. All `notifyListeners`
  calls route through `_set`, which early-returns when `_disposed`; dispose
  tests pin this.

### Verification

- [x] Category A returning after category B cannot replace B.
  `media_tab_controller_test.dart` "a category load returning after a newer one
  cannot replace it" fails against the pre-fix code and passes now.
- [x] Old source response cannot replace a new profile/source. Enforced by
  key-driven controller disposal on source-id change (dispose tests prove
  dropped publishes) plus the `_loadActive` generation guard; a HomeShell
  widget test was judged infeasible without production-only test seams.
- [x] Refresh supersedes an outstanding pagination request.
  `media_tab_controller_test.dart` "refresh supersedes an outstanding
  pagination", including the loadMore-refuses-while-loading sub-case.
- [x] Dispose during a request causes no notification or exception. Dispose
  tests in both controller suites (load, loadMore path, and `refreshNowNext`).
- [x] Old metadata enrichment cannot mutate a newer result.
  `media_tab_controller_test.dart` "old enrichment cannot mutate a newer
  category's result".
- [x] `flutter analyze` and `flutter test` pass on 2026-07-15 (293 tests,
  10 platform/opt-in skips; 11 new race tests across
  `media_tab_controller_test.dart` and `live_controller_test.dart`).

## PR 7 — EPG atomicity, empty results, and indexing

### Implementation

- [x] Treat a normally completed empty EPG result as a successful replacement.
  `_ensureEpg` now always calls `replaceEpg` on normal completion (a returned
  empty list is success; failures throw and never reach the replacement).
- [x] Clear old programmes and update freshness for success-empty.
  `replaceEpg([])` deletes by source and advances `epg_synced_at` in the same
  transaction, so no-EPG sources stop re-fetching on every load.
- [x] Retain the last good cache after exceptions or timeouts. A thrown
  `Source.epg` never reaches `replaceEpg`; the failure is recorded by the
  un-advanced `epg_synced_at` plus a redacted diagnostics line. This required
  fixing `replaceLibrary`, whose `INSERT OR REPLACE` on `sources` nulled
  `epg_synced_at` on every channel refresh — see the decision log.
- [x] Replace programmes and refresh timestamp in one transaction. Already
  true of `replaceEpg`; preserved through the empty-path and chunking changes
  and now pinned by a rollback test.
- [x] Add the measured index needed by source/time now-next queries.
  `idx_prog_source_start(source_id, start)` at schema v12, created in both
  `_createProgrammes` and an idempotent `oldV < 12` branch (v3-trap-safe).
  Channel-scoped guide/catch-up queries keep using `idx_prog_lookup`.
- [x] Confirm index use with `EXPLAIN QUERY PLAN`. `explainNowQueryPlan`
  test seam runs the exact `nowNext` "now" SQL; the plan names the new index
  against a ~20k-programme/2k-channel corpus.
- [x] Avoid constructing duplicate full replacement datasets in memory.
  `replaceEpg` takes `Iterable<Programme>` and flushes inserts in bounded
  1000-row batch chunks inside the single transaction.

### Verification

- [x] Success-empty clears stale programmes. Persistence test: success-empty
  EPG clears stale programmes and advances `lastEpgSynced`.
- [x] Failure retains old programmes and records refresh failure. Persistence
  test asserts the cached programme survives a failed forced refresh and
  `lastEpgSynced` is unchanged; a DB-level pin proves repeat `replaceLibrary`
  calls no longer reset `epg_synced_at`.
- [x] Transaction failure leaves the previous complete EPG intact. A throwing
  programme iterable mid-`replaceEpg` rolls back delete + partial insert,
  leaving old EPG and timestamp untouched.
- [x] Fresh and upgraded databases contain the new index. Fresh-create and a
  seeded v11 fixture upgraded through `openAt` both contain
  `idx_prog_source_start`; the seeded programme survives the upgrade.
- [x] Large now-next lookup selects the intended index. `EXPLAIN QUERY PLAN`
  over ~20k programmes selects `idx_prog_source_start`.
- [x] `flutter analyze` and `flutter test` pass on 2026-07-15 (300 tests,
  10 platform/opt-in skips; persistence suite at 26 tests).

## PR 8 — MethodChannel handler ownership

### Implementation

- [x] Add an owner token for each registered static channel handler.
  `ChannelHandlerOwner` (`lib/player/channel_owner.dart`): `claim` bumps a
  monotonic token and installs a wrapper that ignores superseded tokens.
- [x] Clear a handler only when the disposing owner is still current.
  `release(token)` clears the platform handler only if `token == _current`.
- [x] Ignore callbacks delivered to disposed or superseded owners. The
  wrapper drops superseded-token calls; `_handleNativeHdrMethodCall` gained a
  `!mounted` bail and `LivePreviewController._handleNativeCall` keeps its
  `_disposed` bail as the second gate for calls already in flight.
- [x] Apply identical cleanup rules to Android and Windows. `dispose` now runs
  the same ungated `release(token)` on both platforms, replacing the previous
  Windows-only `setMethodCallHandler(null)` (Android never cleared at all).
  Honest interpretation: the parity is Dart-side — both native sides register
  once per process and are owner-agnostic, so no Kotlin/C++ edits were needed.
- [x] Apply the helper to preview and full-screen player ownership.
  `_PlayerScreenState` (`iptvs/native_hdr_player`) and `LivePreviewController`
  (`iptvs/native_preview`) both claim/release through their static owner.
  `iptvs/updates` is outbound-only from Dart (no handler) — out of scope.

### Verification

- [x] Old preview disposal cannot clear a newer preview handler.
  `test/channel_owner_test.dart`: successor claim + predecessor release leaves
  dispatch reaching the successor with the handler still installed.
- [x] A popped player ignores late position, favorite, and error callbacks.
  Sole-owner release drops dispatched calls (unit test); the `mounted` /
  `_disposed` gates inside the real handlers are verified by inspection —
  instantiating `PlayerScreen` requires a live media_kit engine (documented
  infeasibility fallback, as with PR 6's HomeShell widget test).
- [x] Android handler cleanup matches Windows cleanup. By construction: one
  shared platform-ungated `release` path; the `Platform.isWindows`-only clear
  is gone.
- [x] Repeated route cycles leave exactly one active owner. Unit test runs
  five claim/release cycles asserting monotonic tokens, latest-claimant-only
  dispatch, stale-release no-op (with a dispatch proving the handler
  survived), and a final release that clears the handler entirely.
- [x] `flutter analyze` and `flutter test` pass. Clean analyze; 304 tests pass
  with the 10 expected skips (300 baseline + 4 `channel_owner` tests).

## PR 9 — Native player lifecycle

A read-only audit of every checklist item preceded implementation. Verdict shape: most items
already held (each mechanism cited below); the audit found exactly two code defects, both fixed
(D1: Windows silent surface-failure; D3: preview `TextureView` not detached at PlatformView
dispose). Items whose *behavior* can only be observed on real hardware stay open under the
device-matrix boxes, which the owner runs.

### Android implementation and validation

- [x] Preview adoption leaves one active player and one audible stream. Already
  held: `SharedEngine` is a process-global single engine, `adoptForFullscreen`
  is URL-keyed, `openPreview` refuses while adopted; the non-adopted
  audio-doubling guard is `_openLivePlayer`'s pause/stop split. Verified by
  audit/inspection; on-hardware confirmation in the Android matrices.
- [x] ExoPlayer-to-MPV fallback releases the failed engine. Already held:
  `fallbackToMpv` releases a non-adopted engine and
  `invalidateFromFullscreen`s an adopted one; `triggerFallback` idempotent via
  `fellBack`. Hardened: `ExoPlayerEngine.release()`/`MpvEngine.release()` are
  now explicitly idempotent (`released` flags).
- [x] Route pop and Back release or transfer ownership correctly. Already held:
  `onDestroy` adopted→`fullscreenDetached` (engine kept), non-adopted→
  `engine?.release()`; Dart-side owner release via PR 8's
  `ChannelHandlerOwner`.
- [x] Home/background/foreground transitions behave correctly. Already held:
  `onStop` pauses unless PiP or finishing-while-adopted;
  `MainActivity.onStop` finishing safety net; Dart lifecycle observer stops
  the preview on background. Timing confirmation in the matrices.
- [x] PiP entry, exit, Back, and forced close behave correctly. Logic verified
  by inspection (`onUserLeaveHint`→`enterPip`; pinned-task workaround via
  `MainActivity` WeakReference; `finish`→`restoreMainTaskAfterPip`) —
  behavioral verification is hardware-only and sits in the Android matrices.
- [x] Activity/process recreation restores or fails safely. Broad
  `configChanges` means config changes never recreate the Activity; after
  process death `SharedEngine` is null so adoption fails clean and the
  Activity cold-restarts from Intent extras. Known accepted gap: a
  process-killed VOD session restarts from `EXTRA_RESUME_MS` (the original
  resume point), silently losing in-session progress — fails safe.
- [x] Headers, subtitles, tracks, seek, speed, and volume retain supported
  parity. Already held (full `PlayerCallbacks` wiring; untouched by this PR);
  actual track switching confirmed in the matrices.
- [x] Reconnect cannot revive a superseded source. Already held:
  `reconnectLive` bails on `isFinishing`; the progress ticker is cancelled in
  `onStop`. Timing policy extracted to pure `ReconnectPolicy` and pinned by
  the new plain-JUnit `ReconnectPolicyTest` (4 tests).
- [x] PlatformView disposal releases the surface and native references. Fixed
  (D3): `unregisterPreviewView` now calls the identity-checked
  `ExoPlayerEngine.clearPreviewTexture` when not adopted, so a disposed
  preview `TextureView` can't stay attached to the engine; skipped while
  adopted to protect the transparent handoff.

### Windows implementation and validation

- [x] Partial HWND/D3D initialization failure cleans up safely. Fixed (D1):
  `_open` now stops on a null surface handle and raises the terminal
  error/Retry overlay instead of configuring mpv with no `wid`/`vo` and
  playing audio behind a silent black overlay; Retry re-attempts surface
  creation, and a successful retry reaches the normal (hot-swap) path.
- [x] Embedded/fullscreen/mini-player transitions do not leak surfaces.
  Already held: `native_video_surface_`/`native_controls_overlay_` are single
  reused HWNDs with null-guarded create/destroy; now counted by the debug
  counters so the soak proves it.
- [ ] Parent resize, DPI change, and monitor change behave correctly.
  Hardware-only (audit: `WM_SIZE`/`WM_DPICHANGED` cascade looks correct; mpv
  owns its swapchain resize) — verified in the Windows matrices, including
  HDR↔SDR across mixed-DPI monitors.
- [x] Forced close with callbacks pending does not access disposed state.
  Already held: `_prepareWindowsNativeExit` is timeout-guarded and tears down
  Dart tracking regardless of the native reply; `NotifyNativeControlCommand`
  null-checks the channel; the Dart handler bails on `!mounted`.
- [x] Overlay commands after Dart route disposal are ignored. Held by PR 8's
  `ChannelHandlerOwner` (superseded-token drop) + the `!mounted` second gate;
  the route-replacement handoff smoke folds into the Windows matrices.
- [ ] Reconnect works after surface recreation. Hardware-only — verified in
  the Windows matrices.

### Verification

- [x] Debug-only counters exist for engines, surfaces, reconnect timers, and
  owners. Dart `ResourceCounters` (`mediaKitPlayers`, `reconnectTimers`,
  `channelOwners`; `kDebugMode`), Kotlin `DebugCounters` (`exoEngines`,
  `mpvEngines`, `previewViews`, `progressTickers`, `sharedEngineLive`;
  `BuildConfig.DEBUG` — enabling `buildFeatures.buildConfig` was the one
  gradle line needed), C++ `windowsSurfaces`/`windowsOverlays`
  (`#ifndef NDEBUG`). Merged by `ResourceCounters.snapshot()` via a
  `debugCounters` method on the existing HDR channel (no new inbound channel);
  shown in a debug-only diagnostics-screen section; release builds are inert
  and reply with an empty map.
- [x] A 100-cycle Android open/close soak returns counters to zero. Owner-run:
  `flutter test integration_test/player_soak_test.dart -d <android-device>`
  (the debug-only `soakAutoCloseMs` extra self-finishes `HdrPlayerActivity`
  each cycle). Passed on 2026-07-16; every counter returned to zero.
- [x] A 100-cycle Windows open/close soak returns counters to zero. Owner-run:
  `flutter test integration_test/player_soak_test.dart -d windows`. Passed on
  2026-07-16; every counter returned to zero.
- [ ] Android phone device matrix passes. Owner hardware; includes the PR 8
  `nativeClosed`-after-supersede smoke. In progress: the 0.1.35 closed test
  (approved 2026-07-16, TestersCommunity window through ~2026-07-30) is
  gathering field data alongside the owner runs.
- [ ] Android TV device matrix passes. Owner hardware.
- [ ] Windows SDR device matrix passes. Owner hardware; includes the PR 8
  route-replacement handoff smoke.
- [ ] Windows HDR device matrix passes. Owner hardware.
- [x] No bridge redesign is made without measured correctness or performance
  need. The design pass argued a unified per-platform lifecycle/session object
  and rejected it (decision log): the audit found only two local defects, and
  the counters prove the existing release paths complete precisely because
  they thread through the current call sites.

## PR 10 — Bounded one-pass isolate ingestion

Design: hybrid worker boundary (decision log, 2026-07-16) — one-pass typed workers for
channel/media catalogs, streamed batches only for EPG, additive `LoadToken` cancellation.

### Implementation

- [x] Xtream: decode and map large responses within one worker job. Top-level
  `decodeLiveChannelsBytes`/`decodeMediaItemsBytes` (bytes → typed lists) run
  under `compute` at/above the existing 256 KB threshold, inline below it; the
  dynamic JSON graph never crosses the isolate boundary. Small/generic calls
  (auth, categories, series details) keep the dynamic `_decodeJson` path.
- [x] Stalker: join, decode, and map large channel responses in one worker
  job. New `_requestBytes` fetches `get_all_channels` raw; top-level
  `_ingestStalkerChannels` does utf8→json→token/portal-error detection→
  per-row `_mapChannel` under `Isolate.run`, mirroring `_call`'s
  re-handshake-once semantics (rows carry `tv_genre_id` inline; the
  page-bounded ordered-list fallback stays inline — deferred, decision log).
- [x] XMLTV: decompress, parse, and return compact programme batches.
  `parseXmltvBatched` streams 1000-row `Programme` batches from a raw
  spawned isolate with an ack handshake bounding in-flight batches to one
  (a `ReceivePort` has no backpressure; unbounded sends would re-create the
  peak-memory blowup streaming exists to avoid).
- [x] M3U: decode and parse with bounded batches. Playlist parsing was
  already one-pass typed (`_parseM3uBytes` via `compute`); added the small-
  payload inline threshold. Disk-backed/batch-streamed playlist parsing is
  deferred: the UI holds the full channel list regardless, so it yields no
  peak-memory win (decision log). M3U's XMLTV guide uses the batched EPG path.
- [x] Avoid returning both a giant dynamic graph and a typed graph. All
  large-payload workers return only the typed result; parity pinned by
  `test/xtream_ingest_test.dart` / `test/stalker_ingest_test.dart` /
  `test/xmltv_batch_test.dart`.
- [x] Prevent cancelled or stale batches from reaching the repository.
  `LoadToken` (additive to the pinned generation guards) is cancelled by each
  superseding load: stale channel/media cache writes are skipped in
  `LibraryRepository`, and a cancelled EPG feed throws `LoadCancelledException`
  so `replaceEpgStream`'s single transaction rolls back — a half-fed guide
  can never commit (success-empty contract unchanged).
- [x] Retain measured inline paths for genuinely small payloads. Existing
  256 KB (JSON) / 64 KB (XMLTV) thresholds kept and applied to every new
  path; dev-host baselines record the isolate round-trip overhead
  (~150–280 ms on 40–54 MB catalogs) that justifies them.

### Verification

- [ ] Main-isolate stalls meet the PR 0 budget on the low-memory TV device.
  Owner-run on `TV-Low` hardware/emulator; PR 0 budgets are intentionally
  unset, so the deliverable is a recorded before/after stall comparison.
- [ ] Peak memory remains within the agreed regression allowance. Owner-run
  device capture pending; dev-host RSS recorded in
  `docs/validation-baseline.md` ("One-pass isolate ingestion baseline").
- [x] Cancellation stops publication of subsequent batches.
  `test/epg_batch_cancel_test.dart`: cancel after the first batch → no
  further batches, `replaceEpgStream` rolls back to the seeded guide; stale
  channel write skipped at repository level.
- [x] Malformed data has deterministic partial-failure behavior. Per-row/
  per-element skip pinned in `test/stalker_ingest_test.dart`,
  `test/xtream_ingest_test.dart`, `test/xmltv_batch_test.dart`; whole-payload
  JSON/XML corruption throws the same errors as the old paths.
- [x] Results match the existing parser fixture corpus. Parity tests over the
  PR 0 `WorkloadFixtures` corpus (new workers vs. old pipeline, field-by-field
  samples + counts); `parseXmltvBatched` flattened == `parseXmltv`.
- [x] `flutter analyze` and `flutter test` pass on 2026-07-16 (334 passed;
  11 opt-in baselines and 3 Windows-only updater tests skipped on Linux).

## PR 11 — Cloud, RLS, RPC, and panel hardening

### Implementation

- [x] Set a fixed `search_path` in every `SECURITY DEFINER` function.
  `20260716000000_harden_cloud.sql` recreates all 11 remaining
  `search_path = public` functions (pairing, push, set_device_profile, legacy
  delegates, `current_device_owner`, `enforce_profile_cap`) with
  `search_path = ''` and schema-qualified references; helpers were already `''`.
- [x] Enforce ownership in every profile/snapshot RPC. Design-pass audit found
  no gap: every RPC gates on `current_device_owner()` plus a profile-ownership
  check or an owner-scoped mutation; `delete_account` is self-only with the
  `is_anonymous` device guard. Existing checks carried verbatim into the
  recreated functions.
- [x] Validate JSON shape, field lengths, array counts, and total payload size.
  BEFORE-INSERT/UPDATE triggers on `sources`/`profiles`/`metadata_configs`
  call shared `assert_*` validators (binding panel direct writes and RPC
  writes), and each push RPC checks top-level array count/byte size before any
  mutation. Limits sized ≥10x over the 250k-channel corpus (favorites 200,000 /
  16 MB; 50,000 hidden-category ids per kind / 8 MB settings; fields 64 KB).
  Validators also pre-empt the table's own CHECK/NOT NULL errors, whose
  "Failing row contains" DETAIL would echo credentials.
- [x] Make pairing completion single-use and transactionally safe. Audited as
  already sound (`FOR UPDATE` + `claimed_by is null` guard; `pairing_status`
  scoped to `device_uid = auth.uid()` so codes can't be probed); recreated with
  pinned `search_path` only, no logic change.
- [x] Apply rate limits at the API/edge boundary. DB-side token window
  (`push_rate` + `check_push_rate`, 30/min per device session) on the push
  RPCs; auth endpoints keep Supabase's built-in limits; reads/pulls stay
  unthrottled by design (decision log). An Edge Function proxy was rejected.
- [x] Validate source schemes and field lengths in the panel.
  `panel/src/validate.js` `validateSource`: http/https-or-schemeless
  allowlist on URL fields, per-field length caps; wired into `editSource`,
  profile-name and metadata forms.
- [x] Prevent panel errors from echoing credential-bearing input. All panel
  error surfaces route through `friendlyError` (+`scrubUrls`; `details`/`hint`
  never rendered; raw error to console only). Flutter's cloud screen equally
  routes through `friendlyCloudError` (`e.message` only, `redactText`'d) —
  `PostgrestException.toString()` would have leaked `details`.
- [x] Document last-write-wins behavior and timestamp authority.
  docs/cloud-sync.md "Last-write-wins and timestamp authority" +
  "Validation limits and rate limiting"; CLAUDE.md essentials bullet.

### Verification

- [x] Cross-user profile read/write attempts fail. Owner-run on the live
  project (two accounts) on 2026-07-16 after v0.1.36.
- [x] Expired pairing codes fail. Owner-run on the live project, 2026-07-16.
- [x] Completed pairing codes cannot be replayed. Owner-run on the live
  project, 2026-07-16.
- [x] Concurrent profile creation cannot exceed the profile cap. Owner-run
  parallel inserts at cap 20 exercised the new advisory lock, 2026-07-16.
- [x] Invalid or excessive push payloads fail before mutation. Owner-run on
  the live project, 2026-07-16: typed `iptvs: ` errors with rows unchanged,
  and the >30/min push throttle rejects. Gateway body-size probing showed no
  413 interfering at the tested payload sizes (realistic payloads are ~2 MB;
  the exact platform ceiling was not pinned to a number).
- [x] Clock-skew and equal-timestamp conflict cases are deterministic. By
  construction: no client timestamps exist anywhere — `updated_at` is server
  `now()` via trigger/RPC and is never compared; conflicts resolve by write
  order (documented in docs/cloud-sync.md).
- [x] Panel rendering and validation tests pass. 20 `node:test` cases over
  `validate.js` (`npm test` in `panel/`): schemes, lengths, scrubbing,
  `details` suppression.
- [x] `flutter analyze` and `flutter test` pass. Analyze clean; 338 tests
  (+4 `friendlyCloudError` leak-regression cases).

## PR 12 — Historical migration coverage

- [x] List schema versions that shipped publicly (8: v0.1.0–7, 9: v0.1.8–10,
  10: v0.1.11–15, 11: v0.1.16–34, 12: v0.1.35+; the old table understated the
  v11 range as ending at v0.1.30 — corrected in docs/validation-baseline.md).
- [x] Remove unsupported intermediate versions from the compatibility claim
  (supported upgrades are released schemas 8–11 → current; pre-v8 `onUpgrade`
  branches stay as best-effort dev-era repair paths, documented as outside the
  claim in the `schemaVersion` doc comment, CLAUDE.md, and validation-baseline).
- [x] Add a sanitized database fixture for each supported historical version
  (v8–v11 builders re-verified against tagged source: fresh-install DDL at each
  range's first tag plus normalized-DDL diff across each range — no drift).
- [x] Open and migrate every fixture.
- [x] Compare tables, columns, indexes, constraints, and foreign keys with
  fresh DB (pragma-based `schemaSignature`: `table_info`, name-keyed
  `index_list`/`index_info`, `foreign_key_list`).
- [x] Validate representative favorites, positions, EPG, and metadata after
  upgrade (seeded programme + `external_metadata` rows added to the fixtures).
- [x] Open every migrated fixture a second time to prove stable startup
  (version stays 12, data intact, schema signature unchanged).
- [x] Update `AppDatabase.schemaVersion` documentation after migrations land.
- [x] `flutter analyze` and `flutter test` pass (clean; 346 passed).

## PR 13 — Split oversized UI files

- [x] Fix the adjacent defect found during PR 6: a metadata-config-only change
  (same active source id) rebuilds the repository while `ChannelListScreen`'s
  `ValueKey(config.id)` is unchanged, so live controllers keep the old,
  disposed repository/source. `didUpdateWidget` now replaces and disposes only
  the repository-backed controllers/listenables while retaining the screen's
  focus nodes and scroll ownership; pinned by
  `repository replacement reloads controllers for the new source`.
- [x] Keep `channel_list_screen.dart` responsible for shell, routes, and dialogs.
  Tabs/toolbar/dropdowns moved to `channel_list_chrome.dart`; the screen retains
  navigation, playback routes, sheets, filtering, and ownership.
- [x] Extract live pane widgets without moving their state ownership
  (`live_tab_view.dart`; state remains in the screen/controllers).
- [x] Extract media grid/details widgets without moving controller state
  (`media_tab_view.dart`; controller lifetime remains in the screen).
- [x] Separate player lifecycle coordination from platform presentation widgets.
  `player_overlay.dart` owns embedded controls/error/reconnect presentation;
  `player_screen.dart` retains engines, native channels/surfaces, reconnect,
  persistence, handoff, and disposal.
- [x] Preserve the current `ChangeNotifier`/`Listenable` design.
- [x] Preserve focus-node ownership and disposal exactly.
- [x] Avoid abstractions without at least two concrete consumers (the extracted
  types are concrete presentation components; no generic UI abstraction added).
- [x] Run focused widget/controller tests after extraction (54 passed:
  channel-list focus, live focus/controller, media controller, channel owner).
- [x] `flutter analyze` and `flutter test` pass (clean; 347 passed, 14 skipped).

## PR 14 — Catch-up capability and timezone model

- [x] Model provider catch-up URL mode.
- [x] Model provider timezone or explicit fixed offset.
- [x] Model maximum archive window and duration.
- [x] Model required start/end formatting.
- [x] Keep URL construction inside the owning Source implementation.
- [x] Prefer provider-reported timezone when available.
- [x] Add an advanced per-source override.
- [x] Parse applicable M3U catch-up attributes into the shared capability model.
- [x] Test device/provider timezone disagreement.
- [x] Test DST boundaries.
- [x] Test unsupported catch-up as an explicit capability, not a failed URL guess.
- [x] `flutter analyze` and `flutter test` pass.

## PR 15 — TV focus, accessibility, and input parity

### Automated behavior

- [x] Category/channel/EPG pane boundaries match documented navigation. Channel
  category activation/filter handoff is pinned by
  `test/channel_list_focus_test.dart`; EPG boundaries remain covered by
  `test/epg_grid_test.dart`.
- [x] Up/down wrapping rules match documented navigation. Pure coordinator and
  real-key widget tests cover channel/category wrapping and upward escape.
- [x] Search open/close restores the intended focus target. `TvTextField`
  returns Back/IME dismissal to its routed entry cell; widget tests cover Back
  and the clear-button path.
- [x] Back ladder does not clear or change data prematurely. Flutter tests cover
  row/favorite/category/search/tab rungs; Android native unit and API-36 emulator
  checks cover menu/info/controls/exit policy and duplicate Back suppression.
- [x] Dialog and sheet dismissal restores focus. Update/EPG dialogs autofocus
  an action, and browsing sheets restore the prior attached focus node with a
  route-safe list/tab fallback.
- [x] In-row favorite activation preserves logical selection. Covered by pure
  coordinator and real-key widget tests.
- [x] Return from native playback restores focus. Live restores the played
  channel by id, media restores its last-played tile, and the route-current
  guard leaves EPG restoration to the pushed guide route.
- [x] Async rebuild retains logical selection and usable focus. The live model
  remembers the selected channel id and reconciles its numeric cursor after
  refresh/reorder; explicit search/category changes still reset.
- [x] Held-key repeat cannot issue duplicate activation. Activation runs only
  for `KeyDownEvent`; repeat/up events are swallowed and covered by tests.

### Semantics

- [x] Custom rows expose selected state.
- [x] Rows expose useful channel/programme labels.
- [x] Lists/grids expose position information where practical.
- [x] Favorite state and actions are exposed.
- [x] Custom controls expose an activation action.

### Device matrix

| Flow | Android TV D-pad | Android touch | Windows keyboard | Windows mouse |
|---|---|---|---|---|
| Live browsing | [ ] | [ ] | [ ] | [ ] |
| Search/text fields | [ ] | [ ] | [ ] | [ ] |
| Player overlay | [ ] | [ ] | [ ] | [ ] |
| EPG grid | [ ] | [ ] | [ ] | [ ] |
| PiP/mini-player | [ ] | [ ] | [ ] | [ ] |
| Screen reader | [ ] TalkBack | [ ] TalkBack | [ ] Narrator | [ ] Narrator |

## PR 16 — Diagnostics and conflict/capability UX

- [x] Report redacted compressed and decoded byte counts. Bounded HTTP reads
  publish the encoded and decoded lengths to the local diagnostics log.
- [x] Report provider-load and database-write duration. Structured ingestion
  summaries label the end-to-end provider/stream wait separately from SQLite
  work; batched EPG records both phases.
- [x] Report rejected-row counts without sensitive row contents. M3U pending
  entries and malformed Stalker catalog rows now emit counts only.
- [x] Show cloud revision/timestamp and warn before destructive overwrite.
  Profile `updated_at` is fetched server-side and a newer/unknown revision
  requires an explicit replacement confirmation.
- [x] Preview snapshot restore effects. Profile switching shows credential-free
  source add/remove/retain counts, the resulting active source, metadata
  replacement, cloud-managed count, and whether a panel pull follows.
- [x] Show provider EPG/catch-up/resolution capabilities. Source cards use
  provider-owned capability reports and show unknown/playlist-dependent states
  instead of inferring support or claiming universal adaptive resolution.
- [x] Show cache size and last successful refresh by source. The diagnostics
  route now presents credential-free channel/programme/media counts and channel
  and EPG freshness.
- [x] Offer a safe cache re-ingestion action. Diagnostics invokes the existing
  force-refresh path; it never deletes the last-good cache before replacement.
- [x] Ensure exported diagnostics remain credential-safe. Export applies the
  shared redactor at the final boundary, including messages added by future
  callers.
- [x] `flutter analyze` and `flutter test` pass.

## PR 17 — Microsoft Store MSIX distribution

- [x] Reserve the public product name `IPTVS Player` as an MSIX app in Partner
  Center.
- [x] Record the exact Package Identity Name, Publisher, publisher display name,
  product name, PFN, Package SID, and Store ID in `docs/store-publishing.md`.
- [x] Add deterministic x64 MSIX packaging using those identity values. The
  dedicated workflow uses the checked-in manifest template and fails on
  identity or runtime-payload drift.
- [x] Add explicit `development`, `githubDirect`, `googlePlay`, and
  `microsoftStore` build-time distribution channels.
- [x] Disable GitHub update checks and PowerShell replacement in Store builds.
- [x] Keep Store and GitHub-direct Windows artifacts in separate workflow jobs.
  Store MSIX is manual in `microsoft-store.yml`; direct ZIP remains in
  `release.yml` and cannot consume the Store artifact.
- [x] Use four-part MSIX versions with the fourth component set to `0`.
  Packaging accepts exactly three numeric inputs with a non-zero major
  component and emits `<input>.0`; the first submission uses `1.0.0.0`.
- [x] Remediate the 2026-07-20 certification policy 10.2.4.1 required fix:
  declare `Microsoft.VCLibs.140.00.UWPDesktop` in the MSIX and keep the Visual
  C++ Redistributable disclosure in the first two lines of the canonical Store
  description. The next package version is `1.0.1.0`.
- [ ] Validate the packaged app writes only to supported app-data/cache locations.
- [ ] Run Windows App Certification Kit against the packaged Release build.
- [ ] Test Store flighting install, upgrade, rollback, uninstall, secure storage,
  HDR/SDR playback, libmpv loading, and firewall behavior.
- [ ] Provide privacy/support URLs, listing assets, age rating, and a credential-free
  demo path for certification. URLs, support contact, and exact built-in demo
  steps are recorded; Windows screenshots, Store age rating, and final content
  disclosures remain owner-run Partner Center work.
- [ ] Confirm Store signing on the downloaded certified package.

## Release-candidate gate

### Security

- [x] Release builds use no committed or debug signing material. Verified by
  the protected v0.1.32 release workflow.
- [x] Expected Android signing fingerprint is verified by CI. Verified for the
  v0.1.32 and v0.1.33 GitHub-direct APKs.
- [x] Update manifest signature and artifact digest are verified end to end by
  the protected release workflow. On 2026-07-15 the installed v0.1.32 direct
  build discovered, downloaded, verified, and installed v0.1.33 successfully.
- [x] Downgrades, invalid archives, and unapproved redirects are rejected by the
  PR2 regression suite.
- [x] No raw provider credentials exist in SQLite cache text, cloud payloads,
  diagnostics, or source summaries. PR #105 covers encrypted locators,
  cloud-safe payloads, and redaction tests; v0.1.34 passed protected release CI.

### Correctness and persistence

- [x] Fresh-install and upgraded schemas match. PR 12's schema-signature suite.
- [x] Every supported historical migration passes. PR 12's v8–v11 fixtures.
- [x] EPG success-empty, failure retention, and atomic replacement pass.
  PR 7's persistence suite (26 tests) covers all three plus rollback.
- [x] Source/profile/category race tests pass. PR 6's
  `media_tab_controller_test.dart` and `live_controller_test.dart` suites.
- [x] No tested controller or channel handler notifies a disposed owner.
  PR 6's dispose-during-load/refresh tests plus PR 8's owner-token suite;
  the in-handler `mounted`/`_disposed` gates are inspection-verified.

### Performance

- [ ] Large M3U, Xtream, Stalker, and XMLTV fixtures meet agreed budgets.
- [x] Network and decompression limits reject hostile fixtures in
  `test/net_workload_test.dart`.
- [x] Now-next EPG lookup uses the intended index. `EXPLAIN QUERY PLAN`
  selects `idx_prog_source_start` over a ~20k-programme corpus (PR 7).
- [ ] Peak memory remains within the agreed regression allowance.

### Native platforms

- [x] Android release build succeeds and certificate is verified by the
  protected v0.1.32 workflow; the APK installed successfully on owner hardware.
- [ ] Android phone lifecycle matrix passes on a device.
- [ ] Android TV lifecycle and focus matrices pass on a device.
- [x] Windows x64 release build succeeds in PR #98 CI on 2026-07-14.
- [ ] Windows SDR and HDR lifecycle matrices pass on hardware.
- [x] Android and Windows 100-cycle playback soaks return resource counters to
  zero. Owner-run on 2026-07-16 via `integration_test/player_soak_test.dart`
  on both platforms.

### General quality

- [x] `flutter analyze` passes locally and in PR #98 CI on 2026-07-14.
- [x] `flutter test` passes locally and in PR #98 CI on 2026-07-14.
- [x] PR #98 build, Android, Windows, CodeQL, and secret-scanning workflows pass
  from a clean checkout on 2026-07-14.
- [x] README and CI both declare Flutter 3.44.5.
- [x] `CLAUDE.md` schema and architecture claims match implementation. Reviewed
  and corrected after the PR 0–16 audit on 2026-07-16.
- [x] `docs/player.md`, `docs/tv-navigation.md`, `docs/cloud-sync.md`, and
  `docs/updates.md` describe the released behavior. Reviewed after the PR 0–16
  audit; cloud snapshot-revision behavior was added explicitly.

## Decision log

Add an entry before implementing any choice that materially changes compatibility,
security, persisted data, or provider behavior.

| Date | Decision | Reason | Consequences | PR |
|---|---|---|---|---|
| 2026-07-14 | Use a staged PR programme rather than a state-management rewrite | Existing ChangeNotifier/Listenable boundaries are workable; findings are local correctness and lifecycle problems | Keep current state-management approach | Planning |
| 2026-07-14 | Treat Android signing and updater trust as release blockers | The committed release signing key and unsigned update flow undermine update authenticity | No normal release before PRs 1–2 | Planning |
| 2026-07-14 | Use `IPTVS Player` as the customer-facing Microsoft Store and Google Play title | `iptvs` was unavailable in Partner Center; Store titles are presentation metadata and need not match package/application IDs | Use the reserved name consistently while keeping technical identities channel-specific | Store setup |
| 2026-07-14 | Store builds use Store-managed updates; only GitHub-direct builds may switch between signed GitHub stable/beta releases | Play prohibits self-update package installation and packaged MSIX updates are Store-owned | Use Store test tracks/flights only for submission validation; ongoing public betas use GitHub direct | PR 2 / Store setup |
| 2026-07-14 | Keep Store and GitHub-direct installations on separate identities | The owner prefers low-overhead GitHub beta distribution without Store signing, policy, or version conflicts | Play uses `com.gchofficial.iptvs.player`; GitHub direct uses `.player.direct`; Store builds never self-update | PR 1 / Store setup |
| 2026-07-15 | Per-controller monotonic `_loadGeneration` counters instead of a shared guard helper; only snapshot-writing ops (`load`, `setCategory`) bump the generation, while `loadMore`, `search`, `clearSearch`, and `refreshNowNext` read without bumping and abandon superseded results | Precedence policy is inherently per-controller, so a shared helper adds abstraction without removing duplication; search publishes to `searchResults`, independent of `snapshot`, so bumping there would drop a load's terminal state update (stuck `loading` flag) | Refresh always supersedes pagination, never the reverse; disposal stays expressed solely through `_disposed` checked in `_set`; the invariant is summarized in `CLAUDE.md` key conventions | PR 6 |
| 2026-07-15 | Record EPG refresh failure via the un-advanced `epg_synced_at` plus a redacted diagnostics line, not a persisted failure column; add `idx_prog_source_start(source_id, start)` at schema v12 for the source+time now-next queries | A failure column has no consumer until PR 16's diagnostics UX and would enlarge PR 12's migration matrix; the existing `(source_id, channel_id, start)` index cannot serve a query with no `channel_id` constraint | Success-empty is a real replacement (clears stale rows, advances freshness); failures leave the timestamp stale so the scheduler retries; channel-scoped queries keep `idx_prog_lookup` | PR 7 |
| 2026-07-15 | `replaceLibrary` writes the `sources` row via non-destructive update-else-insert instead of `INSERT OR REPLACE` | `INSERT OR REPLACE` deleted the row and nulled `epg_synced_at` on every channel refresh, defeating PR 7's failure-observability design; `ON CONFLICT DO UPDATE` was avoided because Android below API 30 ships SQLite older than 3.24 | Channel refresh now preserves EPG freshness and any future `sources` column; dead programme rows for removed channels persist at most ~3h until the next scheduled `replaceEpg` clears them by source | PR 7 |
| 2026-07-15 | Guard the two static inbound native channels with a Dart-side monotonic owner-token registry (`ChannelHandlerOwner`) instead of per-instance channels or a permanent multiplexer; no Kotlin/C++ changes | Flutter runs a replacement route's `initState` before the old route's `dispose`, so an unconditional dispose-time `setMethodCallHandler(null)` wipes the newer owner's handler (previously Windows-only cleared; Android never cleared); both native sides register once per process and hold no per-Dart-owner state, so ownership is purely a Dart problem; a permanent multiplexer would be a bridge redesign reserved for PR 9 evidence | "Identical Android/Windows cleanup" is satisfied Dart-side: both platforms run the same release-if-current path; real handlers keep `mounted`/`_disposed` second gates for calls already dispatched; invariant recorded in `CLAUDE.md` Player essentials and `docs/player.md` | PR 8 |
| 2026-07-17 | Keep the built-in demo as a deterministic capability fixture, while linking (rather than bundling) official Blender open-movie encodes and clearly labelling Apple/Mux protocol samples | Closed-test and certification users need meaningful Live, Movies, and Series paths without IPTV credentials; bundling or presenting third-party streams as owned content would create unnecessary rights and update liabilities | Demo exposes generated EPG/archive rows and complete media metadata, but remote URLs may still experience ordinary network/provider downtime; Blender descriptions carry the applicable CC attribution and protocol fixtures remain test-only | Demo catalogue |
| 2026-07-16 | PR 11 validation lives in BEFORE-INSERT/UPDATE triggers calling shared `assert_*` helpers on `sources`/`profiles`/`metadata_configs`, plus cheap top-level array-count/byte-size guards inside the push RPCs before any mutation; CHECK constraints and RPC-only validation were both rejected. Rate limiting is a DB-side token window (`push_rate` table + `check_push_rate`, 30 pushes/min per device session — per-device rather than per-owner so multiple devices on one account never throttle each other) modeled on `request_pairing`'s counter; an Edge Function proxy was rejected. All limits sized ≥10x above realistic maxima measured against the 250k-channel validation corpus (favorites cap 200,000; 50,000 hidden-category ids per kind; 16 MB payload ceilings) | The panel writes tables directly under RLS, so RPC-only validation leaves the credential-bearing `sources.fields` path unbounded; a CHECK-constraint failure emits `details = "Failing row contains (…)"` which `PostgrestException.toString()` surfaces verbatim in the Flutter UI — a credential leak; triggers deploy idempotently on a live table with no NOT VALID/VALIDATE dance. An Edge proxy is a new deploy target plus counter store for a threat already bounded to the caller's own account by owner-scoping and payload caps | Legitimate huge-portal users are never rejected by our own validation (typed `iptvs: `-prefixed `check_violation` errors, no payload values interpolated); reads/pulls stay unthrottled by design (RLS-scoped, documented as accepted risk); the Supabase gateway's own body-size ceiling is verified empirically against the live project as an owner-run item | PR 11 |
| 2026-07-16 | Harden the player lifecycle with targeted per-defect fixes plus a queryable debug-only counter registry (Dart `ResourceCounters` / Kotlin `DebugCounters` / C++ `#ifndef NDEBUG` ints), rejecting a unified per-platform lifecycle/session object; counters merge through a `debugCounters` method on the existing HDR channel rather than a new inbound channel | The audit found only two genuine, local defects (Windows silent surface-failure; preview `TextureView` not detached at PlatformView dispose) — a session object is precisely the bridge redesign the ledger forbids without measured need and would rewrite through seven load-bearing, currently-passing invariants; a new inbound channel would add handler-ownership surface right after PR 8 removed that class of bug; the soak must programmatically assert zero, which pure logging cannot fail on | Counters thread through the existing call sites, so a green soak proves those exact release paths complete; release builds are inert (`kDebugMode`/`BuildConfig.DEBUG`/`NDEBUG`, empty `debugCounters` reply); deferred as a known efficiency item, not a leak: PlayerScreen constructs an embedded media_kit `Player` even on the Android native path where it is never opened (counted and disposed, so soaks still balance) | PR 9 |

| 2026-08-04 | Name a device at pairing time by carrying a device-supplied *suggestion* on the pairing row (`pairings.suggested_label`, written by a new `request_pairing(p_label)`) and an optional panel-supplied name on a new `claim_pairing(p_code, p_label)`. Overloads are **arity-distinct with no `DEFAULT`**, and the narrow 0-arg/1-arg forms are kept forever as thin delegates. Precedence: panel > existing `devices.label` (same owner only) > suggestion > `''`. Rejected: (a) a `set_device_label` RPC letting the device write `devices.label` itself; (b) a single `claim_pairing(p_code, p_label DEFAULT null)` with the 1-arg dropped; (c) a panel-side follow-up `UPDATE devices` after the claim; (d) a device-side name text field | A device is an anonymous auth user and `devices_update` requires `is_real_user()`, so (a) needs permanent new RPC surface a device could call at any time to overwrite an owner-chosen name, not just at pairing. (b) is a correctness trap: PostgREST resolves overloads by parameter-name set and answers `PGRST203` when two candidates match, so a `DEFAULT` beside the 1-arg breaks 100% of pairings; dropping the 1-arg instead breaks any panel SPA tab loaded before the deploy, and `request_pairing()` must survive arbitrarily old app installs. (c) cannot read `pairings` (RLS is `device_uid = auth.uid()`), so it would infer the new `device_uid` by diffing the device list — racy, and it renames the wrong device under concurrency. (d) would put a focus target and a Back-ladder rung on a screen driven by a TV remote | Device-side naming is zero-typing (read-only hint text only); `suggested_label` is attacker-controlled text reaching another account's panel, so it is bounded 256 (**coupled** to `devices_validate`'s ceiling — a larger bound would let a device deny its owner's claim), control-chars rejected, and frozen on UPDATE; a cross-account re-pair no longer inherits the previous owner's name (deliberate behaviour change); both clients fall back to the narrow RPC on `isMissingFunctionError` to survive panel/migration deploy skew; residuals recorded — the suggestion is unauthenticated by nature, and bidi/zero-width Unicode is not caught | Device naming |

| 2026-08-22 | Render the Android live preview into a **`SurfaceView` embedded with hybrid composition** (`PlatformViewsService.initExpensiveAndroidView`), replacing the `TextureView` platform view; the platform view is non-focusable and blocks descendant focus | The original choice was recorded as "TextureView because SurfaceViews don't compose inside Flutter platform views" — true of Flutter's default path, and ruinous at 4K50 HDR10. A SurfaceView's buffers reach the system compositor untouched (usually a hardware overlay plane, zero copy, HDR metadata intact); a TextureView's go through a `SurfaceTexture` into an external GL texture the app's GPU draws and Flutter then composites again — two extra full-frame passes at 3840x2160x10-bit, fifty times a second, on a set-top box. An export measured the same codec instance on the same stream holding `fps=49.3 dropped=+3` into fullscreen's SurfaceView while a mostly-preview window managed ~11.7 fps | Hybrid composition is mandatory, not optional: Flutter's default path returns a texture and a SurfaceView has none to give, so `AndroidView` renders nothing at all. Its cost is that widgets painted *over* the platform view are promoted onto their own overlay surfaces — one small static chip does, and the full-bleed loading/error scrims are structurally alternatives to the video rather than layers on it (`test/preview_overlay_test.dart` pins that). Changes the rendering path on **every** Android device, not just TVs. The transparent handoff's frozen last frame is the one visual property this could disturb and is device-only to verify | Android TV playback |
| 2026-08-22 | `readCategories`/`readMediaCategories` order by **`rowid`** (the provider's own order) instead of `title`; **no** stored `position` column and no schema bump | A fresh load shows `Source.categories()` while the cached read re-sorted alphabetically, so the category pane silently reshuffled between a forced refresh and the next app start — and once Favorites derived their order from it, the favorites list reshuffled too. `replaceLibrary`/`replaceMediaLibrary` delete the source's rows and re-insert the whole list in order in one transaction, so rowid already *is* the provider position; a column would be a second copy of it bought with a migration | **Makes an implicit rowid load-bearing.** If a path is ever added that updates a category row in place, add the column instead. Two recorded non-hazards: `VACUUM` renumbers rowids but rewrites rows in rowid order (and nothing here vacuums), and a duplicate id inside one payload collapses to the later position. Visible change for existing users: category panes and media dropdowns switch from alphabetical to provider order. Pinned by `persistence_test.dart` | Android TV playback |
| 2026-08-22 | A **television always gets the wide two-pane layout**, independent of logical width (`isWideLayout`, `isTelevision` resolved once at boot off the existing `iptvs/device` channel); rejected lowering `kWideLayoutMinWidth` | Logical width is physical pixels over the device pixel ratio, so one 4K panel reports 960 at dpr 4.0 and 873 at dpr 4.4 — a set-top box lands either side of the 950 breakpoint on a density it picked for itself. The phone layout it falls into is silent: no category pane, no preview panel, and therefore no shared-engine preview path at all. Lowering the breakpoint would instead hand the two-pane layout to large phones in landscape, which is the band it exists to exclude | Detection is `UiModeManager` **or** the leanback/television system features — boxes reporting `UI_MODE_TYPE_NORMAL` while being televisions are common, and neither signal can fire on a handset. One `isTelevisionDevice()` shared by the browsing layout and the player chrome, because a split between them produced a two-pane list with handset-sized player controls. Awaited before `runApp` (inside the existing parallel boot tuple, bounded by a timeout) so no frame is built with the wrong answer; fails closed to false | Android TV playback |
| 2026-08-23 | The cross-source Favorites view **carries an EPG**, keyed by `(sourceId, channelId)` and refreshed through the channel-constrained `nowNextForChannels`; `LiveTabView` gains an `epgFor` resolver and an explicit `showsEpg` flag, replacing `now.isNotEmpty` as the row-height input | The view shipped with **no** guide, recorded as a deliberate limit. The reason was sound but the conclusion was too strong: the live tab's now/next maps are keyed by channel id, which is unique only *within* a provider, and this is the one view where two providers meet — so reading them would print another provider's programme against a foreign row. Keying by the pair removes the collision entirely, and the guide is already cached per source. The row set here is a small, fully known list of favorites, which is precisely the case `nowNextForChannels` exists for and the live tab cannot use | A foreign source's guide is only refreshed while that source is active, so it can be stale — that degrades to *nothing*, not to something wrong, since both halves of the query are bounded by the current instant. `showsEpg` had to become explicit: a view served by `epgFor` has empty maps while its rows are the tall kind, and the extent assert compared against `now.isNotEmpty`. All four printing surfaces (row, preview panel, phone sheet, fullscreen player) now resolve through `_epgFor`; they previously handed a foreign row `null` on every one | Field reports |

## Progress log

Add one short entry when a PR starts, changes scope, becomes blocked, or completes.

| Date | PR | State | Evidence or next action |
|---|---|---|---|
| 2026-07-14 | Planning | Created | Begin PR 0 fixture and benchmark inventory |
| 2026-07-14 | PR 0 | In progress | Added deterministic provider workloads, opt-in host/SQLite baseline, seeded public v8–v11 schema fixtures, and validation documentation; application-profile and native-device evidence remain |
| 2026-07-14 | PR 1 | In progress | Selected side-by-side Play/GitHub-direct/development package IDs, configured permanent GitHub signing, and documented the authenticated cloud migration with exact retained/reset state; protected workflow and old/new device evidence remain |
| 2026-07-14 | PR 2 | In progress | Added signed manifests, pre-connection redirect approval, exact artifact gates, Android package/signer verification, staged Windows rollback, immutable Action pins, downgrade rejection, and signed GitHub stable/beta selection; PR #98 Windows rejection/rollback CI passed, while protected release and device evidence remain |
| 2026-07-14 | Store setup | In progress | Reserved Microsoft `IPTVS Player`, recorded Partner Center identity, completed Play verification, and created Play app `com.gchofficial.iptvs.player`; generated/configured an isolated Play upload key and protected identity/certificate-verified AAB workflow, with two encrypted backups confirmed; Play enrollment and Store packages remain |
| 2026-07-14 | PR 15 subset | Ready for PR | API-36 Android TV emulator confirmed compact live density and native controls→exit Back peeling; automated tests now prove category filtering hands focus to the filtered channel list. Broader accessibility and device matrix remain. |
| 2026-07-15 | PR 15 subset | Merged | PR #100 merged as `912392f`; Android TV Back, density, category focus, tests, and store screenshots are on `main`. |
| 2026-07-16 | PR 15 | Ready for PR | Added stable-id selection reconciliation, explicit sheet/search/playback focus restoration coverage, repeat-safe activation tests, and selected/position/action semantics for live, media, and EPG custom rows. `flutter analyze` is clean and all 356 tests pass (14 skipped); the physical device/input/screen-reader matrix remains owner-run. |
| 2026-07-17 | PR 17 | In progress | Added exact-identity x64 MSIX packaging and unpack-time verification in a dedicated manual Store workflow; four-part `.0` versioning, minimal full-trust manifest, required Flutter/libmpv payload, Store URLs, and credential-free demo instructions are pinned. Run CI packaging, WACK, Partner Center flight/device matrix, listing assets/rating, and certified-signature check next. |
| 2026-07-15 | PR 3 | In progress | Shared bounded HTTP/decompression boundary implemented and all Dart callers migrated; oversized Stalker/Xtream live catalogs now partition through pagination/categories instead of rejecting the source. Phone/TV profiling also exposed and fixed non-finite media-card image cache sizing. Provider temp-file ingestion remains intentionally sequenced with PR 10's one-pass parser work. |
| 2026-07-15 | PR 3 | Merged | PR #101 merged as `ec33886`; owner verified large Stalker live/EPG loading, playback, and movie/series posters on the 2 GiB TV emulator. A focused follow-up retries one transient catalog failure and keeps raw provider exceptions out of the UI. |
| 2026-07-15 | PR 0 | Complete | Android phone/TV profile baselines and longstanding Windows x64 SDR/HDR validation are sufficient for early testing. Deeper import/RSS/SQLite budgets are deferred until closed-testing feedback supplies representative problems. |
| 2026-07-15 | PR 1 | Verification | Play accepted an initial internal AAB and its update; authenticated cloud migration restored sources/favorites and documented local exclusions began fresh. API 26 smoke and permanent GitHub-direct certificate evidence remain. |
| 2026-07-15 | PR 2 | Verification | Tag `v0.1.31` exposed an Android build-tools output-format bug in certificate parsing after the signed APK built; parser accepts both legacy and current labels in the follow-up, then a new tag will provide end-to-end evidence. |
| 2026-07-15 | PR 1 | Complete | Protected v0.1.32 CI verified the permanent GitHub-direct APK certificate; the signed APK installed on owner hardware, and API-26 x86_64 smoke passed on a 1 GiB/four-core emulator. |
| 2026-07-15 | PR 2 | Complete | Protected v0.1.32 release produced signed manifests/artifacts, verified the exact APK identity/certificate, and installed successfully; the next tag will exercise the in-app GitHub-direct update path. |
| 2026-07-15 | PR 3 follow-up | Complete | PR #102 merged transient retry/error sanitization, mobile SQLite-factory correction, signing-parser compatibility, and the API-26 PiP return-stack fix as `a909738`. |
| 2026-07-15 | PR 4 | Ready for PR | SourceConfig UUID namespaces and opaque normalized M3U channel IDs are implemented with atomic cache/favorites/EPG/position/cloud migration; analyze, all 269 tests, and Android Kotlin compilation pass. Merge and tag next so v0.1.32 can exercise the GitHub-direct updater. |
| 2026-07-15 | PR 4 | Complete | PR #103 merged as `c3eab92`; protected v0.1.33 release CI passed, and the owner completed the in-app GitHub-direct update from v0.1.32 to v0.1.33. The one-time identity migration made the first post-update launch somewhat longer but completed successfully. |
| 2026-07-15 | PR 4 follow-up | Ready for PR | A verified pending APK now survives unknown-source/OEM Auto Blocker detours and process recreation; settings return retries the same file, every resume repeats cache size/hash plus native package/signer validation, and analyze, all 277 tests, and Android Kotlin compilation pass. |
| 2026-07-15 | PR 5 | Ready for PR | Added AES-GCM installation-key protection for cached playback locators, one-time legacy cache migration, deterministic missing-key invalidation, cloud-safe source/metadata payloads with local-secret preservation, redacted source summaries, and credential-field reveal controls; analyze, all 280 tests, and Android Kotlin compilation pass. |
| 2026-07-15 | PR 5 | Complete | PR #105 merged as `b857be0` and protected v0.1.34 release CI published signed Android and Windows artifacts. The owner installed the update, confirmed favorites persisted, and successfully played a pre-update favorite; all 282 tests pass with 10 expected skips. |
| 2026-07-15 | PR 6 | Complete | Merged as #106 (`78e9a48`) with all CI checks green. Generation guards landed in `MediaTabController`, `LiveController`, and `HomeShell._loadActive`/`_loadProfileInfo`; 11 new Completer-gated race tests (two proven load-bearing against pre-fix code). Known adjacent defect deferred to PR 13: a metadata-config-only change rebuilds the repository without changing `ChannelListScreen`'s `ValueKey`, leaving controllers on a disposed repository. |
| 2026-07-15 | PR 7 | Ready for PR | Success-empty EPG is now a real atomic replacement (clears stale rows, advances freshness); failures retain the cached guide with the timestamp as the failure record; `replaceEpg` streams bounded 1000-row chunks inside one transaction; schema v12 adds `idx_prog_source_start` on both create and upgrade paths, confirmed by `EXPLAIN QUERY PLAN` over a 20k-programme corpus. Also fixed pre-existing `replaceLibrary` `INSERT OR REPLACE` nulling `epg_synced_at` on every channel refresh (decision log). Analyze and all 300 tests pass. |
| 2026-07-15 | PR 7 | Complete | Merged as #107 (`5316220`) with all CI checks green. |
| 2026-07-15 | PR 8 | Ready for PR | `ChannelHandlerOwner` token registry guards `iptvs/native_hdr_player` and `iptvs/native_preview`; dispose-time clear is now release-if-current on both platforms (was Windows-only; Android never cleared) and the HDR handler bails on `!mounted`. Four unit tests pin claim/release/supersede semantics via real channel dispatch; no native edits needed (natives are owner-agnostic). Analyze clean; 304 tests pass. Unblocks PR 9 and, with PR 6, the widget-split sequencing gate for PR 13. On-hardware smoke of the Windows route-replacement handoff and Android `nativeClosed`-after-supersede folds into PR 9's device matrices. |
| 2026-07-15 | PR 8 | Complete | Merged as #108 (`4458068`) with all CI checks green. |
| 2026-07-16 | PR 9 | Ready for PR | Audit-first pass over the whole native lifecycle found two defects, both fixed: Windows surface-creation failure now raises the terminal error/Retry overlay instead of silent audio-only playback behind a black overlay, and preview PlatformView disposal now detaches the destroyed `TextureView` from ExoPlayer (identity-checked, skipped while adopted). Added the full debug-only counter registry across Dart/Kotlin/C++ (release-inert, merged via `debugCounters` on the existing HDR channel, shown on the diagnostics screen), the owner-runnable 100-cycle soak (`integration_test/player_soak_test.dart`, with a debug-only auto-close extra so `HdrPlayerActivity` cycles unattended), idempotent engine `release()`s, and the pure `ReconnectPolicy` extraction pinned by 4 new plain-JUnit tests. Analyze clean; 305 Dart tests pass (+1 counter-balance test); Kotlin compile + 6/6 JVM tests pass. Remaining open boxes are owner-hardware: both 100-cycle soaks, the four device matrices (which absorb the two PR 8 smokes), and the two hardware-only Windows items (DPI/monitor changes, reconnect after surface recreation). |
| 2026-07-16 | Store setup | Complete | Android developer verification registered the Play and GitHub-direct packages with their separate certificates; the Play-installed internal-track APK matched the Play-managed fingerprint; privacy, data-safety, content-rating, phone, and TV listings plus internal phone/TV smoke tests are complete. Internal testing continues before production publication. |
| 2026-07-16 | PR 9 | Complete (matrices open) | Merged as #109 (`49ea241`) with all CI checks green and released as v0.1.35 (signed direct release + Play AAB). Google approved the 0.1.35 closed-testing release the same day; TestersCommunity's 14-day tester window opened 2026-07-16, so the personal-account production gate completes no earlier than 2026-07-30. Owner ran both 100-cycle soaks (Android and Windows) on 2026-07-16 and every counter returned to zero. The four device matrices and the two hardware-only Windows items stay open while closed-test feedback accumulates. |
| 2026-07-16 | PR 10 | In progress | Design pass started on `perf/isolate-ingestion`: audit the four ingestion paths, develop competing worker-boundary designs, then implement bounded one-pass isolate ingestion against the PR 0 fixture corpus and budgets. |
| 2026-07-16 | PR 10 | Ready for PR | Hybrid worker boundary implemented: Xtream/Stalker catalogs decode+map bytes→typed lists in one worker job (dynamic JSON graph never crosses the isolate boundary; Stalker's ~28 MB `get_all_channels` no longer `jsonDecode`s on the UI thread), XMLTV streams 1000-row `Programme` batches with single-in-flight ack flow control into the new one-transaction `replaceEpgStream` (success-empty contract preserved; cancellation rolls back via `LoadCancelledException`), and an additive `LoadToken` stops superseded loads from writing stale data (pinned generation-guard tests pass unmodified — token rides a documented settable repository field because a signature change would break the pinned `_GatedRepo` overrides). `BatchedEpgSource` is a separate optional capability interface since `implements` doesn't inherit default bodies. Dev-host baselines recorded (inline vs. isolate round-trip; batched XMLTV slightly faster than single-list). Analyze clean; 334 tests pass (+29: ingest parity, malformed-row, batch/cancel, stream-persistence suites). Remaining open boxes are owner-run on-device: TV-Low stall and peak-RSS before/after capture. |
| 2026-07-16 | PR 10 | Merged | Merged as #110 with all CI checks green. Owner-run TV-Low stall and peak-RSS before/after capture remains open. |
| 2026-07-16 | PR 11 | In progress | Deep-reasoner design pass complete on `sec/cloud-hardening`: gaps confirmed (no payload validation anywhere, `search_path = public` on 11 SECURITY DEFINER functions, no push rate limit, panel/Flutter error surfaces can echo Postgres `details`), pairing single-use verified already sound, ownership sweep found no gap. Implementing: one idempotent migration (BEFORE-trigger validation + RPC top-level guards + DB-side push rate limit), panel validation/error scrubbing, Flutter `friendlyCloudError`. |
| 2026-07-16 | PR 11 | Ready for PR | Migration `20260716000000_harden_cloud.sql` (search_path sweep, trigger + RPC validation with ≥10x-over-250k-corpus limits, per-device push rate limit, advisory-locked INVOKER profile cap, `delete_account` reaps rate rows; orchestrator review added the kind/NOT-NULL/position pre-emption so table-constraint errors can't echo "Failing row contains" credentials). Panel: `validate.js` scheme/length validation + `friendlyError`/`scrubUrls` on every error surface, 20 node tests green. Flutter: `friendlyCloudError` replaces all raw `'$e'` sites (PostgrestException `details` leak closed), 4 new tests. Analyze clean; 338 tests pass. Live-project verification items are owner-run after merge (the migration auto-applies on push to main). |
| 2026-07-16 | PR 11 | Merged (live checks open) | Merged as #111 (`545fc93`); all functional CI green (the one red check was GitGuardian's documented false positive on the synthetic credential fixtures in `panel/test/validate.test.js`). The Supabase GitHub integration applied `20260716000000_harden_cloud` to the live project, and the security advisor now shows no mutable-`search_path` findings — remaining advisor items are documented-intentional (policy-less `push_rate`, the privileged RPC surface, anonymous device sessions) plus Supabase's own benign `rls_auto_enable` event-trigger helper. Owner-run live verification (cross-user rejection, pairing expiry/replay, concurrent profile-cap race, oversized/throttled pushes, gateway body-size bound) remains open. |
| 2026-07-16 | PR 11 | Complete | v0.1.36 released (signed direct release; all workflow gates green) and the owner completed the live-project verification pass the same day: 0.1.35→0.1.36 in-app update plus normal sync/panel smoke, oversized/invalid pushes rejected with typed `iptvs: ` errors before mutation, >30/min push throttle, pairing expiry/replay and cross-user rejection, and the concurrent profile-cap race at 20. No gateway 413 interfered at tested payload sizes. |
| 2026-07-16 | PR 12 | Ready for PR | Tag archaeology confirmed the public schema history and corrected the v11 range (v0.1.16–v0.1.34, not –v0.1.30; v12 first shipped in v0.1.35); normalized-DDL diffs across each tag range show no intra-range drift, and the v8–v11 fixture builders match the tagged fresh-install DDL exactly. Compatibility claim scoped to released schemas 8–11 → current (pre-v8 branches documented as best-effort dev-era paths in the `schemaVersion` doc comment, CLAUDE.md, and validation-baseline). `released_schema_fixtures_test.dart` now pins, per released version: migrate → pragma-based schema parity with a fresh install (`table_info`, name-keyed indexes, `foreign_key_list`) → seeded favorites/positions/EPG/`external_metadata` survival → stable second open (version 12, data intact, signature unchanged). Analyze clean; 346 tests pass (+8). |
| 2026-07-16 | PR 12 | Complete | Squash-merged as #112 (`c07920e`); the remote topic branch was removed. |
| 2026-07-16 | PR 13 | Ready for PR | Fixed same-source repository replacement by rebuilding/disposal-scoping the repository-backed live/media/favorites/preview controllers in `didUpdateWidget` while preserving screen-owned focus/scroll nodes; a widget regression proves the new source replaces the old controller data. Moved tabs/search/category/action chrome into `channel_list_chrome.dart` and embedded player controls/error/reconnect presentation into `player_overlay.dart`; route/dialog orchestration and all player/native lifecycle state remain with their existing owners. `channel_list_screen.dart` dropped from 2,043 to 1,590 lines and `player_screen.dart` from 1,845 to 1,638. Focused suites: 54 passed. Analyze clean; all 347 tests pass (14 expected skips). |
| 2026-07-16 | PR 14 | Ready for PR | Added explicit `CatchupCapability`/URL modes, provider timezone or fixed-offset conversion, archive-window and formatting metadata, Xtream/Stalker source-owned capability reporting, M3U `catchup`/`catchup-days`/`catchup-source` parsing and template resolution, and persisted advanced per-source overrides. Unsupported catch-up remains explicit. Added timezone/device-disagreement, DST-boundary, and capability tests. Analyze clean; all 350 tests pass (14 expected skips). |
| 2026-07-16 | PR 16 | Ready for PR | Completed structured redacted ingestion summaries (parse/database durations, encoded/decoded HTTP bytes, and parser rejection counts), source cache statistics, final-boundary export redaction, source-card EPG/catch-up/adaptive-resolution summaries, server-revision overwrite confirmation, credential-free profile snapshot restore previews, and safe force-refresh re-ingestion. Analyze clean; full suite passes (360 tests, 14 expected skips). |
| 2026-07-16 | PR 14/16 review fixes | Implemented | Corrected M3U header/per-entry catch-up propagation, added real IANA/DST conversion and user-visible overrides, preferred reported provider timezones, replaced inferred capability labels with provider-owned unknown/supported states, advanced profile snapshot revisions for source/metadata mutations, split streamed provider/database timings, and redacted diagnostics at insertion/display/export. Analyze clean; 367 tests pass with 14 expected skips. The new cloud migration still requires normal deployment/live verification. |
| 2026-07-17 | Demo catalogue | Implemented | Expanded the credential-free demo source into a capability fixture: six live-tab rows, generated now/next + archive guide, four Blender open-movie movie entries with artwork/licence metadata, two series hierarchies, HLS/fMP4/HEVC/MP4 fixtures, category/search filtering, and 5 focused catalogue tests. Existing hierarchy/focus tests remain green; full suite is the next validation step. |
| 2026-07-17 | Linux feedback | Implemented | Closed a 5 px embedded-player `RenderFlex` overflow when EPG now and next were both present at short desktop heights by compacting them into one ellipsized top-bar line. Analyzer and focused navigation/catalogue tests pass. |
| 2026-07-20 | Microsoft Store certification | Required fix implemented | The `1.0.0` submission passed with a policy 10.2.4.1 follow-up for the undisclosed Microsoft Visual C++ Redistributable. Added the Store-provided VCLibs framework dependency to the manifest and verifier, pinned the required disclosure as the first two description lines, corrected reviewer demo instructions, and selected `1.0.1.0` for the next submission. |
| 2026-07-20 | Release feedback | Implemented | Expanded Android compact browsing from the live preview shell to denser 56/88 px channel rows and adaptive 5–10-column movie/series grids; subscription expiry now preserves dated/unlimited/unknown states; compared playback with v0.1.30 and removed the post-Linux-release native-mpv discovery delay from ordinary SDR/direct fullscreen opens. Focused tests and analyzer pass; full suite and release builds next. |

| 2026-07-29 | Edge-to-edge insets | Implemented | Play flagged edge-to-edge for the next Android release; the app already ships `targetSdk` 36 (Flutter 3.44.5 default), so enforcement was already live rather than pending. Reproduced on an API-36 phone emulator in **landscape**, where the 3-button bar is a *side* inset: the Help & about cards' trailing link icons rendered underneath it. Wrapped every `Scaffold` body in `SafeArea(top: false)` (AppBar already consumes the top inset) — chosen over list padding so `LiveFocusCoordinator._reveal` and the EPG grid keep computing against a viewport that excludes the inset, leaving their index→offset maths unchanged. Replaced the deprecated `systemUiVisibility` flag block in `HdrPlayerActivity` with `WindowInsetsControllerCompat` + `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE`, added `LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES` so video fills a notched phone instead of letterboxing, and inset the Compose overlay's controls/menus via `safeDrawingPadding()` while keeping the scrim full-bleed. A review pass then caught a second surface: the shared embedded overlay (`player_overlay.dart`) is Android's fallback when `HdrPlayerActivity` can't launch and runs in the ordinary, non-immersive Flutter window, so its Back button/scrubber sat under the bars too — now inset via `_barInsets`, pinned by a load-bearing test (fails `Expected: <48.0> Actual: <0.0>` against pre-fix code). Analyze clean; all 571 tests pass; Android Kotlin compiles. Insets are zero on Android TV, so the TV navigation model is unaffected. |

| 2026-08-04 | Device naming | Implemented | A freshly paired device now arrives named instead of showing as "Device" until renamed. Added `pairings.suggested_label` plus `request_pairing(p_label)` / `claim_pairing(p_code, p_label)` (`20260804000000_pairing_suggested_label.sql`), keeping the 0-arg/1-arg forms as delegates — PostgREST resolves overloads by parameter-name set, so a `DEFAULT` beside a narrower form would answer `PGRST203` and break every pairing. Panel gained an optional Name box beside the code; the app derives a zero-typing suggestion (`device_label.dart`, Android TV vs handset over a new outbound-only `iptvs/device` channel) and sends it with the code, with an `isMissingFunctionError` fallback on both clients for panel/migration deploy skew. Precedence is panel > existing name (same owner) > suggestion > empty, so a blank panel field can never clobber a hand-chosen name, and a cross-account re-pair no longer inherits the previous owner's name. Evidence: new `supabase/tests/13_pairing_label.test.sql` (14 assertions covering the precedence matrix, the 256/control-char bounds, and the UPDATE freeze), plus additions to `02_pairing_flow` (legacy 0-arg path still yields an empty label), `03_devices_immutable` (cross-account re-pair drops the old name), `12_rpc_guard_coverage` (2-arg claim still rejects an anonymous session). Analyze clean; 696 Flutter tests and 111 panel tests pass; panel builds. **Not yet verified:** the pgTAP suite has not been executed (no local Postgres/Docker — `db-tests.yml` runs it on the PR), and the Android TV vs handset detection needs an on-device check. |

| 2026-08-10 | Poster re-decode | Implemented | Posters visibly reloaded (placeholder and all) every time the focus cursor crossed them, on TV *and* desktop. `FocusableCard` drew its ring as the `AnimatedContainer`'s `decoration` border at `width: _focused ? 2 : 1`, and a `BoxDecoration`'s border is what insets a `Container`'s child — so focus narrowed the subtree by 2 logical px through ~7 interpolated fractional widths, and the grid poster (`width: double.infinity`) fed each of those to `imageCacheSize` → `memCacheWidth`, which is part of the `ResizeImage` cache key. Every animation frame was a cache miss. The ring moved to a `foregroundDecoration` behind a fixed-width transparent border (`kFocusableCardBorderWidth`, which `MediaGridMetrics.tileBorder` now reads rather than restates — the two drifting apart is what previously overflowed a focused tile by ~1.6 px); layout is now identical in both states and the visual is unchanged. Defence in depth: decode widths snap **up** to `kImageCacheSizeBucket` (32 physical px), so a window drag, a text-scale change or a fractional grid division reuses the bitmap instead of missing. Analyze clean; 803 tests pass. **Not yet verified:** `channel_list_focus_test.dart` skips locally without libmpv, so the focus/Back-ladder suite is CI-only — treat the ring change as unconfirmed until CI is green. |

| 2026-08-10 | TV handoff instrumentation | Implemented | Follow-up reports on the preview→fullscreen handoff ("higher-bitrate/resolution/fps channels stutter, and on the latest build many stay blocked") arrived with an exported log that proved the handoff *mechanism* worked — `decision=adoptNative` → `adoptShared=true adopted=true`, ~777 ms OK-to-adoption — and then said nothing for the next 6.3 s. Everything past `adopted=…` was logcat-only, so a failing session and a working one exported identically. `HdrPlayerActivity` now stamps notes with ms since `onCreate` and reports surface-claim mode/wait, first-frame latency, stream shape (`1920x1080 fps=50 codec=HEVC range=HDR10`), reconnect `kind=`, re-resolve outcome, and engine swaps — all bare numbers/labels, safe to export verbatim (`ExoPlayerEngine.onDiagnostic`, bound by `adoptForFullscreen` *before* `claimViewSurface` and cleared by `bindPreviewCallbacks` so a preview never holds a finished Activity's closure). One defect was solid enough to fix without waiting: `pollLiveReconnect` judged stalls from `isBuffering \|\| ended`, which are the engine's own *claims*, so a decoder re-instantiated across the output-surface swap sat in `STATE_READY` reporting `isPlaying` with nothing drawn — healthy by every flag, never reconnected, never logged. `FrameLivenessWatch` (pure, `ReconnectPolicy.kt`) samples `PlaybackEngine.renderedFrameCount` on the existing 500 ms tick and fires after `NO_FRAME_STALL_MS` (6 s); it fails inert three ways — `-1` (mpv, audio-only), any non-healthy state, and **a counter never seen to advance**, since that can't be told apart from a decode path that doesn't report one and a stream rendering nothing is a buffering stall the older watchdog already owns. Analyze clean; 803 Flutter tests and 7 new + existing Kotlin JVM tests pass. **Not yet verified:** none of this has run on the reporting TV — the point of the change is that the *next* report can distinguish the three remaining candidate causes (the 1 s `CLAIM_FALLBACK_MS` bet losing on real 4K hardware, the preview `TextureView` being destroyed inside the deferral window, and `prioritizeTimeOverSizeThresholds = true` at 15 s/50 s letting the allocator run away at high bitrate). |

| 2026-08-10 | Stalker expiry | Implemented | MAG portal expiry read "unknown" on **every** portal. Root cause was ordering, not parsing: `_call` only guarantees `_resolveEndpoint` (handshake + token), while a MAG session is established by `get_profile` — which only `connect()` sends, and which `subscriptionExpiry()` never called. Since `_SourceCard._fetchExpiry` builds a *fresh* source per card, `account_info`/`get_main_info` was always the first action on an unauthorized session. `subscriptionExpiry()` now awaits `connect()` and reuses the profile `js` it already fetched (`_lastProfileJs`) instead of paying a second round trip. Three parsing gaps behind it: the lenient `extractExpiryFromText` was applied to `phone` alone while the *named* fields went through the strict Unix/ISO parser (so an ordinary `end_date` in any human format read as no answer); month-name dates — PHP's default formatting, i.e. what a stock Ministra skin emits — were not handled at all; and coverage missed `expire_date` at top level, `tariff_expired_date`, `end_date_timestamp`, the `account_info`/`info`/`data` wrappers, and the `fname`/`ls` identity fields panels stuff the date into as readily as `phone` (`comment`/`description` were tried and dropped — a date in a free-form note is more likely about something else, and a wrong expiry is worse than none). A far-future sentinel (`9999-12-31`) is now **unlimited**, not unknown — but **only when written as a date**: review caught that a bare integer read as Unix seconds lands centuries out (`40712345678` → year 3260), so a customer's phone number in the very field panels stuff dates into would have reported a lifetime subscription. The existing "phone is not a date" test missed it because it asserts on the *date*, and unlimited carries none; the new one asserts on the kind. When the answer is still unknown the payload is logged as key *names* plus `expiryValueShape` masks (`dddd-dd-dd`) — never values, since `phone`/`fname`/`ls` are customer PII. Analyze clean; 803 tests pass (+10 expiry, including negatives and a diagnostics-leak assertion). **Not yet verified:** no live MAG portal was available, so the fix is code-derived — the shape logging exists precisely so the next report names the field and format instead of repeating "shows unknown". |

| 2026-08-10 | Expiry caching | Implemented | Every sources-screen card builds its own `Source` and asks the provider, so uncached the screen is a full portal round trip per card per visit — and for Stalker now a handshake + `get_profile` + `get_main_info`, since the badge has to authorize first. New device-local `ExpiryCache` (`lib/data/expiry_cache.dart`), keychain-backed like `UpdateStore`. **Deliberately not `SourceConfig.settings`**: that blob rides the source row into the cloud (`push_sources`), so caching there would push a timestamp rewrite per refresh, advance `profiles.updated_at` through `touch_profile_snapshot_revision` on every paired device, and hand other devices an answer for a portal they may not reach. Entries carry an `expiryConfigFingerprint` (a hash of `kind` + `fields`, so an edited credential invalidates while a rename doesn't) and three staleness rules: 12 h for a definite answer, 30 min for `unknown` (as often a transient portal failure as a real absence), and **immediately** within 48 h of the date itself — the renewal window, which is the one time the user is watching the badge expecting it to move, and the reason no manual refresh control was added. A stale entry still renders while it revalidates; only an empty cache spins, and a failed revalidation keeps the value on screen. `_fetchExpiry` is generation-guarded per CLAUDE.md so an edit mid-flight can't persist an answer for replaced credentials. Analyze clean; 803 tests pass (+16 cache). |

| 2026-08-10 | M3U expiry | Implemented | Debug-run feedback: the Stalker fix landed (a test portal now reports its expiry), but an M3U source whose URL is an Xtream credentials link still read unknown **with nothing in the diagnostics log**. Both halves were real. `M3uSource.subscriptionExpiry()` was a single pure expression over the URL query params (`exp`/`expiry`/`expire`/`expires`) with no logging at all, and an Xtream `get.php` link carries `username`/`password` and *no* expiry parameter — so there was nothing to find, while `player_api.php` would have answered on request. It now falls through to a short-lived `XtreamSource` probe (detected by the existing `xtreamCredentialsFromUrl`, delegating rather than reimplementing `user_info.exp_date`; `debugXtreamApi` seam so the path is testable without HTTP), and every unknown outcome logs its reason to a new `m3u` scope — no-parameter-and-no-panel, panel-answered-with-nothing, and lookup-failed are three different problems that were previously identical and silent. The add-source `_maybeConvertM3uToXtream` conversion remains the better outcome (it also unlocks Movies/Series); this covers sources that stayed M3U. Note the pre-existing test asserting "no expiry param → unknown" used a `get.php` URL, so it would have started making a **real network call** — rewritten onto the seam. Analyze clean; 807 tests pass (+5 M3U, covering that a URL answer never troubles the panel and that a plain playlist never probes one). **Not yet verified on a real source, and the reason is worth recording:** the debug run that exercised this saved the source, which runs `_maybeConvertM3uToXtream` on *every* M3U save (not only on add) — so the source was converted to Xtream and `XtreamSource.subscriptionExpiry()` produced the date, while the M3U probe never ran. The probe is still the right fallback: conversion only fires in the edit-save path, so a source the user never re-saves (exactly this one, until they did) stays M3U forever and the probe is the only thing that answers for it. |

| 2026-08-10 | Expiry cache diagnosability | Fixed | Debug-run feedback again: the Stalker portal now shows `Expires 2027-04-11` (fix confirmed on real hardware), but the M3U/Xtream-link source still read unknown **with no logs at all** — including none of the `m3u` scope lines added hours earlier. Cause was the cache I had just introduced, and it was a design fault rather than a slip: a lookup that once returned unknown is cached for `kExpiryCacheUnknownTtl` (30 min), and serving it short-circuits `subscriptionExpiry()` entirely — so the provider's own "here is *why* it was unknown" logging never ran either. The cache was suppressing the retry *and* the explanation for the one state anybody wants explained, and nothing could dislodge it: an edit that leaves credentials alone keeps the same `expiryConfigFingerprint`. Two fixes: cache hits now log `expiry from cache source=… kind=… ageMin=…`, and `didUpdateWidget` passes `force: true` so **saving a source re-checks it** — the only lever the UI offers, and the moment a user expects one. The decision is extracted as pure `canServeCachedExpiry(entry, force:)` and pinned by 4 tests. General lesson recorded in CLAUDE.md: a cache that can hide a diagnostic has to say when it is doing so. Analyze clean; 811 tests pass. |

| 2026-08-10 | M3U→Xtream upgrade at load | Implemented | The previous entry established that saving an M3U source converts it to Xtream when `player_api.php` authenticates — which is why the field report's source suddenly reported an expiry. But the conversion only ever ran on *save*, so a source added once and never touched again stayed a flat playlist forever: live only, no Movies, no Series, no expiry, while the same credentials would have answered for all three. It now also runs at load. Extracted the edit screen's private `_maybeConvertM3uToXtream` into `upgradeM3uToXtream` (`sources/m3u_upgrade.dart`, `debugApi` seam) so one implementation serves both callers, with a pure `couldBeXtreamPanel` pre-check; the screen keeps a thin delegate. `HomeShell._loadActive` fires it **`unawaited`, after the UI is up** — it ends in a network round trip and a dead panel must not hold the app on a spinner — then saves and re-runs `_loadActive` on success. Terminates by construction (the saved config is `xtream`, so the second pass fails the pre-check) and fails closed (anything short of the panel authenticating leaves the source untouched). Same source id, so the SQLite cache, favorites and playback positions carry over. Cost when it does nothing is one small background request per app start, and zero for a plain playlist. **Adjacent pre-existing bug found and fixed while extracting:** `EditSourceScreen._save` rebuilt the config from its own controllers with no `settings`, so editing a source — even just to fix a label typo — silently wiped every hidden category and catch-up override it had; now carried across, gated on the kind being unchanged since hidden-category ids are provider specific. Analyze clean; 820 tests pass (+9 upgrade). **Cloud interaction audited before merge, and one real hazard closed.** `pullSources` replaces every cloud-managed source wholesale from its row (`store.setAll`), and a pull runs on **profile switch** as well as on demand — so a load-time conversion of a managed source would be reverted by the next pull and re-attempted on the load after it: the source flipping kind indefinitely, one `player_api.php` probe plus one `_loadActive` (repository rebuild + library reload) per cycle, and the change never reaching the cloud because pushing is a deliberate user action this must not take on the user's behalf. The load-time path now skips managed sources (`CloudSync.managedSourceIds`, failing **closed** to skip — the cost of skipping is a source that stays M3U until saved, the cost of guessing wrong is the flip-flop). The push side is sound as-is: `sources.kind` is a plain `check (kind in (...))` column with no immutability trigger, so `push_sources` accepts the change; `splitFields` sends `host` broad and `username`/`password` as secrets; and the stale `playlistUrl` secret is preserved server-side (absent secret → preserve) but inert, since `build()` switches on kind. **Not yet verified:** the load-time path has not run against a live panel (the field source was already converted by its save). |

| 2026-08-10 | Type selector overlap | Fixed | The Edit-source "Type" dropdown drew its label on top of the kind icon and value. Cause: the field's `InputDecoration` carried `labelText: 'Type'` *and* `isCollapsed: true`, inside a fixed `height: 48` frame — `isCollapsed` removes the vertical space a floating label needs, so it had nowhere to float to. It was also the only field in that form with a floating label at all; every `TvTextField` beside it renders its label as a separate line above the box. Now matched to them (a plain `Text` above, no `labelText`), which fixes the overlap and the inconsistency together. Noted but deliberately not changed: `_SourceKindFieldFrame` still animates its focus border `1 → 2`, the same layout-shifting focus ring corrected in `FocusableCard` — harmless here (fixed-height box, centred content, no image decode behind it), so it stays out of this PR rather than churning more UI. |

| 2026-08-10 | Xtream detection: panel + device offer | Implemented | Closing the gap the load-time upgrade deliberately left: cloud-managed sources are skipped there (a pull would revert them), so they had no route to Xtream at all. Two halves, split along what each side can actually do. **Panel** (`panel/src/validate.js` `xtreamCredentialsFromPlaylistUrl`, mirroring the Dart `xtreamCredentialsFromUrl`): the add/edit form detects a `get.php?username=…&password=…` shape as it is typed and offers "Switch to Xtream" with host/username/password prefilled. It **suggests and never converts** — a browser cannot verify a provider panel (an `http://` URL from the HTTPS panel is blocked as mixed content before CORS is consulted, and IPTV panels send no `Access-Control-Allow-Origin`), so panel-side detection is a guess about a URL shape, and some resellers serve `get.php` with no `player_api.php`; converting one blind would break a working source. **Device** (`source_settings_screen`): an "Upgrade to Xtream" tile, shown when `couldBeXtreamPanel`, which probes on tap and converts only on a real authentication, then prompts the user to push. The device is the only side that can verify; the panel is the only side that makes it stick across devices. Auto-push after conversion was considered and rejected: `pushSources` sends the **entire** list with row-level last-write-wins, so firing it from a background upgrade could clobber panel edits the user has not pulled, and it breaks the documented invariant that device→cloud writes are deliberate. A server-side verified probe (Edge Function) was scoped and deferred — outbound HTTP to a user-supplied URL is an SSRF surface that needs its own threat model. Analyze clean; 820 Flutter tests and 119 panel tests pass (+8 detection, covering userinfo form, scheme-less host, percent-encoded credentials, and refusal of `javascript:`/`data:`/`file:`); panel builds. **Not yet verified:** neither half has been exercised against a live panel in a browser or on device. |

| 2026-08-22 | Android TV playback | Implemented, validated on hardware | Two reports from a 4K50 HDR10 set-top box — "the stream runs in slow motion" and "backing out leaves the preview crawling" — turned out to share one cause, and it was ours. `FrameLivenessWatch` judged liveness on `renderedOutputBufferCount` alone, which reads as *frozen* for a renderer decoding every frame and dropping some to catch up; the rebuild it fired then made things strictly worse. Across three consecutive opens of one channel the **only** open that did not rebuild held `fps=49.3 dropped=+3`, the session after a rebuild fell to `fps=28.8 dropped=+50`, and because the rebuilt codec belongs to the **shared preview engine** the damage outlived fullscreen: 174 rendered against 127 dropped over 14.8 s (11.7 fps on a 50 fps stream) through a window that was mostly the preview panel. Both handoff clocks were also too tight — sized from one 251 ms first frame, they fired at 525 ms/535 ms after healthy first frames, and a *healthy* `sinceClaimMs=1439` cleared the 1500 ms threshold by 61 ms. Fixes: dropped-frame movement counts as decoder liveness **inside the handoff window only** (outside it, dropping every frame is a frozen picture a reload genuinely fixes — that scoping is the founding case of the class and is pinned both ways); `HANDOFF_NO_FRAME_STALL_MS` 1.5 s→3 s and `HANDOFF_POST_FRAME_STALL_MS` 500 ms→1 s; `DecoderCounters.ensureUpdated()` before every cross-thread counter read (the whole stall decision is "this number did not change", so a stale read was indistinguishable from a wedged decoder); `markHandoffFirstFrame(now)` restarts the clock at the frame. Also in this batch: the SurfaceView preview, the return-leg instrumentation (`sinceReattachMs`, `reattach sample renderedDelta=`, surface register/unregister — that leg previously reported nothing at all), TV layout detection, favorites in catalog order, provider category order, and cross-source favorites gaining preview + seamless handoff with `(sourceId, channelId)` identity. Analyze clean; 918 Dart and 79 Kotlin tests pass. **Not yet verified:** none of the playback work has run on the reporting hardware — an Android TV emulator cannot reproduce it (no HEVC Main10 L5.1 decoder, so ExoPlayer refuses and mpv software-decodes 4K50 at ~3 fps). **Validated 2026-08-23** on the reporting box: roughly ten minutes per channel across 4K, 4K HDR10 and 1080, all smooth, with the favorites order and the cross-source preview both correct |

| 2026-08-23 | Field reports | Implemented, hardware validation pending | **The Android TV playback work is confirmed on the reporting hardware.** Roughly ten minutes per channel across 4K, 4K HDR10 and 1080 — all smooth; the favorites order and the cross-source preview both read as correct. That closes the open question from v0.1.54. Three new reports from the same session, all fixed here. (1) *Cross-source favorites did not populate instantly.* A star press goes through `FavoritesController`, which writes the same `favorites` table `GlobalFavoritesController` mirrors but knows nothing about it — so the view only caught up on the next full reload, while the per-source Favorites view updated immediately. `applyLocalChange` inserts the row in catalog order with no I/O; a reload was rejected because this runs on every star press and re-reads the OS keychain plus one query per contributing source. (2) *No EPG in the cross-source view* — see the decision row; it now carries one on every surface that prints a programme. (3) *The per-source category settings screen answered the D-pad in seconds.* Its body was `ListView(children: [...])`, which is **not lazy**: every category built up front and again on every keystroke and every toggle. Now lazy slivers, with the filtered lists cached on the query and the hidden-id set resolved once per section rather than per row (`hiddenCategoryIds` rebuilds a `Set` per call). Analyze clean; 929 Dart tests pass (11 new). **Not yet verified:** all three are Android TV UX reports and none has been seen on that hardware since the fix. Also reported and *not* addressed: the player overlay showed no resolution on some channel, while the screenshot from the same session shows `3840 x 2160 / 50 fps / HDR10 / HEVC` resolving correctly — needs the specific channel before it is anything more than an anecdote |

| 2026-08-23 | Field reports | Implemented, hardware validation pending | Three more from the same round. (1) *"Continue watching" named episodes, not series.* The rail on the series tab is built from episode rows, whose `title` is the episode name — "Gran Dillama", not "Caminandes" — so it read as a list of unrelated titles. `readSeriesTitlesForEpisodes` resolves the series two hops up (episode -> season -> series, the shape every provider builds), and the tile leads with it. Both joins are inner, so a half-cached tree yields no row and the caller falls back to the episode title rather than blanking. The episode name moves into the semantics label, not a third line: the tile has exactly two single-line runs and the rail's height is derived from that, so a third would be paid for by the movie tab too. (2) *The Windows native volume slider ignored dragging.* The overlay acted on `WM_LBUTTONDOWN` alone, so both sliders answered a click and nothing captured the mouse — which also swallowed the button-up that would have ended the gesture, hence "locks up". Now capture-on-press/track-on-move/release-on-up for both, with the ratio recomputed from the track rect so the drag survives leaving the groove. Volume applies continuously; a seek paints a preview and commits once on release, because dragging a full-width scrubber would otherwise ask for a seek per pixel. (3) *Overlay button sizes were ragged and the label text looked rough on HDR.* The row had grown four sizes (play 42x42, seek 44x36, icons 36x36, aspect 52x36) against a Flutter pointer overlay that is uniformly 44x40 and an Android one at 44dp; unified on 44x40 r12. The text was drawn with `CLEARTYPE_QUALITY` on a **per-pixel-alpha layered window**, where GDI's subpixel filter writes RGB without ever touching the alpha it is blended through — coloured fringing on every glyph edge, worst on thin strokes (hence buttons rough, heavier badges fine) and amplified by an HDR compositor lifting SDR content. Now `ANTIALIASED_QUALITY`, with bold button labels. Analyze clean; 933 Dart tests pass (3 new); the Windows runner compiles. **Not yet verified:** the two Windows overlay fixes are visual and pointer-driven, so nothing in CI exercises them — they need a run on a real HDR display. Also reported and closed as **not ours**: a box OSD showing `Video Resolution: 0 x 0`, which is the set-top box's own overlay reading Amlogic video-layer sysfs nodes; every resolution readout this app owns is zero-guarded and omits the row rather than printing zeros, and our panel read the stream correctly in the same screenshot |
| 2026-08-23 | Field reports | Implemented, visual check pending | Follow-up on the Windows overlay polish. The stream-info panel's "border" was two defects: it drew an accent stroke no other overlay has (Android `InfoPanel` and the Flutter `_infoPanel` are both a borderless rounded fill), and its **corners came back opaque black** — nothing in GDI can express "transparent here", so `RoundRect` leaves the pixels outside its curve untouched and `NormalizeNativeControlBitmapAlpha` then reads that zero alpha as "GDI drew this" and forces it opaque, boxing a rounded card into a hard square. `ApplyRoundRectAlphaMask` cuts them back with coverage, after the normalizer; the list menus had the identical defect. Then the antialiasing refactor: `FillRoundRectAA` composites rounded shapes into the DIB with per-pixel coverage instead of calling GDI's aliased `RoundRect`, for every shape inside the control bars (buttons, badges, both sliders, the live-EPG progress bar). The invariant that keeps it correct is narrow and worth restating: **it is only valid over pixels whose alpha is already right** — the directly-written scrim, or another `FillRoundRectAA` result — never over a GDI-drawn surface, whose alpha stays 0 until the normalizer runs at the end of the paint, so the menu's own option rows deliberately stay on the GDI path. Also found on the way: **GDI's `RoundRect` takes the ellipse diameter, not a radius**, so every shape in this file had been drawing half the corner it named — 6px where the Flutter and Compose overlays draw 12. Both paths now mean a true corner radius, so corners are visibly rounder and finally match. Windows builds; analyze clean; 933 Dart tests pass. **Not yet verified:** all of it is pixel work on a layered surface with no automated coverage — it needs eyes on a real display, ideally HDR. The things to look at are the info panel and a track menu (rounded, no border, no black corners), the button corners against a bright frame, and the volume thumb, which is a circle drawn as a round rect and was the worst of the staircases |
| 2026-08-23 | Field reports | Implemented, visual check pending | The favorite star now sits in **one slot on every surface**: the control row, immediately right of "Go to live", at that row's ordinary button size. It was in three states — Android and iOS had always drawn it there (Kotlin `RightCluster`, iOS `clusterStack`), while the Windows GDI overlay put it in the *top* bar at 38x38, the shared Flutter overlay put it in the top bar at compact 34x32, and the Linux Lua OSD put it in the top bar at 44px. Windows and Flutter matter most together because Windows swaps between its native and embedded surfaces on the same machine purely on whether the stream is HDR, so the star changed size and position when the user changed channel; Linux has the same split for HDR-on-Wayland. **Android and iOS were left untouched** — they were the reference, and moving Android's would have disturbed a focus ring that is expensive to re-validate on hardware. Also folded in: the accent now tints the star's *glyph* rather than filling the whole button (the filled state means keyboard focus), the Windows hit rect reads the laid-out `l.favorite` instead of repeating its geometry, and `IsTopBarFocusItem` narrows to `kBack`. A stale comment claiming the top-bar placement "mirrored the embedded/Android overlays" is gone; it never did. Pinned by `overlay_layout_test.lua`, which now asserts the star shares a row with the aspect chip, is nowhere near the top bar, and swaps outline/filled with the state. Windows builds; analyze clean; 933 Dart tests and the Lua OSD harness pass. **Not yet verified:** the visual result on Windows and the Linux OSD, and that the Windows keyboard focus ring still walks the control row in visual order now that the star has joined it |
| 2026-08-23 | Multiple EPG guides per source | Implemented, real-guide validation pending | A source can now carry several XMLTV guides — the provider's own plus user-added top-ups, edited in **Source settings -> EPG guides** and stored in the new secret field `fields['epgUrls']` (newline-separated, *additional* guides only). Asked for as "assign multiple EPG sources to a list"; investigated whether it needed a hosted EPG API and concluded it does not — such a service's product is an XMLTV URL, which this path already consumes, and the specific vendor looked at advertises a documentation host (`api.epgservice.tv`) that does not resolve, with contact-only pricing. **Three decisions carry the design.** (1) *Merging is per channel, never a row union.* `nowNext`'s "now" half has no `GROUP BY` and folds rows into a map by channel id, so last row wins arbitrarily — two guides covering one channel would make its now-playing programme nondeterministic across refreshes and draw overlapping cells in the grid. `mergeEpgGuides` therefore lets the first guide that carries a channel own it and filters later guides against those claims, accumulating per guide so a guide is never filtered against itself. (2) *At least one guide must succeed*, rather than a hard-failing primary. A hard primary was the first design and it is wrong: the case that motivates the feature is a provider guide that is broken or thin, with the top-up added to replace it. So a single failure is logged and skipped — but if all fail the error rethrows, because `replaceEpgStream` reads a normally-completed empty stream as a successful *empty* guide and would clear the cache and advance `epg_synced_at`, turning a network blip into a lost EPG. (3) *Names match what ids miss.* A third-party guide numbers channels its own way, so exact `tvg-id` matching alone leaves it essentially empty — the feature would have shipped doing nothing. `XmltvChannelResolver` settles claims in one pass (the XMLTV DTD fixes `(channel*, programme*)`, so all declarations precede the first programme): exact ids win globally, names fill the rest, and a channel contested by two guide channels goes to neither. Exact after normalisation, never fuzzy — wrong programme data is worse than none, since the row looks authoritative and the catch-up window is computed from it. One guide channel may claim several of ours (HD/SD duplicates share a schedule) but no more than 8, because programmes are stored per `channel_id` and an uncapped fan-out turns a ~10^6-programme guide into a multi-million-row ingest. **Also in this change:** the XMLTV parser now reads `<channel>` declarations, which it previously discarded (backward compatible — a guide that declares none takes exactly the old path); `looksLikeValidUrl` moved from `sources_screen` into `net.dart` and gained `requireScheme`, because the lenient form it needs for a scheme-less host field accepts literally `nonsense` and was useless for a pasted guide URL; `epgUrls` joined `kSourceSecretKeys`, the panel's `SOURCE_SECRET_KEYS` and a new `sources_validate()` strip (`20260823000000_epg_urls_secret.sql` — `secret_keys_parity_test` fails until all three agree, which is what surfaced the need). **Reviewed before merge; nine findings, all acted on, and two were data loss.** (a) `EditSourceScreen._save` rebuilds `fields` from its own `_FieldSpec` controllers, so `epgUrls` — which has no spec — was destroyed by any unrelated edit: fix a label typo, press Save, guides gone. This is the same bug the `settings` carry-over comment two lines below it records, arriving through the other map, so the fix carries forward *every* unrendered field key rather than naming this one. (b) The same loss via the cloud: the panel builds `fields` from `KIND_FIELDS` only and `set_source_secret` does `payload = excluded.payload`, a wholesale replace — so renaming a source in the panel would delete guides added on a TV, for every paired device. `carryUnrenderedSecrets` (extracted to `validate.js` so it is actually unit-testable rather than a source-text assertion) re-merges unrendered secret keys, kind-guarded like the Dart side. (c) The failure policy was wrong in the multi-guide case it was written for: swallowing a guide that failed **mid-feed** let a truncated guide commit as a whole one, since its batches are already in the transaction — a drop 80% through a large guide would have destroyed the complete cached guide and advanced `epg_synced_at`. Now the policy turns on whether the guide had yielded: pre-yield failures skip, mid-feed failures rethrow. (d) Name matching is now gated to user-added guides (`epgNameIndexFor`), which fixes two findings at once — it no longer changes every existing install's EPG on upgrade, and the O(channels) index build no longer runs on the main isolate for users who added no guide (it was unconditional, against CLAUDE.md's rule about provider-sized main-isolate work). (e) `'raw'` left `_qualityTokens`: unlike hd/fhd/backup it is part of real channel identities, and "WWE Raw" normalised to `wwe`, so one guide entry would paint WWE's schedule onto WWE Raw — the exact wrong-data outcome the module argues against. (f) Sockets leaked on a non-200 guide fetch (the body was never drained, so the connection never returned to the pool — one per ~3-hourly refresh); fixed in all three sources, since user-typed guide URLs make a 404 routine. (g) Saving the list now calls `invalidateEpg`, without which a newly added guide was invisible for up to the 3 h refresh interval. Two findings were closed as documentation rather than code: an exact `tvg-id` deliberately does *not* beat a name claim for a channel the guide never **declared** (by then the claims are frozen and that channel's rows are written, so honouring it would stack a second schedule rather than replace the first), and the per-channel split regex was hoisted out of the 250k-times-per-refresh path. Two pre-existing tests encoded the old swallow-always policy and were corrected, one deleted as superseded. Analyze clean; 997 Dart tests pass (+64) and 138 panel tests. **Deploy the migration before shipping a client that writes `epgUrls`**; the clients apply the split themselves, so the trigger is defence in depth, but it is the half that holds when a writer is old or wrong. **Not yet verified:** nothing has run against a real third-party guide, so the matcher's hit rate on actual provider/guide name pairs is unmeasured — that is the number that decides whether the feature is worth having, and it needs a real playlist plus a real public guide. Stalker is included: its portal guide joins the merge as a plain (non-XMLTV) feed, and its third-party downloads deliberately bypass the portal transport, which would otherwise send the MAC cookie and Bearer token to an arbitrary user-supplied host. Also outstanding: the web panel has no editor for the field — it round-trips safely, since an absent secret is preserved server-side, but a panel user cannot add a guide |
| 2026-08-23 | Field reports | Implemented, hardware validation pending | Two from the same round. (1) *A TV remote could not press "Try again" when a source failed to load.* The live tab's body is a selection model — its rows are deliberately not focus targets — so a body rendered *instead* of the rows has no focus targets either. The button drew, was plainly the only action on screen, and was unpressable: nothing was stealing the key (`handleChannelsKey` correctly ignores keys with no visible channels), there was simply no focusable widget in the subtree. Worst possible moment for it, since a source that will not load is exactly when the user cannot route around the problem. Both tabs' error bodies became one `SourceErrorView` whose retry autofocuses — safe because that body only mounts on a failed load, which replaces the list wholesale, so there is no focus to steal. (2) *A preview came back permanently black after a long fullscreen session.* The handoff's **return** leg had no liveness watch and no recovery: the forward leg's `FrameLivenessWatch` lives in `HdrPlayerActivity`, which is finishing by the time the return leg runs. Coming back is the same output-surface transition as the claim, on the same hardware that re-instantiates a codec for one, so a `setOutputSurface` that produced no frames was terminal — and silent: the exported log showed nothing where a `first frame sinceReattachMs=` should be, which is why the report read as a healthy session. `ExoPlayerEngine.attachPreviewSurface` now arms `previewFrameWatch` (3 s, sized like the forward leg's `HANDOFF_NO_FRAME_STALL_MS` for the same IDR-wait reason), which fires exactly one `rebuildVideoDecoder` and then a log-only verify pass so a still-black preview leaves evidence. **The reported case is not channel-specific, which is why it was worth fixing rather than filing:** the stream changed codec mid-session (HEVC 25fps → H.264 50fps across a clean `kind=ended` reconnect that re-resolved to the same URL), so the decoder was rebuilt *while in fullscreen* and the codec handed back to the preview was one created against the Activity's SurfaceView rather than one the preview had lent out. Any reconnect during a long fullscreen session reaches that state, and live IPTV reconnects routinely. Analyze clean; 1000 Dart tests pass (+3) and the Kotlin suite builds green. **Not yet verified:** neither has run on the reporting hardware. The preview fix in particular is a hypothesis the log supports but does not prove — the evidence is the absence of a first-frame line plus the mid-session decoder swap, and the fix is deliberately a general safety net that recovers regardless of which step of the transition failed. The new `preview no frame …; rebuilding decoder` / `preview still blank …` lines are what a repeat report should be read for |
| 2026-08-23 | Buffer presets | Implemented, hardware validation pending | Buffering depth is now a per-source preset (`settings['bufferPreset']`: low/normal/high) rather than one hardcoded tuning, because the right depth is a property of the *link* and no default serves both a clean wired connection and a throttled one. Three presets rather than raw millisecond fields: four interacting durations is a knob people copy out of forum posts, and an invalid combination — a resume threshold above the stall watchdog's patience — is a reconnect loop we would then have to explain. **The design decision worth recording is that only the sustained cushion moves between presets, not the start gates.** What absorbs network variance once playing is `min`/`maxBufferMs`; the gates decide how long a zap stares at black, so raising them to "buffer more" would cost the thing users notice while barely helping the thing they are trying to fix — and they cannot rise far anyway, since a stream below the resume threshold sits in `STATE_BUFFERING` and `STALL_RECONNECT_MS` (8 s) of that reloads the source, so the 4x margin caps the resume threshold at 2 s. `high` therefore buys its stall resistance entirely from the cushion. The mpv side has no such constraint (`cache-secs` is prefetch depth, not a start gate) so its `high` is proportionally much deeper, bounded by `demuxer-max-bytes` because that prefetch is real memory on a 2 GiB TV box. `normal` is byte-for-byte the previous tuning on both engines — the mpv map is deliberately *empty* so mpv keeps its own defaults rather than a tuning that merely resembles them — and returning the tile to Normal removes the key, so an untouched install serializes and plays exactly as before. Plumbed to ExoPlayer via the native `open` payload (its `LoadControl` is a build-time argument, so `SharedEngine` rebuilds the engine on a preset change the way it does for changed headers) and to mpv on the embedded, preview, Windows-native and Linux-native paths. A cross-source favorite uses its **owning** source's preset, the same rule its repository, EPG and reconnect already follow. `ExoBufferPolicyTest` now asserts every invariant for every preset, which is the point once the durations are selectable: the dangerous edit is no longer a changed constant but a plausible-looking new preset that violates the stall margin. **Reviewed before merge; ten findings, all acted on, and the top one meant the feature did not work at all on the path that matters most.** (a) The Android `open` payload carried the preset name but `MainActivity` never put it on the Intent, so `HdrPlayerActivity` read null and built *every* fullscreen engine on NORMAL — only the preview path consumed it. The docs described the chain that was missing its middle link. (b) The one diagnostic that would have revealed (a) from a user's export could never fire: it was logged in `ExoPlayerEngine.init`, and `onDiagnostic` is a rebindable `var` the host assigns *after* construction, so it was always null there. Moved to `load`, and it now logs on `normal` too — gating it on "the preset changed something" meant an export could not tell "the user chose normal" from "the preset never arrived", which is exactly the question a buffering report asks. (c) The preview's mpv options were applied only in `_createPlayer`, which runs once behind `_player ??=` while an ordinary `stop()` keeps the player alive — so changing the setting and returning did nothing until an app restart, and a cross-source favorite previewed on the previous source's buffering. Re-applied on every `start`; these are runtime-settable properties, so no rebuild. (d) **A factual premise was wrong and mis-sized the presets:** the doc claimed `normal` left "mpv's own defaults (150 MiB)" alone, but media_kit always overrides `demuxer-max-bytes` through `PlayerConfiguration.bufferSize`, which this app sets per surface (64 MB fullscreen, media_kit's default for the preview). So `low`'s 32 MiB was a no-op on one surface and `high`'s 192 MiB a 6x jump rather than the modest bump the "2 GiB TV box" reasoning assumed — and on VOD it silently retuned a cache sized for seek smoothness. The preset now sets **`cache-secs` only** and leaves the byte cap to media_kit; the cap still bounds a deep prefetch, which degrades gracefully. (e) Android's libmpv fallback was the one mpv surface left out, so a DV-P5 channel buffered differently from every other channel on the same source; wired through `MpvEngine`/`MpvController`. (f) Saving deleted a blank row the user had just added, because `_saveEpgGuides` also runs from a row's own Done key — the pruning is gone. Two dartdoc blocks had been orphaned by inserting members between a comment and the member it described. **Two more found before the review, both mine:** `LivePreviewController.start` took the preset with a *default* and only one of six call sites passed it — including the EOF re-arm, so a user who chose Large for an unstable stream got it once and Normal on every reconnect after; making the parameter required turned that into six compile errors. And the new EPG guide rows used a Material `IconButton` for remove where `TvTextField` already has a proper sibling focus stop, so on a TV the control had no focus ring (`FocusableCard`'s ring paints from `hasFocus` precisely because `FocusManager.highlightMode` starts as `touch` on Android); rows now use the built-in clear, and removal is clear-then-save. Analyze clean; 1025 Dart tests pass (+25), 191 Swift tests, and the Kotlin suite is green. **Not yet verified:** none of it has run on hardware, and the presets' numbers are reasoned from the existing constraints rather than measured against a real flaky link — which is the only thing that can say whether `high` is deep enough to be worth choosing. iOS takes the same preset and applies it as `AVPlayerItem.preferredForwardBufferDuration`, held on the engine rather than passed to `load` so a reconnect or “Go to live” keeps it — one that survived only the first open would revert to automatic buffering on exactly the flaky link it was raised for; `.normal` leaves the property unset for the same reason the mpv map is empty. **A caveat I got wrong first time, corrected here:** the `IptvsPlayerCore` package is pure Swift and its `swift test` suite *does* run on the Windows development machine (191 tests, including the new parse and mapping cases) — only the AVFoundation/UIKit files that consume it need a macOS build. Also deferred: the "auto frame rate" half of the advice that prompted this (display-mode switching for 25/50fps broadcast content) is a separate feature and was not started |
| 2026-08-23 | Stretch mode + display cutout | Implemented, visual check pending | A user wrote in: *"I love this app … but it just needs stretch To allow full-screen viewing."* Two candidate causes were found in the code and **both were real gaps, so both were fixed** rather than guessing which one he hit. (1) *There was no stretch mode.* The aspect cycle was Fit/Fill/16:9/4:3, and `Fill` maps to `RESIZE_MODE_ZOOM` — it **crops** to fill while keeping the picture's shape (mpv `panscan=1.0` does the same). Nothing in the app distorted to fill. That matters far more on a phone than a TV: on a 20:9 handset `Fill` costs 16:9 content about a fifth of its width and 4:3 content a great deal more, so a viewer who wants the whole frame edge to edge is not served by a zoom. Added `Stretch` between Fill and the forced ratios on every surface — `RESIZE_MODE_FILL`, mpv `keepaspect=no`, `videoGravity = .resize`, `BoxFit.fill`. Two things worth keeping: `keepaspect` is restored by **every** mode rather than only set by Stretch, because the modes are cycled and leaving Stretch must undo it; and the **embedded** surface turned out to be framed by Flutter (`media_kit`'s `Video` draws the texture with a `BoxFit`), not by the mpv properties that frame the native surfaces — so `_AspectMode` now carries both, since the two surfaces swap on one machine on HDR alone and framing must not change with a stream's dynamic range. (Which also means `Fill` was likely inert on the embedded path before this; it is not now.) iOS gained the mode because `.resize` maps onto `videoGravity` exactly, which is that surface's own stated rule for inclusion — the 16:9/4:3 gap there is unchanged and still needs a hand-computed layer transform. (2) *The player never opted into the display cutout.* No `windowLayoutInDisplayCutoutMode` anywhere, so the default mode letterboxes the whole window away from the camera notch **in landscape** — a black band down one edge, in the one orientation video is watched in, which reads as "the app won't use my whole screen" and is easily mistaken for an aspect problem. `HdrPlayerTheme` now sets `shortEdges`, which is safe *because* the Compose overlay already insets itself with `safeDrawingPadding()` (whose `safeDrawing` set includes the cutout): the picture extends behind the notch, the controls stay clear. API 35+ enforces edge-to-edge itself; this covers API 26–34, which is most phones in use. **Self-reviewed (the review agent hit an account session limit and returned nothing, so this was a manual pass); three issues found, all mine.** (a) *A default-behaviour regression.* `_aspectModeIndex` started at "Fill" because the Windows *native* surface is configured with `panscan=1.0` — but the embedded surfaces never applied panscan, so they rendered letterboxed while the chip said "Fill". Making the embedded path honour the mode would have turned that stale label into a real default of **cropping**, losing the top and bottom of 4:3 content on first play across Linux, the iOS mpv fallback and Windows SDR. Everything now starts on Fit, which is what Kotlin and Swift already defaulted to — so Windows agrees with them rather than the reverse, and the only visible change is the Windows native HDR surface moving to the option that discards nothing. (b) *The Windows aspect chip would have clipped.* Its width is hand-set (`place(l.aspect, 56)`, sized when "Fill" was the longest label) and `DrawTextButton` draws `DT_SINGLELINE` with no `DT_NOCLIP`, so "Stretch" would have been cut off rather than overflowing visibly. Now a named constant sized against the 13px bold glyphs. The Lua OSD measures its chip and was already correct; it gained the test that proves the measuring path works, since Windows cannot measure and Android/iOS size to content. (c) The iOS `videoGravity` assignment was an immediately-applied closure, whose return type Swift has to infer — rewritten as a plain switch, because that file only compiles in a macOS build and the form that cannot be wrong is worth preferring there. Analyze clean; 1025 Dart tests, 193 Swift tests (+2), Kotlin suite, the Lua OSD gate (+4 checks) and the Windows runner build all green. **Not yet verified:** all of it is visual and none has run on a phone. The reporter was never asked which symptom he saw, so it is not known which fix addresses him — worth asking, because if it was the cutout then Stretch would not have helped him at all, and vice versa. **No Dart-side test:** `_AspectMode` and `_aspectModes` are private to `_PlayerScreenState`, so the mode list is pinned on the Kotlin and Swift sides only; the label sets agreeing across the three languages is currently a convention, not an assertion |
| 2026-08-23 | All Favorites scroll position | Implemented, hardware validation pending | Reported as: on All Favorites the last-highlighted channel isn't centred, and one press of Up or Down brings it back. The description is exact and names the mechanism. The live list scrolls by exact `index * itemExtent` arithmetic, so an offset is only valid for the extent it was computed against — rows are 72px without an EPG line and 112 with one, chosen by `_liveRowsShowEpg`. For the cross-source view that predicate reads `GlobalFavoritesController.hasEpg`, which **populates asynchronously, after the rows are already on screen**: the remembered channel is restored and revealed against 72, the guide then lands, the rows re-render at 112, and the offset is wrong by a margin that grows with the row index — which is why it reads as "not centred" rather than "slightly off". Any arrow key re-reveals against the corrected extent and it snaps back. Fixed with `LiveFocusCoordinator.revealSelectedChannel()` plus `_resyncLiveRowExtent()`, which calls it **post-frame** when the extent changes — post-frame because the reveal has to run after the list is rebuilt with the new `itemExtent`, or it recomputes against the old geometry again. Written generally rather than special-casing the cross-source view: the same class of bug reaches an ordinary category whenever the active source's guide lands after its rows. Pinned by `test/live_row_extent_reveal_test.dart`, which uses a **real attached** `ScrollController` — the existing coordinator harness uses a detached one, where `_reveal` no-ops and neither the bug nor the fix is observable — and covers the extent change, that an already-visible row does not jerk the list (the reveal scrolls the minimum, so a late guide must not fight a user mid-scroll), and the empty-list state the cross-source view starts in. Analyze clean; 1028 Dart tests pass (+3). **Not yet verified:** the screen-side wiring — `_resyncLiveRowExtent` firing when `hasEpg` flips — is uncovered, because that needs the whole live tab mounted with a real preview player, which is the suite that skips without libmpv on the development machine. The coordinator half is tested; the trigger is not |
| 2026-08-23 | Aspect defaults + persistence | Implemented, visual check pending | Two changes to one control. **Defaults now follow the container's shape:** Fill on a television or handset (a fixed screen that usually matches the content, where Fill and Fit are indistinguishable on 16:9 and differ only on 4:3), Fit on a desktop (an arbitrary window shape, where Fill crops continuously and by an amount that moves as it is resized). Keyed off `isTelevision`/`Platform`, never off the rendering surface — on Windows the native and embedded surfaces are chosen purely by HDR, so a surface-derived default would frame the same channel differently on the same machine. This reverses the earlier "every surface starts on Fit" decision, whose actual finding — that the chip's label and the native `panscan` had drifted apart — is preserved by *deriving* the initial `panscan`/`keepaspect`/`video-aspect-override` from the resolved index instead of writing them out separately. **The choice now persists**, per source, on `settings['aspectMode']` (broad, not secret), written against the *owning* config so a cross-source favorite stores against its own provider; it round-trips through the native player (`EXTRA_ASPECT` in, `RESULT_ASPECT` out) so a change made in the native overlay persists exactly like a Flutter-side one. The cycle moved out of `_PlayerScreenState` into `lib/player/aspect_mode.dart` — it was the one copy of three that no test pinned. Evidence: `test/aspect_mode_test.dart` (13), `flutter analyze` clean, Kotlin `BUILD SUCCESSFUL`. Next: confirm on a TV, a handset and a resized Windows window. |
| 2026-08-23 | EPG refresh off the load path | Implemented, hardware validation pending | Reported as: adding one top-up guide costs 5–10 s on every source refresh. `LibraryRepository.load` now returns as soon as the channels are ready and refreshes the guide behind them. Backgrounding alone was tried a day earlier and reverted the same day, because it deadlocked — and the reason was not in the call site: `replaceEpgStream` holds one write transaction for the whole ingest, and the batches it consumed were lazy, so the transaction stayed open across each guide's **HTTP download**, on the single sqflite connection the whole app shares, which serialises reads as well as writes. Awaited, that hid behind the spinner; unawaited it was a multi-second freeze, and a source switch mid-ingest hung for `channel_list_focus_test`'s full ten-minute timeout. The lock also had no upper bound — a guide server that connects and stalls held the entire database until the read timeout. Fixed by two new pieces: `ProgrammeSpool` (`lib/data/programme_spool.dart`) drains the merged guide to a length-prefixed temp file before any transaction opens, so the transaction spans local inserts only and peak memory stays one batch; `EpgIngestCoordinator` (`lib/data/epg_ingest.dart`), held on `AppDatabase` because the contended resource is that connection, keeps one refresh at a time app-wide and *waits for* a superseded one to stop rather than merely cancelling it. `close()` **awaits** `shutdown()`. A first attempt made it non-waiting, on the theory that pending I/O cannot complete inside fake-async; that was wrong, and the hang came back. Instrumenting the repository showed a `replaceEpg` that began and never ended, with sqflite's `database has been locked` warning behind it: teardown *does* get real event-loop time, and the ingest was mid-transaction when the test ended, so `_db.close()` blocked on it with no cancellation and nothing logged. Follow-ons the change forced: `AppDatabase.epgChanged` announces a replaced guide carrying the source id (a refresh for the source the user just left reaches the same stream, and re-reading for it would blank the current source's now/next), `LiveController` subscribes so the guide is not stale until the one-minute poll, and staleness is decided in `load` before scheduling so `pendingEpgRefresh` is null when there is no work — the live status line reads that to append `· updating guide…`, which is now the only thing distinguishing "still downloading" from "this source has no guide". Evidence: `test/programme_spool_test.dart` (11), `test/epg_ingest_test.dart` (11), six new `LibraryRepository` cases in `test/persistence_test.dart`, full suite green. Next: measure perceived reload time on a TV box with a real multi-guide source, and confirm the guide lands visibly rather than silently. |
| 2026-08-24 | Guide visibility after the refresh moved | Implemented, hardware validation pending | Two consequences of the guide landing after the channel list, both of which would have read as regressions. (1) *Row height.* A channel row is 72 px without an EPG line and 112 with one, so a source's first load drew short rows and jumped. `LiveController.expectsEpg` now takes the source at its word while a refresh runs — Stalker/Xtream always report `supported`, M3U when it has an EPG URL, and `unknown` deliberately keeps the old wait-and-see behaviour rather than sizing rows tall for a guide that may never arrive. `_settleEpgRefresh` re-reads now/next *before* clearing the flag, or the rows drop for the frames between the two and rise again. `_resyncLiveRowExtent` still handles a genuine flip; this reduces how often one happens. (2) *Silent failure.* A failed refresh retains the cached guide and says nothing, which is correct until there is no cached guide — at which point "this source has no EPG" and "every guide URL is broken" are indistinguishable and only the second is actionable. `LibraryRepository.lastEpgRefreshFailed` records the verdict (a superseded refresh sets neither; it is not an outcome) and `LiveController.epgUnavailable` pairs it with an empty guide, so the status line reads `· guide unavailable` — deliberately both conditions, since a failure standing behind a cached guide is the retain policy working. Evidence: 7 new `LiveController` cases, 2 new `liveRowsShowEpg` cases, full suite green. Next: confirm on a real source with a broken guide URL, and on a first load of a large Xtream source. |
| 2026-08-24 | Pre-PR review of the above | Fixed, hardware validation still pending | Read the whole diff back before opening the PR; four defects, two of them behavioural. (1) *A superseded refresh was recorded as a success.* Both cancellation paths in `_ensureEpg` returned normally, so `_refreshEpg` fell through to `_lastEpgRefreshFailed = false` and its `on LoadCancelledException` arm was dead code — a supersede could clear a real failure verdict and take `· guide unavailable` off the screen with nothing fixed. The plain path now throws `LoadCancelledException` and the batched branch lets it propagate, so the verdict is decided in exactly one place. Pinned by a new test, verified to fail against the old shape. (2) *The Windows native surface never set `video-aspect-override`.* Harmless while the initial index was always Fit; once it is restored from the user's choice, a source saved as 16:9 or 4:3 opened with the chip naming a mode the picture was not in — the exact failure the comment above it claimed to prevent. (3) *`RESULT_ASPECT` was gated on `canFavorite`*, so an aspect change made in the native overlay was dropped for VOD even though Dart persists it there. (4) Two doc comments had been welded onto the wrong declarations by a patch script, leaving `lastEpgRefreshFailed` and `_bufferPresetForChannel` documented as something else. Evidence: `flutter analyze` clean, 1080 tests green, Kotlin `BUILD SUCCESSFUL`. |
| 2026-08-24 | Profile PINs + focused-star ring | Implemented, hardware validation pending | Two independent changes. (1) *The focused favourite star was drawn off-centre on Android TV.* Its accent ring was a `decoration` border, which adds its width to the cell (20 icon + 12 padding + 4 border = 36) — that fits the 44 px pointer target but not the ten-foot 32 px one, so the `Center` above squeezed the cell back to 32, the `Icon` collapsed 20 → 16, and a 20 px glyph paints from the top-left of the box it overflows: the star sat ~2 px down and right of its own ring, and only while focused. Diagnosed by measuring the reporter's photograph (ring 90 px outer / glyph offset +6, +5 at 2.8 px per logical px, cross-checked against the 24 px play icon beside it) and reproduced exactly by a test that reads 16x16 against the old shape. Ring moved to `foregroundDecoration`, matching the row body. (2) *Optional 4-digit profile PINs*, local and cloud, synced: a new broad `profiles.pin` column + `set_profile_pin` RPC (+ pgTAP file), `profile_pin.dart` / `panel/src/pin.js` deriving byte-identical PBKDF2 verifiers pinned to shared vectors, an in-app keypad off desktop (no IME on a TV), a locked active profile that overrides the boot short-circuit and withdraws Skip, and a device-side mirror of cloud verifiers so the gate holds offline. Deliberately *not* a security control — rationale in docs/cloud-sync.md “Profile PINs”. Evidence: `flutter analyze` clean, 1115 tests green (34 skipped, the usual libmpv ones), panel `npm test` 144 green. Outstanding: the pgTAP file has not been run locally (no Docker on this machine) and awaits CI, and neither the PIN dialog nor the star fix has been seen on the television yet. |
| 2026-08-24 | Pre-PR review of the above | Fixed | Reviewed the diff back; six findings, three of them behavioural. (1) *`_lockedBoot` was cleared on a correct PIN rather than on actually entering a profile*, so unlocking a second profile and then declining the restore confirmation brought Skip back — and Skip goes home into the locked profile still loaded in the store. It is now never cleared; the flag ends by leaving the screen. (2) *The wrong-PIN cooldown lived in the dialog's state*, so Cancel reset it: four guesses and a Back press bought four more, indefinitely, and the documented “seventeen hours” was fiction. Hoisted to a per-profile, process-lifetime map. (3) *The offline lock-cache fallback fired on a definitive “not paired”*, so a device the panel unpaired would synthesise a phantom locked cloud profile and hold the boot on it; the fallback now needs the server to have not answered at all. (4) `unpair` did not clear the cloud lock cache, unlike the sticky E2EE marks it sits beside — same account-scoping argument, same fix. (5) The SQL/panel shape regex allowed more iterations than the Dart parser accepts, i.e. a verifier the server would store and the device could never read; tightened to a strict subset. (6) The iteration-cost comment claimed “a few tens of milliseconds” on a set-top box, which was never measured — it now states the measured desktop figure and that the device figure is unknown. Findings 1 and 2 each have a regression test verified to fail against the old shape. Evidence: `flutter analyze` clean, 1118 tests green, panel `npm test` 144 green. |
| 2026-08-24 | PIN dialog layout sweep | Fixed | Asked whether the new PIN surface was navigable everywhere and tested rather than assumed: **19 of 19 sweep cases failed**. The pad was a fixed 3x4 lattice of 68x52 keys in a scrolling dialog, so on a 320x568 phone, a 360x640 phone and an 800x360 landscape handset (and at text scale 1.3-2.0 generally) keys fell outside the window or overflowed it — and with `scrollOnFocus: false` a D-pad could not bring them back, i.e. digits that cannot be pressed on the device this feature exists for. Fixed by making the pad *fit* rather than scroll: `Flexible` + `FittedBox(scaleDown)`, the explanatory line dropped below a 420 px viewport, tighter dialog insets, and digit labels opted out of the platform text scale. Now pinned by a 7-size x 3-text-scale sweep in `layout_overflow_test.dart` (every key inside the window *and* the pad still types), plus arrows-and-OK walks of the whole pad — including the corner where Down from 7 must find 0 — and of the manage menu. Evidence: `flutter analyze` clean, 1143 tests green. Still untested: real hardware, RTL, screen readers. |
## Removal checklist

This document can be deleted when all of the following are true:

- [ ] Every required release-candidate gate above is complete.
- [ ] Deferred items have their own issue with scope and acceptance criteria.
- [ ] Lasting architecture decisions are recorded in canonical documentation.
- [ ] Schema/version/toolchain documentation matches the released tree.
- [ ] Device-test evidence is retained outside this temporary ledger.
- [ ] No active PR depends on context that exists only in this file.
- [ ] The temporary implementation-plan link is removed from `CLAUDE.md`.
