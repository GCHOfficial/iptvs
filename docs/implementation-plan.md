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

- Last updated: 2026-07-15
- Active phase: Phase 0 — Credential removal
- Active PR: PR 4 follow-up — resumable Android installer handoff
- Previous PR: PR 4 — merged as #103 and released as v0.1.33
- Plan baseline commit: `966418fec7a07646163073377c6a3a1013b93dd0`
- Baseline branch: `main`
- Baseline working tree: clean
- CI Flutter version: 3.44.5
- Declared Dart SDK constraint: `^3.12.2`
- Documentation Flutter version: README and CI declare 3.44.5
- Baseline `flutter analyze`: passed
- Baseline `flutter test`: passed, 204 tests
- Current PR 0 `flutter analyze`: passed on 2026-07-14
- Current implementation `flutter test`: passed, 277 tests with 7 opt-in
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
- [ ] Do not split the large player or browsing widgets before async-race and
  MethodChannel ownership regression tests exist.
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
| 5 | Phase 0 | Remove credentials from SQLite, cloud, UI, and logs | L | PR 4 | [ ] |
| 6 | Phase 1 | Guard controllers against stale async results | M | PR 0 | [ ] |
| 7 | Phase 1 | Make EPG refresh atomic and indexed | M | PR 4 | [ ] |
| 8 | Phase 1 | Give MethodChannel handlers explicit ownership | M | PR 0 | [ ] |
| 9 | Phase 1 | Harden and validate native player lifecycle | L | PR 8 | [ ] |
| 10 | Phase 2 | Build bounded one-pass isolate ingestion | L | PR 3 | [ ] |
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

- [ ] Add a provider-neutral encrypted secret-locator field where playback requires
  persistence of a URL or provider secret.
- [ ] Store its per-install encryption key in `flutter_secure_storage`.
- [ ] Keep non-secret provider metadata in the normal `extra` field.
- [ ] If the encryption key is missing, invalidate and re-ingest regenerable cache.
- [ ] Atomically migrate source IDs, channel IDs, favorites, positions, EPG, and
  related metadata.
- [ ] Ensure cloud item IDs contain no raw URLs, MAC addresses, or credentials.
- [ ] Ensure encrypted playback locators are never uploaded to cloud sync.
- [ ] Redact URL user-info, paths, queries, and fragments in UI and diagnostics.
- [ ] Redact source summaries in the Flutter UI and JavaScript panel.
- [ ] Render credential inputs as password fields with explicit reveal controls.

### Verification

- [ ] Existing M3U favorites survive migration.
- [ ] Continue Watching survives migration.
- [ ] Existing EPG links survive migration.
- [ ] Migration failure rolls back all related tables.
- [ ] No fixture credential appears in SQLite text values.
- [ ] No fixture credential appears in cloud payloads.
- [ ] No fixture credential appears in diagnostics or rendered summaries.
- [ ] Missing encryption-key behavior is deterministic and recoverable.
- [ ] Fresh and migrated databases have matching schemas.
- [ ] `flutter analyze` and `flutter test` pass.

## PR 6 — Async generation and disposal guards

### Implementation

- [ ] Add generation tokens to `MediaTabController` category loads and pagination.
- [ ] Add generation tokens to `LiveController` loads and refreshes.
- [ ] Guard source/profile loading in `HomeShell`.
- [ ] Guard asynchronous metadata enrichment.
- [ ] Publish results only if controller, generation, source, profile, and category
  still match the request.
- [ ] Define refresh versus `loadMore` precedence explicitly.
- [ ] Prevent notification after controller disposal.

### Verification

- [ ] Category A returning after category B cannot replace B.
- [ ] Old source response cannot replace a new profile/source.
- [ ] Refresh supersedes an outstanding pagination request.
- [ ] Dispose during a request causes no notification or exception.
- [ ] Old metadata enrichment cannot mutate a newer result.
- [ ] `flutter analyze` and `flutter test` pass.

