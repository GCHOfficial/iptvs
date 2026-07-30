# iOS

**Status: in progress, nothing shipped yet.** This document records the scope, the two
distribution paths, and the player design (a single full-hybrid release — no staged
`v1`/`v2` split; see "Shipping plan" under Player). **The Dart side is real and tested, the
plugin's host-visibility reporting is real and tested, and the player surface itself is not
written.** Every Dart contract this design commits to is implemented and covered by the suite:
`selectIosEngine`/`IosEngineMemo` (`lib/player/ios_engine.dart`), the cross-engine fullscreen
handoff (`decideFullscreenHandoff`'s `crossEngineFullscreen` flag, `channel_list_screen.dart`,
pinned by `test/fullscreen_handoff_test.dart` and `test/ios_engine_selection_test.dart`), the
`nativePlayback` (`engineFailed`/`hostVisibility`)/`resolveAgain` handling and the never-dead-ends
fallback gate (`decideIosFallbackAction`, `IosFallbackAction`, pinned by
`test/ios_fallback_gate_test.dart`) in `PlayerScreen` (`lib/player/player_screen.dart`), and
`iosManageAudioSession: false` at both `PlayerConfiguration` sites. On the Swift side,
`packages/iptvs_ios_player/`'s `IptvsIosPlayerPlugin` (`ios/Classes/`) already owns the real
process-wide host-visibility reporting — `UIApplication` notification observers,
`currentHostVisibility()`, `emitEngineFailed`, the `IptvsPipStateProviding` registration point —
backed by the Foundation-only `Core` SwiftPM target's `HostVisibility`/`HostVisibilityTracker`/
`PlaybackEventPayload` (plus `ReconnectPolicy`/`EngineSelection`/`PlayerBackPolicy`/
`DynamicRangeLabel`), covered by `swift test`. What is **not** written is
`IptvsPlayerViewController` itself — the presented AVPlayer surface described below, and the only
thing the `open` method-channel call and the PiP provider registration are waiting on. Nothing
plays through AVPlayer on iOS today; every Dart and plugin path described above is exercised only
by tests and by the mpv-fallback code paths that already run through the ordinary embedded
`media_kit` surface.

iOS is a **phone/tablet target only**. tvOS is explicitly out of scope (Flutter
has no official tvOS support), so Apple TV is not a counterpart to the Android TV
target and the D-pad navigation system in `docs/tv-navigation.md` degrades to
plain touch here.

## Why not the App Store

Deliberate decision, not a deferral. App Review guideline 5.2.3 rejects apps
offering "potentially unauthorized access to third-party audio or video
streaming" and requires documentary proof of streaming rights in App Store
Connect. `iptvs` ships no content, no channel lists, no provider directory and no
preloaded playlists — but defending that framing is a per-submission gamble with
no durable outcome, and every accepted submission would still have to give up the
update pipeline and carry a permanent review-risk overhang.

The shipping path below is a **sideload** path. It does not involve App Review.

Consequences that follow from this and must not be quietly reversed:

- **No direct updater on iOS, ever.** The Ed25519-signed manifest + binary
  replacement in `docs/updates.md` is impossible inside the iOS sandbox.
  AltStore owns the update lifecycle.
- The demo content reachable through `DemoSource` should stay rights-clear
  (public domain or self-hosted test streams). That is now a hygiene matter
  rather than a review matter, but the reason to keep it true is unchanged.

## Distribution

**AltStore Classic only.** AltStore PAL was evaluated and deliberately dropped —
see the decision record below.

| | AltStore Classic |
|---|---|
| Reach | Worldwide |
| Signing | User's own free Apple ID |
| Notarization | None |
| Apple Developer Program | Not required |
| Cost to you | **$0** |
| Cost to users | $0 |
| Expiry | **7 days**, user re-signs |
| Apps per device | 3 (free-Apple-ID limit) |
| Artifact | `.ipa` |

**AltStore charges nothing** — not to developers, not to users, on either of its
paths. Classic costs $0 outright: build unsigned (`flutter build ios
--no-codesign`) and users re-sign with their own free Apple ID. A macOS build
host is required, but GitHub Actions `macos` runners are free for public
repositories, so the realistic total cost of iOS support is zero.

### Decision: AltStore PAL dropped

PAL would have given permanent installs with no 7-day expiry and no per-device
app limit — a materially better user experience. **Rejected on cost/benefit:**
it requires the $99/yr Apple Developer Program, because PAL distributes only
Apple-**notarized** apps and notarization requires a Developer Program account
plus an Apple-issued alternative-distribution certificate. That signature *is*
the permanence; there is no way to obtain one without paying. It is Apple's
charge, not AltStore's.

`iptvs` earns no revenue, and PAL is additionally **EU-only**, so a recurring
annual fee for a fraction of an already-small sideloading audience is not
justified. The 7-day refresh cycle is accepted as the cost of the platform.

To revisit later, the delta is bounded and additive — nothing here forecloses it:
a second bundle identifier, an alternative-distribution export alongside the
existing one, a notarization step, and a second source manifest whose
`downloadURL` points at the ADP `manifest.json` rather than the `.ipa` and which
carries a `marketplaceID`. The schema is otherwise identical. Note that a PAL
build could never upgrade in place over a Classic install regardless — iOS
refuses to update across a different signing identity — so adding PAL later means
a side-by-side install and a cloud push/pull migration, not an in-place upgrade.

### Bundle identities

Following the existing side-by-side convention in `docs/store-publishing.md`:

| Channel | Bundle identifier |
|---|---|
| AltStore Classic | `com.gchofficial.iptvs.player.sideload` |
| Development | `com.gchofficial.iptvs.player.dev` |

`com.gchofficial.iptvs.player.pal` is reserved by convention should PAL ever be
revived; do not reuse it for anything else.

The manifest `bundleIdentifier` is **case-sensitive and must match `Info.plist`
exactly**.

### Source manifest

One manifest, generated per release, with `downloadURL` pointing at the `.ipa`.
`marketplaceID` is omitted — it is required only for PAL.

Required source fields: `name`, `apps`, `news`. Required per app: `name`,
`bundleIdentifier`, `developerName`, `localizedDescription`, `iconURL`,
`versions`, `appPermissions`. Required per version: `version` (maps to
`CFBundleShortVersionString`), `buildVersion` (`CFBundleVersion`), `date`
(ISO 8601), `downloadURL`, `size` (bytes).

**The source URL must be stable and the file must be regenerated per release.**
Users add the source once; its `downloadURL`s change every release. The release
workflow must rewrite it, prepending the new entry to `versions` (keep history;
AltStore uses it to offer downgrades).

