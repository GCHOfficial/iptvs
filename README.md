# iptvs

[![Build](https://github.com/GCHOfficial/iptvs/actions/workflows/build.yml/badge.svg)](https://github.com/GCHOfficial/iptvs/actions/workflows/build.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

A cross-platform **IPTV player** for Windows and Android (including **Android TV**),
built with Flutter and libmpv. It connects to your own IPTV provider, caches its
channel/VOD/EPG data locally, enriches movie/series metadata from public APIs, and
plays streams with **true HDR** — handling HEVC / AC-3 / MPEG-TS that a plain video
element can't.

> iptvs ships **no channels, playlists, or content** of its own and is not
> affiliated with any IPTV provider. You bring your own provider credentials. See
> [Disclaimer](#disclaimer).

## Features

- **Providers, one interface** — Stalker (MAG portal), Xtream Codes, and M3U/M3U8
  playlists, plus a built-in demo source. Live TV, Movies (VOD), and Series.
- **True HDR** — HDR10, HDR10+, HLG, and Dolby Vision Profile 8 play through the
  hardware decoder to the display; Dolby Vision Profile 5 is reshaped via a
  `libdovi`-enabled libmpv. Dynamic range is read from the decoder, so the badge
  matches what your TV actually receives.
- **Android TV / D-pad** — fully navigable with a remote (Leanback launcher, focus
  rings, "OK to edit" fields and sliders). One universal APK serves phone + TV.
- **EPG & metadata** — XMLTV EPG with now/next and a live progress strip; posters,
  overviews, and ratings pulled from TMDB / TVDB / MDBList.
- **Resilient live playback** — auto-reconnect with backoff when a live stream
  stalls or drops, plus a "Go to live" control.
- **Native overlays** — a Windows (D3D11) and Android (Compose) player overlay at
  parity: play/pause, ±10s, scrubber, audio/subtitle/speed menus, aspect cycle,
  resolution/HDR/FPS/clock badges, and an info panel.

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

Requires the **Flutter `3.44.2`** stable toolchain (the version CI pins).

```bash
flutter pub get
flutter run -d windows   # or: -d android
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
