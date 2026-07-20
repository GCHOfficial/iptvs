#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <version> <flutter-linux-bundle>" >&2
  exit 2
fi

version="$1"
bundle="$2"
linuxdeploy="${LINUXDEPLOY:-linuxdeploy-x86_64.AppImage}"
appimagetool="${APPIMAGETOOL:-}"
runtime="${APPIMAGE_RUNTIME_FILE:-}"
output="${OUTPUT:-iptvs-$version-linux-x86_64.AppImage}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must be semantic x.y.z" >&2
  exit 2
fi
if [[ ! -x "$bundle/iptvs" || ! -d "$bundle/data" || ! -d "$bundle/lib" ]]; then
  echo "Not a complete Flutter Linux release bundle: $bundle" >&2
  exit 1
fi
if [[ ! -x "$linuxdeploy" ]] && ! command -v "$linuxdeploy" >/dev/null 2>&1; then
  echo "linuxdeploy not found: $linuxdeploy" >&2
  exit 1
fi

appdir="$(mktemp -d "${TMPDIR:-/tmp}/iptvs-appdir.XXXXXX")"
trap 'rm -rf "$appdir"' EXIT
mkdir -p "$appdir/usr/bin" "$appdir/usr/share/applications" "$appdir/usr/share/icons/hicolor/512x512/apps"
mkdir -p "$appdir/usr/share/iptvs/fonts"
cp -a "$bundle/." "$appdir/usr/bin/"
cp linux/mpv/iptvs_overlay.lua "$appdir/usr/share/iptvs/overlay.lua"
# Inter + Material Icons for the overlay's \fn text/glyphs (libass finds them
# via the --osd-fonts-dir launch arg LinuxNativeSession points at this dir).
cp linux/mpv/fonts/Inter-Regular.ttf linux/mpv/fonts/Inter-SemiBold.ttf \
  linux/mpv/fonts/MaterialIcons-Regular.otf "$appdir/usr/share/iptvs/fonts/"
if [[ -n "${MPV_BINARY:-}" ]]; then
  if [[ ! -x "$MPV_BINARY" ]]; then
    echo "MPV_BINARY is not executable: $MPV_BINARY" >&2
    exit 1
  fi
  cp "$MPV_BINARY" "$appdir/usr/bin/mpv"
fi
cp linux/com.gchofficial.iptvs.desktop "$appdir/usr/share/applications/"
cp macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png \
  "$appdir/usr/share/icons/hicolor/512x512/apps/com.gchofficial.iptvs.png"

# linuxdeploy copies the GTK/system dependency closure into the AppDir. The
# Flutter bundle (binary, data, and package native assets) stays together under
# usr/bin so its $ORIGIN-relative lookup remains valid on X11 and Wayland.
# Flutter already strips release artifacts. Avoid linuxdeploy's bundled older
# strip touching distro libraries (modern RELR sections are otherwise rejected).
linuxdeploy_args=(
  --appdir "$appdir" \
  --desktop-file "$appdir/usr/share/applications/com.gchofficial.iptvs.desktop" \
  --icon-file "$appdir/usr/share/icons/hicolor/512x512/apps/com.gchofficial.iptvs.png"
)
if [[ -n "$appimagetool" ]]; then
  ARCH=x86_64 NO_STRIP=1 "$linuxdeploy" "${linuxdeploy_args[@]}"
  appimage_args=()
  if [[ -n "$runtime" ]]; then
    appimage_args+=(--runtime-file "$runtime")
  fi
  APPIMAGE_EXTRACT_AND_RUN=1 "$appimagetool" "${appimage_args[@]}" "$appdir" "$output"
else
  ARCH=x86_64 OUTPUT="$output" NO_STRIP=1 "$linuxdeploy" "${linuxdeploy_args[@]}" --output appimage
fi

test -s "$output"
chmod 0755 "$output"
echo "Created $output"