Generated by `tool/generate_altstore_source.dart` — idempotent and prepend-only,
so re-running it for an already-present `version`+`buildVersion` is a true no-op.
Run `dart run tool/generate_altstore_source.dart` with no arguments for usage.

**Hosting is an open decision.** Three options, none yet chosen:

1. **`releases/latest/download/source.json`** *(recommended)* — GitHub resolves
   this URL to the newest release's asset automatically, so it is stable without
   any commit-back-to-`main`, and `release.yml` already uploads assets. Cost: the
   generator must fetch the current manifest from that URL before regenerating, and
   the job **must fail closed if that fetch fails on a non-first release** — silently
   emitting a single-version manifest would erase users' downgrade history.
2. **Committed `altstore/source.json` on `main`**, served via
   `raw.githubusercontent.com`. Most durable (history lives in git) and simplest to
   reason about, at the cost of a bot commit per release and the usual care around
   not retriggering CI.
3. **GitHub Pages** — note this is *already occupied*: `.github/workflows/pages.yml`
   publishes the `panel/` site, and Pages allows one deployment per repository. Using
   it would mean folding the manifest into the panel's build output and coupling
   AltStore releases to a workflow that currently only runs on `panel/**` changes.
   Least attractive of the three for that reason.

`release.yml` already produces an AI-generated changelog; reuse it verbatim for
the version's `localizedDescription` so the AltStore entry matches the GitHub
release body.

### Distribution channels in code

