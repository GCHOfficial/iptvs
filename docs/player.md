# Player — full detail

`lib/player/player_screen.dart` coordinates a resolved `StreamInfo`, media_kit lifecycle, and two
platform-specific native-HDR paths. `lib/player/player_overlay.dart` contains the embedded
media_kit controls plus reconnect/error presentation. The compact rules live in CLAUDE.md; read
this before changing playback, preview, or overlay code.

## Android

Hands off to a native HDR player via the `iptvs/native_hdr_player` MethodChannel (`open`); falls
back to the embedded `media_kit` surface if unavailable. The native player is a self-contained
`ComponentActivity` (`android/app/src/main/kotlin/.../HdrPlayerActivity.kt`) that hosts a
**pluggable `PlaybackEngine`** (`.../player/`) behind a **Jetpack Compose overlay**, and uses
**two engines**:

- **`ExoPlayerEngine` (default)** — ExoPlayer/Media3 + MediaCodec hardware decode into a
  `PlayerView` (SurfaceView-backed). This is what gives **true HDR** (HDR10/HDR10+/HLG/DV-P8) on
  capable devices/displays, because the hardware decoder's HDR metadata reaches the compositor
  directly.
- **`MpvEngine` (fallback)** — wraps libmpv (`dev.jdtech.mpv:libmpv`, gpu-next/libplacebo,
  `MpvController.kt`) in a `SurfaceView`. Used **only** when ExoPlayer can't decode the video
  track (`ExoPlayerEngine.detectUnsupportedVideo`/decoder error → `onUnsupportedVideo` →
  `HdrPlayerActivity.fallbackToMpv()`) — chiefly **Dolby Vision Profile 5** (single-layer, no
  HDR10 base) on non-DV hardware (e.g. Samsung Galaxy), which mpv software-reshapes (`hwdec=no`)
  and **tone-maps to SDR** (mpv's GL render path can't signal HDR to an Android surface). The
  fallback is device-aware: on DV-capable hardware ExoPlayer handles DV in hardware and it never
  fires. **DV P5 reshaping needs a libplacebo built with `libdovi`** (the stock
  `dev.jdtech.mpv:libmpv` lacks it → green/magenta), so the app vendors a **libdovi-enabled AAR**
  at `android/app/libs/libmpv-dovi.aar` (`implementation(files(...))`, committed via Git LFS,
  ~48 MB) — built from the fork
  [`GCHOfficial/libmpv-android@libdovi`](https://github.com/GCHOfficial/libmpv-android/tree/libdovi)
  (the source of truth; forked off the v1.0.0 tag for `MPVLib` API parity). Recipe + rebuild in
  [`android/app/libs/README.md`](../android/app/libs/README.md) + `android/app/libs/fork/`.
  `jniLibs.pickFirsts` keeps this `libmpv.so` over media_kit's (verify it has
  `pl_dovi_metadata`).

**Buffer policy (time-to-first-frame).** `ExoPlayerEngine` builds its `ExoPlayer` with an explicit
`DefaultLoadControl` fed from the pure `ExoBufferPolicy` object (same file, pinned by
`ExoBufferPolicyTest`). Without it media3's defaults apply, and
`DEFAULT_BUFFER_FOR_PLAYBACK_MS = 2500` means **2.5s of black on every Android open** — zap,
EPG-grid play, *and* preview start, since `SharedEngine.openPreview` runs the same engine — plus
5s after every rebuffer. The tuned values are 1000 ms to start, 2000 ms to resume after an
underrun, a 15s/50s sustained window, and `prioritizeTimeOverSizeThresholds = true` (IPTV bitrates
vary too much between providers for a byte-based threshold to give a predictable startup budget).
The start/resume thresholds are a **floor, not a target**: a stream that can't reach the resume
threshold sits in `STATE_BUFFERING`, and 8s of that (`ReconnectPolicy.STALL_RECONNECT_MS`) makes
the Activity's watchdog reload the source — so pushing them toward the stall threshold would turn
ordinary underruns into a reconnect loop. The ≥4x margin between them is what the JUnit test pins,
along with the ordering `DefaultLoadControl.Builder` asserts at build time.

