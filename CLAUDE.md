# CLAUDE.md

Guidance for working in this repository. Keep it accurate — update it when the architecture
changes. This file is the compact, always-loaded layer: the map, the invariants, the rules.
Deep detail (mechanisms, rationale, failure history) lives in `docs/*.md` — **read the relevant
doc before working in its area**, and update doc + this file together when behavior changes:

- [docs/implementation-plan.md](docs/implementation-plan.md) — temporary audit-remediation ledger; update its checklist, evidence, decisions, and progress entry in every related PR.
- [docs/validation-baseline.md](docs/validation-baseline.md) — reproducible large-ingestion workloads, public schema history, performance evidence, and native-device validation matrix.
- [docs/android-signing.md](docs/android-signing.md) — signing-compromise evidence, package-identity recovery decision, protected release-key setup, and APK certificate gates.
- [docs/store-publishing.md](docs/store-publishing.md) — Android/Play and Windows/Microsoft Store identities, signing roles, packaging, channel-specific updater ownership, and certification gates.
- [docs/tv-navigation.md](docs/tv-navigation.md) — the D-pad/focus system: selection models, the Back ladder, `TvTextField`/`FocusableCard` internals, the EPG grid cursor.
- [docs/player.md](docs/player.md) — the playback stack: Android dual-engine + HDR, Windows native surface, the shared-engine preview handoff, auto-reconnect, PiP.
- [docs/cloud-sync.md](docs/cloud-sync.md) — the Supabase panel, pairing, the RLS security model, cloud + device-side profiles.
- [docs/updates.md](docs/updates.md) — the self-update pipeline: release changelog, per-platform install, update-dialog focus behavior.

**Upkeep rule:** documentation updates land **in the same commit/PR** as the change that
invalidates them. If a change alters behavior described in a detail doc, update that doc; if it
alters a rule or invariant summarized here, update this file too. Subagents are instructed to
flag doc impact in their reports — the orchestrator owns making the updates happen before the
work is considered done.

## What this is

`iptvs` is a cross-platform Flutter IPTV player (Windows, Android incl. Android TV, plus the
usual Flutter targets). It connects to user-configured IPTV providers, caches their
channel/VOD/EPG data locally, enriches movie/series metadata from public APIs, and plays streams
with libmpv (via `media_kit`) so it handles HEVC / AC-3 / MPEG-TS that an HTML video element
can't. There is no backend for playback — the app talks directly to user-supplied provider panels
and public metadata APIs. The one *optional* backend is a Supabase-backed cloud source panel
(docs/cloud-sync.md); it's off unless built with Supabase config and never touches playback.

## Commands

```bash
flutter analyze        # must be clean before committing
flutter test           # unit tests live under test/
flutter run -d windows
flutter run -d android --flavor development --dart-define=DISTRIBUTION_CHANNEL=development
```

Lints: `package:flutter_lints`. CI ([`.github/workflows/build.yml`](.github/workflows/build.yml)):
analyze + test, then Windows and a universal Android APK. The Windows libmpv DLL is fetched at
configure time by `windows/CMakeLists.txt`; the Android libdovi AAR comes from **Git LFS**
(`android/app/libs/libmpv-dovi.aar`), so a clone needs LFS to build Android. The Windows runner
compiles `/utf-8` (non-ASCII literals trip C4066 under `/WX`). A fixed public debug keystore is
committed for non-distributable debug builds. Release builds fail closed unless protected signing
environment variables are present, and the release workflow verifies the resulting certificate;
see `docs/android-signing.md` before touching package identity or signing.
Direct in-app updates fail closed unless an Ed25519-signed release manifest authenticates the
exact platform filename, size, and SHA-256; see `docs/updates.md` before changing release assets.

## Orchestration workflow

The lead session (Fable 5 for now; switch to Opus 4.8 when Fable is no longer available under
subscription) is the **orchestrator**: plan, decompose, synthesize — and keep its own context
lean by delegating rather than doing mechanical work itself.

- **Reasoning-heavy phases** (architecture, debugging complex issues, algorithm design — in this
  repo: focus/D-pad logic, the player stack, `LibraryRepository` merge paths, migrations, RLS)
  → **deep-reasoner** (Opus, `.claude/agents/deep-reasoner.md`).
