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

The embedded media_kit top bar compacts EPG now/next into one ellipsized line. This keeps the
overlay within short desktop/Linux video heights while retaining both programme labels; native
Android/Windows overlays keep their existing platform-specific EPG layout.

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
  decision. Every downstream boolean (`existingPlayer` gating,
  pause/stop/restore-mute behavior) derives from the returned enum via the
  `FullscreenHandoffDerived` getters — never from stale pre-await values. Only
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
Linux fallback (`_LinuxPlayerControls` in `player_overlay.dart`), not a
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
unwired or the resolve fails). **Three independent watchdogs** because the platforms play through
different stacks:

- **Android** in `HdrPlayerActivity` (its 500ms progress ticker watches `PlayerUiState`;
  ExoPlayer network errors that leave it idle trigger an immediate reconnect).
- **Windows/embedded** in `player_screen.dart` (a 1s `Timer` watching media_kit's buffering/error
  streams — the Dart `_player` only plays on these paths). A **clean server-side EOF** needs its
  own trigger here: mpv maps it to `eof-reached`, which media_kit surfaces as `completed=true`
  *and* `buffering=false` — invisible to the buffering-gated stall poll, and `reconnect_at_eof`
  can't compensate (it hangs HLS manifest reads on FFmpeg 8; see `mpv_options.dart`). So a
  `stream.completed` listener treats a *live* `completed` as a drop (pure decision:
  `shouldReconnectOnCompleted`, pinned in `test/reconnect_policy_test.dart`) — VOD completing is
  a legitimate end of playback and is left alone, and app-initiated `stop()` resets
  `completed` to false so teardown/handoffs never trip it.
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
  without ever incrementing).
- **Kotlin** (`android/.../player/DebugCounters.kt`, `BuildConfig.DEBUG`-gated `AtomicInteger`s):
  `exoEngines`/`mpvEngines` (constructor ↔ now-idempotent `release()`), `previewViews`
  (`PreviewPlatformView` init/dispose), `progressTickers` (launch ↔ `invokeOnCompletion`),
  `sharedEngineLive` (the `SharedEngine.engine` setter — a single choke point, so the adoption
  handoff stays balanced).
- **C++** (`windows/runner/flutter_window.cpp`, `#ifndef NDEBUG`): `windowsSurfaces` /
  `windowsOverlays` — incremented only when `CreateWindowEx` actually creates (the reuse path
  doesn't count), decremented on real destroys. Platform-thread-confined plain ints.

`ResourceCounters.snapshot()` merges the Dart counts with the natives' reply to a `debugCounters`
method on `iptvs/native_hdr_player` (deliberately *not* a new inbound channel — no new handler
ownership surface; release builds reply with an empty map). The snapshot renders in a
`kDebugMode`-only section of the diagnostics screen.

The **100-cycle soak** (`integration_test/player_soak_test.dart`, never run by CI or plain
`flutter test`) cycles `PlayerScreen` push/pop and preview start/stop on real hardware —
`flutter test integration_test/player_soak_test.dart -d windows|<android>` — then asserts every
counter is zero. It never asserts playback state (the soak device's network may not reach the
demo streams). On Android, `PlayerScreen.debugSoakAutoCloseMs` (debug-only, passed as
`soakAutoCloseMs` on the native `open` call → `EXTRA_SOAK_AUTOCLOSE_MS`) makes
`HdrPlayerActivity` finish itself each cycle so the soak runs unattended; the extra is inert in
release builds.
