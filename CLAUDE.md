# CLAUDE.md

Guidance for working in this repository. Keep it accurate — update it when the architecture changes.

## What this is

`iptvs` is a cross-platform Flutter IPTV player (Windows, Android, plus the usual Flutter desktop/mobile targets). It connects to user-configured IPTV providers, caches their channel/VOD/EPG data locally, enriches movie/series metadata from public APIs, and plays streams with libmpv (via `media_kit`) so it handles HEVC / AC-3 / MPEG-TS that an HTML video element can't.

There is no backend for playback — the app talks directly to user-supplied provider panels and public metadata APIs. There is one *optional* backend: a Supabase-backed **cloud source panel** for managing the source list from the web (see "Cloud sync" below); it's off unless built with Supabase config and never touches the playback path.

## Commands

```bash
flutter analyze        # must be clean before committing
flutter test           # unit tests live under test/
flutter run -d windows # or -d android, etc.
```

The analyzer uses `package:flutter_lints`. CI expectation: `flutter analyze` reports no issues and `flutter test` is green.

**CI** ([`.github/workflows/build.yml`](.github/workflows/build.yml)): on push to `main` and PRs, runs `analyze-test` (analyze + test) then builds **Windows** and a **universal Android APK** (one APK serves phone + Android TV). The Windows libmpv DLL is fetched at configure time by `windows/CMakeLists.txt`; the Android libdovi AAR comes from **Git LFS** (`android/app/libs/libmpv-dovi.aar`), so a clone needs LFS to build Android. The runner is compiled `/utf-8` (non-ASCII literals like the `×` speed badge trip C4066 under `/WX` otherwise).