- **Mechanical work** (boilerplate, tests following existing patterns, formatting, simple edits)
  → **fast-worker** (Sonnet, `.claude/agents/fast-worker.md`).
- **Registration:** agent discovery happens at session startup and fails silently, so the
  definitions are also symlinked into `~/.claude/agents/` (user-level, loads in every session —
  re-create the symlinks when setting up a new machine). **Fallback** if the named types still
  aren't registered ("agent type not found"): spawn `general-purpose` with the matching `model`
  override and make the agent's first instruction "read `.claude/agents/<name>.md` and adopt it
  as your operating rules" — keep the definition file the single source of truth instead of
  paraphrasing it into the prompt.
- **High-stakes decisions**: one deep-reasoner pass that must develop **≥2 competing designs and
  argue the winner**; the orchestrator adjudicates. Reserve a true second, independently framed
  run for hard-to-reverse decisions (schema migrations, RLS changes).
- **Plan waves by file overlap.** Agents whose edits can't collide run in parallel in the same
  tree; every implementing agent's prompt carries an explicit file-ownership list ("you own X;
  don't touch Y"). Clusters that share files run in sequence — or run the shared-file cluster as
  a **read-only diagnose/design pass** in the first wave (no file footprint, so it parallelizes
  freely) and implement from its report in the next.
- **Handoffs between waves**: pass the design report verbatim, plus two caveats — line numbers
  may be stale (match by function name), and the tree contains uncommitted work from other
  agents (build on top; never revert unexpected diffs).
- If an agent dies mid-task (rate limit, crash), **resume it via SendMessage** — its context
  (spec, files already read) survives; a fresh spawn re-pays the whole cold start. Stagger heavy
  Opus agents that don't strictly need to run concurrently — parallel Opus waves can hit
  session usage limits.
- When delegating work in an area covered by a `docs/*.md` detail doc, tell the agent to read
  that doc first — agents get this file automatically, but not the detail docs.

## Architecture

Layered, provider-agnostic. The golden rule: **the UI and cache never know which kind of provider
they're talking to** — everything goes through the `Source` interface.

```
screens/  ──▶  LibraryRepository  ──▶  Source (Stalker | Xtream | M3U | Demo)
                      │                        │
                      ▼                        ▼
                 AppDatabase (SQLite)    MetadataProvider (TMDB | TVDB | MDBList)
```

- **`lib/sources/source.dart`** — the core domain models (`Channel`, `MediaItem`, `Category`,
  `Programme`, `StreamInfo`, `ContentKind`) and the `Source` interface. To add a provider you
  implement this one interface and change nothing else. Read the doc comments here first.
