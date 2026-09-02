---
title: Troubleshooting
description: Common problems and what to try, plus how to export a diagnostic log.
---

## I can't sign in to the panel

If it says **too many sign-in emails**, wait a few minutes. Sign-in emails are
rate limited across the whole service, so asking again straight away won't help
and neither will a different address.

If the link arrives but doesn't sign you in, it has probably expired — they are
short-lived. Ask for a fresh one.

## A channel won't play

**Try another channel first.** If everything fails, it's the source or the
connection; if only one fails, it's that stream.

- Most IPTV subscriptions allow **one connection at a time**. If a preview is
  running on another device, or the app is open twice, the second stream is
  refused.
- Check the source's expiry on the Sources screen. An expired subscription
  usually fails at play time, not at login.
- On Linux, playback needs **mpv 0.40 or newer** installed on the host.

## It reconnects on its own, repeatedly

That means the stream is dropping and the app is picking it back up. Raise the
source's **buffer** setting to High — it gives the player more slack when the
connection is uneven.

If it happens on every channel of one provider but not another, it's the
provider.

## The guide is empty or says "guide unavailable"

"Updating guide…" means it is still downloading; large guides take a while and
the channel list works meanwhile.

"Guide unavailable" means the download failed and there is nothing cached. Check
the source's EPG URL, or [add another guide](/guides/adding-a-source/#extra-epg-guides).

If the guide is present but wrong for some channels, the channel ids in the guide
don't match the playlist. Adding a guide that matches on names often fixes it.

## No artwork — every poster is a placeholder

Artwork comes from a metadata provider you configure with your own API key. Check
the key in Metadata settings. If images vanished after working, the key may have
been revoked or rate limited.

## My sources disappeared after reinstalling

Sources live in the device's keychain and are removed with the app. If you had
[paired with the cloud panel](/guides/cloud-sync/), pair again and pull them back.

## The app won't update on Android

If the installer refuses, the build you have and the build you're installing were
signed differently — the Play version and the direct-download APK are not
interchangeable. Uninstall first, then install the one you want.

## Nothing here matches

Open **Settings → Diagnostics** on the device and export the log. It records what
failed and when.

The log is redacted — provider URLs, usernames and passwords are stripped before
anything is written — so it is safe to share. Skim it before sending anyway.

Then bring it somewhere with the log, what you did, and what happened:

- **[Discord](https://discord.gg/Eh2BMVRJT)** or
  **[Telegram](https://t.me/+l_fENZkpwDw4MTU0)** — quickest, and someone may
  have hit the same provider quirk already.
- **[GitHub issues](https://github.com/GCHOfficial/iptvs/issues)** — best for
  anything reproducible, since it does not get lost in a chat scroll.
- **<support@iptvs.click>** — if you would rather not post in public.

:::caution
Whichever you choose, **never paste your provider username, password, MAC
address or playlist URL**. Nobody needs them to help, and a chat log is
searchable. The exported diagnostics deliberately strip them for you.
:::