**Android signing.** A fixed **debug keystore is committed** (`android/app/debug.keystore`, standard public android debug creds — not a release secret; force-added past `android/.gitignore`'s `**/*.keystore`). Both debug and release (`build.gradle.kts` points release at the `debug` config) sign with it, so every CI APK shares one signature and **installs in place over the previous one** on a test device. Without this, each runner's auto-generated keystore changed the signature and Android silently refused the update — making new code look like it had no effect. Adopting it once needs a single uninstall.

## Architecture

Layered, provider-agnostic. The golden rule: **the UI and cache never know which kind of provider they're talking to** — everything goes through the `Source` interface.

```
screens/  ──▶  LibraryRepository  ──▶  Source (Stalker | Xtream | M3U | Demo)
                      │                        │
                      ▼                        ▼
                 AppDatabase (SQLite)    MetadataProvider (TMDB | TVDB | MDBList)
```

- **`lib/sources/source.dart`** — the core domain models (`Channel`, `MediaItem`, `Category`, `Programme`, `StreamInfo`, `ContentKind`) and the `Source` interface. To add a provider you implement this one interface and change nothing else. Read the doc comments here first.
- **`lib/sources/*_source.dart`** — provider implementations: `stalker_source.dart` (MAG portal, the largest/most intricate), `xtream_source.dart` (Xtream Codes panel), `m3u_source.dart` (M3U/M3U8 playlist), `demo_source.dart` (built-in sample streams, used for tests).
- **`lib/data/library_repository.dart`** — orchestration between a `Source` and the cache: serves channels/media from SQLite when fresh, refreshes EPG on its own schedule, handles paging (`loadMore*`), and runs metadata enrichment. The most logic-dense file; treat its cache/refresh/merge paths carefully.
- **`lib/data/app_database.dart`** — local SQLite cache (channels, categories, EPG, movies/series, paging state, external metadata), keyed by `Source.id`. Schema is versioned (`schemaVersion`) with a hand-rolled `onUpgrade`. See "Database migrations" below.
- **`lib/data/*_client.dart`** + **`metadata_provider.dart`** — `MetadataProvider` implementations enriching `MediaItem`s with posters/overviews/ratings. `ratingsOnly` providers (MDBList) only contribute ratings and run after a visual provider has matched.
- **`lib/data/source_store.dart`** — persists `SourceConfig`s (credentials included) in the OS keychain via `flutter_secure_storage`, plus the active source and metadata config.
- **`lib/screens/`** — UI. `home_shell.dart` resolves the active source and builds its repository; `channel_list_screen.dart` is the main browsing UI (live/movies/series, search, paging); `sources_screen.dart` manages provider configs; `diagnostics_screen.dart` views/export the in-memory log. Built to be usable by a TV remote's D-pad as well as touch/mouse — see "TV / remote navigation" below.
- **`lib/widgets/`** — shared UI widgets: `focusable_card.dart` (`FocusableCard`, the D-pad-navigable list/grid tile) and `tv_text_field.dart` (`TvTextField`, the edit-mode text input). Both are central to TV navigation.
- **`lib/player/player_screen.dart`** — playback. See "Player" below.

## Key conventions

- **Provider-specific data rides in `extra`.** `Channel`/`MediaItem` carry a `Map<String,dynamic> extra` that only the owning `Source` interprets (Stalker `cmd`, Xtream stream id, etc.). Keep provider details out of the shared models and out of the UI.
- **Resolve streams at play time, never ahead.** Stalker `create_link` URLs are short-lived. `Source.resolve` / `resolveMedia` are called right before playback.
- **Liveness is provider metadata, not inferred.** `StreamInfo.isLive` is set by the `Source`. Don't guess from stream duration (an HLS live window looks finite). Live = no seek bar.
- **Secrets must never reach logs, on-screen errors, or exported diagnostics.** Provider URLs and errors carry credentials. Use `redactUrl` (`lib/data/net.dart`) for any URL that goes into an error/log; Stalker additionally uses `redactStalkerDiagnostic` / `_redactUrl` for MAC/Bearer tokens. The diagnostics log is user-exportable — assume anything you log may be shared for support.
- **HTTP timeouts.** All `HttpClient`s set `connectionTimeout` (TCP handshake only). For the response, use `response.readBytes()` and `.timeout(kHttpReadTimeout)` on `request.close()` (both in `lib/data/net.dart`) — `connectionTimeout` does **not** cover a server that connects then stalls mid-body.

## TV / remote navigation

The app targets Android TV (the universal APK) and must be fully D-pad-navigable, not just touch/mouse. Conventions:

- **Lists/grids** use `FocusableCard` (`lib/widgets/focusable_card.dart`): a `FocusableActionDetector` tile that shows an accent focus ring, activates on OK/Enter/Select (`ActivateIntent`), and scrolls itself into view on focus. First item gets `autofocus`.
- **Text inputs** use `TvTextField` (`lib/widgets/tv_text_field.dart`) — never a bare `TextField` on a TV-facing screen. A plain `TextField` traps D-pad focus (its editor eats the arrow keys). `TvTextField` is an **"OK to edit" cell**: in traversal it's one focusable stop the D-pad passes over; OK/Select (or tap) enters edit mode (the inner field — `ExcludeFocus`'d + `IgnorePointer`'d until then — takes focus and the keyboard opens); the IME action or **Back** (via `PopScope`, *not* `BackButtonListener`, which needs a `Router` this app doesn't have) exits edit and returns focus to the cell. Applied to the channel search box and every `sources_screen` credential/config field.
- **The same "OK to edit" model** governs the player's sliders (see Player) — focus passes them freely; OK enters adjust mode.
- **Content-kind selector** (`channel_list_screen` `_ContentTabs`) is a focusable chip strip (not `SegmentedButton`), the natural top of the focus order. AppBar actions and the body are each wrapped in a `FocusTraversalGroup` so D-pad arrows stay within the body instead of jumping sideways into the app bar (Flutter's directional traversal is geometry-based).

## Cloud sync (optional source panel)

A **web panel** lets users manage their source list with a real keyboard instead of a TV remote;
devices then **pull** it down with no on-device login. It's entirely optional — when the Supabase
build config is absent the feature hides itself and the app is unchanged.

- **Backend**: Supabase (the only free option bundling Postgres + Auth + RLS + a client SDK that's
  safe to call directly from a static page). Schema + the entire security boundary live in
  [`supabase/migrations/`](supabase/migrations/) (timestamped `<version>_<name>.sql`, the first is the
  schema + RLS) — read the first file's header before changing it. Four tables (`sources`,
  `metadata_configs`, `devices`, `pairings`) with **deny-by-default RLS** (no policy = no access) and
  three `SECURITY DEFINER` pairing RPCs. Migrations are applied to the live project and re-applying is
  idempotent; the Supabase GitHub integration auto-applies new ones on push.
