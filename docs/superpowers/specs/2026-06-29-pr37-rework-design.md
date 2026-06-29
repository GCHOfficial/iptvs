# PR #37 rework — expiry, M3U⇄Xtream, player/EPG/Windows UI

**Date:** 2026-06-29
**Source:** Reworks the good ideas from fork PR #37 (`vladskz`) to fit this repo's
conventions. Original author credited via `Co-Authored-By` on the relevant commits.

## Motivation

PR #37 bundles three good ideas but isn't mergeable as-is: `flutter analyze` fails
(16 issues), `flutter test` fails (the author's own named-date test is red), an
`XtreamSource` is leaked inside `M3uSource`, full credential-bearing URLs are logged,
and several player changes are accidental regressions. The ideas are worth keeping;
this spec reworks them so they respect the layering ("everything provider-specific
goes through the `Source` interface"), pass CI, and don't regress existing behavior.

## Delivery

One feature branch, **three independent commits**, opened as our own PR (the fork's
history is messy). Each commit must leave `flutter analyze` clean and `flutter test`
green on its own.

1. M3U⇄Xtream interchange
2. Subscription expiry on the `Source` interface
3. Player / EPG / Windows overlay UI

---

## 1. M3U ⇄ Xtream interchange (convert at add-time)

**Problem it solves:** an "M3U" source whose URL is really an Xtream `get.php` panel
currently only exposes flat channels — no Movies/Series, even though the same
host+credentials serve `player_api.php` (structured VOD/series) and `xmltv.php` (EPG).

**Approach:** detect and convert at the point the source is added/saved, not at runtime.

- **Shared helper** `XtreamCredentials? xtreamCredentialsFromUrl(Uri uri)` — a single
  implementation (in `xtream_source.dart`), replacing the two duplicated copies the PR
  added (`m3u_source.dart` `_extractXtreamCredentials` + `expiry_service.dart`
  `extractXtreamCredentials`). Extracts host (`scheme://host[:port]`), username, password
  from either `userInfo` (`http://user:pass@host/...`) or query params
  (`username`/`password`). Returns null when host/username/password aren't all present.
- **Conversion in the add/edit save path** (the source-add screen / `sources_screen`
  save flow): when the chosen kind is M3U and `xtreamCredentialsFromUrl` succeeds,
  **probe `player_api.php`** with those creds. If it returns a valid Xtream `user_info`
  response, persist the source as `SourceKind.xtream` (label preserved). If the probe
  fails or times out, keep it as a flat `M3uSource` — pure static playlists are
  unaffected.
- **`M3uSource` reverts to channels-only**: remove the embedded `XtreamSource`, the
  delegation in `connect`/`epg`/`media*`/`resolveMedia`, and the `dispose` leak. The
  `unnecessary_non_null_assertion` and `library_private_types_in_public_api` warnings
  disappear with it.

**Data flow:** add-source UI → `xtreamCredentialsFromUrl` → probe `player_api.php` →
on success rewrite `SourceConfig{kind: xtream, fields:{host,username,password}}` →
`SourceStore`. From then on it's an ordinary Xtream source everywhere (paging, VOD,
series, EPG, expiry) with zero new code paths.

**Edge cases:** get.php with `type=m3u_plus`/`output=...` extra params (ignored);
creds in userInfo vs query; panel on a non-standard port; `player_api.php` disabled on
some panels (→ stays M3U). Probe uses the existing `net.dart` timeout helpers.

**Testing:** `xtreamCredentialsFromUrl` is pure → unit-tested (adapt the PR's
`m3u_xtream_conversion_test.dart`) covering userInfo form, query form, missing creds,
ports, and non-Xtream URLs. The probe is network and is not unit-tested (kept thin).

---

## 2. Subscription expiry (on the `Source` interface)

**Problem it solves:** users can't see when a subscription expires.

**Approach:** a capability method on the domain interface, implemented by the providers
that have the data, reusing their existing auth.

- **Interface:** add `Future<DateTime?> subscriptionExpiry()` to `Source` with a
  **default implementation returning `null`** (= unsupported/unknown). M3U and Demo
  inherit the default. No `config.kind` switching anywhere.
- **Delete the standalone `ExpiryService`** class and its duplicated Stalker/Xtream HTTP
  (the second copy of the MAG handshake). Only its pure date parser survives, moved to
  `lib/sources/expiry.dart`.
- **`XtreamSource.subscriptionExpiry`:** `player_api.php` → `user_info.exp_date`
  (Unix ts or date string) via a shared date parser. Reuses the source's host/creds.
- **`StalkerSource.subscriptionExpiry`:** reuses the source's **existing** handshake +
  `account_info`/`get_main_info` flow (no second copy of the MAG handshake). Scans the
  known expiry field names + `tariff.expire_date`.
- **Redaction:** all URLs/errors go through the providers' existing `redactUrl` /
  `redactStalkerDiagnostic`. No raw credential-bearing URL is ever logged — fixes the
  PR's `debugPrint('...$url')` violations.
- **Date parsing:** extract the pure parser (`parseExpiryValue`) into a small standalone
  module (`lib/sources/expiry.dart`) used by both `XtreamSource` and `StalkerSource`.
  Keep only the formats these providers actually emit: **Unix timestamp** (seconds or
  ms) and **ISO-8601 / `YYYY-MM-DD[ HH:MM:SS]`** (via `DateTime.tryParse` with a
  `space→T` normalization). **Remove the speculative named-month parsing**
  (`_parseNamedMonthDate`, `_parseNonIsoDate`, the named-month regex branch) and delete
  `test/expiry_service_named_date_test.dart` — Xtream returns a Unix `exp_date` and
  Stalker returns ISO-style dates, so "June 19, 2026" is a format neither provider
  produces. This removes both the `unused_element` warnings and the failing test in one
  stroke. (If implementation surfaces a real provider using another format, add it then,
  with a test.)
- **UI:** keep the PR's `_ExpiryBadge` in `sources_screen` (loading shimmer / date /
  "expired" / "unavailable" / "unknown" states). Build each source from its config and
  call `subscriptionExpiry()`. **Trigger: lazy per-card fetch on first display** — each
  card fetches its own expiry when it first becomes visible, never an automatic fan-out
  to every provider on screen open. Results cached in screen state keyed by source id,
  pruned on delete, re-fetched on edit.

