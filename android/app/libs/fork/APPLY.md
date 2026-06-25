# Fork edits to add libdovi to libmpv-android

Base your fork on `jarnedemeulemeester/libmpv-android` @ the tag/commit matching
the AAR you currently use (it ships libplacebo 7.360.1 / ffmpeg 8.1 / mpv 0.41.0
/ NDK 29.x). Apply the four edits below, plus copy the two files in this folder:

- `scripts-dovi.sh` → `buildscripts/scripts/dovi.sh` (`chmod +x`)
- `build.yaml`      → `.github/workflows/build.yaml`

Then push to your fork's `main` (or run the workflow via *Actions → Run
workflow*). Download the `libmpv-release.aar` artifact and follow the parent
[`../README.md`](../README.md) → "Wire the AAR into the app".

---

## 1. `buildscripts/include/depinfo.sh`

Add a version under the others, e.g. after `v_libplacebo=7.360.1`:

```bash
v_dovi=libdovi-3.3.2
```

In the dependency tree, add a `dovi` node and make libplacebo depend on it so it
builds first:

```bash
dep_dovi=()
dep_libplacebo=(dovi)        # was: dep_libplacebo=()
```

## 2. `buildscripts/include/download-deps.sh`

Add a clone just before the `libplacebo` clone:

```bash
# dovi (libdovi — Dolby Vision RPU parser)
[ ! -d dovi ] && git clone --depth 1 --branch $v_dovi https://github.com/quietvoid/dovi_tool.git dovi
```

## 3. `buildscripts/scripts/libplacebo.sh`

Add `-Dlibdovi=enabled` to the `meson setup` line:

```bash
meson setup $build --cross-file "$prefix_dir"/crossfile.txt \
	-Dvulkan=disabled -Ddemos=false -Dlibdovi=enabled
```

Meson finds `dovi.pc` via `PKG_CONFIG_LIBDIR` (set by `path.sh`). The configure
summary should report **Dolby Vision: enabled**. If meson can't find libdovi,
confirm `dovi.sh` ran for this ABI and `$prefix_dir/lib/pkgconfig/dovi.pc` exists.

## 4. `buildscripts/scripts/dovi.sh`

Copy `scripts-dovi.sh` from this folder. It builds libdovi with cargo-c for the
ABI's Rust target and installs `libdovi.a` + `dovi.pc` into the prefix.

---

## Notes / troubleshooting
- The final `libmpv.so` link must pull `libdovi.a`. libplacebo's `.pc` carries it
  as a static dependency, and mpv links libplacebo with `pkg-config --static`, so
  this is automatic. If the link reports undefined `dovi_*` symbols, verify
  `libplacebo.pc` lists the dovi dependency and that pkg-config `--static` is in use.
- libdovi is a Rust `staticlib` (bundles std), so no extra runtime `.so`.
- Keep ABIs minimal (`--arch arm64`, optionally `x86_64` for the emulator) to keep
  the AAR small; ffmpeg needs no libdovi (it already exports HEVC RPU side data).