- **Open-source security model**: the Supabase URL + **anon/publishable** key ship in the app and the
  panel (safe *by design* — access is gated only by RLS). The `service_role` key must never appear in
  any client or this repo. Devices authenticate as **anonymous** Supabase users and are read-only by
  construction (write policies require `is_real_user()`); they gain read access only after a real
  account claims their pairing code (`claim_pairing`). Pairing codes are short-lived + rate-limited.
- **Pairing flow (code-based, works on every platform)**: the device shows a code
  ([`cloud_sync_screen.dart`](lib/screens/cloud_sync_screen.dart)); the user enters it in the panel's
  Devices page; the device polls `pairing_status` until claimed, then pulls.
- **Flutter side**: [`cloud_config.dart`](lib/data/cloud_config.dart) (build-time `--dart-define`
  `SUPABASE_URL`/`SUPABASE_ANON_KEY`/`PANEL_URL`; `isConfigured` gates the whole feature),
  [`cloud_sync.dart`](lib/data/cloud_sync.dart) (`CloudSync`: anon session, pairing, **read-only**
  `pullSources`/`pullMetadata` that write through the existing `SourceStore` — cloud-managed source
  ids are tracked in secure storage so a pull replaces the managed set but leaves local-only sources
  alone), and [`secure_local_storage.dart`](lib/data/secure_local_storage.dart) (persists the Supabase
  session in the keychain, not plaintext prefs). Init is in `main.dart`, behind `isConfigured`. The
  pure row→`SourceConfig` mapper `cloudRowToConfig` is unit-tested in `test/cloud_sync_test.dart`.
- **Web panel**: [`panel/`](panel/) — a tiny Vite + `@supabase/supabase-js` SPA (no framework).
  Field shapes mirror `SourceConfig` per kind. Deployed to **GitHub Pages** by
  [`.github/workflows/pages.yml`](.github/workflows/pages.yml) (Supabase values from repo Variables).
  Note: the Flutter web target lives in `web/`; the panel deliberately lives in `panel/`.

## Database migrations

`AppDatabase` is at `schemaVersion = 8`. When changing the schema: bump `schemaVersion`, add an `onUpgrade` branch, and make new tables/columns idempotent (`CREATE TABLE IF NOT EXISTS`, the `_isDuplicateColumn` guard for `ALTER`). Note the design: upgrading from before v3 calls `_createMediaTables`, which builds the *current* media schema, so the later `oldV >= 3` ALTER branches are intentionally skipped for those users — so **any table `_createMediaTables` doesn't create must also have an `oldV < N` repair branch**, or fresh installs and pre-v3 upgrades miss it. (This was the v7 `external_metadata` bug: it was created only in the `oldV >= 3 && oldV < 7` branch, so fresh installs landed at v7 without it and every metadata query crashed; v8 adds it to `_createMediaTables` and an `oldV < 8` repair branch.) `AppDatabase.openAt(path)` is a `@visibleForTesting` seam that opens/migrates a DB without `path_provider` — used by `test/persistence_test.dart`.

## Player

`player_screen.dart` plays a resolved `StreamInfo` via `media_kit`, with two platform-specific native-HDR paths layered on top of the embedded path:

