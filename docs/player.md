# Player — full detail

`lib/player/player_screen.dart` plays a resolved `StreamInfo` via `media_kit`, with two
platform-specific native-HDR paths layered on top of the embedded path. The compact rules live in
CLAUDE.md; read this before changing playback, preview, or overlay code.

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

## Windows

Renders into a native HWND surface (`createSurface`) so mpv presents directly through D3D11 (real
HDR) instead of round-tripping through Flutter's SDR texture (`vo=gpu-next`,
`gpu-context=d3d11`, `hwdec=auto-safe` — `auto-safe` negotiates d3d11va zero-copy and falls back
to software cleanly; a *forced* `d3d11va` could half-init and desync). Control state is mirrored
to native via `setControlState` (Dart→C++) / `nativeControl` (C++→Dart commands); the GDI overlay
(`windows/runner/flutter_window.cpp`) draws the **same control set, badges, live EPG strip,
go-to-live, and "Reconnecting…" indicator** as the Android Compose overlay. The controls overlay
is a layered window clipped to a region covering only the top+bottom bars (+ open menu/info), so
anything drawn must fall inside it — `UpdateNativeControlState` rebuilds the region when the bar
height changes (e.g. the taller live-EPG bar).

**Dynamic range** here comes from mpv's `video-params` (`gamma`/`primaries`/`colormatrix`, in
`_dynamicRangeLabel`) — mpv/libavcodec already parse the in-band VUI/SEI, so this matches the
decoder-authoritative Android path for SDR/HDR10/HLG/DV without the `Format.colorInfo` gap.
**HDR10+** is best-effort (mpv exposes no clean flag): `_probeHdr10Plus` reads the ST2094-40
per-scene sub-properties (`video-params/scene-max-r|g|b`, `scene-avg`) — non-zero only with real
dynamic metadata, and *not* synthesised by `hdr-compute-peak` (so no false-positive on plain
HDR10) — and upgrades PQ→"HDR10+ · PQ"; any missing property/error stays at "HDR10". Older mpv
builds without those sub-properties simply under-report (HDR10).

A **mini-player** mode (`setMiniPlayer`, toggled with the `M` key) restyles the top-level window
into a compact frameless always-on-top window docked bottom-right — draggable via the video area
(manual `WM_NCLBUTTONDOWN`/`HTCAPTION` from the surface WndProc), resizable via `WS_THICKFRAME`,
mutually exclusive with fullscreen, restoring the saved placement on exit/`prepareExit`.

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

## PiP note

When `HdrPlayerActivity` enters picture-in-picture it is reparented into its own **pinned task**,
so `moveTaskToBack()` from the player would hide the PiP window itself (black screen). To show the
launcher behind the PiP window it instead calls `MainActivity.instance` (a `WeakReference`
companion) to move the *main* task back.

## Live auto-reconnect

A live stream that stalls (buffering) or drops (error/EOF) is reconnected by **reloading the
source** with capped backoff (≈8s stall threshold, ≤30s between attempts), surfacing a
"Reconnecting…" indicator until playback resumes — VOD is untouched (it keeps the manual
error/Retry overlay). Two independent watchdogs because the two platforms play through different
stacks: Android in `HdrPlayerActivity` (its 500ms progress ticker watches `PlayerUiState`;
ExoPlayer network errors that leave it idle trigger an immediate reconnect); Windows/embedded in
`player_screen.dart` (a 1s `Timer` watching media_kit's buffering/error streams — the Dart
`_player` only plays on these paths). The same **reload** is how "Go to live" works, since live
IPTV is typically non-seekable.

## Headers and logging

Playback headers (e.g. a MAG `User-Agent` / `Referer` for Stalker) are passed both to
`Media(httpHeaders:)` and set as mpv `user-agent`/`referrer` properties. All playback logs go
through `_logPlayback`, which redacts URLs via `_redactPlayback`.

## MethodChannel handler ownership

The two inbound native→Dart channels — `iptvs/native_hdr_player` (Android `nativeClosed` with
position/duration/favorite; Windows `nativeControl`/`nativeInput` from the GDI overlay) and
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
- Cleanup is **identical on Android and Windows** by construction: both platforms run the same
  ungated `release(token)` in `dispose` (previously Windows-only cleared, Android never did).
- The native sides register their channel handlers once per process and are **owner-agnostic**
  (no per-Dart-owner state in Kotlin or C++) — handler ownership is purely Dart-side.

Pinned by `test/channel_owner_test.dart` (claim/release/supersede semantics via
`TestDefaultBinaryMessengerBinding`); the `mounted`/`_disposed` gates inside the real handlers are
verified by inspection (instantiating `PlayerScreen` needs a live media_kit engine).