`lib/data/distribution_channel.dart` needs **one** new member — `altStore`. The
plumbing is small: `DistributionConfig` is consumed at exactly three sites
([update_installer.dart:52](../lib/data/update_installer.dart#L52),
[home_shell.dart:98](../lib/screens/home_shell.dart#L98),
[sources_screen.dart:279](../lib/screens/sources_screen.dart#L279)), all gated on
`directUpdaterEnabled`, and `isStoreManaged` currently has no consumer at all.

Setting `ownsDirectUpdates = false` switches off the entire update UI without
touching those three call sites. AltStore owns the update lifecycle by reading
the source manifest.

Optional polish, not launch scope: because Classic builds carry a **7-day
provisioning expiry**, the bundled `embedded.mobileprovision` can be parsed at
launch for its `ExpirationDate` to show a "refresh in AltStore" hint before the
app stops opening. This is the one piece of UI that exists only because PAL was
dropped.

## Player

Full HDR, Dolby Vision, and PiP are achievable on iOS — but only through
AVFoundation, and only for containers AVFoundation accepts.

### Shipping plan: the full hybrid, first release

**Decided 2026-07-29**, superseding an earlier staged plan that would have shipped
an mpv-only v1 first. The intent is to ship the app as it is meant to be built and
get feedback on the real thing, rather than on a knowingly degraded tier.

An earlier draft argued for mpv-only-first on a coverage asymmetry: AVPlayer cannot
play raw MPEG-TS or MKV, so an AVPlayer-*only* build is incomplete, while an
mpv-only build is complete but SDR. **That reasoning is still correct and still
load-bearing** — it is now the justification for the engine-selection rule that
routes every *unknown* container to mpv (see below) rather than a release-staging
argument.

Two things that made this viable, both now resolved rather than assumed:

- **The audio-session blocker is fixed** — `media_kit` is git-pinned to the
  `iosManageAudioSession` commit (Constraint 1 above).
- **A Mac is not required.** GitHub-hosted macOS runners provide Xcode 26.5,
  CocoaPods and an iOS Simulator, so Swift compiles, links, and can be smoke-tested
  in CI. The real constraint is an **iPhone for validation** (HDR, PiP, hardware
  decode, sustained live playback), which the AltStore sideload path supplies.
  What is genuinely lost without a Mac is **iteration speed**: ~4 minutes per
  compile round trip. That cost is real and still a design input — it's part of
  why pure logic lives in a fast-compiling SwiftPM `Core` target (see
  "Plugin-package layout" below) — but it is **not** why AVPlayer renders into a
  presented controller rather than a Flutter platform view; that choice is decided
  on the HDR-through-hybrid-composition risk instead (see "Native player" below).
  An earlier draft of this document did lean on compile speed to justify avoiding
  native chrome, and that framing is retracted there.

### Dual engine, mirroring `HdrPlayerActivity`

| | Android (shipping) | iOS |
|---|---|---|
| Default engine | ExoPlayer | **AVPlayer / AVPlayerLayer** |
| Fallback engine | mpv + libdovi | **libmpv via media_kit** |
| Fallback triggers on | DV P5 on non-DV hardware | raw MPEG-TS, MKV |

`AVPlayer` gives HDR10, HLG and Dolby Vision through Apple's EDR pipeline (P8.4 is
documented by Apple; **P5 is listed in the HLS authoring spec but must be verified
on-device before it is promised**), PiP via `AVPictureInPictureController`,
plus background audio, lock-screen controls via `MPNowPlayingInfoCenter`, and
AirPlay — the last being a capability no other platform in this repo has.

Note the inversion worth remembering: **DV Profile 5 is the hard case on Android**
(the entire reason `android/app/libs/libmpv-dovi.aar` is vendored through Git LFS)
and the native, hardware path on Apple. iOS HDR may end up *better* than Android's.

### What routes to which engine

AVPlayer accepts HLS and MP4/fMP4. It does **not** accept a naked continuous
MPEG-TS stream (TS segments *inside* an HLS playlist are fine) and does not
accept MKV.

Selection is **decided in Dart** (`lib/player/ios_engine.dart`, `selectIosEngine`),
because the trigger is the container, which Dart knows from the resolved URL, and
because a pure function is unit-testable at zero cost. Swift keeps only a defensive
mirror that can reject an impossible scheme; it never overrides Dart. Rules, in order:

1. Session memo says this content already failed on AVPlayer → **mpv**.
2. Scheme not `http`/`https`/`file` (rtmp, rtsp, udp, rtp, mms) → **mpv**.
3. Extension of the last path segment, query and fragment stripped:
   `m3u8`, `mp4`, `m4v`, `mov`, `m4a`, `mp3`, `aac` → **AVPlayer**;
   `ts`, `m2ts`, `mkv`, `avi`, `flv`, `webm`, `mpg`, `mpeg`, `wmv`, `vob`, … → **mpv**.
4. **No extension, or an unknown one → mpv.**

**Rule 1's memo keys are deliberately scoped, not global.** `IosEngineMemo.markMpvOnly` is keyed
per caller (`channel_list_screen.dart`): `channel.id` for live, `item.id` for VOD, and
`'catchup:${channel.id}'` for catch-up — three distinct keyspaces for what can otherwise be the
same channel. This is intentional: an archive-container AVPlayer failure on a catch-up recording
must not permanently downgrade the *live* channel to mpv for the rest of the session, and vice
versa. A null/empty `iosEngineKey` is a documented opt-out (no memoisation for that call), never
a wildcard that would apply to everything. Worth stating explicitly because collapsing this to a
single per-channel key looks like a harmless simplification and silently breaks the isolation.

**Known Dart/Swift asymmetry, deliberately left as-is.** Dart's `selectIosEngine` calls
`url.trim()` before parsing; the Swift mirror (`EngineSelection.swift`'s `selectEngine`) hands the
raw string straight to `URLComponents(string:)`, with no trim. A locator with leading/trailing
whitespace would therefore route to `avPlayer` in Dart and `mpv` in Swift — a real divergence, not
a hypothetical one. It is left unfixed because every resolved provider URL in this codebase is
already trimmed well before it reaches either selector, so the divergence is unreachable in
practice, and both selectors are separately pinned by tests on their own side — closing the gap
by adding `.trim()` to the Swift mirror (the only direction that's safe; Dart's selector is the
source of truth) means re-verifying that mirror's test suite for no gain. Recorded here so it
reads as a known, accepted asymmetry rather than a bug waiting to be found.

**Rule 4 is the load-bearing one**, and it is where the coverage asymmetry argument
now lives. A wrong guess toward mpv costs *quality* (SDR). A wrong guess toward
AVPlayer costs a *visible failure and a reopen beat* on every zap of the app's most
common path. Asymmetric costs justify an asymmetric default.

**Consequence to state plainly: Stalker/MAG portals get HDR only when `create_link`
returns an `.m3u8` URL**, because its locators are extension-less and therefore hit
rule 4. This is what makes the `streamExtension` lever below launch scope rather
than a nicety — defaulting Xtream to `m3u8` on iOS is what actually makes AVPlayer
the common path.

Container sniffing can still be wrong — a `.m3u8` AVPlayer accepts and then chokes on. A
**runtime fallback** is therefore mandatory, not optional: three Swift-detected failure shapes
(hard failure, ready-but-no-video-track, never-started-within-10s) all emit one `engineFailed`
event over the plugin's method channel.

**This is not Android's in-process engine swap.** `HdrPlayerActivity.fallbackToMpv()` swaps
`PlaybackEngine` implementations *inside the same Activity*, because both ExoPlayer and mpv are
reachable from Kotlin. iOS cannot do that — libmpv is only reachable from Dart, through
`media_kit` — so `engineFailed` is a **cross-language handoff**: `IptvsPlayerViewController`
tears itself down and dismisses; Dart, on receiving the event, calls `IosEngineMemo.markMpvOnly`
so `selectIosEngine` rule 1 catches the same content on any retry, re-resolves for live (a
failed AVPlayer attempt still burns the single-use Stalker `play_token` the URL carried), and
reopens the same content on the embedded media_kit/mpv surface — reusing the existing
`_pendingEmbeddedResume` seek for VOD, the same shape `_maybeEscalateLinuxNative` uses for its
own engine switch. This is the most intricate cross-language path in the design, and its one
visible cost is an honest one: a black beat while the presented controller dismisses and the
embedded surface opens. Rule 4 already keeps this path rare by routing the common failure case
(extension-less locators) to mpv before AVPlayer is ever attempted.

The reopen is additionally **gated**, not merely deferred: `decideIosFallbackAction`
(`lib/player/player_screen.dart`) must say it is safe before the embedded surface actually opens.
The reopen must not happen while nothing of this route is on screen — libmpv would take a
provider connection (single-connection accounts) and start decoding, with background audio
enabled for PiP audibly, behind the launcher or a PiP window; and media_kit's iOS GLES render
context is exactly the thing whose teardown/creation races (Constraint 2, `#1361`) when the
Flutter raster thread isn't running.

**Three independent opinions, any one of which vetoes** — belt and braces, because the original
design trusted exactly one of them and that was the mistake. `nativePipActive`
(`AVPictureInPictureController.isPictureInPictureActive`, read in Swift — the only
*authoritative* answer, since Flutter cannot see PiP at all) and `nativeAppActive`
(`UIApplication.shared.applicationState == .active`, also read in Swift, guarding the case where
Flutter's lifecycle is stale or was never delivered around an `.overFullScreen` presentation) sit
alongside `flutterLifecycle` (Flutter's own state, kept as the conservative third opinion: anything
other than `resumed` vetoes). **A `null` opinion is an absence, not a veto**: Swift may not have
stated a fact yet, and treating absence as "unsafe" would manufacture exactly the silent stall this
design exists to prevent — only an explicit `false`/non-`resumed` blocks. This is what makes a
plugin build that sends neither native fact behave exactly like the old single-signal gate, rather
than dead-ending: the two native opinions are additive safety, never a new way to get stuck.

**The wait cannot dead-end, because it does not depend on any one release path firing.** Four
independent ways to re-evaluate: (1) a Flutter lifecycle transition, now re-checked on *every*
edge rather than only a transition to `resumed`; (2) a native `hostVisibility` event
(`IptvsIosPlayerPlugin.publishHostVisibility`), which bypasses Flutter's lifecycle plumbing
entirely and is the wake path that survives even if `.overFullScreen` turns out to deliver no
Flutter transition at all; (3) a **1 Hz poll while a fallback is pending** — level-triggered, so
unlike the other two (edge-triggered) it cannot miss a change that arrived before anything was
listening for it; and (4) after `kIosFallbackSurfaceAfter` (10s) the route puts the error/Retry
overlay on screen **and keeps waiting** — surfacing is additive, never terminal, so whichever
happens first, a safe window or a tap, recovers playback. The load-bearing insight: a user tapping
Retry is *proof* the route is visible, where every automatic wake is only a *prediction* — an
off-screen route cannot be tapped. So the worst case degrades from "playback silently dead
forever" to "one tap", with no dependency on any UIKit→`AppLifecycleState` mapping being correct.

**Two traps worth flagging explicitly:**

1. **The surfaced overlay's Retry calls `_runIosFallbackNow`, not `_open`.** `_open` would reuse
   `widget.stream`, whose single-use Stalker `play_token` the failed AVPlayer attempt already
   burned — Retry would appear to work and then fail. `_runIosFallbackNow` re-resolves through
   `_freshLiveStream` (live) and keeps the captured VOD position, and the tap itself is the
   visibility proof the deferral was waiting for, so it also bypasses `decideIosFallbackAction`
   entirely rather than re-checking it.
2. **`pipActive` must be an omitted key, never `false`, when Swift doesn't know.** Dart
   distinguishes the two: absent means no opinion; `false` is an authoritative "PiP is off," which
   *clears* the PiP veto. A layer that cannot see PiP (no `IptvsPipStateProviding` registered yet)
   must not report `false`, or it would silently clear a veto it has no basis to evaluate —
   `IptvsIosPlayerPlugin.currentHostVisibility()` and `HostVisibility.pipActive` both encode this
   as an optional, and the payload builder omits the key rather than defaulting it.

**Where this leaves iOS ahead of Android, worth recording because the usual direction is
reversed:** the iOS fallback re-resolves before reopening, so it never retries a locator it
already knows just failed. Android's own native reconnect
(`HdrPlayerActivity`'s progress-ticker watchdog, docs/player.md "Live auto-reconnect") has no
such step — it reloads the *same* URL ExoPlayer just failed on, so a portal-side `create_link`
kill on Android currently requires backing out and re-entering the channel before a fresh
`create_link` is issued. Backporting a Kotlin→Dart re-resolve hook for that path is a real
opportunity this design surfaces; it is not implemented today.

### Fallback engine: verified capability, and two hard constraints

Researched 2026-07-29 against primary sources (the package build recipes, not docs).

**The codec floor is solid — this was checked because it could have killed the
design, and it did not.** `pubspec.lock` resolves `media_kit_libs_ios_video` 1.1.4,
whose `ios/Makefile` pulls the **`video-default` flavor** from
`media-kit/libmpv-darwin-build`. That project's FFmpeg meson recipe explicitly
enables `--enable-decoder=ac3`, `--enable-decoder=eac3`, `--enable-decoder=hevc`
(with `--enable-hwaccel=hevc_videotoolbox`), `--enable-demuxer=mpegts`,
`--enable-demuxer=hls` and `--enable-protocol=hls`. Darwin's `default` flavor is
deliberately built to the **same decoder/demuxer set as the Android `default`
flavor this repo already ships**. It is not a size- or licence-reduced iOS variant.

**Constraint 1 — `iosManageAudioSession` — RESOLVED 2026-07-29 via git pin.** mpv's
`ao_audiounit` driver on iOS *unconditionally* calls `AVAudioSession.setActive:`
YES/NO on init and dispose. `AVAudioSession` is process-wide, so the mpv fallback
would clobber AVPlayer's session state on every engine teardown — silently
breaking background audio and lock-screen controls.

Upstream fixed this in media_kit PR #1419, **merged 2026-06-24 and still in no
published release** — 1.2.6 remains the newest version on pub.dev, and the release
cadence has stalled (1.2.0 ~16 months ago, 1.2.1–1.2.6 clustered 7–9 months ago,
nothing since). Waiting was therefore not a safe plan, so `media_kit` is now
**git-pinned to the merge commit**:

```yaml
dependency_overrides:
  media_kit:
    git:
      url: https://github.com/media-kit/media-kit.git
      ref: d7b68a584e545a9e4fa5f9a600bfab556a106654
      path: media_kit
```

Pinned to an immutable merge SHA, not a branch tip — this repo pins action SHAs
everywhere and a floating `main` would make builds non-reproducible. Verified by
reading the commit's own patch rather than trusting the PR title: it adds
`final bool iosManageAudioSession` to `PlayerConfiguration` **defaulting to `true`**,
and when `Platform.isIOS && !configuration.iosManageAudioSession` it passes mpv the
option `audiounit-skip-session-management: yes`.

**Because the default is `true`, the iOS fallback engine must explicitly set
`iosManageAudioSession: false`.** Omitting it silently restores the exact bug the
pin exists to fix.

`dependency_overrides` was required — `media_kit_video` and `media_kit_libs_video`
come from pub.dev declaring `media_kit: ^1.2.6`, and pub will not resolve one package
name from two sources. Only `media_kit` is pinned; the siblings stay on pub.dev.
Verified: `flutter pub get` resolves cleanly, the lockfile delta touches **only** the
`media_kit` entry, `flutter analyze` is clean and the full suite passes (579).

**Maintenance obligation:** this override must be removed once a pub.dev release
carries the option. Leaving it indefinitely pins the project to unpublished upstream
state and silently overrides the constraint for every consumer. Re-run the iOS build
probe after removing it. Given the stalled cadence, assume this pin is long-lived —
and note the same applies to Constraint 2 below, which is also unreleased and
unfixed, so git-pinning may be the normal posture here rather than an exception.

**Constraint 2 — a live render-context teardown race.** media_kit issue #1361 (open,
filed 2026-01-06, reproduced on media_kit 1.2.6 / media_kit_video 1.3.1, iOS 16.6.1+)
is an `EXC_BAD_ACCESS` in `mpv_render_context_free` when the Flutter raster thread
tears down the render context while mpv's core thread is still writing frames. No
documented workaround. Rapid channel zapping is precisely the workload that stresses
this, so it must be an explicit target of the iOS soak run rather than something
discovered in the field.

Also confirmed, and worth recording because it converts an assumption into evidence:
mpv on iOS **cannot** carry HDR. `libmpv-darwin-build` applies
`patches/ffmpeg-fix-ios-hdr-texture.patch` to `libavcodec/videotoolbox.c`, forcing
10-bit VideoToolbox output down to 8-bit BGRA under `TARGET_OS_IPHONE`, commented
"iOS doesn't support 10 bit textures in GLES." The SDR cap on every mpv-routed row
in the table above is an upstream hardware/API limitation, not a policy choice.

media_kit's iOS renderer is still OpenGL ES (no `metal/` path in the plugin source
as of this research). No Metal migration is underway and no breakage traceable to
GLES deprecation was found — Apple has deprecated, not removed, it. Watch, don't panic.

### The `streamExtension` lever

[xtream_source.dart:30](../lib/sources/xtream_source.dart#L30) already carries
`streamExtension` (`'ts'` or `'m3u8'`), feeding both the live URL
([:181](../lib/sources/xtream_source.dart#L181)) and timeshift
([:195](../lib/sources/xtream_source.dart#L195)). Most Xtream panels serve both.
Preferring `m3u8` on iOS therefore routes a large share of live content onto
AVPlayer with **no new plumbing** — a per-platform default, not a feature.

This does not help Stalker, whose `create_link` returns whatever the portal
chooses, nor M3U playlists that name `.ts` directly.

### Native player

**Superseded design, recorded so it isn't re-proposed:** an earlier draft of this section
(title: "Native code layout — two decisions driven by blind iteration") put `AVPlayerLayer`
inside a Flutter `UiKitView` platform view, composited under the existing Dart
`EmbeddedPlayerControls` overlay, specifically to avoid writing native chrome. That is
**rejected**. Every platform in this repo that needed real HDR ended up taking video *out*
of the host UI compositor — Android's `HdrPlayerActivity` is a separate `ComponentActivity`
with its own `PlayerView`, entirely outside Flutter; Windows renders HDR through a native
HWND surface (`wid`-owned, escaped from the Flutter texture); Linux's Wayland-HDR path is a
standalone mpv process outside the embedded surface. The composited path is the SDR tier on
every platform, without exception. Routing AVPlayer through a Flutter platform view would
have made iOS the first exception, and would have put "does EDR actually survive Flutter's
hybrid compositor" as an *unverified, load-bearing risk* sitting directly under the entire
reason the AVPlayer engine exists. A presented controller sidesteps that question instead of
betting the release on it.

`IptvsPlayerViewController` is a **presented** `UIViewController` owning an `AVPlayerLayer` —
the direct analogue of `HdrPlayerActivity`:

- **`present(_:animated:completion:)` with `modalPresentationStyle = .overFullScreen`, not
  `.fullScreen`.** `.fullScreen` removes the presenting view controller from the view
  hierarchy, and Flutter treats that as an `AppLifecycleState` transition — which has real
  downstream consumers in this codebase: the preview-stop lifecycle observer
  (docs/player.md "Live preview + seamless handoff"), the update-flow prompt gate, and the
  cloud-sync pull/push timers all react to app lifecycle state. `.overFullScreen` keeps the
  Flutter view controller alive and foregrounded underneath, so presenting the player reads
  to the rest of the app exactly like every other platform's fullscreen player route does — a
  Dart route push, not a background transition.
- **`isModalInPresentation = true`** disables the interactive swipe-to-dismiss gesture. Without
  it, a stray edge swipe would dismiss the controller outside every exit path the rest of the
  app enforces — see the new iOS paragraph in docs/tv-navigation.md's Back-ladder section. Exit
  is always explicit.
- **`animated: false`** on present and dismiss, matching every other platform's zero-transition
  player route (docs/player.md "The Android handoff is made visually seamless... a
  non-opaque zero-transition route" / "Non-adopted fullscreen routes also use an opaque
  zero-duration transition").
- `prefersStatusBarHidden` and `prefersHomeIndicatorAutoHidden` both return `true` while
  presented, mirroring Android's immersive fullscreen (`hideSystemUi()`) and Windows'
  borderless fullscreen.
- **`isIdleTimerDisabled = true`** on appear, cleared on disappear (except when the
  disappearance is PiP starting) — forgetting the clear leaves the screen awake for the rest
  of the process; forgetting to set it lets the screen sleep mid-film. Neither failure shows up
  in the Simulator (idle-timer behavior is real-device-only), so there is no automated guard —
  it must be checked explicitly in the on-device test protocol below.
- **Scrim full-bleed, controls inset to `safeAreaLayoutGuide`** — the same full-bleed-scrim /
  inset-content split as the Android Compose overlay (`ControlsOverlay`'s
  `safeDrawingPadding()` groups) and the Windows GDI overlay's bar insets. Only video/scrim may
  run under the notch/Dynamic Island; every control (play/pause, scrubber, badges, favorite
  star) stays inside the safe area.
- **Must register itself as the PiP state provider on `viewDidLoad`.** The plugin
  (`IptvsIosPlayerPlugin.pipStateProvider`, weak) already exists and defaults to `nil` — set
  `IptvsIosPlayerPlugin.current?.pipStateProvider = self` as one of the controller's first acts, or
  every `hostVisibility`/`engineFailed` payload reports `pipActive` as *unknown* rather than the
  real PiP state for the whole time PiP is genuinely running, silently weakening (never breaking —
  see "Contracts that already exist") the AVPlayer→mpv fallback's PiP veto. Also the source of the
  **stop-PiP-before-emit** ordering: `emitEngineFailed` must be called only after the controller
  has torn down its `AVPlayer`, stopped PiP, and is dismissing itself, so the host snapshot riding
  on that payload already reflects the post-teardown state.

### Why not `AVPlayerViewController`

Evaluated and rejected. It would save an estimated **~400 lines of Swift chrome** — see the
line-count comparison in "Plugin-package layout" below for how that fits the wider budget —
but breaks three behaviours this codebase treats as pinned invariants on every other platform:

1. **The Back ladder becomes uninterceptable.** The stock "Done" button dismisses the
   controller directly, with no delegate callback to intercept the press and peel one rung
   (menu → info → hide → exit) the way `HdrPlayerActivity.dispatchKeyEvent`, `PlayerScreen`'s
   Escape binding, and the Lua `handle_back` all do on their platforms. Every other platform
   funnels Back/Escape/Done through a single-press peel; the stock control has no seam for it.
2. **Control-visibility state is not observable.** Apple's chrome auto-hides on its own private
   timer with no public hook, so it would run on a *different* clock than this app's
   badges/EPG-strip/go-to-live chrome, which all redraw from the shared `PlayerUiState`. The two
   chrome layers would show and hide independently instead of together.
3. **Custom controls are second-class.** The favorite star, "Go to live", and aspect-cycle
   button have no home in stock `AVPlayerViewController` except `contentOverlayView`, which
   sits *beneath* Apple's own control scrim — custom chrome would render dimmed and half-covered
   rather than at parity with the stock bar.

A fourth reason specifically rules it out for **live**: `AVPlayerViewController` needs
`requiresLinearPlayback = true` to suppress scrubbing on a non-seekable stream, and it infers
scrubbability from the player item's seekable time ranges — making the transport bar's very
presence a *guess about the stream* rather than the explicit, provider-declared
`StreamInfo.isLive` this repo requires (CLAUDE.md: "Liveness is provider metadata, not
inferred"). A custom transport bar driven directly by `isLive` avoids re-deriving that from
seekable-range heuristics.

### Plugin-package layout

The native Swift ships as a local Flutter plugin package, `packages/iptvs_ios_player/`, never
inside the `Runner` target — for **engineering-hygiene reasons, not compile-cycle economics**.
(The earlier draft of this document justified the same plugin-package split primarily on a
4-minute compile round trip; that framing is retracted below, not the decision itself.)

- `ios/Runner.xcodeproj/project.pbxproj` is `objectVersion = 54` with **no synchronized file
  groups**. Every `.swift` file added directly to `Runner` needs roughly four hand-written
  `project.pbxproj` entries with fresh 24-hex UUIDs (`PBXBuildFile`, `PBXFileReference`, a
  `PBXGroup` child, a `PBXSourcesBuildPhase` entry). At the estimated ~12 Swift files the native
  player needs (view controller, engine shim, colorimetry mapping, reconnect policy, engine
  selection mirror, plus tests), that is **~48 hand-authored entries** — an unreviewable,
  mechanically fragile artifact where one dropped or duplicated UUID surfaces as an opaque "no
  such file" or "undefined symbol" at link time, not a diagnosable compile error. A plugin pod's
  `source_files` glob picks up new files with **zero project-file edits, ever**, and registers
  automatically through `GeneratedPluginRegistrant`.
- **Module isolation** — the plugin package is the analogue of Android's
  `com.gchofficial.iptvs.player` package boundary: the native player is a self-contained unit
  with its own namespace, not diffused through `Runner`'s general-purpose files.
- **The `Core` SwiftPM target** (Foundation-only: `ReconnectPolicy`, colorimetry/dynamic-range
  mapping, the `selectIosEngine` defensive mirror, and `HostVisibility`/`HostVisibilityTracker`/
  `PlaybackEventPayload` — the host-facts type, its emit-on-change filter, and the
  `nativePlayback` payload builders shared with `IptvsIosPlayerPlugin`) is the counterpart of
  Android's plain-JUnit harness (`android/app/src/test/kotlin/`,
  `PlayerBackPolicyTest`/`ReconnectPolicyTest`) — pure logic pulled out so `swift test` compiles
  and runs it on the CI host in seconds, with no simulator (no `UIApplication`/`AVKit` import
  needed to test the `pipActive`-omission rule, for instance). It is the cheap canary that catches
  a typo before it costs a multi-minute build-and-deploy round trip, independent of whichever
  native-surface design is chosen.

**Line-count check, since it's what the trade above turns on:** the estimate that justified
taking on native chrome is **~1,310 UI lines vs Android's ~1,442** (`ControlsOverlay` + friends)
— iOS's custom overlay subtracts what Android's Compose chrome carries and iOS doesn't need:
the D-pad focus apparatus, the custom OK-to-edit slider widgets, the volume slider (AirPlay/
hardware volume covers it), and the clock badge. Total native Swift, view controller plus
engine shim plus overlay, comes to an estimated **~2,790 lines vs Android's ~4,206**. The
premise the platform-view design was built on — "native chrome is prohibitively expensive on
iOS" — does not hold up against Android's own numbers; iOS chrome is smaller.

### Deployment target and bundle identity

**`IPHONEOS_DEPLOYMENT_TARGET` is 15.0** (`ios/Runner.xcodeproj/project.pbxproj`, all three
build-setting sites), not the `flutter create` default. Reasons:

- Avoids `@available` churn for `UIWindowScene.keyWindow` and
  `canStartPictureInPictureAutomaticallyFromInline` (iOS 14.2) — both needed by the plugin's
  window-lookup and PiP paths, and both cleanly available with no fallback branch once the floor
  is 15.
- The floor excludes only 2013–2014 hardware (iPhone 6/6 Plus-era and older) that cannot decode
  HEVC or display HDR anyway — a null-cost exclusion for an HDR-focused IPTV player.
- **Fully reversible today, and never again**: iptvs has zero iOS users (nothing has shipped yet
  — see the top of this document), so this is the one point in the project's life where a
  deployment-target floor is a free choice rather than a support-matrix cut against real
  installs.

The bundle identifier has already moved off the `flutter create` default `com.example.iptvs`
onto the `com.gchofficial.iptvs.player.*` family described in "Bundle identities" above —
`project.pbxproj` and `Info.plist` carry `com.gchofficial.iptvs.player.sideload` for the
shipping (AltStore Classic) configuration.

### Contracts that already exist

The native engine is new; almost nothing around it is. These are engine-agnostic
and already specified and tested, and the iOS controller must honour them:

- `ChannelHandlerOwner` token ownership (`lib/player/channel_owner.dart`) — the
  inbound channel is process-static and claim/release is monotonic.
- `ReconnectPolicy` timing, mirrored between Dart and Kotlin — iOS gets a third
  implementation of the *same* policy, not a new one.
- `ResourceCounters` / `DebugCounters` balance, release-inert, merged through
  `debugCounters` on the HDR channel.
- Favorite state round-tripping via launch extra + a result on close.
- Live treats a clean EOF as a drop (`shouldReconnectOnCompleted`); VOD
  completing stays a legitimate end.
- **VOD position persistence defers to `nativeClosed`, exactly as on Android.**
  `PlayerScreen._persistPlaybackPosition` (`lib/player/player_screen.dart`) is a no-op whenever
  `(Platform.isAndroid || Platform.isIOS) && _nativePlaybackLaunched` — the embedded `_player` is
  idle while a native engine owns playback, so reading its (zero) position would overwrite the
  real one. This means the presented controller **must** send `positionMs`/`durationMs` on
  `nativeClosed` for VOD, the same payload shape Android's Activity already sends, or Continue
  Watching resume points silently stop being written on iOS with no error anywhere in the chain.
- **`nativePlayback` carries two events over the shared channel** (`PlaybackEventPayload`,
  `packages/iptvs_ios_player/ios/Core/Sources/IptvsPlayerCore/HostVisibility.swift` — key names
  centralised there so Swift and `_handleNativeHdrMethodCall`/`_handleIosEngineFailed`/
  `_handleIosHostVisibility` in `lib/player/player_screen.dart` can't drift): `engineFailed` (sent
  *instead of* `nativeClosed`, carrying `reason`/`positionMs`/`pipWasActive` plus the current host
  snapshot) and `hostVisibility` (`appActive`/`pipActive`, sent on every real UIKit foreground/
  background/PiP transition, unconditionally — not only while a fallback happens to be pending,
  since Swift has no way to know that and Dart just ignores events it doesn't need).
- **`pipActive` is an omitted key, never an explicit `false`, when the plugin cannot see PiP.**
  `HostVisibility.pipActive` is `Bool?`; both payload builders in `PlaybackEventPayload` skip the
  key entirely when it's `nil` rather than defaulting it. Dart's `decideIosFallbackAction`
  distinguishes the two on receipt: an absent key is "no opinion" (never vetoes), an explicit
  `false` is an authoritative "PiP is off" (*clears* the PiP veto) — so a build that reports a
  confident `false` from a layer that genuinely cannot evaluate PiP would silently reintroduce the
  exact stall this whole contract exists to close.
- **`IptvsPlayerViewController` must register itself as the plugin's PiP state provider.**
  `IptvsIosPlayerPlugin.pipStateProvider` (`IptvsPipStateProviding`, weak) defaults to `nil` —
  which `currentHostVisibility()` reports as `pipActive: nil`, per the rule above — until the
  controller sets `IptvsIosPlayerPlugin.current?.pipStateProvider = self` (documented target:
  `viewDidLoad`). Weak by design: the provider clears itself automatically when the controller
  deallocates, so a torn-down controller can't leave a stale PiP opinion behind for the *next*
  playback attempt to inherit.
- **Stop PiP before emitting `engineFailed`, not after.** The documented contract on
  `IptvsIosPlayerPlugin.emitEngineFailed` is that the controller has already torn down its
  `AVPlayer`, **stopped PiP**, and dismissed itself before calling it — the current host snapshot
  (`currentHostVisibility()`) rides on that same payload, so Dart's very first
  `decideIosFallbackAction` evaluation already sees the post-teardown facts (in particular
  `pipActive: false`, not a stale `true` from a PiP session that's actually already ending)
  instead of one more round trip to find out.

### Known parity gaps

Accepted, to be documented as a platform tier rather than tracked as bugs. The full hybrid ships
as one release (see "Shipping plan" above) — there is no staged HDR-less tier to describe
separately, and no `v1`/`v2` split left in this design.

- **HDR10+ is permanently absent.** AVFoundation exposes no per-scene ST2094-40 metadata API
  (unlike the decoder-level reads the Android/Windows/Linux paths use), so there is no way to
  distinguish HDR10+ from plain HDR10 through AVPlayer. Plain HDR10/HLG/DV are unaffected.
- **The cross-engine handoff for AVPlayer-routed channels is implemented; the permanent gap is
  that it can never be seamless.** `decideFullscreenHandoff`
  (`lib/screens/channel_list_screen.dart`, pinned by `test/fullscreen_handoff_test.dart`) takes a
  `crossEngineFullscreen` flag — the iOS analogue of the Linux Wayland-HDR case, collapsed into
  the same `FullscreenHandoff.stopResolveFresh` outcome — computed by `_openLivePlayer` from
  `selectIosEngine` on the preview's already-resolved URL. When it's an AVPlayer-routed channel,
  the embedded preview is stopped outright (never paused — a paused media_kit engine still holds
  its provider connection, and accounts are single-connection) and the channel is re-resolved
  fresh before the presented controller opens. What remains a genuine, permanent gap is the
  *seamlessness* itself: every AVPlayer open is a fresh resolve and a fresh `AVPlayerItem`, with
  one visible black beat — unlike Android's `SharedEngine` adoption (one ExoPlayer engine, output
  retargeted) or Windows' embedded hot-swap (same `Player`, `vo` swapped onto the HWND), because
  AVPlayer cannot adopt a running mpv session. An `IosSharedEngine` analogue — a persistent
  AVPlayer the preview and fullscreen surface could share, closing that gap — is recorded here as
  a **deferred idea, not a design**, so it isn't rediscovered from scratch later; it is not
  committed to.
  **Known benign race:** `_openLivePlayer` decides `crossEngineFullscreen` from the *preview's*
  URL, but `PlayerScreen` re-runs `selectIosEngine` on the freshly re-resolved URL once it opens.
  A portal that returns `.m3u8` for one `create_link` call and `.ts` for the next costs one
  unnecessary non-seamless handoff (preview stopped and re-resolved for nothing) — never a double
  provider connection, never wrong playback. Deliberately not plumbed through the `await`;
  recorded here so it isn't later mistaken for a bug.
- **mpv-routed content stays SDR and PiP-less, permanently** — a hard ceiling of the fallback
  engine on this platform, not a version-staging gap. `libmpv-darwin-build` forces 10-bit
  VideoToolbox output down to 8-bit BGRA under `TARGET_OS_IPHONE` ("iOS doesn't support 10 bit
  textures in GLES"), and media_kit has no PiP path (upstream #587, #1410 open feature requests).
  Mirrors DV P5 tone-mapped-to-SDR being a hard ceiling of Android's mpv fallback.
- **No AirPlay through the mpv fallback** — AirPlay is an AVFoundation feature, so it exists only
  for AVPlayer-routed content.

**Permanent, independent of engine:**

- No Android TV/D-pad counterpart (tvOS out of scope).
- No in-app updater (AltStore owns updates).

## Other work required

- **Layout branches: no change required.** An earlier draft of this document claimed
  the `TargetPlatform.android` tests at
  [live_tab_view.dart:381](../lib/screens/live_tab_view.dart#L381),
  [media_tab_view.dart:212](../lib/screens/media_tab_view.dart#L212) and
  [channel_list_screen.dart:1438](../lib/screens/channel_list_screen.dart#L1438)
  would give an iPhone "the desktop-wide layout" and must become form-factor tests.
  **That was wrong and is recorded here so it does not get re-raised.** The wide
  layout is selected by *width alone* (`constraints.maxWidth >= kWideLayoutMinWidth`,
  950) and is platform-independent on every target; the platform flag only selects
  **density within** an already width-chosen wide layout. Measured: iPhone portrait
  and every iPhone below 950 pt landscape are bit-identical either way (scale 1.0);
  the sole affected device is an iPhone 16 Pro Max in landscape, where the entire
  delta is ~22 px of preview height. On iPad the flag does matter and **today's
  value is the correct one** — 0.625 is across-the-room TV density and would be a
  regression on a 10–13" touch tablet. Re-keying these on form factor would be an
  **Android tablet regression** (1280×800 landscape is compact today), not an iOS fix.
- **`_deliberatePreview` — real, but blocked on a deeper question.**
  [channel_list_screen.dart:435](../lib/screens/channel_list_screen.dart#L435) is
  genuinely a touch-vs-pointer policy rather than an Android one, and iOS currently
  lands on the desktop hover model (muted auto-start after a 500 ms focus debounce).
  The one-line fix is `Platform.isAndroid || Platform.isIOS`, which is provably
  zero-delta on every shipping platform. **Do not land it alone.** With
  `deliberate = true` a *wide touch* layout has no affordance that can start a
  preview at all — `onLongPress` is null when wide
  ([live_tab_view.dart:323](../lib/screens/live_tab_view.dart#L323)), tap plays, and
  the only start path is OK/Enter — so an iPad would show a permanently dead preview
  panel under the hint "Press OK/Select to preview". That gap **already exists on
  Android tablets in landscape today**, so fixing it properly means adding a
  wide+touch preview affordance, which changes shipping Android behavior and needs
  its own justification. Settle it on a real iPad, not blind.
- **ATS — done.** `ios/Runner/Info.plist` now carries
  `NSAppTransportSecurity` → `NSAllowsArbitraryLoads`, with an XML comment recording
  why the blunt form is the only possible one (the user supplies provider hosts at
  runtime, so there is no fixed domain set to allowlist). This was a **hard blocker
  for any testable build**: iOS blocks plain HTTP by default and most providers are
  plain HTTP, so without it every provider request fails with no visible cause.
- **`UIBackgroundModes = [audio]` — REQUIRED.** This reverses an earlier decision to
  omit it, and the reversal is a hard technical fact rather than a change of taste:
  **`AVPictureInPictureController` refuses to start without the audio background
  mode.** PiP is a headline reason the hybrid exists, so the mode is mandatory, not
  optional. Two consequences that must be honoured:
  1. The lifecycle observer that stops the preview on app pause becomes
     **load-bearing** rather than merely polite — without it a muted preview keeps
     decoding, and holding a provider connection, behind the launcher. Verify it
     fires on iOS `AppLifecycleState.paused`.
  2. The fullscreen player *should* keep playing in the background (that is the
     feature); the preview must not. Encode this by having `LivePreviewController`
     release its audio-session client on lifecycle pause while `PlayerScreen`
     retains its own.
- **Encryption declaration — not required.** `ITSAppUsesNonExemptEncryption` (for
  the AES-GCM/P-256 in `cloud_crypto.dart`) is only checked on App Store Connect
  upload. Nothing on the Classic path submits to Apple, so it is moot. It would
  come back if PAL is ever revived.
- **Ports for free, verify anyway:** `AppDatabase` already routes non-desktop to the
  sqflite plugin ([app_database.dart:102](../lib/data/app_database.dart#L102)), and
  `flutter_secure_storage_darwin` is already resolved in `pubspec.lock`, so
  `SourceStore` lands on the iOS Keychain with no change.

## Open questions

Resolve these before committing to a schedule.

**1. Does libmpv-on-iOS actually play these providers' streams? — PARTIALLY
ANSWERED (2026-07-29).** The *capability* half is settled: the iOS build is not
codec-reduced and carries HEVC, AC-3/E-AC-3, MPEG-TS and HLS, at parity with the
Android build already shipping (see "Fallback engine" above). The design's floor
holds. What remains open is *robustness in practice* — compiled-in is not the same
as correctly demuxed, synced, and stable over hours — plus the two constraints
recorded above. Two further sub-answers are now cheap:

- **Compile and link: PASSES.** `.github/workflows/ios-build-probe.yml`
  (`workflow_dispatch`-only, free macOS runner) was dispatched 2026-07-29
  ([run 30474118811](https://github.com/GCHOfficial/iptvs/actions/runs/30474118811))
  and **succeeded in 4m12s** on Xcode 26.5 / CocoaPods 1.17.0, producing
  `build/ios/iphoneos/Runner.app` at 45.6 MB. `pod install` resolved in 3.7 s with
  `media_kit_libs_ios_video` and `media_kit_video` among the installed pods, so
  **libmpv links on iOS** — the 45.6 MB output is consistent with it being bundled.
  `IPHONEOS_DEPLOYMENT_TARGET = 13.0` proved sufficient for every dependency's
  podspec; no pod demanded a higher minimum, and the auto-generated `Podfile` (there
  is still no `ios/Podfile` in the tree) needed no intervention. Re-run the probe
  after any dependency bump — especially the media_kit upgrade that Constraint 1
  requires, which is the most likely thing to move the deployment-target floor.
  *That run predates the ATS fix and built under `DISTRIBUTION_CHANNEL=development`
  producing only `Runner.app`; the workflow now builds under `altStore` and uploads
  an installable unsigned `.ipa`. It also predates the deployment-target bump to
  15.0 ("Deployment target and bundle identity" above) — the probe has not yet been
  re-dispatched against that floor. Record the first post-change dispatch here.*

**2. Dolby Vision Profile 5 on-device**, via AVPlayer, from an HLS source. Apple
documents P8.4; P5 appears in the HLS authoring spec but is unverified here.

**3. What share of the target providers actually serve `m3u8`?** Decides whether
AVPlayer is the common path or the exception.

### On-device test protocol

For the first session with real hardware. Ordered by how much each can invalidate:

1. **AVAudioSession interaction**, on a media_kit build carrying
   `iosManageAudioSession: false` — confirm the mpv fallback does not stop, duck, or
   steal AVPlayer's now-playing session, background audio, or lock-screen controls.
2. **Engine-handoff soak** — 100+ zap cycles across the AVPlayer↔mpv boundary in the
   routing table, watching the console specifically for the #1361 `EXC_BAD_ACCESS`
   teardown signature. Mirrors what `integration_test/player_soak_test.dart` already
   does for Android/Windows.
3. **Raw MPEG-TS live** from an actual Stalker/M3U provider (continuous `.ts`, not
   TS-in-HLS) through the mpv fallback, sustained ≥30 min, watching for the periodic
   stall pattern of media_kit issue #440.
4. **AC-3/E-AC-3 sync and artefacts** on a real provider stream carrying that track.
5. **MKV VOD** — inferred from the compiled matroska demuxer, never observed.
6. **DV P5 / HDR** via AVPlayer (question 2 above).
7. **`engineFailed` deferral behaviour around PiP — a behavioural observation, not a
   trust gate.** Earlier revisions of this design deferred the mpv reopen purely on
   `WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed`, so whether
   entering PiP actually moves that value was a real unknown the whole safety property
   rested on. It no longer does: `decideIosFallbackAction` also consults the two native
   facts (`nativeAppActive`, `nativePipActive`) Swift reads directly off UIKit/AVKit, so
   even if Flutter's lifecycle turns out to report `resumed` throughout a PiP session, the
   native `pipActive` opinion vetoes on its own — and if *that* somehow failed to report
   too, the 10s surface-then-keep-waiting backstop still bounds the damage to one tap.
   Worth observing on real hardware anyway, to confirm which signal actually ends up doing
   the vetoing in practice (useful for future debugging), but nothing here can leave
   playback silently and permanently stuck.
8. **Waking via the PiP restore button** — trigger `engineFailed` while in PiP, then tap
   the PiP window's restore control (rather than switching apps) to bring
   `IptvsPlayerViewController`'s host back to the foreground; confirm the pending fallback
   reopens promptly rather than waiting for the 1 Hz poll or the 10s surface timeout.
9. **The surfaced Retry overlay in iPadOS Split View** — trigger a deferral that outlasts
   `kIosFallbackSurfaceAfter` while the app is the secondary Split View pane (reduced size,
   partially occluded by the primary app); confirm the error/Retry overlay actually renders
   within the app's reduced bounds and the Retry button is reachable and tappable there,
   not just in full-screen single-app mode.