## PR 7 — EPG atomicity, empty results, and indexing

### Implementation

- [ ] Treat a normally completed empty EPG result as a successful replacement.
- [ ] Clear old programmes and update freshness for success-empty.
- [ ] Retain the last good cache after exceptions or timeouts.
- [ ] Replace programmes and refresh timestamp in one transaction.
- [ ] Add the measured index needed by source/time now-next queries.
- [ ] Confirm index use with `EXPLAIN QUERY PLAN`.
- [ ] Avoid constructing duplicate full replacement datasets in memory.

### Verification

- [ ] Success-empty clears stale programmes.
- [ ] Failure retains old programmes and records refresh failure.
- [ ] Transaction failure leaves the previous complete EPG intact.
- [ ] Fresh and upgraded databases contain the new index.
- [ ] Large now-next lookup selects the intended index.
- [ ] `flutter analyze` and `flutter test` pass.

## PR 8 — MethodChannel handler ownership

### Implementation

- [ ] Add an owner token for each registered static channel handler.
- [ ] Clear a handler only when the disposing owner is still current.
- [ ] Ignore callbacks delivered to disposed or superseded owners.
- [ ] Apply identical cleanup rules to Android and Windows.
- [ ] Apply the helper to preview and full-screen player ownership.

### Verification

- [ ] Old preview disposal cannot clear a newer preview handler.
- [ ] A popped player ignores late position, favorite, and error callbacks.
- [ ] Android handler cleanup matches Windows cleanup.
- [ ] Repeated route cycles leave exactly one active owner.
- [ ] `flutter analyze` and `flutter test` pass.

## PR 9 — Native player lifecycle

### Android implementation and validation

- [ ] Preview adoption leaves one active player and one audible stream.
- [ ] ExoPlayer-to-MPV fallback releases the failed engine.
- [ ] Route pop and Back release or transfer ownership correctly.
- [ ] Home/background/foreground transitions behave correctly.
- [ ] PiP entry, exit, Back, and forced close behave correctly.
- [ ] Activity/process recreation restores or fails safely.
- [ ] Headers, subtitles, tracks, seek, speed, and volume retain supported parity.
- [ ] Reconnect cannot revive a superseded source.
- [ ] PlatformView disposal releases the surface and native references.

### Windows implementation and validation

- [ ] Partial HWND/D3D initialization failure cleans up safely.
- [ ] Embedded/fullscreen/mini-player transitions do not leak surfaces.
- [ ] Parent resize, DPI change, and monitor change behave correctly.
- [ ] Forced close with callbacks pending does not access disposed state.
- [ ] Overlay commands after Dart route disposal are ignored.
- [ ] Reconnect works after surface recreation.

### Verification

- [ ] Debug-only counters exist for engines, surfaces, reconnect timers, and owners.
- [ ] A 100-cycle Android open/close soak returns counters to zero.
- [ ] A 100-cycle Windows open/close soak returns counters to zero.
- [ ] Android phone device matrix passes.
- [ ] Android TV device matrix passes.
- [ ] Windows SDR device matrix passes.
- [ ] Windows HDR device matrix passes.
- [ ] No bridge redesign is made without measured correctness or performance need.

## PR 10 — Bounded one-pass isolate ingestion

### Implementation

- [ ] Xtream: decode and map large responses within one worker job.
- [ ] Stalker: join, decode, and map large channel responses in one worker job.
- [ ] XMLTV: decompress, parse, and return compact programme batches.
- [ ] M3U: decode and parse with bounded batches.
- [ ] Avoid returning both a giant dynamic graph and a typed graph.
- [ ] Prevent cancelled or stale batches from reaching the repository.
- [ ] Retain measured inline paths for genuinely small payloads.

### Verification

