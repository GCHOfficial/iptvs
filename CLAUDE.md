# CLAUDE.md

Guidance for working in this repository. Keep it accurate — update it when the architecture changes.

## What this is

`iptvs` is a cross-platform Flutter IPTV player (Windows, Android, plus the usual Flutter desktop/mobile targets). It connects to user-configured IPTV providers, caches their channel/VOD/EPG data locally, enriches movie/series metadata from public APIs, and plays streams with libmpv (via `media_kit`) so it handles HEVC / AC-3 / MPEG-TS that an HTML video element can't.

There is no backend — the app talks directly to user-supplied provider panels and public metadata APIs.

## Commands

```bash
flutter analyze        # must be clean before committing
flutter test           # unit tests live under test/
flutter run -d windows # or -d android, etc.
```

The analyzer uses `package:flutter_lints`. CI expectation: `flutter analyze` reports no issues and `flutter test` is green.

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
- **`lib/screens/`** — UI. `home_shell.dart` resolves the active source and builds its repository; `channel_list_screen.dart` is the main browsing UI (live/movies/series, search, paging); `sources_screen.dart` manages provider configs; `diagnostics_screen.dart` views/export the in-memory log.
- **`lib/player/player_screen.dart`** — playback. See "Player" below.

## Key conventions

- **Provider-specific data rides in `extra`.** `Channel`/`MediaItem` carry a `Map<String,dynamic> extra` that only the owning `Source` interprets (Stalker `cmd`, Xtream stream id, etc.). Keep provider details out of the shared models and out of the UI.
- **Resolve streams at play time, never ahead.** Stalker `create_link` URLs are short-lived. `Source.resolve` / `resolveMedia` are called right before playback.
- **Liveness is provider metadata, not inferred.** `StreamInfo.isLive` is set by the `Source`. Don't guess from stream duration (an HLS live window looks finite). Live = no seek bar.
- **Secrets must never reach logs, on-screen errors, or exported diagnostics.** Provider URLs and errors carry credentials. Use `redactUrl` (`lib/data/net.dart`) for any URL that goes into an error/log; Stalker additionally uses `redactStalkerDiagnostic` / `_redactUrl` for MAC/Bearer tokens. The diagnostics log is user-exportable — assume anything you log may be shared for support.
- **HTTP timeouts.** All `HttpClient`s set `connectionTimeout` (TCP handshake only). For the response, use `response.readBytes()` and `.timeout(kHttpReadTimeout)` on `request.close()` (both in `lib/data/net.dart`) — `connectionTimeout` does **not** cover a server that connects then stalls mid-body.

## Database migrations

`AppDatabase` is at `schemaVersion = 7`. When changing the schema: bump `schemaVersion`, add an `onUpgrade` branch, and make new tables/columns idempotent (`CREATE TABLE IF NOT EXISTS`, the `_isDuplicateColumn` guard for `ALTER`). Note the design: upgrading from before v3 calls `_createMediaTables`, which builds the *current* media schema, so the later `oldV >= 3` ALTER branches are intentionally skipped for those users. `AppDatabase.openAt(path)` is a `@visibleForTesting` seam that opens/migrates a DB without `path_provider` — used by `test/persistence_test.dart`.

## Player

`player_screen.dart` plays a resolved `StreamInfo` via `media_kit`, with two platform-specific native-HDR paths layered on top of the embedded path:

- **Android** — hands off to a native HDR player via the `iptvs/native_hdr_player` MethodChannel (`open`); falls back to the embedded `media_kit` surface if unavailable.
- **Windows** — renders into a native HWND surface (`createSurface`) so mpv presents directly through D3D11 (real HDR) instead of round-tripping through Flutter's SDR texture; control state is mirrored to native via `setControlState`/`nativeControl`.
- **Other platforms / fallback** — embedded `media_kit_video` controls, with mpv asked to tone-map HDR into SDR.

Playback headers (e.g. a MAG `User-Agent` / `Referer` for Stalker) are passed both to `Media(httpHeaders:)` and set as mpv `user-agent`/`referrer` properties. All playback logs go through `_logPlayback`, which redacts URLs via `_redactPlayback`.

## Testing notes

- Tests are pure-logic / persistence unit tests (no widget tests yet despite the `widget_test.dart` name). Use `DemoSource` or a small fake `Source` rather than hitting the network.
- The data layer is well covered: Stalker series/episode parsing, Xtream mapping & paging, XMLTV, redaction, metadata config, source-hint language detection (`widget_test.dart`); redaction + DB migrations + repository cache behaviour (`net_test.dart`, `persistence_test.dart`).
- **Known gap:** migration coverage exercises v1→7 and fresh-create, but not the v3→7 ALTER/`media_page_state` rebuild branches (reconstructing the exact v3 schema in a test is fiddly). Worth adding if those paths change.
