# Custom libmpv (gpu-next / Dolby Vision)

`media_kit` bundles a libmpv build from September 2023 that was **not compiled
with libplacebo**, so mpv's modern `gpu-next` video output is unavailable. Without
`gpu-next`, Dolby Vision (Profile 5/8) and some HDR titles render with a green /
magenta cast, because the legacy `gpu` VO can't apply the DV reshaping.

## How it's handled

`windows/CMakeLists.txt` fixes this automatically: if `libmpv-2.dll` is not
already present in this folder, the build **downloads a pinned, hash-verified
libplacebo build** (from zhongfly's `mpv-winbuild`) at configure time and copies
it over the one media_kit bundles. So a fresh clone / CI just works — no manual
step. The player then requests `vo=gpu-next`.

To pin a newer/different build, update `LIBMPV_PLACEBO_URL` + `LIBMPV_PLACEBO_SHA256`
in `windows/CMakeLists.txt`.

## Using your own DLL (override / offline)

Drop a libplacebo-enabled `libmpv-2.dll` here:

```
windows/libmpv/libmpv-2.dll
```

When that file exists it takes precedence over the auto-download (the build skips
the fetch and copies yours at install time — just rebuild, no `flutter clean`).

## Where to get the DLL

Use a maintained Windows libmpv build that includes libplacebo. Both of these do:

- **shinchiro** — https://github.com/shinchiro/mpv-winbuild-cmake/releases
- **zhongfly** — https://github.com/zhongfly/mpv-winbuild/releases

Download the **`mpv-dev-x86_64-…​.7z`** asset (the `-dev` archive contains
`libmpv-2.dll`; the non-dev archive is the player only). Extract it and copy the
`libmpv-2.dll` from inside into this folder.

The libmpv **client API is ABI-stable and backward-compatible**, so a newer DLL
works with the `media_kit` bindings in this project. These dev builds statically
include ffmpeg + libplacebo, so it's a single self-contained DLL (~100 MB) — no
extra runtime files needed.

## Verifying it loaded

Play an HDR/DV title and check the diagnostics log for:

```
active vo=gpu-next hwdec=...
```

If it shows `active vo=gpu` instead, the DLL isn't being picked up (wrong file,
wrong location, or it lacks gpu-next) and you'll see `Video output gpu-next not
found!` in the log.

## Note on Git

The DLL is large; it is git-ignored by default (see `.gitignore` in this folder).
If you want it tracked, use Git LFS rather than committing it directly.
