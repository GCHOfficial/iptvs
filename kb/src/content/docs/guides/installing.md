---
title: Installing
description: Where to get iptvs for Windows, Android, Android TV and Linux, and how updates work on each.
---

iptvs runs on Windows, Android (phones and tablets), Android TV, and Linux.

## Android and Android TV

Install from Google Play, or download the APK from the
[releases page](https://github.com/GCHOfficial/iptvs/releases).

The two are **signed with different certificates and cannot be installed over each
other** — Android refuses an update whose signing certificate changed. Pick one
and stay on it. To switch, uninstall first; your sources are in the device
keychain and will be gone with the app, so
[pair with the cloud panel](/guides/cloud-sync/) first if you want them back
without retyping.

On Android TV, sideloading the APK usually means enabling "install unknown apps"
for whichever file manager you used.

## Windows

Install from the Microsoft Store, or download the `.zip` from the releases page
and unpack it anywhere you like.

The Store build updates itself through the Store. The zip build updates itself
from within the app: it downloads the new version, verifies it, and swaps itself
out. Both are the same application.

## Linux

Download the AppImage from the releases page, mark it executable, and run it.

**mpv must be installed on the host** — the AppImage deliberately does not bundle
it, so it uses your distribution's build and your GPU drivers. Version 0.40 or
newer is required; 0.41 is recommended.

```sh
sudo apt install mpv        # Debian / Ubuntu
sudo dnf install mpv        # Fedora
sudo pacman -S mpv          # Arch
```

If the AppImage is somewhere writable it can update itself in place; if you put
it somewhere root-owned, update it the way you installed it.

## Updates

Outside the stores, the app checks for its own updates and offers them in a
dialog. Every download is verified against a signed release manifest before it
is installed — filename, size and hash all have to match — so a partial or
tampered download is refused rather than run.