**Testing:** the pure date parser is unit-tested, including the previously-failing
`'June 19, 2026, 8:34 pm'` case. Provider methods use a fake/`DemoSource` default for the
`null` path; live HTTP isn't unit-tested.

---

## 3. Player / EPG / Windows overlay UI

**Keep (cleaned up):**
- Next-programme **start–stop time labels** on the channel-list tile.
- Player **title** now/next info — formatted as a clean time range (e.g.
  `20:00 – 21:00 · <title>`), carrying the same information the dropped overlay box did.
- Live **EPG strip** enrichment: next-programme interval (`Next · HH:MM – HH:MM ·
  <title>`) across **all three renderers** — see Cross-platform parity. This is how we
  "make existing EPG info as informative without a separate box."
- Control **backdrop** (`backdropColor` ~20% black) on the embedded controls.
- **Restore-list-focus-after-playback** (channel_list_screen): on returning from the
  player, refocus the last-played item when still visible, else the first item — a real
  TV-UX win. Keep with its focus nodes disposed correctly.

**Revert (accidental regressions in the PR):**
- Aspect modes back to **Fit / Fill / 16:9 / 4:3** (PR cut to 2).
- Speeds back to **0.5 / 0.75 / 1.0 / 1.25 / 1.5 / 2.0** (PR cut to 4).
- Initial `_aspectModeIndex` back to **Fill (1)** to match the native surface's
  `panscan=1.0` (PR's `0`/Fit caused a UI↔native mismatch).
- Drop `FocusScope.of(context).nextFocus()` after play/pause (fixes the 5
  `use_build_context_synchronously` warnings and the focus-wander).
- Restore the explanatory comments the PR deleted (aspect/panscan rationale, HDR10+
  detection, TV focus-chain, cloud-sync `_move` note).

**Drop:**
- `lib/player/now_programme_overlay.dart` and its always-on placement — replaced by the
  enriched title/strip above. Remove the leftover unused `_LivePill`.

**Windows overlay (`flutter_window.cpp`) — keep, with verification caveat:**
- D-pad **focus navigation** for the GDI overlay (`NativeFocusItem`, focus index,
  `FocusableItems`, `CommandForFocusedItem`, `ApplyOverlayOwnedCommand`, active-button
  highlight) — brings Windows to parity with the Android Compose overlay (a stated repo
  goal).
- **Alpha-blended semi-transparent overlay** (32-bit DIB section + premultiplied alpha +
  `AlphaBlend`/`Msimg32.lib`) — matches the embedded backdrop.
- Info-panel accent **border**; removal of the now-redundant **Now/Next rows** from the
  native info panel (the strip already shows them).
- **Verification:** `clang -fsyntax-only` pass locally against Wine's Win32 headers
  (embedder headers stubbed) to catch C++ errors; authoritative compile via the CI
  Windows build job; **alpha rendering correctness must be visually verified on Windows
  by the maintainer** (cannot be checked on Linux).

---

---

## Cross-platform parity (must hold for every change)

The player overlay has **three renderers** that must stay in lockstep (CLAUDE.md: the
Android Compose overlay is "at parity with the Windows overlay"): the embedded
`media_kit` Flutter widgets, the Windows GDI overlay (`flutter_window.cpp`), and the
Android Compose overlay (`android/.../player/`). The PR enriched only Windows + the
embedded path and **left Android untouched** — this rework closes that gap.

- **EPG strip — next-programme interval.** The enriched format is
  `Next · HH:MM – HH:MM · <title>`, consistent across all three renderers and the
  channel-list tile:
  - Embedded Flutter (`player_screen` title / EPG line) — Dart.
  - Windows GDI strip (`epg_next_stop_ms` already plumbed by the PR) — C++.
  - **Android Compose `LiveEpgStrip`** (`PlayerControls.kt`) — currently renders
    `Next · <title>` only; update it to include the time range. `epgNextStopMs` is
    already passed over the MethodChannel and received as `EXTRA_EPG_NEXT_STOP`, so this
    is render-only — **Kotlin change the PR missed.**
- **Info panel — drop redundant Now/Next.** The PR removed the Now/Next rows from the
  Windows native info panel (the strip already shows them). Mirror this in Android
  `InfoPanel.kt` (the `state.epgNext?.let { add("Next" to it.title) }` row) for parity.
- **Dropped overlay box** (`NowProgrammeOverlay`) only ever rendered on the embedded
  Flutter path (Windows/Android draw native overlays on top), so removing it affects only
  that path; the enriched title/line replaces it there.
- **Expiry + M3U⇄Xtream** are pure Dart + HTTP through existing helpers — inherently
  platform-agnostic; they work identically on Windows, Android (phone + TV), and desktop.
- **Restore-list-focus-after-playback** is Flutter-level (`channel_list_screen`), so it
  applies on every platform and TV remotes without per-platform work.
- **Aspect/speed/focus reverts** restore the embedded-path controls; the native overlays
  keep their own (unchanged) aspect/speed menus, which already match the restored lists.

## Out of scope / non-goals

- No change to the playback resolution path, cloud sync, or database schema.
- No new Source kind; M3U-that's-Xtream becomes an ordinary Xtream source.
- No automatic background polling of expiry across all sources.

## Exit criteria

- `flutter analyze` reports **0 issues**.
- `flutter test` is green (incl. the named-date and M3U⇄Xtream unit tests).
- CI `analyze-test`, Windows build, and Android APK build all pass.
- EPG strip shows the next-programme time range identically on the embedded, Windows, and
  Android overlays (cross-platform parity holds).
- Maintainer visually verifies the Windows overlay alpha + D-pad nav on a Windows device,
  and the enriched EPG strip on an Android TV device.
