# Third-party notices

iptvs is licensed under **GPLv3** (see [`LICENSE`](LICENSE)). It is GPL — rather
than a more permissive license — because it is distributed as binaries linked
against a GPL build of FFmpeg/mpv (details below). This file records the bundled
third-party components and their licenses, and points to the *corresponding source*
for the components we vendor in binary form, as the GPL/LGPL require.

## Native media stack (libmpv)

Both the Android fallback engine and the Windows player use **libmpv** with
libplacebo (`vo=gpu-next`) and a `libdovi`-enabled Dolby Vision path. The shipped
`libmpv` binary is a **combined GPLv3 work**, because FFmpeg is built with
`--enable-gpl --enable-version3`.

| Component | Version | License | Notes |
|-----------|---------|---------|-------|
| FFmpeg | 8.1 | **GPLv3** (`--enable-gpl --enable-version3`) | Makes the combined libmpv GPLv3. |
| mpv | 0.41.0 | LGPLv2.1+ (GPL as combined with FFmpeg) | |
| libplacebo | 7.360.1 | LGPLv2.1+ | HDR / Dolby Vision rendering (`gpu-next`). |
| libdovi / dovi_tool | 3.3.2 | MIT | Dolby Vision RPU parser/reshaper. |
| libass | — | ISC | Subtitle rendering. |

### Corresponding source

- **Android `libmpv.so`** (`android/app/libs/libmpv-dovi.aar`, vendored via Git
  LFS) — built from
  [`GCHOfficial/libmpv-android@libdovi`](https://github.com/GCHOfficial/libmpv-android/tree/libdovi)
  (a public fork of
  [`jarnedemeulemeester/libmpv-android`](https://github.com/jarnedemeulemeester/libmpv-android)).
  The exact build edits are documented in
  [`android/app/libs/README.md`](android/app/libs/README.md) and
  [`android/app/libs/fork/`](android/app/libs/fork/).
- **Windows `libmpv-2.dll`** — fetched at build time from
  [`zhongfly/mpv-winbuild`](https://github.com/zhongfly/mpv-winbuild) (a public GPL
  mpv build for Windows); the pinned release URL + SHA-256 are in
  [`windows/CMakeLists.txt`](windows/CMakeLists.txt).

## Flutter / Dart packages

Per their respective licenses (mostly MIT / BSD / Apache-2.0):

- [`media_kit`](https://pub.dev/packages/media_kit),
  [`media_kit_video`](https://pub.dev/packages/media_kit_video),
  [`media_kit_libs_video`](https://pub.dev/packages/media_kit_libs_video) — MIT
- [`sqflite`](https://pub.dev/packages/sqflite),
  [`sqflite_common_ffi`](https://pub.dev/packages/sqflite_common_ffi),
  [`sqlite3_flutter_libs`](https://pub.dev/packages/sqlite3_flutter_libs)
- [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage),
  [`path_provider`](https://pub.dev/packages/path_provider),
  [`path`](https://pub.dev/packages/path), [`xml`](https://pub.dev/packages/xml),
  [`crypto`](https://pub.dev/packages/crypto),
  [`google_fonts`](https://pub.dev/packages/google_fonts),
  [`cupertino_icons`](https://pub.dev/packages/cupertino_icons)

The bundled **Inter** font (`android/app/src/main/res/font`) is licensed under the
SIL Open Font License 1.1.

A full machine-readable list of Dart dependency licenses is available via
`flutter pub deps` / the in-app licenses page (`showLicensePage`).
