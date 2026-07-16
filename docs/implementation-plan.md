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

- Last updated: 2026-07-16
- Active phase: Phase 1 — Correctness and lifecycle
- Active PR: PR 12 (historical migration coverage) — implemented on
  `test/migration-coverage`, ready for PR
- Previous PR: PR 11 complete — merged as #111, released as v0.1.36, live
  verification passed 2026-07-16; PR 10 merged as #110 (on-device TV-Low
  stall/RSS capture outstanding); device matrices stay open while the closed
  test gathers data
- Plan baseline commit: `966418fec7a07646163073377c6a3a1013b93dd0`
- Baseline branch: `main`
- Baseline working tree: clean
- CI Flutter version: 3.44.5
- Declared Dart SDK constraint: `^3.12.2`
- Documentation Flutter version: README and CI declare 3.44.5
- Baseline `flutter analyze`: passed
- Baseline `flutter test`: passed, 204 tests
- Current PR 0 `flutter analyze`: passed on 2026-07-14
- Current implementation `flutter test`: passed, 334 tests with 11 opt-in
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
- [ ] Do not begin optional feature work while a Phase 0 release blocker remains.

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
| 10 | Phase 2 | Build bounded one-pass isolate ingestion | L | PR 3 | Ready for PR |
| 11 | Phase 2 | Harden cloud sync, RLS, RPCs, and panel input | M | PR 5 | [ ] |
| 12 | Phase 2 | Test every supported historical migration | M | PRs 5 and 7 | [ ] |
| 13 | Phase 2 | Split oversized UI files along tested boundaries | M | PRs 6 and 8 | [ ] |
| 14 | Phase 3 | Model catch-up capabilities and timezone | M | PR 4 | [ ] |
| 15 | Phase 3 | Complete TV focus, accessibility, and input parity | L | PR 9 | [ ] |
| 16 | Phase 4 | Add diagnostics and conflict/capability UX | M/L | Stable release | [ ] |
| 17 | Phase 4 | Publish a channel-safe Microsoft Store MSIX | M | PRs 2 and 9 | [ ] |

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

- [ ] Fix the adjacent defect found during PR 6: a metadata-config-only change
  (same active source id) rebuilds the repository while `ChannelListScreen`'s
  `ValueKey(config.id)` is unchanged, so live controllers keep the old,
  disposed repository/source. Add `didUpdateWidget` handling or key on
  repository identity while preserving controller/focus-node ownership.
- [ ] Keep `channel_list_screen.dart` responsible for shell, routes, and dialogs.
- [ ] Extract live pane widgets without moving their state ownership.
- [ ] Extract media grid/details widgets without moving controller state.
- [ ] Separate player lifecycle coordination from platform presentation widgets.
- [ ] Preserve the current `ChangeNotifier`/`Listenable` design.
- [ ] Preserve focus-node ownership and disposal exactly.
- [ ] Avoid abstractions without at least two concrete consumers.
- [ ] Run focused widget tests after each extraction.
- [ ] `flutter analyze` and `flutter test` pass.

## PR 14 — Catch-up capability and timezone model

- [ ] Model provider catch-up URL mode.
- [ ] Model provider timezone or explicit fixed offset.
- [ ] Model maximum archive window and duration.
- [ ] Model required start/end formatting.
- [ ] Keep URL construction inside the owning Source implementation.
- [ ] Prefer provider-reported timezone when available.
- [ ] Add an advanced per-source override.
- [ ] Parse applicable M3U catch-up attributes into the shared capability model.
- [ ] Test device/provider timezone disagreement.
- [ ] Test DST boundaries.
- [ ] Test unsupported catch-up as an explicit capability, not a failed URL guess.
- [ ] `flutter analyze` and `flutter test` pass.

## PR 15 — TV focus, accessibility, and input parity

### Automated behavior

- [x] Category/channel/EPG pane boundaries match documented navigation. Channel
  category activation/filter handoff is pinned by
  `test/channel_list_focus_test.dart`; EPG boundaries remain covered by
  `test/epg_grid_test.dart`.
- [x] Up/down wrapping rules match documented navigation. Pure coordinator and
  real-key widget tests cover channel/category wrapping and upward escape.
- [ ] Search open/close restores the intended focus target.
- [x] Back ladder does not clear or change data prematurely. Flutter tests cover
  row/favorite/category/search/tab rungs; Android native unit and API-36 emulator
  checks cover menu/info/controls/exit policy and duplicate Back suppression.
- [ ] Dialog and sheet dismissal restores focus.
- [x] In-row favorite activation preserves logical selection. Covered by pure
  coordinator and real-key widget tests.
- [ ] Return from native playback restores focus.
- [ ] Async rebuild retains logical selection and usable focus.
- [ ] Held-key repeat cannot issue duplicate activation.

### Semantics

- [ ] Custom rows expose selected state.
- [ ] Rows expose useful channel/programme labels.
- [ ] Lists/grids expose position information where practical.
- [ ] Favorite state and actions are exposed.
- [ ] Custom controls expose an activation action.

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

- [ ] Report redacted compressed and decoded byte counts.
- [ ] Report parse and database-write duration.
- [ ] Report rejected-row counts without sensitive row contents.
- [ ] Show cloud revision/timestamp and warn before destructive overwrite.
- [ ] Preview snapshot restore effects.
- [ ] Show provider EPG/catch-up/resolution capabilities.
- [ ] Show cache size and last successful refresh by source.
- [ ] Offer a safe cache re-ingestion action.
- [ ] Ensure exported diagnostics remain credential-safe.
- [ ] `flutter analyze` and `flutter test` pass.

## PR 17 — Microsoft Store MSIX distribution

- [x] Reserve the public product name `IPTVS Player` as an MSIX app in Partner
  Center.
