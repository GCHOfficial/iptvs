# iptvs

[![Build](https://github.com/GCHOfficial/iptvs/actions/workflows/build.yml/badge.svg)](https://github.com/GCHOfficial/iptvs/actions/workflows/build.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

A cross-platform **IPTV player** for Windows and Android (including **Android TV**),
built with Flutter and libmpv. It connects to your own IPTV provider, caches its
channel/VOD/EPG data locally, enriches movie/series metadata from public APIs, and
plays streams with **true HDR** — handling HEVC / AC-3 / MPEG-TS that a plain video
element can't.

> iptvs ships no provider channels or playlists and is not affiliated with any
> IPTV provider. A credential-free **Demo** source links to public protocol
> fixtures and Blender open movies for development and closed testing; those
> third-party streams remain subject to their own terms and licences. See
> [Disclaimer](#disclaimer).

## Features

- **Providers, one interface** — Stalker (MAG portal), Xtream Codes, and M3U/M3U8
  playlists, plus a built-in demo source. Live TV, Movies (VOD), and Series.
- **Credential-free demo catalogue** — generated now/next and archive rows,
  codec/HLS/HEVC/MP4 playback fixtures, four Blender open-movie films with
  artwork and attribution metadata, and two browsable series hierarchies.
- **True HDR** — HDR10, HDR10+, HLG, and Dolby Vision Profile 8 play through the
  hardware decoder to the display; Dolby Vision Profile 5 is reshaped via a
  `libdovi`-enabled libmpv. Dynamic range is read from the decoder, so the badge
  matches what your TV actually receives.
- **Android TV / D-pad** — fully navigable with a remote (Leanback launcher, focus
  rings, "OK to edit" fields and sliders). One universal APK serves phone + TV.
- **EPG & metadata** — XMLTV EPG with now/next and a live progress strip; posters,
  overviews, and ratings pulled from TMDB / TVDB / MDBList.
- **Favorites & per-source settings** — star live channels, movies, and series into a
  **Favorites** row at the top of each list; disable categories you don't care about on
  a per-source settings screen so they vanish from browsing.
- **Resilient live playback** — auto-reconnect with backoff when a live stream
  stalls or drops, plus a "Go to live" control.
- **Native overlays** — a Windows (D3D11) and Android (Compose) player overlay at
  parity: play/pause, ±10s, scrubber, audio/subtitle/speed menus, aspect cycle,
  resolution/HDR/FPS/clock badges, and an info panel.
- **Optional web panel** — manage your sources from a browser as one or more **profiles**
  (separate setups on one account), and pull a profile onto each device by entering a short
  pairing code (or push a device's set back up), with **no login on the TV**. Off unless
  built with cloud config. See [Cloud sync](#cloud-sync-optional).

## Platforms

| Platform | Status |
|----------|--------|
| Windows (x64) | Supported — native D3D11 HDR path |
| Android phone / **Android TV** | Supported — single universal APK |
| Linux / macOS / iOS | Builds via Flutter; not a focus / untested |

## Download

Grab the latest Windows zip and Android APK from the
[**Releases**](https://github.com/GCHOfficial/iptvs/releases) page. The APK installs
on both phones and Android TV.

## Build from source

Requires the **Flutter `3.44.5`** stable toolchain (the version CI pins).

```bash
flutter pub get
flutter run -d windows
flutter run -d android --flavor development \
  --dart-define=DISTRIBUTION_CHANNEL=development
```

Platform notes:

- **Android needs Git LFS.** The Dolby Vision libmpv AAR
  (`android/app/libs/libmpv-dovi.aar`, ~48 MB) is stored in Git LFS — run
  `git lfs install && git lfs pull` before an Android build, or it won't link. See
  [`android/app/libs/README.md`](android/app/libs/README.md).
- **Windows** fetches a libplacebo/Dolby-Vision `libmpv-2.dll` automatically at
  CMake configure time (hash-verified); drop your own in `windows/libmpv/` to
  override. See [`windows/libmpv/README.md`](windows/libmpv/README.md).

CI expectation: `flutter analyze` is clean and `flutter test` is green.

## Cloud sync (optional)

Maintaining a source list with a TV remote is painful, so iptvs can optionally talk to
a **web panel** — a static site on GitHub Pages backed by [Supabase](https://supabase.com) —
where you manage, reorder, and keep your sources and metadata keys with a real keyboard.
The live panel is at **<https://gchofficial.github.io/iptvs/>**. Each device pulls a list
down after a one-time **pairing code**, so there is **no login on the TV** — and can
optionally **push** its own set back up (newest change wins).

- **Profiles** — an account can hold several named **profiles**, each its own complete
  setup: source list, metadata keys, disabled categories, and favorites. A device pairs to
  the account, then picks which profile to sync (switchable any time). Profiles are
  created and renamed in the panel; the device just selects one. A single-profile account
  behaves exactly like before.

- **Private by design** — sources are isolated per account by Postgres row-level security;
  the app and panel ship only the public anon/publishable key, and the `service_role` key is
  never embedded anywhere. Devices authenticate anonymously and hold **no direct write
  access**; the optional push goes through an owner-scoped `SECURITY DEFINER` function that
  rejects any caller that isn't a paired device writing its own account's data.
- **Fully optional** — builds without cloud config behave exactly as before; the cloud UI
  stays hidden (`CloudConfig.isConfigured`).

Setup lives in [`supabase/README.md`](supabase/README.md) (database, RLS, auth) and
[`panel/README.md`](panel/README.md) (the web app, deployed to Pages by
[`pages.yml`](.github/workflows/pages.yml)). To enable it in the app, build with the Supabase
values — locally via `flutter run --dart-define-from-file=dart_define.json` (copy
[`dart_define.example.json`](dart_define.example.json)); in CI they come from repo Variables.

## Disclaimer

iptvs is a **player only**. It contains no streams, playlists, or media, and it is
not affiliated with, endorsed by, or connected to any IPTV provider. You are
responsible for the source you configure and for complying with the laws and the
provider terms applicable to you. The maintainers do not host, distribute, or
provide access to any content.

## License

Licensed under the **GNU General Public License v3.0** — see [`LICENSE`](LICENSE).
iptvs distributes binaries linked against a GPL build of FFmpeg/mpv; the bundled
third-party components and their corresponding source are listed in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
