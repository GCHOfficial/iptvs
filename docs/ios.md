# iOS

**Status: planned, not implemented.** This document records the scope, the two
distribution paths, and the player design. No iOS code has been written yet
beyond the default `ios/Runner` scaffold that `flutter create` left behind.

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

### Dual engine, mirroring `HdrPlayerActivity`

| | Android (shipping) | iOS (planned) |
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

- **Live over `.m3u8`** → AVPlayer. Full HDR + PiP.
- **Live over `.ts`** (Stalker/MAG `create_link`, panels without HLS) → mpv, SDR.
- **VOD, MP4** → AVPlayer.
- **VOD, MKV** → mpv, SDR.

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

**Constraint 1 — `iosManageAudioSession` is a hard version dependency.** mpv's
`ao_audiounit` driver on iOS *unconditionally* calls `AVAudioSession.setActive:`
YES/NO on init and dispose. `AVAudioSession` is process-wide, so the mpv fallback
would clobber AVPlayer's session state on every engine teardown — silently
breaking background audio and lock-screen controls. Upstream added an
`iosManageAudioSession` option to `PlayerConfiguration` in media_kit PR #1419,
**merged 2026-06-24 but not yet in a published release** — this repo is pinned to
media_kit 1.2.6, which predates it. Therefore: the iOS fallback engine **must not
ship on 1.2.6**. Either wait for a release beyond 1.2.6 carrying the option, or pin
to a git ref, and set `iosManageAudioSession: false` so mpv never contests the
session AVPlayer owns. Treat this as a blocker, not a polish item.

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

### Known parity gaps

Accepted, to be documented as a platform tier rather than tracked as bugs:

- DV/HDR in a raw TS container (falls to mpv, tone-mapped to SDR).
- HDR for MKV VOD (same).
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
- **ATS.** Most providers are plain HTTP, so `NSAppTransportSecurity` needs an
  arbitrary-loads exception. No review to justify it to on these paths, but record
  the reason (user-supplied arbitrary hosts) in the Info.plist comments.
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

- `.github/workflows/ios-build-probe.yml` (`workflow_dispatch`-only, free macOS
  runner) answers **does the stack compile and link at all**, without a Mac. Unrun
  as of this writing. Record its verdict here when dispatched. Note `ios/` has no
  `Podfile` — Flutter auto-generates one — and `project.pbxproj` sets
  `IPHONEOS_DEPLOYMENT_TARGET = 13.0`; whether that satisfies every dependency's
  podspec is exactly what the probe will surface.

**2. Dolby Vision Profile 5 on-device**, via AVPlayer, from an HLS source. Apple
documents P8.4; P5 appears in the HLS authoring spec but is unverified here.

**3. What share of the target providers actually serve `m3u8`?** Decides whether
AVPlayer is the common path or the exception.

### On-device test protocol

For the first session with real hardware. Ordered by how much each can invalidate:

1. **Raw MPEG-TS live** from an actual Stalker/M3U provider (continuous `.ts`, not
   TS-in-HLS) through the mpv fallback, sustained ≥30 min, watching for the periodic
   stall pattern of media_kit issue #440.
2. **Engine-handoff soak** — 100+ zap cycles across the AVPlayer↔mpv boundary in the
   routing table, watching the console specifically for the #1361 `EXC_BAD_ACCESS`
   teardown signature. Mirrors what `integration_test/player_soak_test.dart` already
   does for Android/Windows.
3. **AVAudioSession interaction**, on a media_kit build carrying
   `iosManageAudioSession: false` — confirm the mpv fallback does not stop, duck, or
   steal AVPlayer's now-playing session, background audio, or lock-screen controls.
4. **AC-3/E-AC-3 sync and artefacts** on a real provider stream carrying that track.
5. **MKV VOD** — inferred from the compiled matroska demuxer, never observed.
6. **DV P5 / HDR** via AVPlayer (question 2 above).