- [x] Record the exact Package Identity Name, Publisher, publisher display name,
  product name, PFN, Package SID, and Store ID in `docs/store-publishing.md`.
- [ ] Add deterministic x64 MSIX packaging using those identity values.
- [x] Add explicit `development`, `githubDirect`, `googlePlay`, and
  `microsoftStore` build-time distribution channels.
- [x] Disable GitHub update checks and PowerShell replacement in Store builds.
- [ ] Keep Store and GitHub-direct Windows artifacts in separate workflow jobs.
- [ ] Use four-part MSIX versions with the fourth component set to `0`.
- [ ] Validate the packaged app writes only to supported app-data/cache locations.
- [ ] Run Windows App Certification Kit against the packaged Release build.
- [ ] Test Store flighting install, upgrade, rollback, uninstall, secure storage,
  HDR/SDR playback, libmpv loading, and firewall behavior.
- [ ] Provide privacy/support URLs, listing assets, age rating, and a credential-free
  demo path for certification.
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

- [ ] Fresh-install and upgraded schemas match.
- [ ] Every supported historical migration passes.
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
- [ ] `CLAUDE.md` schema and architecture claims match implementation.
- [ ] `docs/player.md`, `docs/tv-navigation.md`, `docs/cloud-sync.md`, and
  `docs/updates.md` describe the released behavior.

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
| 2026-07-16 | PR 10 uses a hybrid worker boundary: one-pass `Isolate.run` decode+map (bytes in, typed list out) for large Xtream/Stalker channel and media payloads, streamed compact `Programme` batches only for XMLTV EPG (new `replaceEpgStream` preserving the atomic success-empty/rollback contract), and an additive `LoadToken` cancel guard beside the existing generation guards; disk-backed M3U line parsing and ordered-list-fallback offload are deferred | Channels/media are held in full by the UI regardless, so batch-streaming them reduces nothing — the win is keeping the dynamic JSON graph inside the worker and building the typed graph off the main isolate; EPG is the only path where the full typed list on the main isolate is pure waste (programmes flow straight to SQLite); a long-lived ingestion isolate's spawn-amortization benefit is irrelevant at refresh cadence and would force multi-batch semantics onto the atomic cache | `Source` stays provider-agnostic via one optional `epgBatched` member defaulting to null; existing generation guards and their pinned tests are untouched (the token adds only DB-write/batch-feed guarding); main-isolate stall and peak-memory verification remain before/after recordings on the low-memory TV device since PR 0 budgets were intentionally unset | PR 10 |
| 2026-07-16 | PR 11 validation lives in BEFORE-INSERT/UPDATE triggers calling shared `assert_*` helpers on `sources`/`profiles`/`metadata_configs`, plus cheap top-level array-count/byte-size guards inside the push RPCs before any mutation; CHECK constraints and RPC-only validation were both rejected. Rate limiting is a DB-side token window (`push_rate` table + `check_push_rate`, 30 pushes/min per device session — per-device rather than per-owner so multiple devices on one account never throttle each other) modeled on `request_pairing`'s counter; an Edge Function proxy was rejected. All limits sized ≥10x above realistic maxima measured against the 250k-channel validation corpus (favorites cap 200,000; 50,000 hidden-category ids per kind; 16 MB payload ceilings) | The panel writes tables directly under RLS, so RPC-only validation leaves the credential-bearing `sources.fields` path unbounded; a CHECK-constraint failure emits `details = "Failing row contains (…)"` which `PostgrestException.toString()` surfaces verbatim in the Flutter UI — a credential leak; triggers deploy idempotently on a live table with no NOT VALID/VALIDATE dance. An Edge proxy is a new deploy target plus counter store for a threat already bounded to the caller's own account by owner-scoping and payload caps | Legitimate huge-portal users are never rejected by our own validation (typed `iptvs: `-prefixed `check_violation` errors, no payload values interpolated); reads/pulls stay unthrottled by design (RLS-scoped, documented as accepted risk); the Supabase gateway's own body-size ceiling is verified empirically against the live project as an owner-run item | PR 11 |
| 2026-07-16 | Harden the player lifecycle with targeted per-defect fixes plus a queryable debug-only counter registry (Dart `ResourceCounters` / Kotlin `DebugCounters` / C++ `#ifndef NDEBUG` ints), rejecting a unified per-platform lifecycle/session object; counters merge through a `debugCounters` method on the existing HDR channel rather than a new inbound channel | The audit found only two genuine, local defects (Windows silent surface-failure; preview `TextureView` not detached at PlatformView dispose) — a session object is precisely the bridge redesign the ledger forbids without measured need and would rewrite through seven load-bearing, currently-passing invariants; a new inbound channel would add handler-ownership surface right after PR 8 removed that class of bug; the soak must programmatically assert zero, which pure logging cannot fail on | Counters thread through the existing call sites, so a green soak proves those exact release paths complete; release builds are inert (`kDebugMode`/`BuildConfig.DEBUG`/`NDEBUG`, empty `debugCounters` reply); deferred as a known efficiency item, not a leak: PlayerScreen constructs an embedded media_kit `Player` even on the Android native path where it is never opened (counted and disposed, so soaks still balance) | PR 9 |

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

## Removal checklist

This document can be deleted when all of the following are true:

- [ ] Every required release-candidate gate above is complete.
- [ ] Deferred items have their own issue with scope and acceptance criteria.
- [ ] Lasting architecture decisions are recorded in canonical documentation.
- [ ] Schema/version/toolchain documentation matches the released tree.
- [ ] Device-test evidence is retained outside this temporary ledger.
- [ ] No active PR depends on context that exists only in this file.
- [ ] The temporary implementation-plan link is removed from `CLAUDE.md`.