- **`lib/sources/*_source.dart`** — provider implementations: `stalker_source.dart` (MAG portal,
  the largest/most intricate), `xtream_source.dart`, `m3u_source.dart`, `demo_source.dart` (used
  by tests). `Source.subscriptionExpiry()` feeds the sources screen's expiry badge; shared parsing
  in `expiry.dart`. Stalker tries `account_info`/`get_main_info` first (the canonical action,
  wrapped so a portal that doesn't support it falls through rather than aborting the chain), then
  `get_profile` — MAG portals stuff the end date into odd fields on either, classically `phone`.
  M3U playlists carry no expiry metadata themselves, so `expiryFromPlaylistUrl` best-effort-reads
  it off a provider query param (`exp`/`expiry`/`expire`/`expires`) on the playlist URL.
- **`lib/data/library_repository.dart`** — orchestration between a `Source` and the cache: serves
  from SQLite when fresh, refreshes EPG on its own schedule, handles paging (`loadMore*`), runs
  metadata enrichment. The most logic-dense file; treat its cache/refresh/merge paths carefully.
  EPG contract: a normally completed empty `Source.epg` result is **success** and atomically
  replaces the cache (clears stale rows, advances `epg_synced_at`); a thrown error retains the
  last good guide with the un-advanced timestamp as the failure record. `replaceEpgStream` is
  the streamed counterpart (large XMLTV guides via the optional `BatchedEpgSource` capability):
  same one-transaction, success-empty semantics, and a cancelled feed must end in a thrown
  `LoadCancelledException` — never a quiet stream close — so the transaction rolls back instead
  of committing a half-fed guide. Don't reintroduce an `isNotEmpty` guard before `replaceEpg`/
  `replaceEpgStream`, and don't write the `sources` row with `INSERT OR REPLACE` (it destroys
  columns the writer doesn't own — see `replaceLibrary`).
- **`lib/data/app_database.dart`** — local SQLite cache keyed by `Source.id`, versioned schema
  with hand-rolled `onUpgrade`. See "Database migrations" below.
- **`lib/data/*_client.dart`** + **`metadata_provider.dart`** — `MetadataProvider`s enriching
  `MediaItem`s with posters/overviews/ratings. `ratingsOnly` providers (MDBList) only contribute
  ratings and run after a visual provider has matched.
- **`lib/data/source_store.dart`** — persists `SourceConfig`s (credentials included) in the OS
  keychain via `flutter_secure_storage`, plus the active source and metadata config. The whole
  source list lives under one storage key (fine: the Windows v4 backend is a DPAPI file with no
  per-entry size cap; Android likewise).
- **`lib/data/local_profile_store.dart`** — device profiles: keychain-persisted `LocalProfile`s,
  per-cloud-profile `ProfileSnapshot`s, the picker's startup mode. See docs/cloud-sync.md.
- **`lib/screens/`** — UI. `home_shell.dart` resolves the active source and builds its
  repository. The main browsing UI: `channel_list_screen.dart` (screen state, tabs, toolbar —
  controller notifications rebuild scoped `ListenableBuilder` subtrees, never the whole screen),
  `live_tab_view.dart` (live body: channel list, category pane, preview panel, catch-up +
  phone-preview sheets), `media_tab_view.dart` (movies/series grid, details sheet, series
  browser), `live_focus_coordinator.dart` (the live D-pad selection model),
  `epg_grid_screen.dart` (the TV-guide timeline, selection-cursor model) — both navigation models
  are documented in docs/tv-navigation.md. `sources_screen.dart` manages provider configs
  (add/edit/delete/activate, ↑/↓ reorder via `SourceStore.setAll`); `source_settings_screen.dart`
  toggles a source's categories (persisted on `SourceConfig.settings`). Favorites are tagged from
  the per-item surfaces and appear as a "Favorites" entry atop each category list. Live channels
  with an archive (`Channel.hasArchive`) get a catch-up button (`CatchupSheet`, played via
  `Source.resolveArchive`). `diagnostics_screen.dart` views/exports the in-memory log;
  `profile_pick_screen.dart` is the boot-time profile picker.
- **`lib/widgets/`** — shared widgets: `focusable_card.dart` and `tv_text_field.dart` (central to
  TV navigation — see docs/tv-navigation.md), `profile_avatar.dart`, `favorite_controls.dart`,
  `release_notes_view.dart` (dependency-free changelog renderer used by the update dialog), and
  `image_utils.dart` (all network images go through `cached_network_image` with display-sized
  decode — don't add bare `Image.network`).
- **`lib/player/player_screen.dart`** — playback. See "Player" below + docs/player.md.

## Key conventions

- **Provider-specific data rides in `extra`.** `Channel`/`MediaItem` carry a
  `Map<String,dynamic> extra` that only the owning `Source` interprets (Stalker `cmd`, Xtream
  stream id, etc.). Keep provider details out of the shared models and out of the UI.
- **Resolve streams at play time, never ahead.** Stalker `create_link` URLs are short-lived.
  `Source.resolve` / `resolveMedia` are called right before playback.
- **Async publishes are generation-guarded.** `MediaTabController`, `LiveController`, and
  `HomeShell._loadActive` each hold a monotonic `_loadGeneration`: only dataset-replacing ops
  (`load`, `setCategory`) bump it and publish results only if still current; subordinate ops
  (`loadMore`, `search`, `clearSearch`, `refreshNowNext`) read it without bumping and abandon
  superseded results — so a refresh always beats an in-flight pagination, never the reverse.
  Disposal is expressed solely through `_disposed`, checked in `_set` (the only
  `notifyListeners` site). Pinned by `test/media_tab_controller_test.dart` and
  `test/live_controller_test.dart` — keep new async publish paths behind these guards.
  Additive to (never instead of) the generation guard: a `LoadToken`
  (`lib/data/load_token.dart`) per generation stops a superseded load from *writing* to the
  cache or feeding more EPG batches (the generation guard only stops the UI publish). It is
  delivered via the settable `LibraryRepository.loadToken` field — set in the same synchronous
  prologue as the call, read into a local before the method's first `await` — not a method
  parameter, because the pinned tests' `_GatedRepo` overrides would break on any signature change.
- **Large provider payloads are ingested one-pass off the main isolate.** Xtream/Stalker
  catalogs ≥256 KB go bytes-in→typed-list-out through top-level workers
  (`decodeLiveChannelsBytes`/`decodeMediaItemsBytes`, Stalker `_ingestStalkerChannels`) — the
  dynamic JSON graph never crosses the isolate boundary; smaller payloads parse inline (isolate
  spawn would dominate). Large XMLTV guides stream bounded `Programme` batches
  (`parseXmltvBatched`, single in-flight batch by design) straight into `replaceEpgStream`.
  Sources with a batched guide implement the optional `BatchedEpgSource` capability interface —
  deliberately separate from `Source`, since `implements` doesn't inherit default bodies.
  Don't add new parse/map work on the main isolate for provider-sized payloads, and don't
  return both a dynamic and a typed graph from a worker.
- **Liveness is provider metadata, not inferred.** `StreamInfo.isLive` is set by the `Source`.
  Don't guess from stream duration (an HLS live window looks finite). Live = no seek bar.
- **Secrets must never reach logs, on-screen errors, or exported diagnostics.** Provider URLs and
  errors carry credentials. Use `redactUrl` (`lib/data/net.dart`) for any URL that goes into an
  error/log, and `redactText` (same file) for free-form text that may *embed* a URL — it also
  scrubs credential-shaped *path* segments (`/live/user/pass/1.ts`), which `redactUrl`'s
  query-focused redaction doesn't. Stalker additionally uses `redactStalkerDiagnostic` /
  `_redactUrl` for MAC/Bearer tokens. The diagnostics log is user-exportable — assume anything
  you log may be shared for support.
- **HTTP timeouts.** All `HttpClient`s set `connectionTimeout` (TCP handshake only). For the
  response, use `response.readBytes()` and `.timeout(kHttpReadTimeout)` on `request.close()`
  (both in `lib/data/net.dart`) — `connectionTimeout` does **not** cover a server that connects
  then stalls mid-body.

## TV / remote navigation (essentials)

Full D-pad navigability is a hard requirement (Android TV target). **Read
docs/tv-navigation.md before touching focus or navigation code** — the current design replaced a
per-row-focus approach whose races produced repeated D-pad bugs, and the doc records why.

- Lists/grids use `FocusableCard`; text inputs use `TvTextField` ("OK to edit") — never a bare
  `TextField` on a TV-facing screen (it traps D-pad focus).
- **Exception:** the two live-tab lists and the EPG grid are **selection models** — one focus
  node + a selected index; rows are *not* focus targets. Never add focus nodes to their rows.
  Both live lists set an explicit `itemExtent` (`kChannelRowExtentWithEpg` 112 /
  `kChannelRowExtentPlain` 72 / `kCategoryRowExtent` 44 in `live_tab_view.dart`) — uniform rows
  make index→offset exact; the tallest EPG row must fit the extent.
- **Movement is deliberately asymmetric: Down wraps; Up never wraps — it escapes upward.**
  Right first enters the selected channel row's **favorite star** (the intra-row
  `ChannelRowColumn`; OK there toggles the favorite in place) and Left peels it back before
  crossing panes; beyond that Left/Right cross panes, and every arrow is consumed (geometry
  traversal never runs in the live body).
- **The Back ladder** (`channel_list_screen` `_handleRootBack`): Back never changes data or
  filters — it peels exactly one rung per press toward the exit (rung list in
  docs/tv-navigation.md); chrome (AppBar/toolbar buttons, route key `''`) sits above the ladder;
  exit is behind a double-Back snackbar.
- Pinned by `test/live_focus_coordinator_test.dart`, `test/channel_list_focus_test.dart`,
  `test/epg_grid_test.dart`, `test/tv_text_field_test.dart` — keep them green.

## Cloud sync + profiles (essentials)

Optional Supabase-backed web panel for managing sources; device pairs by code, pulls the profile's
sources/metadata/favorites, and can push back. Hidden entirely unless built with
`SUPABASE_URL`/`SUPABASE_ANON_KEY` (`cloud_config.dart` `isConfigured`). **Read
docs/cloud-sync.md before touching sync, pairing, profiles, or `supabase/`.** Non-negotiables:

- The **anon key ships in clients by design**; access control is *only* RLS + `SECURITY DEFINER`
  RPCs (`supabase/migrations/`, deny-by-default — read the first migration's header before
  changing it). The `service_role` key must never appear in any client or this repo.
- Devices are anonymous users with **no direct table writes**; the only device→cloud write path
  is the owner-scoped `push_*` RPCs. Push is last-write-wins.
- Every profile (local and cloud) owns a `ProfileSnapshot`; switching snapshots the outgoing
  state and restores the incoming one, keeping cloud-managed source ids scoped per profile so
  pulls never leak sources across profiles (`local_profile_store.dart`).
- The app boots into `ProfilePickScreen`, which self-decides via
  `shouldShowPickerAtStartup(mode, profileCount)` — single-profile installs boot straight to
  `HomeShell`.

## Database migrations

`AppDatabase` is at `schemaVersion = 12` (v9: `favorites` table, deliberately separate from
`channels`/`media_items` so a refresh never drops favorites; v10: `channels.archive_days` →
`Channel.hasArchive` / catch-up; v11: VOD playback positions / Continue Watching; v12:
`idx_prog_source_start(source_id, start)` on `programmes` for the source+time now/next lookup —
channel-scoped guide/catch-up queries keep using `idx_prog_lookup`). When
changing the schema: bump `schemaVersion`, add an
`onUpgrade` branch, make new tables/columns idempotent (`CREATE TABLE IF NOT EXISTS`, the
`_isDuplicateColumn` guard). **Design trap:** upgrading from before v3 calls `_createMediaTables`,
which builds the *current* media schema, so later `oldV >= 3` ALTER branches are intentionally
skipped for those users — therefore **any table `_createMediaTables` doesn't create must also
have an `oldV < N` repair branch**, or fresh installs miss it (the v7 `external_metadata` bug:
created only in an `oldV >= 3 && oldV < 7` branch, fresh installs crashed on every metadata
query; v8 fixed it both ways). `AppDatabase.openAt(path)` is the `@visibleForTesting` seam used
by `test/persistence_test.dart`.

## Player (essentials)

`player_screen.dart` plays a resolved `StreamInfo` via `media_kit`, with native-HDR paths on
Android (`HdrPlayerActivity`: **ExoPlayer default**, **mpv fallback** only when ExoPlayer can't
decode — chiefly DV P5 on non-DV hardware, needing the vendored libdovi AAR) and Windows (native
HWND surface, mpv d3d11). Other platforms: embedded `media_kit_video`, HDR tone-mapped to SDR.
**Read docs/player.md before touching playback, preview, or overlay code.** Non-negotiables:

- **Windows handoff: set `wid` before `vo`** in `_configureNativePlayer`, or mpv flashes a stray
  top-level window.
- **Android preview and fullscreen share one engine** (`SharedEngine` adoption) — only one
  provider connection ever exists (single-connection accounts); the Activity never releases an
  adopted engine, and the preview is never paused around the *adopted* handoff. But **any
  *non*-adopted fullscreen (last-channel zap, EPG-grid play) must silence the running preview** in
  `_openLivePlayer` — even one previewing a *different* channel — or its audio doubles up behind the
  new pipeline: a same-channel preview is *paused* (resumed on return, `pausedPreview`), a
  different-channel one is *stopped* (`stoppedPreview`, releases the 2nd connection; not restarted).
- On a TV remote the preview is **deliberate and locked**: only OK starts/switches it; D-pad
  focus movement never does. The preview engine is stopped when the app backgrounds or exits.
- **Overlay Back is owned by the root `onPreviewKeyEvent`** (not the `BackHandler`) so a focused
  control can't eat the first press to clear its highlight; single-press peels menu→info→hide→exit.
  Relies on predictive back staying **off** (no `enableOnBackInvokedCallback`). Live channels get a
  **favorite star** in both overlays; the native one round-trips state via Intent extra + a
  `RESULT_FAVORITE` reply on close (no live channel from the Activity to Dart).
- **Live auto-reconnect reloads the source** (capped backoff, "Reconnecting…" indicator); VOD
  keeps the manual error/Retry overlay. Two independent watchdogs (Kotlin for Android native,
  Dart for Windows/embedded).
- Playback headers go to both `Media(httpHeaders:)` and mpv `user-agent`/`referrer` properties;
  all playback logs go through `_logPlayback` (redacted).
- Both media_kit and the libmpv AAR ship `libmpv.so` — `jniLibs.pickFirsts` must keep the
  libdovi/libplacebo one.
- **Debug-only resource counters must balance.** Every player-lifecycle resource is counted in
  the layer that owns it — Dart `ResourceCounters` (media_kit players, the live watchdog timer,
  channel-owner claims), Kotlin `DebugCounters` (Exo/mpv engines, preview views, progress ticker,
  `SharedEngine` slot), C++ `windowsSurfaces`/`windowsOverlays` — all release-inert
  (`kDebugMode`/`BuildConfig.DEBUG`/`#ifndef NDEBUG`) and merged by `ResourceCounters.snapshot()`
  via a `debugCounters` method on the existing HDR channel. Counters must return to zero after an
  open/close cycle; `integration_test/player_soak_test.dart` (owner-run on hardware, never CI)
  asserts it over 100 cycles. When adding a lifecycle resource or a new create/dispose path, keep
  the counting balanced. Detail: docs/player.md "Debug resource counters + lifecycle soak".
- **Inbound native channels are token-owned.** `iptvs/native_hdr_player` and
  `iptvs/native_preview` are process-static; handler registration goes through
  `ChannelHandlerOwner` (`lib/player/channel_owner.dart`): claim bumps a monotonic token,
  release clears only if still current, superseded owners' calls are ignored — so an old
  route's dispose can't null a newer route's handler. Cleanup is identical on Android and
  Windows (Dart-side; natives are owner-agnostic). Real handlers keep a `mounted`/`_disposed`
  second gate. Pinned by `test/channel_owner_test.dart`.

## In-app updates (essentials)

Self-updates from GitHub Releases (`GCHOfficial/iptvs`): shared Dart service
(`update_service.dart`, pure version compare, unit-tested) + keychain prefs (`update_store.dart`)
+ per-platform installer (`update_installer.dart`: Android system installer via FileProvider;
Windows detached PowerShell swap + `exit(0)`). `update_flow.dart` drives prompt → download →
install; Android persists a verified pending APK, retries it after unknown-source settings, and
offers to resume it after OEM installer/settings detours with repeat cache hash + native
package/signer checks. Dialogs are D-pad-safe (primary action autofocuses; the update dialog traps focus).
Release bodies open with an AI-generated changelog (fail-open Gemini step in release.yml),
rendered by `ReleaseNotesView`. Detail: docs/updates.md.

## Testing notes

- Mostly pure-logic / persistence unit tests; use `DemoSource` or a small fake `Source` rather
  than hitting the network. Real widget tests exist for `TvTextField`, focus/Back-ladder
  behavior, the EPG grid, and the update dialog — keep them green when touching those areas.
- The data layer is well covered: Stalker series/episode parsing, Xtream mapping & paging, XMLTV,
  redaction, metadata config, source-hint language detection (`widget_test.dart` — mostly logic
  tests despite the name); redaction + DB migrations + repository cache behaviour (`net_test.dart`,
  `persistence_test.dart`).
- **Known gap:** migration coverage exercises v1→8, fresh-create, and the v7→8
  `external_metadata` repair, but not the v3→7 ALTER/`media_page_state` rebuild branches. Worth
  adding if those paths change.
- Kotlin has a small plain-JUnit harness (`android/app/src/test/kotlin/` — `PlayerBackPolicyTest`,
  `ReconnectPolicyTest`; run via `./gradlew :app:testDevelopmentDebugUnitTest`) for pure logic
  extracted from the native player. `integration_test/player_soak_test.dart` is owner-run on real
  hardware only (see docs/player.md) — plain `flutter test` doesn't collect it.
- Credential-shaped test fixtures (`username=u&password=p` in URL literals) trip GitGuardian on
  every PR that adds one — it's a false positive to dismiss in their dashboard, or avoid the
  literal `username=…&password=…` pattern when the parser under test doesn't need it.