- **Android** — hands off to a native HDR player via the `iptvs/native_hdr_player` MethodChannel (`open`); falls back to the embedded `media_kit` surface if unavailable. The native player is a self-contained `ComponentActivity` (`android/app/src/main/kotlin/.../HdrPlayerActivity.kt`) that hosts a **pluggable `PlaybackEngine`** (`.../player/`) behind a **Jetpack Compose overlay**, and uses **two engines**:
  - **`ExoPlayerEngine` (default)** — ExoPlayer/Media3 + MediaCodec hardware decode into a `PlayerView` (SurfaceView-backed). This is what gives **true HDR** (HDR10/HDR10+/HLG/DV-P8) on capable devices/displays, because the hardware decoder's HDR metadata reaches the compositor directly.
  - **`MpvEngine` (fallback)** — wraps libmpv (`dev.jdtech.mpv:libmpv`, gpu-next/libplacebo, `MpvController.kt`) in a `SurfaceView`. Used **only** when ExoPlayer can't decode the video track (`ExoPlayerEngine.detectUnsupportedVideo`/decoder error → `onUnsupportedVideo` → `HdrPlayerActivity.fallbackToMpv()`) — chiefly **Dolby Vision Profile 5** (single-layer, no HDR10 base) on non-DV hardware (e.g. Samsung Galaxy), which mpv software-reshapes (`hwdec=no`) and **tone-maps to SDR** (mpv's GL render path can't signal HDR to an Android surface). The fallback is device-aware: on DV-capable hardware ExoPlayer handles DV in hardware and it never fires. **DV P5 reshaping needs a libplacebo built with `libdovi`** (the stock `dev.jdtech.mpv:libmpv` lacks it → green/magenta), so the app vendors a **libdovi-enabled AAR** at `android/app/libs/libmpv-dovi.aar` (`implementation(files(...))`, committed via Git LFS, ~48 MB) — built from the fork [`GCHOfficial/libmpv-android@libdovi`](https://github.com/GCHOfficial/libmpv-android/tree/libdovi) (the source of truth; forked off the v1.0.0 tag for `MPVLib` API parity). Recipe + rebuild in [`android/app/libs/README.md`](android/app/libs/README.md) + `android/app/libs/fork/`. `jniLibs.pickFirsts` keeps this `libmpv.so` over media_kit's (verify it has `pl_dovi_metadata`).

  Both engines drive the same engine-agnostic `PlayerUiState` and respond to the same `PlayerCallbacks`; the overlay (`PlayerControls`, `ListMenu`, `InfoPanel`, `PlayerTheme`, `PlayerUiState`) is at parity with the Windows overlay — play/pause, ±10s, mute/volume, scrubber, audio/subtitle/speed list-menus, aspect cycle, info panel, contextual hiding, and **D-pad nav** (single-press Back peels menu→info→hide→exit via the root `onPreviewKeyEvent`/`BackHandler`; sliders are custom "OK to edit" controls, not Material `Slider`, so the D-pad isn't trapped). Top-right **badges**: resolution, HDR, FPS, source name, and a clock (clock on TV only — `UiModeManager`). **Live extras**: an EPG now/next + programme-progress strip where the VOD scrubber sits, and a **"Go to live"** control (shown once behind the edge) that reloads the source to the live edge; the LIVE badge greys when behind. Most control logic lives in Kotlin, but the Dart `open` call now passes `title`/`sourceName`/`isLive`/EPG now-next/headers/subtitles, and `MainActivity` calls back `nativeClosed` so the Dart route pops on exit. FPS comes from `Format.frameRate` when present, else is **measured** from ExoPlayer's rendered-frame counter (most IPTV streams omit it). **Dynamic range** (the info-panel "Dynamic range" + HDR badge) is read from the **decoder's output `MediaFormat`** via a custom `HdrRenderersFactory`/`MediaCodecVideoRenderer` (`player/HdrRenderersFactory.kt`, `onOutputFormatChanged` → `KEY_COLOR_TRANSFER`/`KEY_COLOR_STANDARD`/`KEY_HDR10_PLUS_INFO`), **not** from `Format.colorInfo` — for HEVC-over-MPEG-TS the HDR signalling is in the in-band VUI/SEI the TS extractor drops, so `colorInfo` reads SDR while the decoder/HDMI go HDR. The decoder value is authoritative (matches a system HDMI-InfoFrame overlay) and is the only source that distinguishes **HDR10+** (per-frame `KEY_HDR10_PLUS_INFO`) from HDR10; `Format.colorInfo` remains the fallback until the decoder reports. `PlayerTheme` mirrors `lib/theme.dart` tokens; Inter is bundled in `res/font`. Note: both media_kit and the libmpv AAR ship `libmpv.so` — `app/build.gradle.kts` `packaging.jniLibs.pickFirsts` keeps the libplacebo one; minSdk is raised to 26 (libmpv requirement).
- **Windows** — renders into a native HWND surface (`createSurface`) so mpv presents directly through D3D11 (real HDR) instead of round-tripping through Flutter's SDR texture (`vo=gpu-next`, `gpu-context=d3d11`, `hwdec=auto-safe` — `auto-safe` negotiates d3d11va zero-copy and falls back to software cleanly; a *forced* `d3d11va` could half-init and desync). Control state is mirrored to native via `setControlState` (Dart→C++) / `nativeControl` (C++→Dart commands); the GDI overlay (`windows/runner/flutter_window.cpp`) draws the **same control set, badges, live EPG strip, go-to-live, and "Reconnecting…" indicator** as the Android Compose overlay. The controls overlay is a layered window clipped to a region covering only the top+bottom bars (+ open menu/info), so anything drawn must fall inside it — `UpdateNativeControlState` rebuilds the region when the bar height changes (e.g. the taller live-EPG bar). **Dynamic range** here comes from mpv's `video-params` (`gamma`/`primaries`/`colormatrix`, in `_dynamicRangeLabel`) — mpv/libavcodec already parse the in-band VUI/SEI, so this matches the decoder-authoritative Android path for SDR/HDR10/HLG/DV without the `Format.colorInfo` gap. **HDR10+** is best-effort (mpv exposes no clean flag): `_probeHdr10Plus` reads the ST2094-40 per-scene sub-properties (`video-params/scene-max-r|g|b`, `scene-avg`) — non-zero only with real dynamic metadata, and *not* synthesised by `hdr-compute-peak` (so no false-positive on plain HDR10) — and upgrades PQ→"HDR10+ · PQ"; any missing property/error stays at "HDR10". Older mpv builds without those sub-properties simply under-report (HDR10).
- **Other platforms / fallback** — embedded `media_kit_video` controls, with mpv asked to tone-map HDR into SDR.

**Live auto-reconnect.** A live stream that stalls (buffering) or drops (error/EOF) is reconnected by **reloading the source** with capped backoff (≈8s stall threshold, ≤30s between attempts), surfacing a "Reconnecting…" indicator until playback resumes — VOD is untouched (it keeps the manual error/Retry overlay). Two independent watchdogs because the two platforms play through different stacks: Android in `HdrPlayerActivity` (its 500ms progress ticker watches `PlayerUiState`; ExoPlayer network errors that leave it idle trigger an immediate reconnect); Windows/embedded in `player_screen.dart` (a 1s `Timer` watching media_kit's buffering/error streams — the Dart `_player` only plays on these paths). The same **reload** is how "Go to live" works, since live IPTV is typically non-seekable.

Playback headers (e.g. a MAG `User-Agent` / `Referer` for Stalker) are passed both to `Media(httpHeaders:)` and set as mpv `user-agent`/`referrer` properties. All playback logs go through `_logPlayback`, which redacts URLs via `_redactPlayback`.

## Testing notes

- Mostly pure-logic / persistence unit tests; use `DemoSource` or a small fake `Source` rather than hitting the network. There are a few real widget tests (`test/tv_text_field_test.dart`) — keep these green when touching `TvTextField` (one guards that it builds under a plain `Navigator`, the regression that caught the `BackButtonListener`/`Router` crash).
- The data layer is well covered: Stalker series/episode parsing, Xtream mapping & paging, XMLTV, redaction, metadata config, source-hint language detection (`widget_test.dart` — still mostly logic tests despite the name); redaction + DB migrations + repository cache behaviour (`net_test.dart`, `persistence_test.dart`).
- **Known gap:** migration coverage exercises v1→8, fresh-create, and the v7→8 `external_metadata` repair, but not the v3→7 ALTER/`media_page_state` rebuild branches (reconstructing the exact v3 schema in a test is fiddly). Worth adding if those paths change.