**The Dart embedded media_kit surface is a fallback only on Android.** `MainActivity`'s
`iptvs/native_hdr_player` `open` handler always replies `true` — engine selection, including the
mpv fallback, happens *inside* `HdrPlayerActivity` — so `_tryOpenNativeHdrPlayer` returns false
only when the channel itself fails (`MissingPluginException`, the 10s timeout, a
`PlatformException`). `PlayerScreen._nativePlaybackLaunched` therefore starts **true on Android as
well as Windows**, and `_playbackSurface` checks it *before* touching `_controller`: on the happy
path the `VideoController` and the `Video` widget tree are never built at all. That matters
because constructing an `AndroidVideoController` costs an `Utils.IsEmulator` channel round-trip, a
decoder query, a SurfaceTexture/ANativeWindow allocation and ~10 mpv property sets, all on the
main isolate during exactly the frames that decide time-to-first-frame. `_controller` is `late`
for this reason — **reading it is what constructs it** — so nothing may read it before the
fallback is genuinely taking over. The fallback branch in `_open` calls `_ensureEmbeddedController()`
(forcing the lazy build *before* `_configureNativePlayer` applies the embedded mpv options, since
`VideoController` creation sets `vo`/`hwdec` itself) and then flips the flag to false. The
media_kit `Player` itself stays eager (it's what `initState` wires every stream listener to) and
so its `ResourceCounters.mediaKitPlayers` accounting is unchanged.

Both engines drive the same engine-agnostic `PlayerUiState` and respond to the same
`PlayerCallbacks`; the overlay (`PlayerControls`, `ListMenu`, `InfoPanel`, `PlayerTheme`,
`PlayerUiState`) is at parity with the Windows overlay — play/pause, ±10s, mute/volume, scrubber,
audio/subtitle/speed list-menus, aspect cycle, info panel, contextual hiding, a **live-channel
favorite star** (see below), and **D-pad nav** (single-press Back peels menu→info→hide→exit;
sliders are custom "OK to edit" controls, not Material `Slider`, so the D-pad isn't trapped).

**Back has one Activity-owned policy.** `HdrPlayerActivity.dispatchKeyEvent` consumes hardware and
remote Back on both key-down and key-up before a focused Compose control can eat it; key repeat is
ignored so a held button peels only one rung. Gesture navigation reaches the Activity's lifecycle-
aware `onBackPressedDispatcher` callback; Compose does not register a second Back handler.
`PlayerBackGuard` rejects duplicate key/dispatcher callbacks within 120ms on TV images that route
one physical press through both paths. `handleSystemBack` then applies
`nextPlayerBackAction`: close menu → close info → hide controls → exit. Keeping the state change at
the Activity boundary prevents one physical press from being handled once by the Compose key path
and again by Android's Back dispatcher. The visible overlay Back arrow remains an explicit Exit
command rather than a system-Back gesture.

**Immersive fullscreen + display cutout.** `hideSystemUi()` uses
`WindowInsetsControllerCompat` with `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE` (the supported
equivalent of the old `SYSTEM_UI_FLAG_IMMERSIVE_STICKY`). The pre-API-30 `systemUiVisibility` flag
set was removed: under edge-to-edge enforcement (targetSdk 35+) its `LAYOUT_*` half is meaningless,
because `setDecorFitsSystemWindows` is disabled and the window is already edge-to-edge.
`WindowCompat.setDecorFitsSystemWindows(window, false)` is still called — it is what produces
edge-to-edge layout on API 26–34, and is the no-op on 35+, not the reverse.

The Activity sets `LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES` (API 28+) so video reaches the
physical edge of a notched phone instead of being letterboxed away from the cutout — the DEFAULT
mode letterboxes in landscape, which is the orientation a player is actually used in. That is safe
**only because the overlay insets itself**: `ControlsOverlay` keeps its scrim full-bleed but wraps
its control `Column` in `safeDrawingPadding()`, and the menus/info layer is wrapped as one group the
same way. So only video extends under the cutout, and a transient swipe-revealed system bar never
covers a control. When changing the overlay layout, keep new chrome inside one of those two inset
groups rather than aligning it against the raw window edge.

**On a TV that is not enough**, because `safeDrawingPadding()` reports zero insets on essentially
every Android TV while the panel may still crop. `PlayerDimens.TvEdgePadding` (40 dp) and
`TvEdgeExtraVertical` (+14 dp on the outer edge only) carry that job, selected through
`edgePadding(isTv)`/`edgeExtraVertical(isTv)` so phone and tablet geometry is byte-identical. The
numbers are derived, not chosen: a 1080p TV is a 960×540 dp layout, so the 5% guideline safe area
is 48/27 dp while the legacy worst-case crop is ~2.5% per side — **24 dp**, exactly where
`EdgePadding` already sat, i.e. the chrome was resting precisely on the crop line with no margin
at all. 40 dp is that 24 dp of crop coverage plus 16 dp of genuinely visible margin. The vertical
extra lands on the outer edge only so the bars don't grow taller on a 540 dp-tall layout. Two
bar-clearance offsets must track it — the info panel's `top` and `ListMenu`'s `bottom` — or on TV
the panel opens inside the taller top bar and the menu hides under the taller bottom bar. Still
**needs on-device confirmation**, ideally on one set with overscan deliberately enabled and one
modern set (to check it doesn't merely look wasteful).

**Live favorite star** (`PlayerUiState.canFavorite`/`isFavorite`, shown only for live channels):
the Dart host owns the favorites store, so it seeds the initial state via an Intent extra
(`EXTRA_CAN_FAVORITE`/`EXTRA_IS_FAVORITE`) and reads the final state back on exit
(`RESULT_FAVORITE`, relayed by `MainActivity` in the `nativeClosed` args) — the Activity toggles
its own `uiState.isFavorite` locally, since it has no live method channel to Dart. Dart applies the
returned value through the same `FavoritesController.toggle` the channel list uses, so an in-player
toggle shows up in the list on return. The embedded media_kit overlay carries the same star in its
top bar, toggling the store directly.
Top-right **badges**: resolution, HDR, FPS, source name, and a clock (clock on TV only —
`UiModeManager`). **Live extras**: an EPG now/next + programme-progress strip where the VOD
scrubber sits, and a **"Go to live"** control (shown once behind the edge) that reloads the source
to the live edge; the LIVE badge greys when behind. Most control logic lives in Kotlin, but the
Dart `open` call passes `title`/`sourceName`/`isLive`/EPG now-next/headers/subtitles, and
`MainActivity` calls back `nativeClosed` so the Dart route pops on exit.

**"Go to live" re-resolves through the same single-flight gate the reconnect watchdog uses**
(`ResolveGate` in `android/.../player/LiveResolve.kt`, `HdrPlayerActivity.withFreshLiveLocator`):
the currently-held locator may already be spent (a Stalker `play_token` the portal killed), and
two concurrent `create_link` calls would exceed a single-connection account, so whichever of "Go
to live" or the watchdog gets there first owns the round trip and the other bails. This makes
`pollLiveReconnect`'s early-return necessary, not just tidy: while a resolve is in flight, both
`ended` and `isBuffering` read `false` (the engine sits in its terminal state with no further
transition callback, and `reconnectLive` already cleared `ended` before the round trip started),
which the 500ms progress ticker would otherwise read as "healthy" and use to clear the
reconnecting chip and reset the backoff counter every single tick of the wait — so the ticker
checks `resolveGate.inFlight` and returns immediately whenever a re-resolve already owns the next
reload.

**The live EPG strip is one layout, shared by every overlay that draws its own chrome.** Where the
VOD scrubber sits, a live channel gets three stacked rows: the current programme's title with its
`HH:mm – HH:mm` range right-aligned opposite it, a thin elapsed-progress bar, then
`Next · HH:mm – HH:mm · title`. That is Kotlin `LiveEpgStrip`, iOS `epgStrip`, the Windows GDI
`epg_title`/`epg_time`/`epg_progress`/`epg_next` rects, and — since the Windows SDR/HDR parity fix —
Dart `EmbeddedPlayerControlsState._liveEpgStrip`. The **LIVE pill is a top-bar badge** in all of
them, and the badge cluster reads source, LIVE, resolution, HDR, fps, clock left to right. No guide
for the channel → the strip is dropped entirely (a bar frozen at 0.0 reads as "still loading"), and
only the pill remains.

The shared Flutter overlay used to do neither: it compacted now/next into one ellipsized line under
the *title* and put a `LIVE ▸ progress ▸ title` row where the strip belongs, so the two Windows
surfaces — which show the same channel to the same user, chosen only by whether the stream is HDR —
looked visibly different. The Windows GDI cluster was also the only one ordering its badges
fps/resolution/LIVE and writing `Next: title (HH:mm - HH:mm)`; both now match everything else.
Pinned by the "live EPG strip (parity with the native overlays)" group in
`test/player_overlay_test.dart`.

**The volume slider is a chip, so its focus is visible.** It is the one focus stop in the Compose
overlay that isn't a button, and its focused state used to be a 2 dp ring on a 14 dp thumb — walking
onto it with a D-pad read as "focus disappeared", the same symptom as the "Go to live" stranding
below but harmless. `SlimSlider(chip = true)` gives it the same rounded fill and focus colour as its
neighbours in the transport row. Opt-in, because the VOD scrubber spans the bar and stays a bare
track. One catch worth keeping: `ButtonBgFocused` **is** `Accent`, the slider's own fill colour, so a
focused chip draws its track and thumb in white instead — otherwise the value vanishes into its own
background.

**"Go to live" hands focus to play/pause before it disappears.** It is the only control in any
overlay that *removes itself while you are standing on it*: pressing it reloads to the live edge,
`liveSynced` flips true and the button leaves the tree. On Android TV that took the D-pad with it —
Compose had no focused node left inside the overlay, so no arrow key did anything until Back tore
the whole player down. `RightCluster` now moves focus to play/pause on the press, and again from an
`onDispose` if the button vanishes while focused for any *other* reason (the reconnect watchdog
reaching the live edge by itself). The Windows GDI keyboard ring had the same shape in a quieter
form — the ring is rebuilt every paint and the stale index silently pointed at whichever control
slid into that slot — so it parks `g_native_focus_index` on play/pause for the same command.
Verified on the TV emulator: pause → focus the chip → OK → the chip goes, the stream returns to the
live edge, and focus is on play/pause with the D-pad still walking the row.

**"Go to live" is labelled with the action, everywhere.** The control that jumps to the live edge
(shown only once playback is behind it) read **"LIVE"** on Android, iOS and Windows and
**"Go to live"** on Linux and the shared Flutter overlay, while *all five* already declared
"Go to live" as its accessible name. "LIVE" was the wrong half of that split: the top bar carries a
LIVE **status** badge that greys at the very moment this button appears, so the screen showed the
same word twice for two different things, and the one that was actionable said nothing about what
pressing it does. Every surface now renders a plain text chip reading `Go to live` — no icon, which
is what the other text buttons in that row (speed, aspect) already do; the Windows chip widened
54→92 px to fit. The shared overlay still collapses to an icon below `kCompactControlsWidth`, a
width no native surface reaches. Confirmed on the TV emulator by pausing a live stream (LIVE badge
greys, `Go to live` appears leftmost in the right cluster).

**Badge *labels* are one contract too**, not just their order: `4K`/`1440p`/`1080p`/`720p`/`SD` on
deliberately loose thresholds (a 1088-tall stream is 1080p), a compact `DV`/`HDR10+`/`HDR10`/`HLG`/
`HDR` — **nothing at all for SDR** — `50fps`/`23.976fps` with no space, a source name truncated at
20, and a dated `Sat 8 Aug · 16:02` clock — **unpadded day** — on the pointer/TV surfaces (bare
`HH:mm` under `touch`, matching the iOS controller; the GDI overlay needs MSVC's `%#d` for that,
and the Lua one builds it from `os.date('*t')` because `os.date`'s `%a`/`%b` are locale-dependent). Kotlin `PlayerUiState`, Swift `BadgeFormatting`, the GDI
`ResolutionBadge`/`HdrBadge`/`FpsBadge` and Dart's top-level `resolutionBadgeLabel`/`hdrBadgeLabel`/
`fpsBadgeLabel`/`sourceBadgeLabel`/`playerClockLabel` (`player_overlay.dart`, pure and directly
tested) all implement it. The shared overlay previously printed `3840×2160`, `50.00 FPS`, the *full*
dynamic-range label and a bare `SDR` badge no other surface shows; the GDI overlay had drifted to an
exact `h >= 1080` tier test (calling a 1088-tall stream 720p), `25 fps`, and a 22-character source
truncation. `FormatFps` keeps its spaced form for the info panel's "Frame rate" **row** — the
natives split badge and reading form the same way.

**The Linux Lua OSD is on the same layout** (`linux/mpv/iptvs_overlay.lua`, the Wayland-HDR window):
the programme line under the title is gone, the LIVE pill moved into the top-bar badge run
(`live_pill_badge`, right-anchored to match `badge`'s contract), the badges use the shared compact
labels (`resolution_badge`/`hdr_badge`/`fps_badge`/`source_badge`/`clock_badge` — `dynamic_range()`
still returns the *full* label for the info panel), and the bottom bar draws the three-row strip.
`bottom_h` grows by `px(34)` **only** for live-with-guide, which keeps the old gap between the strip
and the transport row; the scrim takes `bottom_h` and the list menu already anchors to `by`, so both
follow for free. Everything is in `px()`/`fs()`, which scale with window height, so the info panel
can't collide with the taller bar at any size.

**It is also the first Linux OSD change with a test.** `linux/mpv/overlay_layout_test.lua` stubs the
three mpv modules the script requires, renders a frame per scenario and asserts on the emitted ASS
events — row order, the badge order, the strip clearing the transport row, no raw `1920×1080` or
`50.00 FPS`, VOD keeping its scrubber. `lua linux/mpv/overlay_layout_test.lua` runs anywhere Lua 5.1
does (mpv's own dialect), and CI now runs it plus `luac5.1 -p` in `analyze-test`: before this,
nothing anywhere executed the script, so a syntax error or a layout regression could ship. It proves
the geometry is *ordered and clear*, not that it *looks right* — the Wayland+HDR session check is
still outstanding.

**FPS** comes from `Format.frameRate` when present (container-declared, authoritative); otherwise
it's derived **once** from a short burst of real frame-presentation timestamps
(`ExoPlayer.setVideoFrameMetadataListener`, `ExoPlayerEngine.onVideoFrameMetadata` — median of
`FRAME_SAMPLE_TARGET` consecutive intervals, snapped to a standard rate), then frozen — not a
continuously re-measured/live-jittery number. Falls back further to the older
rendered-frame-counter/wall-clock heuristic (`measureFps`) only if the frame-timestamp method
never converges for a given device/stream.

**Dynamic range** (the info-panel "Dynamic range" + HDR badge) is read from the **decoder's
output `MediaFormat`** via a custom `HdrRenderersFactory`/`MediaCodecVideoRenderer`
(`player/HdrRenderersFactory.kt`, `onOutputFormatChanged` →
`KEY_COLOR_TRANSFER`/`KEY_COLOR_STANDARD`/`KEY_HDR10_PLUS_INFO`), **not** from `Format.colorInfo`
— for HEVC-over-MPEG-TS the HDR signalling is in the in-band VUI/SEI the TS extractor drops, so
`colorInfo` reads SDR while the decoder/HDMI go HDR. The decoder value is authoritative (matches a
system HDMI-InfoFrame overlay) and is the only source that distinguishes **HDR10+** (per-frame
`KEY_HDR10_PLUS_INFO`) from HDR10; `Format.colorInfo` remains the fallback until the decoder
reports. `PlayerTheme` mirrors `lib/theme.dart` tokens; Inter is bundled in `res/font`.

Note: both media_kit and the libmpv AAR ship `libmpv.so` — `app/build.gradle.kts`
`packaging.jniLibs.pickFirsts` keeps the libplacebo one; minSdk is raised to 26 (libmpv
requirement).

## iOS

**Status: implemented; on-device validation pending — see docs/ios.md for the full design,
decision record, and on-device test protocol.** Its overlay tracks Android's control set with two
deliberate differences: it carries an **`AVRoutePickerView`** (the only control in the app with no
Android counterpart — AirPlay is an AVFoundation capability no other platform here has), and its
"a pinned overlay never auto-hides" rule has an iOS-only third rung, the route sheet, because
AVKit presents that itself and nothing inside it reaches `pokeControls`. Its clock badge is
deliberately not TV-gated the way Android's is. Details and the on-device checklist are in
docs/ios.md. iOS gets a native surface too, the same shape as Android and Windows:
`IptvsPlayerViewController` (`packages/iptvs_ios_player/`) is a **presented** `UIViewController`
owning an `AVPlayerLayer` — `.overFullScreen`, not `.fullScreen` (the latter delivers a Flutter
`AppLifecycleState` transition to the preview-stop observer, the update flow, and the
cloud-sync timers, none of which should fire just because the player opened),
`isModalInPresentation = true` (exit is always explicit — see docs/tv-navigation.md), and its
own chrome built for parity with the Android Compose overlay and the Windows GDI overlay rather
than the stock `AVPlayerViewController` controls (rejected — the Back ladder, control-visibility
observability, and custom-control layering all needed a seam the stock class doesn't expose; see
docs/ios.md "Why not `AVPlayerViewController`").

- **Two engines, chosen in Dart.** `selectIosEngine` (`lib/player/ios_engine.dart`) is a pure
  function of the resolved URL — the trigger is the container, which Dart already knows from the
  resolved locator — mirrored defensively in Swift (`EngineSelection.swift`'s `selectEngine`,
  which only rejects an impossible scheme and never overrides Dart's choice). **AVPlayer**
  (default) plays HLS and MP4/fMP4 and is the only path to real HDR10/HLG/Dolby Vision, PiP,
  AirPlay, and lock-screen controls. **libmpv via media_kit** (fallback) plays everything else —
  raw MPEG-TS, MKV, non-HTTP schemes — always tone-mapped SDR on iOS (`libmpv-darwin-build`
  forces 10-bit VideoToolbox output down to 8-bit BGRA under `TARGET_OS_IPHONE`; no PiP). An
  extension-less locator (Stalker/MAG `create_link`) routes to mpv by default, so a Stalker
  portal gets HDR only when `create_link` happens to return an `.m3u8` URL — see docs/ios.md for
  the full routing table and the coverage-asymmetry argument behind the extension-less default.
  Every `PlayerScreen` open passes a stable `iosEngineKey` (`channel_list_screen.dart`:
  `channel.id` for live, `item.id` for VOD, `'catchup:${channel.id}'` for catch-up), which
  `_handleIosEngineFailed` feeds into `IosEngineMemo.markMpvOnly` on an AVPlayer failure —
  deliberately scoped per call site so an archive-container failure can never downgrade the live
  channel to mpv, or vice versa; a null key is a documented opt-out, never a wildcard.
- **`iosManageAudioSession: false` is set at both `PlayerConfiguration` sites** —
  [player_screen.dart:291](../lib/player/player_screen.dart#L291) and
  [live_preview_controller.dart:113](../lib/screens/live_preview_controller.dart#L113) — done, not
  pending: the option defaults to `true`, and mpv's `ao_audiounit` driver unconditionally calls
  `AVAudioSession.setActive:` on init/dispose otherwise, clobbering AVPlayer's session state
  (background audio, lock-screen controls) on every mpv engine teardown. `media_kit` is
  git-pinned to the merge commit carrying the option (media-kit/media-kit PR #1419, unreleased on
  pub.dev — docs/ios.md Constraint 1). Both sites construct a `PlayerConfiguration`
  independently — the option is inert off iOS, so this is a one-line invariant to preserve at
  each site, not a runtime-configurable thing to get wrong once and fix everywhere.
- **`engineFailed` is a cross-language handoff, not an in-process swap — and its reopen is gated,
  not immediate.** Android's `HdrPlayerActivity.fallbackToMpv()` switches `PlaybackEngine`
  implementations inside the same Activity, because both engines are reachable from Kotlin. On iOS
  libmpv is only reachable from Dart, so a Swift-detected AVPlayer failure (hard failure,
  never-started-within-10s, or started-but-never-showed-a-picture) tears down
  `IptvsPlayerViewController` and
  dismisses it; Dart re-resolves first for live (the failed AVPlayer attempt already burned the
  single-use Stalker `play_token`) and then reopens the same content on the embedded media_kit
  surface — but only once `decideIosFallbackAction` (`lib/player/player_screen.dart`) says
  something of this route is actually visible. The gate vetoes on any of three opinions (native
  PiP state, native app-active state, Flutter's own lifecycle — a `null` opinion is an absence,
  never a veto) and **cannot dead-end**: it re-evaluates on every Flutter lifecycle edge, on every
  native `hostVisibility` event, on a 1 Hz poll while pending, and after `kIosFallbackSurfaceAfter`
  (10s) it surfaces the error/Retry overlay while still waiting — a tap is the strongest visibility
  proof there is, since an off-screen route can't be tapped. One visible black beat on the happy
  path, on a route the routing rules already keep rare; see docs/ios.md "What routes to which
  engine" for the full gate design.
- **`resolveAgain` round-trips on reconnect and "Go to live"**, single-flight with each other via
  Swift's own gate — the same shape Android's watchdog now shares (see "Android" and "Live
  auto-reconnect" below); iOS was designed with the round trip from the start rather than
  retrofitted.
- No hardware Back: the Back ladder is expressed through gesture + an explicit exit control — see
  the iOS paragraph in docs/tv-navigation.md's Back-ladder section.
- **`setControlState` is no longer Windows-only** — `_drivesNativeControlState`
  (`lib/player/player_screen.dart`) is true for Windows (once its HWND exists) *and* iOS (once
  `IptvsPlayerViewController` owns playback), and the payload Dart pushes is split in two:
  `_presentationControlState()` — title, source name, EPG now/next, `isLive`/`liveSynced`,
  favorite state, `reconnecting` — is sent to **both** platforms, while the transport half
  (`playing`, `positionMs`/`durationMs`, volume, track lists, speed, aspect, `_streamInfoPayload()`)
  is appended **only for Windows**. iOS receives presentation fields exclusively because the
  presented controller's own `AvPlayerEngine` is the transport-truth authority there — the
  embedded `_player` sits idle reporting zeros while AVPlayer owns playback (the same reason
  `_persistPlaybackPosition` is a no-op on that path), so pushing Dart's transport state would
  overwrite the lock screen and chrome with a stopped player's numbers. On Windows the native HWND
  renders *this* `_player` (mpv via a `vo` swap), so Dart genuinely is the transport authority
  there and the full payload applies.
- **PiP** needs `UIBackgroundModes = [audio]` (already required just to background audio at all —
  docs/ios.md) and the same lifecycle discipline as the Android shared-preview handoff: the
  app-pause observer must stop the **preview** engine, never the fullscreen one, or a muted
  preview keeps decoding — and holding a provider connection — behind the launcher.
- **Cross-engine fullscreen handoff is implemented.** `decideFullscreenHandoff`
  (`lib/screens/channel_list_screen.dart`) takes a `crossEngineFullscreen` flag — the iOS
  analogue of Linux's Wayland-HDR case, collapsed into the same `FullscreenHandoff.stopResolveFresh`
  outcome — computed from `selectIosEngine` on the running preview's URL. An AVPlayer-routed
  channel stops the embedded preview outright (never paused, to avoid holding a second provider
  connection) and re-resolves fresh before the presented controller opens — structurally the same
  shape as Linux's Wayland-HDR "Preview→fullscreen handoff (HDR-escalation only)" below. See
  docs/ios.md "Known parity gaps" for the residual non-seamless beat and the benign
  preview-vs-fresh-URL race that follows from deciding it ahead of the final resolve.
- **The mpv path renders the shared Flutter overlay, in touch mode.** `PlayerVideoSurface`
  (`player_overlay.dart`) builds `EmbeddedPlayerControls` on **iOS as well as Linux/Windows**, with
  `touch: true`. This is not a cosmetic upgrade of a rare fallback: `selectIosEngine` rule 4 routes
  every extension-less `create_link` locator to mpv, so for a Stalker/MAG portal the embedded
  surface *is* the player, and it used to fall through to media_kit's stock `MaterialVideoControls`
  — which ignore `StreamInfo.isLive` and expose the HLS live window as a scrubbable
  `00:04 / 00:30`, breaking CLAUDE.md's "Live = no seek bar", on top of shipping none of the app's
  chrome (EPG, badges, go-to-live, favorite, track menus). **Android deliberately stays on the
  stock controls**: there the embedded surface really is a launch-failure fallback, and it has to
  survive an Android TV D-pad, which this overlay's Material sliders/`PopupMenuButton`s are not
  built for. The `touch` flag (default false, so Linux/Windows are unchanged) carries seven
  gated differences, each chosen to agree with the native `IptvsPlayerViewController` the same
  device reaches on AVPlayer-routed channels:
  - **Tap is the Back ladder**, the Dart twin of Swift's `playerTapAction`: peel info → hide
    visible chrome → reveal it. The pointer path keeps "a tap only ever shows" (hover already
    reveals; hiding under a cursor is wrong). The list menus are modal `PopupMenuButton` routes
    whose own barrier eats the outside tap, so they self-close on one press just like the native
    `closeMenu` rung. The bars **absorb** taps that miss a control under `touch` — a Flutter
    `Container` doesn't hit-test itself, and without that a press on bare gradient would fall to
    the background layer and hide the chrome the user was reaching for (UIKit views absorb by
    default). The explicit control still exits outright, skipping the ladder, and wears the native
    controller's **X** rather than a back arrow.
  - **No fullscreen affordance** — the Flutter route is already fullscreen, media_kit's
    `toggleFullscreen` would push a second `Video` route above the one `PlayerScreen` owns, and the
    native controller has no fullscreen button either. Dropping the double-tap recognizer also
    makes the show/hide tap resolve on the next frame instead of after `kDoubleTapTimeout`.
  - **≥44pt hit targets** in both axes, replacing chip sizes that are deliberately shorter than
    they are wide for a cursor. 44 is a floor, not a target: the roomy metrics below sit at 48pt
    and the dense ones sit exactly on 44, never lower.
  - **Two-row reflow at `kTouchReflowWidth` (560), not `kCompactControlsWidth` (720)** — badges move
    under the title, the button cluster under the transport, mirroring the native overlay's
    `applyCompactLayout` reparenting. This used to trigger off `kCompactControlsWidth`, the
    *pointer* feature-collapse threshold (see "Windows" below) — a real bug, not just a shared
    constant: a 667×375 landscape phone (iPhone SE/8 class) stayed one row on native
    (`PlayerDimens.compactWidth` is also 560) and went two-row here, and stacking rows is exactly
    the wrong answer on the shortest surface the app targets. `kTouchReflowWidth` now owns that
    trigger alone; `kCompactControlsWidth` keeps its 720 and its original pointer-only job. Above
    the reflow width the touch transport is wrapped in an `Expanded` rather than split off with a
    `Spacer`, so free space lands after the transport and the cluster stays hard right.
  - **Dense vertical metrics below `kShortOverlayHeight` (500pt tall)** — a phone in landscape is
    320–440pt tall, and the roomy desktop-sized paddings this overlay otherwise uses left almost no
    picture: measured before the fix, **49pt of visible video on live and 23pt on VOD**, out of a
    375pt-tall screen. Below the threshold, padding and badge gaps shrink and buttons drop from
    48pt to 44pt (the HIG floor above, never lower); the control set doesn't change and the VOD
    seek bar — the one real drag target — keeps its size. The fix restores a genuine video band on
    the shortest surface the app targets; the exact restored height is a test-suite assertion
    (`test/player_overlay_touch_test.dart`), not a number worth hand-carrying here.
  - **The info panel is banded between the two bars, not pinned at a hard-coded offset.** The
    pointer path still opens the card 76px below the top bar — a literal guess that only holds
    because the pointer overlay never reflows. Under touch the card is banded between the real
    top and bottom bars (mirroring the native `infoPanel.top == topBar.bottom + 12` /
    `bottom <= bottomBar.top - 12` constraints) and scrolls if it doesn't fit, instead of opening
    inside the top bar or running through the bottom one — the two failure modes the 76px literal
    produced the moment the badges reflowed onto their own row. Deliberate divergence from native,
    recorded so it isn't "fixed" later: UIKit resolves the same squeeze by lowering constraint
    priority, because it has no scroll fallback; scrolling is the better answer on a 375pt-tall
    screen.
  - **Dynamic Type is clamped to `kTouchMaxTextScale` (1.3).** The native controller sizes every
    label with a fixed `UIFont.systemFont(ofSize:)` — no `UIFontMetrics`, no `preferredFont` — so
    it ignores Dynamic Type outright; an unclamped Flutter overlay diverged from the controller the
    same user reaches on AVPlayer-routed channels for the same content. It was also a layout bug:
    at 2× the two bars alone exceed a 375–393pt-tall landscape phone, and the touch chrome
    *column* overflows where the old independently-`Positioned` bars silently overlapped instead.
    1.3 keeps some of the accessibility benefit rather than copying native's total refusal to
    scale — it is the largest bound at which the worst real surface (667×375, VOD, full control
    set) still fits. Pointer platforms are deliberately unclamped.
  All of the above (reflow, density, button sizing) resolves once per build into a public
  `EmbeddedOverlayMetrics` value class rather than being read off ad hoc —
  `EmbeddedOverlayMetrics.of(anySize, touch: false)` returns one fixed token set at every size,
  which is what keeps the pointer path (Linux/Windows) size-invariant **by construction**: a
  touch-only metric leaking into the pointer path is a failing pure test, not something a reviewer
  has to catch by eye.
  Aspect cycling stays at the full four mpv modes here (Fit/Fill/16:9/4:3) rather than being cut to
  the native controller's two: that limit is an `AVPlayerLayer`/`videoGravity` constraint
  (docs/ios.md "Known parity gaps"), not a design choice, and mpv genuinely does all four.
  Auto-hide stays flat 4s, between the native 3.5s (VOD) and 4.5s (live). Nothing sets
  `SystemChrome.setEnabledSystemUIMode`, so the iOS status bar really does sit over this surface —
  `_barInsets` (`MediaQuery.paddingOf`) is what keeps the chrome clear of it and of the home
  indicator. Pinned by `test/player_overlay_touch_test.dart` (the pointer behavior stays in
  `test/player_overlay_test.dart`, which is untouched).
- **Top/bottom scrims self-size against the bar each backs**, the native-Swift counterpart of the
  reflow above: `topScrim.bottom == topBar.bottom + scrimFade` / `bottomScrim.top == bottomBar.top
  - scrimFade` (`scrimFade = 24`), rather than the old fixed `topScrimHeight = 180` /
  `bottomScrimHeight = 220` pair, which summed to more than a 375–440pt landscape phone's height —
  the two gradients met in the middle and dimmed the whole picture instead of leaving a clear band
  between them. A scrim now follows the bar it backs, including the live bottom bar's taller EPG
  strip pushing its scrim's inner edge down with it.
- **Parity gaps** (docs/ios.md "Known parity gaps"): no HDR10+, ever (AVFoundation exposes no
  per-scene ST2094-40 metadata, unlike the Android/Windows/Linux decoder-level reads); and no
  *seamless* preview→fullscreen handoff for AVPlayer-routed channels — the handoff itself is
  implemented (above), but every AVPlayer open is still a fresh resolve with one black beat,
  unlike Android's `SharedEngine` adoption or Windows' embedded hot-swap, because AVPlayer cannot
  adopt a running mpv session. An `IosSharedEngine` analogue that could close this gap is recorded
  as a deferred idea, not designed.

Read docs/ios.md before touching anything under `packages/iptvs_ios_player/` or
`lib/player/ios_engine.dart` — it carries the full engine-selection rule table, the fallback
engine's capability research (codec floor, the two open media_kit constraints), and the
on-device test protocol.

## Windows

**Surface policy mirrors Linux: embedded for SDR, the native HWND only for HDR.** HDR playback
renders into a native HWND surface (`createSurface`) so mpv presents directly through D3D11 (real
HDR) instead of round-tripping through Flutter's SDR texture (`vo=gpu-next`,
`gpu-context=d3d11`, `hwdec=auto-safe` — `auto-safe` negotiates d3d11va zero-copy and falls back
to software cleanly; a *forced* `d3d11va` could half-init and desync). But a **same-channel SDR
preview→fullscreen handoff stays on the embedded media_kit texture** (`preferWindowsEmbedded`, set
in `_openLivePlayer` when `decision.adoptsEmbeddedPreview` and the preview colorimetry reads SDR):
the adopted preview `Player`/`VideoController` keep rendering with no `vo` swap, so the transition
is seamless both ways (the preview is never disposed, and `hotSwapped` stays false so the channel
list resumes it on return). `_usesWindowsNativeSurface` reflects the *current* surface, not just the
initial choice — an SDR-adopted embedded stream that turns out HDR (PQ/HLG on the `videoParams`
stream) **escalates once** via `_maybeEscalateWindowsNative`: it creates the HWND surface and
hot-swaps `vo` on the *same* player (no fresh resolve, unlike Linux's separate mpv process),
flipping `_windowsNativeActive`/`_didWindowsHotSwap` true so exit discards+restarts the preview like
a normal native open. This covers the cold/fast preview→fullscreen where the ahead-of-time
colorimetry read missed HDR; the cost is a brief mid-playback switch. VOD/direct opens never set
`preferWindowsEmbedded`, so they open native immediately.

**Never ask `_nativePlaybackLaunched` whether this `_player` owns playback — ask
`_separateEngineOwnsPlayback`.** That flag starts **true** on Windows for every non-preview open
(`_usesWindowsNativeSurface`), because the happy path deliberately builds no `VideoController`. But
the Windows HWND surface *is* this same `_player` presenting through a `vo` swap, so Dart remains
the transport authority (same reason the full `setControlState` payload applies on Windows and not
iOS). `_separateEngineOwnsPlayback` — `_linuxNativeSession != null || ((Android || iOS) &&
_nativePlaybackLaunched)` — is the honest test, and both the clean-EOF live reconnect
(`shouldReconnectOnCompleted`) and the VOD resume seek (`shouldApplyEmbeddedResume`) go through it.
The resume seek is where this last went wrong: gated on `_nativePlaybackLaunched`, it was suppressed
for **every Windows VOD**, so positions were saved correctly (`_persistPlaybackPosition` gates on
Android/iOS only) but never restored and "Continue watching" always restarted from zero. The engines
that really do own playback receive the resume point up front instead — Android/iOS in the `resumeMs`
open payload, Linux native mpv as `--start=` — and must not be seeked here. Pinned by
`test/reconnect_policy_test.dart`.

Control state is mirrored
to native via `setControlState` (Dart→C++) / `nativeControl` (C++→Dart commands); the GDI overlay
(`windows/runner/flutter_window.cpp`) draws the **same control set, badges, live EPG strip,
go-to-live, favorite star, and "Reconnecting…" indicator** as the Android Compose overlay, and
its bars **fade into the video** rather than sitting as flat fills — a per-scanline alpha ramp
written straight into the layered window's DIB, mirroring the shared Flutter overlay's
gradients (top `0xB3`→`0x00`, bottom `0x00`→`0x99`→`0xCC`). The ramp floors alpha at 1 rather
than reaching a true 0, because `NormalizeNativeControlBitmapAlpha` treats `alpha == 0` as
"GDI didn't draw here" and forces it **opaque** — a ramp to zero comes back as a solid black
bar. Windows
draws that indicator *inside* the auto-hiding overlay rather than outside the visibility gate the
way Android and iOS do, so `ControlsPinnedByOverlay()` counts `reconnecting` alongside an open
menu/info panel — otherwise the hide timer took the badge away mid-stall and the platform's
primary live path showed a frozen picture with no explanation. (The Linux Lua OSD both draws it
ungated *and* pins; pinning alone is the smaller change and covers the auto-hide case, which is
the one that actually bites.) The favorite star (live channels with a favorites store) sits
rightmost in the top bar; Dart owns the store, so the click sends a `favorite` command and Dart
pushes the new `canFavorite`/`isFavorite` back via `setControlState`. It is in the keyboard-focus
ring — pushed right after `kBack` to match the top bar's visual order, gated on `can_favorite`.
The controls
overlay is a layered window clipped to a region covering only the top+bottom bars (+ open
menu/info), so anything drawn must fall inside it — `UpdateNativeControlState` rebuilds the region
when the bar height changes (e.g. the taller live-EPG bar). The **SDR embedded path** instead uses
the shared Flutter overlay (`EmbeddedPlayerControls` in `player_overlay.dart`, also Linux's and —
in `touch` mode — iOS's mpv path, see "iOS"), kept
at visual parity with the GDI overlay (chip buttons, badges in the same order, favorite star, and
the same three-row live EPG strip — see "The live EPG strip" under "Android"). It reads/drives the
media_kit `Player` through a narrow `EmbeddedControls` seam (`PlayerBackedEmbeddedControls` in
production) purely so the overlay is widget-testable without a libmpv engine —
`test/player_overlay_test.dart` pins the gesture layering/latency, the live-vs-VOD control set,
and the responsive collapse/no-overflow with a stub. **It also insets its bars** (`_barInsets`,
`MediaQuery.paddingOf`) — the same full-bleed-scrim / inset-content split as the Compose overlay.
This matters on Android, not just desktop: the embedded path is the fallback when
`HdrPlayerActivity` can't launch, and it renders in the ordinary Flutter window, which is **not**
immersive (nothing calls `SystemChrome.setEnabledSystemUIMode`), so under edge-to-edge the system
bars really do sit over the video. Insets are zero in widget tests by default, which is why the
regression is pinned explicitly rather than left to be noticed visually.

**Any input reveals the chrome, and a pinned overlay never auto-hides.** These are the two rules
six of the seven control surfaces already followed by accident; they are now contracts on the
shared overlay. `_handlePlaybackInput()` routes *every* `CallbackShortcuts` binding and the
pointer `Listener` to `PlayerVideoSurfaceState.revealChrome()` (which forwards to the controls
state exactly the way `handleBackPeel` does). It used to handle only the Windows *native* surface,
so on Linux, the Windows SDR handoff and iOS's mpv path the whole shortcut set was a no-op for
visibility: chrome auto-hid after 4 s, Space paused, `_scheduleHide` refuses to re-arm while
paused, and nothing but a mouse hover or tap could bring it back — a keyboard-only user was
stranded on a frozen frame. Escape's ordering is deliberately untouched, so it still *peels*
rather than merely revealing. Correspondingly `_scheduleHide()` early-returns on `_menuOpen` as
well as `_showInfo`: `_playingSub` calls it on every `playing` transition, including the
buffering→playing edge a live stream produces routinely, so an open track/subtitle/speed menu
otherwise had the bars pulled out from under it 4 s later (Android pins via `state.pinned`, iOS
via `AutoHidePolicy.shouldSchedule(pinned:)`, Lua via `not open_menu`).

**Key scope is decided by the surface, never the platform.** `F` toggles fullscreen through the
embedded surface unless `_usesWindowsNativeSurface`; it used to branch on `Platform.isLinux`,
which sent the Windows SDR-embedded path — the *common* Windows live path, reached via the
same-channel preview→fullscreen handoff — into `_toggleNativeFullscreen()`, where it early-returned
and did nothing while the on-screen button advertised "Fullscreen (F)". `M` is the mini-player on
the Windows native surface (the native side owns the window geometry, so it can only act there)
and **mute** everywhere else, matching the Lua OSD and the usual media-player convention; the two
surfaces are mutually exclusive, so there is no real collision. `i` (info), `s` (favorite) and
Up/Down (volume) exist for Linux parity — the Lua OSD bound them and the embedded path did not, so
the same physical key did different things depending on whether the stream happened to be
HDR-on-Wayland. All four are gated behind `_usesSharedEmbeddedOverlay`, which matters for what it
**excludes**: Android's embedded path is media_kit's stock Material controls, whose buttons are
focus targets a TV D-pad walks with Up/Down, and binding those arrows would swallow the traversal
and strand the user on the fallback surface.

**Controls that can't act are not shown.** The subtitle button appears only when a track other
than the synthetic Auto/Off exists (Android, iOS and Windows all gate this; most live IPTV
channels carry no subtitle track, so it was a permanently useless button on the busiest surface),
and a live channel with no `epgNow` renders just the LIVE badge rather than a
`LinearProgressIndicator` frozen at 0 that reads as "stuck loading". The aspect control renders
its **current mode label** as a text chip rather than a bare icon — all four native overlays do,
and `docs/player.md` already called Dart the single source of truth for that label sequence, so
the surface owning the truth was the only one not showing it.

**Back/Escape peel + tap-outside parity:** the
info panel is a non-modal `Positioned`, so it needs an explicit single-press peel to match the
native overlays' menu→info→hide→exit ladder — `EmbeddedPlayerControlsState.handleBackPeel()` closes
an open info panel first (consuming the press), and `PlayerScreen`'s Escape binding calls it
(via `PlayerVideoSurfaceState.handleBackPeel`) before falling through to exit. Tapping the exposed
video area also dismisses an open info panel (the panel itself absorbs taps so it isn't re-closed
by its own hit). Under `touch` (iOS) that same tap carries one rung further — it *hides* visible
chrome once there is nothing left to peel, and the bars absorb near-misses; see "iOS". The on-screen back-*arrow* button still exits directly (documented parity with the
native overlays); the modal `PopupMenuButton` menus dismiss themselves and aren't a peel rung.
Two layout/latency
invariants there: (1) **tap-to-show / double-tap-fullscreen sits on a background `Positioned.fill`
layer *behind* the bars, never as an ancestor of them** — a `DoubleTapGestureRecognizer` holds the
gesture arena for `kDoubleTapTimeout` on every tap it can see, so wrapping the whole overlay in it
delayed every control press by that timeout (the "heavy" feel); as a sibling below the bars it only
sees the exposed video area. (2) The **top-bar badges are width-capped and wrap** (a `Wrap` inside a
`ConstrainedBox(maxWidth: constraints.maxWidth * 0.55)` under a `LayoutBuilder`), so a full EPG plus
the resolution/HDR/FPS/source/clock badge set can't overflow the row on a narrow/windowed surface.
The **live-progress title is likewise width-capped and non-flex** (0.4 of the bar) so the `Expanded`
progress bar keeps the rest of the width instead of splitting the row ~50/50, and the **bottom
control row drops its two widest optional pieces below ~720px** (`compact`, `kCompactControlsWidth`
in `player_overlay.dart`): the volume slider collapses to the mute button, and "Go to live"
collapses to its icon. That 720px stays a **feature-collapse** threshold — it decides which optional
pieces a row can still carry, on every platform including iOS, and it is still measured against the
bar's *inner* constraints rather than the surface. What it no longer decides is *layout*: the touch
path's own two-row reflow
(see "iOS" above for the mpv/`EmbeddedPlayerControls` touch path) now answers to a separate,
narrower constant (`kTouchReflowWidth`, 560) — the two used to be the same number, which is exactly
the bug the iOS fix above corrects, so don't assume one constant governs both layouts when reading
either overlay's code.

`PaintNativeControlBar` **caches its ARGB back-buffer** (`OverlayBackBuffer`: DIB + memory DC,
file-scope alongside the other single-overlay globals), recreating it only on a client-size change
rather than allocating + `ZeroMemory`ing a full-window bitmap every `WM_PAINT` — at 4K that was a
~33 MB alloc + memset + full-surface composite per paint, several times a second while the overlay
is up (and pinned through a reconnect). Each paint clears and re-composites only the *union of the
control rects* it drew (the two bars plus any open menu/info), plus whatever the previous paint
touched (so a closed menu / shrunk bar is erased, not left stale in the reused buffer); those rects
are merged into disjoint bands and pushed with `UpdateLayeredWindowIndirect`'s `prcDirty`, so the
transparent middle is never cleared or uploaded. The cached DIB is a debug-counted resource
(`windowsOverlayDibs`), freed in `DestroyNativeControls`.

**Dynamic range** here comes from mpv's `video-params` (`gamma`/`primaries`/`colormatrix`, in
`_dynamicRangeLabel`) — mpv/libavcodec already parse the in-band VUI/SEI, so this matches the
decoder-authoritative Android path for SDR/HDR10/HLG/DV without the `Format.colorInfo` gap.
**HDR10+** is best-effort (mpv exposes no clean flag): `_probeHdr10Plus` reads the ST2094-40
per-scene sub-properties (`video-params/scene-max-r|g|b`, `scene-avg`) — non-zero only with real
dynamic metadata, and *not* synthesised by `hdr-compute-peak` (so no false-positive on plain
HDR10) — and upgrades PQ→"HDR10+ · PQ"; any missing property/error stays at "HDR10". Older mpv
builds without those sub-properties simply under-report (HDR10).

If the native HWND surface **fails to create** (`createSurface` returning null), `_open` stops
and surfaces the standard terminal error/Retry overlay ("Couldn't create the video surface.") —
Retry re-runs `_open` including a fresh surface-creation attempt. It must **not** fall through to
opening the stream: on Windows `_controller` is always null and
`embeddedVideoOptionsForPlatform()` is empty, so proceeding would mean audio-only playback behind
a silent black overlay (the pre-PR-9 behavior). An adopted player on this path lands on the same
overlay (its audio keeps running, as it did before, but the failure is now visible and
recoverable — a successful Retry reaches the normal hot-swap).

A **mini-player** mode (`setMiniPlayer`, toggled with the `M` key) restyles the top-level window
into a compact frameless always-on-top window docked bottom-right — draggable via the video area
(manual `WM_NCLBUTTONDOWN`/`HTCAPTION` from the surface WndProc), resizable via `WS_THICKFRAME`,
mutually exclusive with fullscreen, restoring the saved placement on exit/`prepareExit`.

## Linux

**The embedded `media_kit`/libmpv surface is the default Linux fullscreen path;
the standalone native mpv window is used only for HDR streams on Wayland.**
This mirrors Android's "default engine, escalate only when the stream needs it".
The native path (`LinuxNativeSession`, a standalone mpv process found on the
host, not bundled — see "Host mpv discovery + version gate" below — over a
private Unix JSON-IPC socket, `vo=gpu-next` + compositor colour-space
signalling) is a *separate OS process*: it can never adopt a running preview
engine, so every entry/exit costs a fresh Stalker `create_link` + stream
reopen (a visible black beat). That cost only earns itself for **real HDR
output**, which on Linux exists **only on Wayland** — X11 has no HDR output
path at all (X11 playback is always tone-mapped SDR), and for SDR the native
window renders nothing the seamless embedded path can't. So:

| Backend | Stream | Fullscreen path |
| --- | --- | --- |
| X11 | any | **embedded** (native buys nothing — no HDR output) |
| Wayland | SDR | **embedded**, seamless engine adoption (both directions instant, one provider connection) |
| Wayland | HDR (source gamma PQ/HLG/DV) | **native mpv** — the fresh-resolve handoff is the honest cost of real HDR passthrough |

The policy predicate is `LinuxNativeSession.nativeLikelyAvailable()` (cached),
now **Wayland-gated**: it runs the executable/overlay-script detection and mpv
version gate *and* requires a Wayland session, so it returns false on X11.
`LinuxNativeSession.start()` itself is left backend-agnostic (it still launches
on X11 if called explicitly) — the Wayland restriction is a *policy* choice in
`nativeLikelyAvailable`, not a capability of the session.

When the native path launches it stays pinned to `x11egl` on X11 (the flag is
irrelevant there now, since the policy never uses X11 native — but `start()`
keeps it for the force-native case); on Wayland the `--gpu-context` flag is
omitted so mpv chooses its own context (0.41+ prefers the Vulkan `waylandvk`
context over EGL — a more-tested HDR path than forcing one).
`linux/mpv/iptvs_overlay.lua` renders the app-specific controls inside mpv's
own GPU/OSD surface, so the title, EPG, badges, favourite, seek/live controls,
audio/subtitle/speed/aspect actions, stream information and fullscreen behavior
remain available without placing a second compositor window above HDR video.

**Preview→fullscreen handoff (HDR-escalation only).** Because the native mpv
process can never adopt a running preview engine (unlike Android's shared
ExoPlayer engine or the Windows/embedded media_kit hot-swap), it's chosen only
for a Wayland HDR stream per the table above. There are **two decision points**:

- *Ahead of time, from a same-channel preview.* `channel_list_screen.dart`'s
  `_openLivePlayer` reads the preview engine's current colorimetry
  (`_preview.player.state.videoParams`, guarded on `hasEmbeddedPlayer`) through
  the pure `isHdrColorimetry` helper. Native availability discovery can spawn
  an external mpv version check on its first call, so
  `shouldProbeLinuxNativeForHandoff` permits it only for an adoptable
  same-channel HDR preview; SDR previews, direct opens, zaps, and EPG-grid
  opens never pay that pre-route cost. When a probe is needed, preview state is
  read again after the await before the final `decideFullscreenHandoff`
  decision (`lib/screens/channel_list_screen.dart`, pinned by
  `test/fullscreen_handoff_test.dart`). Every downstream boolean (`existingPlayer` gating,
  pause/stop/restore-mute behavior) derives from the returned enum via the
  `FullscreenHandoffDerived` getters — never from stale pre-await values. On Linux, only
  **Wayland + HDR** yields `FullscreenHandoff.stopResolveFresh`; SDR and X11
  yield `adoptEmbedded` (seamless media_kit adoption — the preview `Player` is
  handed to `PlayerScreen` and kept playing, one provider connection). For
  `stopResolveFresh` the preview is **stopped outright, not paused** (a paused
  media_kit engine still holds its provider connection open, and a real Stalker
  portal kills one side of the resulting double connection, with preview and
  native fighting in a `create_link` storm) and the channel is **re-resolved
  fresh** (the preview's already-resolved stream carries a spent single-use
  Stalker `play_token`). `PlayerScreen` is then pushed with **no adopted
  engine** (`existingPlayer`/`existingController` null) and `preferLinuxNative:
  true`, so `_open` goes straight to `_startLinuxNativeSession` with the fresh
  stream. On return — route didn't hot-swap, screen still mounted — the preview
  is restarted on the same channel (`_preview.start(channel, muted:
  previewWasMuted)`); the `adoptEmbedded` return instead resumes the still-live
  adopted engine (`_preview.play()`), and a different-channel stop stays
  not-restarted.

- *At play time, with no preview knowledge* (zap, EPG-grid play, VOD, narrow
  layout — anything that reaches `PlayerScreen` with `preferLinuxNative: false`).
  These **open embedded first**, then escalate **once** if the embedded player
  reports a PQ/HLG source on Wayland: `PlayerScreen._maybeEscalateLinuxNative`
  (off the `videoParams` stream) re-resolves fresh (`resolveAgain`, falling back
  to `widget.stream`), stops the embedded playback to free the provider
  connection, and launches the same `_startLinuxNativeSession`. For VOD/catch-up
  the embedded player's **current position is captured before the stop** and
  passed as the native session's resume point (`resumeOverride`), so escalation
  continues where the embedded phase reached instead of rewinding to the
  original `resumeFrom`. One-shot
  (`_linuxEscalated`, re-entry-guarded by `_linuxEscalating`): never
  re-escalates, never de-escalates; if the (predicted-available) native launch
  fails it reopens the fresh stream embedded (honest tone-mapped SDR). X11 /
  below-the-version-floor never reach here — `nativeLikelyAvailable()` is false.

Either way the native launch runs through the single reusable
`_startLinuxNativeSession(stream)` (control/playback signal wiring, exit
handler, resource counter `incLinuxNativeSessions`, colorimetry probe). The
spawn + IPC connect can take several seconds, so after its `await` the method
re-checks `mounted`/`_linuxNativeClosing`: a route popped mid-launch disposes
the just-started session immediately instead of adopting it (no orphaned
fullscreen mpv, and the counter — never incremented on that path — stays
balanced). The
visible gap during a native handoff/escalation is stream-open latency: the
blackout deferral (`_markLinuxNativeStarted`, gated on the session's first
`file-loaded`/`playback-restart` signal, 10s fallback timer) holds the route on
the embedded surface's last frame until mpv actually has video. The same gate
keeps initial buffering out of the live stall watchdog — only post-start
`paused-for-cache` stalls feed the 8s reconnect threshold (a drop still forces
an immediate retry). The live reconnect watchdog keys off `_linuxNativeSession
!= null` throughout: pre-escalation it reloads via the embedded `_player`,
post-escalation via mpv's `loadfile replace`; the single `_reconnectTimer`
(created for any live playback) is reused across the switch, so counters stay
balanced.

**Back and orphan safety, in the overlay itself:** `iptvs_overlay.lua`'s ESC
and `MBTN_BACK` bindings (`handle_back`) implement the same single-press
peel as the rest of the app (menu → info → hide-overlay → exit): they close
an open list-menu, else close the info panel, else hide the overlay chrome,
and only `emit('back')` to Dart (which exits the player) once there's
nothing local left to peel. The on-screen back *arrow button* skips this and
always exits directly, matching the embedded overlay's back-arrow parity.
Separately, a `mp.add_periodic_timer(5, …)` watchdog (`check_parent_alive`)
reads `/proc/self/stat`'s ppid every 5s and calls `mp.command('quit')` once
it reads `1` (reparented to init — the Flutter app died without the mpv
child ever being told). This lives in Lua rather than Dart because a SIGKILL
of the Flutter process is nothing `dart:io` can observe or react to, and
`dart:io` has no way to arrange `PR_SET_PDEATHSIG` on the child before it's
spawned either — the mpv process itself, still alive, is the only thing that
can notice its parent is gone. Without it, a killed app would leave mpv
running as an orphaned fullscreen window indefinitely.

**Live reloads re-resolve:** Stalker `create_link` URLs carry
single-use/short-lived `play_token`s, so after any portal-side kill the
originally resolved URL is permanently dead. The reconnect watchdog and "Go
to live" therefore re-resolve through `PlayerScreen.resolveAgain` (wired by
the channel list to `repo.resolve(channel)`; falls back to the original URL
when absent or failing) and refresh `http-header-fields` alongside the new
URL. The native mpv also runs `--ytdl=no` — a dead-URL open failure should
surface as an `end-file` error for the watchdog, not trigger mpv's
youtube-dl fallback.

### Host mpv discovery + version gate

The AppImage does **not** bundle mpv (CI stopped setting `MPV_BINARY`;
`package_linux_appimage.sh`'s `MPV_BINARY` block is now purely an optional
knob for anyone packaging with a hand-picked build). `LinuxNativeSession
.findExecutable()` looks for a binary bundled next to the running executable
first, then falls back to the host's system mpv (`/usr/bin/mpv`,
`/usr/local/bin/mpv`). Whichever is found, `LinuxNativeSession.start` runs
`<mpv> --version`, parses it with the version-tolerant `parseMpvVersion`
(handles upstream `mpv v0.41.0`, distro-patched `mpv 0.37.0-1ubuntu4`, and git
snapshots), and **requires >= 0.40** (`mpvSupportsNativeHdr`) — Wayland HDR
pass-through was added in mpv 0.40; below that (or on an unparseable/missing
binary) `start` returns null and playback falls back to the embedded
media_kit/libmpv SDR path, with a redacted diagnostics log explaining why.
**0.41 is recommended**: `--target-colorspace-hint` was added in 0.41 and
defaults to `auto` there (so the flag is omitted); passing the string
`"auto"` on 0.40 makes mpv exit nonzero at launch (0.40 only understands
`yes`/`no`), so 0.40 gets `--target-colorspace-hint=yes` explicitly
(`mpvColorspaceHintArgs`). This whole gate (parsing, version compare, arg
selection) is pure logic pinned by `test/linux_mpv_version_test.dart`.

The HDR badge (and the info panel's "Dynamic range" row) reads
`video-target-params` — the colorimetry *after* mpv's render pipeline,
tone-mapping included — rather than the source-side `video-params`: if a
PQ/HLG source got tone-mapped down to SDR (e.g. on X11, or an
untested-Wayland-HDR path), the badge honestly shows SDR instead of a false
HDR claim. Dolby Vision detection still consults source-side `video-params`,
since DV metadata doesn't reliably carry through the target-params render
path. `LinuxNativeSession.hdrColorimetry()` mirrors this over IPC for
diagnostics/HDR10+ purposes (see below): it reads `video-target-params/*`
sub-properties first and falls back to `video-params/*` when the target one
comes back null.

HDR10+ detection on this path (`PlayerScreen._probeLinuxNativeHdr`, run once
shortly after native launch, since the native mpv process is a separate OS
process whose output never reaches the embedded `_player`'s `videoParams`
stream) reads the ST2094-40 per-scene sub-properties
(`video-target-params/scene-max-r|g|b`, `scene-avg`, falling back to the
`video-params/*` equivalents) the same way the Windows path does — non-zero
only with real dynamic metadata — and upgrades PQ to "HDR10+ · PQ". The
resulting colorimetry (gamma/primaries/sig-peak) is logged to diagnostics
either way, so exported logs show whether HDR actually engaged. **Dart is the
single label authority**: `dynamicRangeLabelFrom` (player_screen.dart) renders
every surface's badge — the Windows overlay via `_streamInfoPayload`, the
embedded Linux overlay via an injected `dynamicRangeLabel` callback (the
overlay file can't import player_screen without a cycle), and the native Lua
overlay via an `hdr10Plus` field on the `iptvs-state` payload, pushed when the
probe upgrades (Lua derives PQ/HLG from mpv properties but can't judge the
scene metadata's semantics itself).

The overlay is a from-scratch ASS-events renderer at parity with the embedded
Flutter overlay (`EmbeddedPlayerControls` in `player_overlay.dart`, shared by
Linux, the Windows SDR embedded path, and iOS's mpv path), not a
generic mpv skin: text renders in bundled **Inter** and icons as glyphs from
bundled **Material Icons** (`linux/mpv/fonts/`, installed by
`tool/package_linux_appimage.sh` into `usr/share/iptvs/fonts/` and pointed at
by libass via mpv's `--osd-fonts-dir` launch option — the overlay is an OSD
surface, not burned-in subtitles, so `--osd-fonts-dir` is the option that
actually applies, not `--sub-fonts-dir`); every color is a BGR ASS constant
derived from `lib/theme.dart`'s `AppColors` tokens; every geometry value and
font size routes through a `scale = osd_height / 1080` factor so the overlay
renders at the same physical size on HiDPI/4K outputs instead of shrinking;
and the **favorite star** and the **LIVE pill** (in the live-progress row,
not the badge cluster) are drawn, matching the embedded overlay. The
`iptvs-state` IPC payload (`LinuxNativeSession.updateOverlayState`) carries an
`aspectLabel` field — Dart is the single source of truth for the aspect-mode
label sequence (shared with the Windows overlay's `_aspectModes`), pushed
through after every cycle so the Lua button never has to guess which mode
mpv actually landed in. Rendering is throttled: `time-pos`/`duration` are
deliberately **not** observed (mpv fires time-pos near frame rate, and each
observation rebuilt the whole ASS scene for a value only the VOD seek bar
reads — live progress renders from `os.time()`); instead a 4 Hz ticker runs
**only while the chrome is visible**, so a hidden overlay does no periodic
work, and discrete changes (pause, tracks, state messages) still render
immediately. The embedded Flutter overlay applies the same idea: its
position `StreamBuilder` wraps only the VOD seek bar and time label
(`_positionRebuild`), not the whole control surface.

**The same rule binds the Dart IPC client**, which is a second consumer of the
same firehose: `LinuxNativeSession` observes `user-data/iptvs-control`,
`paused-for-cache` and `duration`, but **never `time-pos`** — observing it
delivered 25-60 socket lines + `jsonDecode` per second onto the main isolate for
the whole native session, to keep a cache that only matters *after* the mpv
process exits (`playbackState()` prefers a live `get_property` read whenever the
socket is alive). Instead a **1 Hz poll, started only for VOD**
(`_startPositionPoll`, re-entrancy-guarded, cancelled in `dispose`) refreshes it
through the same `applyPlaybackPropertyChange` seam the observer path uses; live
never persists a position, so it polls nothing. The poll timer is deliberately
*not* in `ResourceCounters` — its lifetime is strictly bounded by the session,
which is already counted as `linuxNativeSessions` (same reasoning as
`player_screen.dart`'s VOD position-persist timer).

If the native executable, overlay script, display backend, or IPC startup is
unavailable — including a host mpv below the 0.40 version floor, or an
unparseable `--version` output — Linux falls back to embedded media_kit/libmpv
with the equivalent Flutter overlay. That path requests `hwdec=auto-safe` and
tone-maps HDR to SDR.

## Other platforms / fallback

Embedded `media_kit_video` controls, with mpv asked to tone-map HDR into SDR.

## Live preview + seamless handoff (Android)

The live preview and the fullscreen player share **one ExoPlayer engine** on Android.
`SharedEngine` (`android/.../player/SharedEngine.kt`, a process-global holder) owns an
`ExoPlayerEngine` the preview starts; the preview renders it through a **TextureView platform
view** (`iptvs/preview_view`, `PreviewPlatformView.kt` — TextureView because SurfaceViews don't
compose inside Flutter platform views), driven from Dart by `LivePreviewController` over the
`iptvs/native_preview` MethodChannel (open/play/pause/setVolume/stop + `previewEvent` callbacks).
Going fullscreen on the previewed channel passes `adoptShared` → `HdrPlayerActivity` **adopts**
the running engine (`SharedEngine.adoptForFullscreen`, keyed on the URL): only the video output
moves to its SurfaceView (`claimViewSurface`), so audio/decoder/buffer never stop — and only **one
provider connection** ever exists (single-connection IPTV accounts). On exit the surface is handed
back (`fullscreenDetached`); the Activity never releases an adopted engine, and `onStop` skips its
usual pause when finishing-while-adopted. Engine callbacks (`onUnsupportedVideo` /
`onRecoverableError`) are mutable vars for the same reason — each host rebinds them.

When the preview **platform view disposes**, `SharedEngine.unregisterPreviewView` also detaches
the destroyed `TextureView` from the engine (`ExoPlayerEngine.clearPreviewTexture`, an
identity-checked `clearVideoTextureView`) so ExoPlayer can't keep a reference to a dead view —
but **only when not adopted**: during an adopted fullscreen handoff the Activity owns the video
output (`claimViewSurface`/`fullscreenDetached`), and clearing there would fight the transparent
handoff.

Streams ExoPlayer can't decode (DV P5 on non-DV hardware) fall back **per channel** to the
embedded media_kit preview (the `previewEvent: unsupported`/`lost` events;
`_nativeUnsupportedIds`), which is also the only preview path on non-Android platforms.
`PlayerUiState`'s presentation fields (`title`/`isLive`/EPG/…) are mutable so the adopted
"faceless" preview state can be filled in from the Intent.

On Windows no equivalent machinery is needed: fullscreen already adopts the preview's mpv `Player`
(`existingPlayer`) and hot-swaps its `vo` to the native HWND — with a **`wid` before `vo`
ordering constraint** in `_configureNativePlayer`: setting `vo=gpu-next` on an already-playing
player before `wid` lands makes mpv spawn its own top-level window and then recreate the VO into
the child surface (a stray window flashing during the handoff). In both adopted paths the preview
is **not paused** around the handoff.

The Android handoff is made visually seamless twice over: `HdrPlayerTheme` sets
`windowDisablePreview` + a null `windowAnimationStyle` (no system starting-window / transition
black frame), and the adopted case pushes `PlayerScreen` as a **non-opaque zero-transition route**
that stays transparent (`_transparentHandoff`) so the channel list — with the preview
TextureView's frozen last frame — remains visible until the Activity's first frame.

Non-adopted fullscreen routes also use an opaque zero-duration transition. The player
starts resolving/opening as soon as the route is installed instead of spending the
default Material transition (~300 ms) behind an already-loading video surface; this
keeps preview-to-fullscreen and direct opens consistent across Android, Windows, Linux,
and other embedded builds.

**Only a *seamless adopted* handoff leaves the preview playing.** Any *other* fullscreen open
launches its own pipeline (a fresh native Activity / media_kit / Windows surface), so a preview
left running would double the audio behind it — and that includes a preview of a **different**
channel. The classic trap is the top-bar "last channel" zap (`swap_horiz`) and EPG-grid play:
they resolve fresh with `reusePreview: false`, so they never adopt the engine that's previewing
whatever else. `_openLivePlayer` handles both non-seamless shapes: a **same-channel** preview
(media_kit fallback going native-fullscreen) is *paused* and resumed on return (`pausedPreview`,
matching catch-up); a **different-channel** preview is *stopped* outright (`stoppedPreview`) — not
just paused — so it neither doubles the audio nor holds a second provider connection open (a
single-connection account would refuse the zap's new stream). A stopped preview isn't restarted.

On a TV remote the preview is **deliberate and locked**: it starts only on an explicit OK press
and stays on that channel — moving D-pad focus never starts, stops, or retargets it (only OK on a
different channel switches it), see `_deliberatePreview`/`_onChannelFocusChanged`. (Desktop keeps
its mouse-hover auto-preview.) The preview engine is stopped when the app itself backgrounds or
back-exits (Dart lifecycle observer in `channel_list_screen` + a finishing-`MainActivity.onStop`
safety net in Kotlin) so no audio survives behind the launcher.

### Two things that made the TV handoff look like a reconnect

Both are Android-TV-shaped for the same structural reason: **the preview→fullscreen handoff only
exists on a wide layout**. A phone's narrow layout goes straight to fullscreen from a fresh resolve
(`_play`'s `!isWide` branch), so none of this is on the phone path at all — "works on mobile, not on
TV" is the expected shape of a handoff bug, not evidence against one.

- **A second OK during the preview's own resolve used to restart the channel.** `_play` asked only
  "is this channel previewing *with a stream*?"; while `create_link` was still in flight the answer
  was no, so a second press fell through to `_preview.start(...)` — superseding the in-flight
  resolve with a second one (both burning single-use Stalker `play_token`s) and calling
  `SharedEngine.openPreview` → `ExoPlayerEngine.load()` on the running engine, i.e. a visible stream
  reload, after which the user still needed a *third* press to reach fullscreen. On a remote, with a
  portal that takes seconds, that second press is the normal thing to do. `decideChannelPlayAction`
  (`channel_list_screen.dart`, pinned in `test/fullscreen_handoff_test.dart`) adds the missing rung:
  a still-resolving same-channel preview is **waited on** (`LivePreviewController.pendingStart`) and
  then handed to fullscreen, never restarted; `_resolving` is held across the wait so further
  presses are swallowed rather than stacked.
- **Adoption claimed the fullscreen surface before that surface existed.**
  `SharedEngine.adoptForFullscreen` runs in `HdrPlayerActivity.onCreate`, before the Compose tree
  hosting the engine's `PlayerView` is attached — and `ExoPlayer.setVideoSurfaceView` on a
  SurfaceView whose holder has no surface sets the video output to **null** and waits for
  `surfaceCreated`. So the decoder made two output transitions (preview texture → placeholder →
  the Activity's surface) where the handoff is supposed to make one, and on any device in media3's
  `codecNeedsSetOutputSurfaceWorkaround` list — thick with TV/set-top chipsets — each transition
  releases and re-instantiates the video codec, meaning two waits for the next IDR on a live
  MPEG-TS stream. `ExoPlayerEngine.claimViewSurface` now defers the swap to `surfaceCreated` (with a
  1 s backstop for a view that never attaches, and cancellation from `attachPreviewTexture`/
  `release`), collapsing it back to one transition.

**The surface-claim half is measured, on an Android TV emulator** (API 36 `android-tv` x86_64, 4K,
demo source, live HLS): the same preview→fullscreen handoff was run against a build with the old
immediate claim and one with the deferred claim, counting
`MediaCodec: [c2.goldfish.h264.decoder] setting surface generation` / `Surface configure completed`
pairs in logcat between `START … HdrPlayerActivity` and `Displayed`:

| build | decoder output-surface reconfigurations | when |
| --- | --- | --- |
| immediate claim (old) | **2** | +183 ms (surfaceless → placeholder), +977 ms (real surface) |
| deferred claim (new) | **1** | +948 ms (real surface) |

So the extra transition is real and the fix removes it. The emulator's goldfish decoder handles
`setOutputSurface` natively, so both builds report `Displayed` at ~1.0–1.2 s — the win is not
visible *there*, and won't be on any device outside media3's
`codecNeedsSetOutputSurfaceWorkaround` list. On a device that is on it, each of those two
transitions is a codec release + re-instantiate + IDR wait, which is what the reports describe;
that part remains unconfirmed until a real TV is measured. Adoption itself was confirmed working on
the emulator (`iptvs.shared: fullscreen adopted the shared preview engine`, video carried across
with no black frame, and the preview alive again on return).

**What remains of the handoff latency is Activity start + surface allocation, not the stream.**
Instrumented on the emulator (warm process, so no class-loading), from `START HdrPlayerActivity`:
+93 ms adoption (inside `onCreate`), +97 ms `setContent` returns, +208 ms the Compose body first
runs, +358 ms `surfaceCreated`, +376 ms the decoder is on the new surface, +471 ms `Displayed`. A
cold first open is roughly double, dominated by the same phases.

**Hoisting the video view out of Compose was tried, measured, and reverted — don't try it again
without new evidence.** The idea was that hosting the engine's `PlayerView` in a `FrameLayout`
attached in `onCreate`, with the `ComposeView` above it, would let the surface be allocated *while*
the overlay composes instead of after it. Built and run on the emulator, it moved nothing:
`surfaceCreated` at +374 ms and `Displayed` at +511 ms against +358/+471 for the Compose-hosted
build, inside a run-to-run spread (471–1030 ms before, 511–754 ms after) far wider than any
difference. The reason is structural, not a tuning miss: `AndroidView` adds the SurfaceView **during
the first composition**, and that composition happens inside the window's *first traversal* — the
same traversal that lays out a pre-attached view. There is no second traversal to save, and the
~150 ms between composition and `surfaceCreated` is surface allocation (4K buffers here), which
neither arrangement can shorten. The revert also gave back the costs the hoist carried: a manual
view swap on the mpv fallback, a Compose root that had to stay transparent so the SurfaceView's
punch-hole showed through, and PiP/aspect paths reasoning about a hierarchy Compose no longer owned.

To make the same thing confirmable in the field, `HdrPlayerActivity` now reports the handoff
outcome into the **exportable**
diagnostics log (`MainActivity.logPlaybackDiagnostic` → Dart `nativeDiagnostic` → `_logPlayback`):
`native fullscreen adoptShared=… adopted=…`, which pairs with the channel list's
`fullscreen open decision=…` line. `adoptShared=true adopted=false` means the URL Dart asked to
adopt didn't match the one `SharedEngine` was playing and the Activity silently reloaded — a real
reconnect, and previously visible only in logcat. Keep anything sent through that relay
credential-free: it is exported verbatim.

## PiP note

When `HdrPlayerActivity` enters picture-in-picture it is reparented into its own **pinned task**,
so `moveTaskToBack()` from the player would hide the PiP window itself (black screen). To show the
launcher behind the PiP window it instead calls `MainActivity.instance` (a `WeakReference`
companion) to move the *main* task back.

## Live auto-reconnect

A live stream that stalls (buffering) or drops (error/EOF) is reconnected by **reloading the
source** with capped backoff (≈8s stall threshold, ≤30s between attempts), surfacing a
"Reconnecting…" indicator until playback resumes — VOD is untouched (it keeps the manual
error/Retry overlay). On the Dart watchdogs a reload **re-resolves the stream first** when the
caller wired `PlayerScreen.resolveAgain` (Stalker `create_link` tokens are single-use, so a
portal-side kill leaves the original URL permanently dead; falls back to the original URL when
unwired or the resolve fails). **Four independent watchdogs** because the platforms play through
different stacks:

- **Android** in `HdrPlayerActivity` (its 500ms progress ticker watches `PlayerUiState`;
  ExoPlayer network errors that leave it idle trigger an immediate reconnect). Its reload
  **re-resolves first** through `withFreshLiveLocator`/`ResolveGate`
  (`android/.../player/LiveResolve.kt`) — a Stalker `play_token` the portal already killed can
  never work a second time — single-flight with "Go to live" (see "Android" above) and falling
  back to the held locator if the round trip times out or fails.
- **iOS**, Swift-side and Kotlin-shaped: `IptvsPlayerViewController` runs its own progress
  watchdog (`LiveReconnectWatchdog`,
  `packages/iptvs_ios_player/ios/Core/Sources/IptvsPlayerCore/LiveReconnectWatchdog.swift`) —
  same constants, same `minGapMs` shape as Android's Kotlin `ReconnectPolicy` and Dart's
  `reconnectMinGapMs`, so backoff timing is identical regardless of engine. Its reload
  **re-resolves first**, through the same `resolveAgain` round trip live opens use (a
  `FreshLocator` parsed from Dart's reply, falling back to the held locator on timeout/failure —
  see docs/ios.md). Two iOS-specific traits: the watchdog is **inert before the stream's first
  frame** (`hasEverStarted`) — that pre-start window belongs entirely to
  `PlaybackStartBackstop` — and a live stream that never starts within 10s hands off to the mpv
  fallback (`engineFailed`, `reason: "no-first-start"`) rather than reconnecting on the usual
  8s/16s/24s/30s backoff cadence, because a stream that has never once played is indistinguishable
  from an unplayable container. Once a stream *has* played, a later drop reconnects exactly like
  every other platform's watchdog — switching engines at that point would permanently downgrade a
  working HDR channel to tone-mapped SDR over what is really just a network blip.
- **Windows/embedded** in `player_screen.dart` (a 1s `Timer` watching media_kit's buffering/error
  streams — the Dart `_player` only plays on these paths). A **clean server-side EOF** needs its
  own trigger here: mpv maps it to `eof-reached`, which media_kit surfaces as `completed=true`
  *and* `buffering=false` — invisible to the buffering-gated stall poll, and `reconnect_at_eof`
  can't compensate (it hangs HLS manifest reads on FFmpeg 8; see `mpv_options.dart`). So a
  `stream.completed` listener treats a *live* `completed` as a drop (pure decision:
  `shouldReconnectOnCompleted`, pinned in `test/reconnect_policy_test.dart`) — VOD completing is
  a legitimate end of playback and is left alone, and app-initiated `stop()` resets
  `completed` to false so teardown/handoffs never trip it. The listener's `nativeSessionActive`
  suppression is deliberately derived as `_linuxNativeSession != null || ((Platform.isAndroid ||
  Platform.isIOS) && _nativePlaybackLaunched)` — i.e. it fires **only** when a *separate* engine
  owns playback and this `_player` sits idle (Linux native mpv, Android native Activity, and now
  iOS's presented `IptvsPlayerViewController` for the same reason: AVPlayer owns playback out of
  process, so this `_player`'s own `completed` describes a stopped/idle engine, not the stream).
  The **Windows native HDR path is not a native session for this purpose**: it renders through
  this *same* `_player` (a `vo` swap onto the HWND, no separate engine), so its `completed` is a
  genuine live EOF and must reconnect — `_reconnectLive` reopens `_player` on the HWND surface,
  the same reopen `_goToLive` already does. (Earlier this counted plain `_nativePlaybackLaunched`, which is true on Windows
  native and wrongly froze HDR-live on the last frame.)
- **Linux native** in `player_screen.dart` too, but the mpv process is a *separate OS process*
  whose media_kit `_player` is idle, so the watchdog is driven off mpv's JSON-IPC signals
  (`LinuxNativeSession.playbackEvents`, a `LinuxNativePlaybackSignal` stream). `end-file` with
  reason `error`/`eof` is a **drop** (a user quit / Dart dispose reports reason `quit`/`stop` and
  is deliberately *not* surfaced, so exiting never triggers a reconnect); an observed
  `paused-for-cache=yes` is a **stall** (mpv reports the cache-induced pause here, never a user
  pause — unlike `core-idle` — so it's a clean stall signal); `file-loaded`/`playback-restart`
  is a **resume** (deliberately *not* `paused-for-cache=no`, which mpv briefly reports at
  `end-file` and would race a drop). A drop/stall sets the same `_buffering` flag the embedded
  watchdog uses (so `_pollLiveReconnect`'s 8s threshold, attempt-scaled backoff, counter reset
  and chip-clearing all apply unchanged) and a drop additionally forces an immediate first retry.
  This matters because with `--keep-open=yes --idle=yes` a dropped stream would otherwise freeze
  on the last frame indefinitely, and mpv's own network-timeout before an `end-file error` can be
  ~60s — the `paused-for-cache` stall path lets the watchdog reconnect at the 8s threshold
  instead of waiting for that. The reload is a `loadfile <url> replace` on the native session
  (same URL the embedded watchdog reopens, same call "Go to live" uses).

The **live preview** gets the same clean-EOF resilience in miniature: `LivePreviewController`
listens to its player's `completed` stream and auto-restarts the *same* channel (a fresh
`start()`, i.e. a fresh resolve — tokens are single-use), rate-limited by the shared
`reconnectMinGapMs` policy and capped at 3 consecutive immediate EOFs before surfacing "Stream
ended". It only ever restarts the channel the user already chose (the "preview is deliberate and
locked" rule), and an app-initiated stop/pause (`_activeChannel` cleared / `_pausedByApp`) never
triggers it.

The reconnect **timing policy** — stall threshold, attempt-scaled capped backoff — is shared
Dart (`reconnectMinGapMs` in `player_screen.dart`, used by the embedded and Linux paths and the
preview's EOF restart), mirroring the Android pure `ReconnectPolicy` object
(`android/.../player/ReconnectPolicy.kt`);
pinned by `test/reconnect_policy_test.dart` (Dart) and the plain-JUnit `ReconnectPolicyTest`
(Kotlin). The same **reload** is how "Go to live" works, since live IPTV is typically
non-seekable. The Linux reconnect reuses the already-counted `_reconnectTimer`
(`ResourceCounters.reconnectTimers`, created for any live playback) — no extra timer — so
open/close cycles stay balanced.

**Native VOD terminal behavior**: the Linux native path has no error/Retry overlay (mpv owns the
surface). A VOD stream that errors/ends does *not* auto-reconnect (contract); mpv's
`--keep-open=yes` holds the last frame and Back (ESC / overlay back → `quit`) exits cleanly. A
terminal VOD error therefore looks like a frozen last frame from which Back returns to the list.

**iOS is the opposite of Linux native here: it does have a native terminal error/Retry overlay.**
`IptvsPlayerViewController.surfaceTerminalError` puts up the same three things
`PlayerErrorOverlay` (`player_overlay.dart`) does — scrim, message, Back + Retry — deliberately a
mirror rather than a new design, reached only where nothing else can act: a VOD hard failure (live
reconnects instead), a VOD reload that never comes back, and an `engineFailed` that has no plugin
channel left to hand off through (see docs/ios.md "New contracts"). Retry goes through the same
`resolveAgain` round trip a live reload uses rather than replaying the original request URL —
Dart leaves `resolveAgain` unwired for VOD (only live channels pass it,
`channel_list_screen.dart`), so `_freshLiveStream` answers with the original stream, which is
exactly what a VOD retry wants, at the cost of one extra method call and no VOD-specific branch on
the Swift side.

## Headers and logging

Playback headers (e.g. a MAG `User-Agent` / `Referer` for Stalker) are passed both to
`Media(httpHeaders:)` and set as mpv `user-agent`/`referrer` properties. mpv's
`http-header-fields` is a comma-separated *string* list, so a header value containing a literal
comma (the default MAG user-agent's `(KHTML, like Gecko)`) must never be naively joined: the
Linux native session sends the headers as a **native JSON array** over IPC
(`buildHeaderFieldsCommand`), and Android's `MpvController.applyHeaders` encodes each item with
mpv's `%n%` **raw-length quoting** (UTF-8 byte counts; `MpvOptionEncoding`, pinned by
`MpvOptionEncodingTest`) since the libmpv AAR only exposes string setters. All playback logs go
through `_logPlayback`, which redacts URLs via `_redactPlayback`.

## MethodChannel handler ownership

The two inbound native→Dart channels — `iptvs/native_hdr_player` (Android `nativeClosed` with
position/duration/favorite; Windows `nativeControl`/`nativeInput` from the GDI overlay; iOS
reuses the same channel name and adds `nativeClosed` (position/duration, same as Android),
`nativePlayback` — carrying **two** distinct events (`PlaybackEventPayload`,
`packages/iptvs_ios_player`) — `engineFailed` when AVPlayer can't play the container, and
`hostVisibility`, a **fire-and-forget** report of `appActive`/`pipActive` sent on every real UIKit
foreground/background/PiP transition (unconditionally, not gated on whether a fallback happens to
be pending — the plugin has no way to know that), which is the wake signal for a deferred
`engineFailed` fallback that bypasses Flutter's lifecycle plumbing entirely, and
`resolveAgain` — unlike either of those, a call-and-response: the presented controller's own watchdog
calls *into* Dart to request a fresh locator (single-use Stalker `play_token`s die with the
failed/stale URL the native side is holding), and `_freshLiveStream`'s return value flows back to
Swift as the method call's result) and
`iptvs/native_preview` (`previewEvent`: unsupported/lost/error) — are **process-static**, so two
widget/controller instances can race over the single handler slot during route transitions
(Flutter runs a replacement route's `initState` *before* the old route's `dispose`). Ownership is
guarded by `ChannelHandlerOwner` (`lib/player/channel_owner.dart`), a monotonic owner-token
registry (the repo's generation-guard idiom):

- `claim(handler)` bumps the token and installs a wrapper that **ignores calls to superseded
  tokens**; `release(token)` clears the platform handler **only if that token is still current**
  — so an old route's dispose can never null a newer route's handler, and repeated route cycles
  leave exactly one active owner (or zero after the sole owner releases).
- The real handlers keep a second gate for calls already dispatched into the wrapper before a
  clear: `_handleNativeHdrMethodCall` bails on `!mounted`, `LivePreviewController._handleNativeCall`
  on `_disposed` — a popped player ignores late position/favorite/error callbacks.
- Cleanup is **identical on Android, Windows, and iOS** by construction: all three platforms run
  the same ungated `release(token)` in `dispose` (previously Windows-only cleared, Android never
  did).
- The native sides register their channel handlers once per process and are **owner-agnostic**
  (no per-Dart-owner state in Kotlin or C++) — handler ownership is purely Dart-side.

Pinned by `test/channel_owner_test.dart` (claim/release/supersede semantics via
`TestDefaultBinaryMessengerBinding`); the `mounted`/`_disposed` gates inside the real handlers are
verified by inspection (instantiating `PlayerScreen` needs a live media_kit engine).

## Debug resource counters + lifecycle soak

Debug-only counters track every player-lifecycle resource, in the layer that owns it, and must
**return to zero after a full open/close cycle** — a nonzero settled count means a leak:

- **Dart** (`lib/player/resource_counters.dart`, `kDebugMode`-gated): `mediaKitPlayers`
  (constructed at `LivePreviewController._createPlayer` and PlayerScreen's fresh-`Player` branch —
  an *adopted* player is counted once by its creator and decremented by whoever actually calls
  `dispose()`: `discardPlayer` after a Windows hot-swap, or the controller's own `dispose`),
  `reconnectTimers` (the 1s live watchdog), `channelOwners` (`ChannelHandlerOwner.claim`/`release`
  — release decrements unconditionally since every claimant releases exactly once, even
  superseded), `linuxNativeSessions` (`LinuxNativeSession` — incremented when `_open` assigns a
  successfully started session; each of the three teardown routes — `_finishLinuxNativePlayback`
  (process exited on its own), `_exitAndPop` (user-initiated Back), and `dispose()` (last-resort)
  — decrements only if it's the one that actually finds the session non-null and nulls it, so
  whichever teardown path runs first is the sole decrementer. The latter two share one
  implementation, `_teardownLinuxNative`, which claims the session synchronously before its first
  `await` so overlapping teardowns can't double-decrement; a fourth, pre-adoption abort — the
  route popped while `LinuxNativeSession.start` was still connecting — disposes the session
  without ever incrementing). Two player-owned `Timer`s are deliberately *outside* this set
  because a counted owner already bounds them: `PlayerScreen`'s 30s VOD position-persist timer
  (bounded by the route) and `LinuxNativeSession`'s 1 Hz VOD position poll (bounded by the
  session, itself counted as `linuxNativeSessions`). The `Player`'s `VideoController` is likewise
  uncounted — it has no independent teardown (disposing the `Player` releases it) — and on Android
  is now built lazily, only if the embedded fallback actually renders.
- **Kotlin** (`android/.../player/DebugCounters.kt`, `BuildConfig.DEBUG`-gated `AtomicInteger`s):
  `exoEngines`/`mpvEngines` (constructor ↔ now-idempotent `release()`), `previewViews`
  (`PreviewPlatformView` init/dispose), `progressTickers` (launch ↔ `invokeOnCompletion`),
  `sharedEngineLive` (the `SharedEngine.engine` setter — a single choke point, so the adoption
  handoff stays balanced).
- **C++** (`windows/runner/flutter_window.cpp`, `#ifndef NDEBUG`): `windowsSurfaces` /
  `windowsOverlays` — incremented only when `CreateWindowEx` actually creates (the reuse path
  doesn't count), decremented on real destroys; `windowsOverlayDibs` — the cached overlay
  back-buffer DIB (0/1), created lazily on first paint and freed in `DestroyNativeControls`.
  Platform-thread-confined plain ints.
- **Swift** (`IosDebugCounters.swift`, `packages/iptvs_ios_player/`, landed, `#if DEBUG` only):
  `iosAvPlayers` (`AvPlayerEngine` init ↔ idempotent `release()`), `iosPlayerControllers`
  (`IptvsPlayerViewController` init ↔ deinit — stays at 1 for the whole of a PiP session, since
  the plugin holds a deliberate strong reference so the layer keeps feeding the PiP window),
  `iosPipControllers` (`IosPipController` init ↔ deinit), `iosTimeObservers`, `iosAudioClients`
  (a *set size* — `IosDebugCounters.set`, mirroring `AudioSessionClients.count` directly rather
  than an increment/decrement pair, so a claim that's never released is visible as a nonzero
  settled count instead of silently drifting). `iosTimeObservers` earns its own counter rather
  than folding into `iosAvPlayers` because an un-removed periodic time observer
  (`AVPlayer.addPeriodicTimeObserver`) **retains the `AVPlayer` itself for the lifetime of the
  observer** — the classic AVFoundation leak, and one that would otherwise show up only as "the
  player never deallocates," not as an obviously-linked counter mismatch. A plain `NSLock`
  guards the map rather than main-thread confinement, because `AvPlayerEngine.deinit`/
  `IosPipController.deinit` are not guaranteed to run on the main queue.

`ResourceCounters.snapshot()` merges the Dart counts with the natives' reply to a `debugCounters`
method on `iptvs/native_hdr_player`, called on **Android, Windows, and iOS**
(`Platform.isAndroid || Platform.isWindows || Platform.isIOS`, `resource_counters.dart`) —
deliberately *not* a new inbound channel — no new handler ownership surface; a missing method,
platform exception, or wrong reply shape just omits the native keys rather than throwing, and
release builds reply with an empty map. The snapshot renders in a `kDebugMode`-only section of
the diagnostics screen.

The **100-cycle soak** (`integration_test/player_soak_test.dart`, never run by CI or plain
`flutter test`) cycles `PlayerScreen` push/pop and preview start/stop on real hardware —
`flutter test integration_test/player_soak_test.dart -d windows|<android>` — then asserts every
counter is zero. It never asserts playback state (the soak device's network may not reach the
demo streams). On Android, `PlayerScreen.debugSoakAutoCloseMs` (debug-only, passed as
`soakAutoCloseMs` on the native `open` call → `EXTRA_SOAK_AUTOCLOSE_MS`) makes
`HdrPlayerActivity` finish itself each cycle so the soak runs unattended; the extra is inert in
release builds.