- [ ] Main-isolate stalls meet the PR 0 budget on the low-memory TV device.
- [ ] Peak memory remains within the agreed regression allowance.
- [ ] Cancellation stops publication of subsequent batches.
- [ ] Malformed data has deterministic partial-failure behavior.
- [ ] Results match the existing parser fixture corpus.
- [ ] `flutter analyze` and `flutter test` pass.

## PR 11 — Cloud, RLS, RPC, and panel hardening

### Implementation

- [ ] Set a fixed `search_path` in every `SECURITY DEFINER` function.
- [ ] Enforce ownership in every profile/snapshot RPC.
- [ ] Validate JSON shape, field lengths, array counts, and total payload size.
- [ ] Make pairing completion single-use and transactionally safe.
- [ ] Apply rate limits at the API/edge boundary.
- [ ] Validate source schemes and field lengths in the panel.
- [ ] Prevent panel errors from echoing credential-bearing input.
- [ ] Document last-write-wins behavior and timestamp authority.

### Verification

- [ ] Cross-user profile read/write attempts fail.
- [ ] Expired pairing codes fail.
- [ ] Completed pairing codes cannot be replayed.
- [ ] Concurrent profile creation cannot exceed the profile cap.
- [ ] Invalid or excessive push payloads fail before mutation.
- [ ] Clock-skew and equal-timestamp conflict cases are deterministic.
- [ ] Panel rendering and validation tests pass.
- [ ] `flutter analyze` and `flutter test` pass.

## PR 12 — Historical migration coverage

- [ ] List schema versions that shipped publicly.
- [ ] Remove unsupported intermediate versions from the compatibility claim.
- [ ] Add a sanitized database fixture for each supported historical version.
- [ ] Open and migrate every fixture.
- [ ] Compare tables, columns, indexes, constraints, and foreign keys with fresh DB.
- [ ] Validate representative favorites, positions, EPG, and metadata after upgrade.
- [ ] Open every migrated fixture a second time to prove stable startup.
- [ ] Update `AppDatabase.schemaVersion` documentation after migrations land.
- [ ] `flutter analyze` and `flutter test` pass.

## PR 13 — Split oversized UI files

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
- [ ] No raw provider credentials exist in SQLite, cloud payloads, diagnostics, or
  source summaries.

### Correctness and persistence

- [ ] Fresh-install and upgraded schemas match.
- [ ] Every supported historical migration passes.
- [ ] EPG success-empty, failure retention, and atomic replacement pass.
- [ ] Source/profile/category race tests pass.
- [ ] No tested controller or channel handler notifies a disposed owner.

### Performance

- [ ] Large M3U, Xtream, Stalker, and XMLTV fixtures meet agreed budgets.
- [x] Network and decompression limits reject hostile fixtures in
  `test/net_workload_test.dart`.
- [ ] Now-next EPG lookup uses the intended index.
- [ ] Peak memory remains within the agreed regression allowance.

### Native platforms

- [x] Android release build succeeds and certificate is verified by the
  protected v0.1.32 workflow; the APK installed successfully on owner hardware.
- [ ] Android phone lifecycle matrix passes on a device.
- [ ] Android TV lifecycle and focus matrices pass on a device.
- [x] Windows x64 release build succeeds in PR #98 CI on 2026-07-14.
- [ ] Windows SDR and HDR lifecycle matrices pass on hardware.
- [ ] Android and Windows 100-cycle playback soaks return resource counters to zero.

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

## Removal checklist

This document can be deleted when all of the following are true:

- [ ] Every required release-candidate gate above is complete.
- [ ] Deferred items have their own issue with scope and acceptance criteria.
- [ ] Lasting architecture decisions are recorded in canonical documentation.
- [ ] Schema/version/toolchain documentation matches the released tree.
- [ ] Device-test evidence is retained outside this temporary ledger.
- [ ] No active PR depends on context that exists only in this file.
- [ ] The temporary implementation-plan link is removed from `CLAUDE.md`.
