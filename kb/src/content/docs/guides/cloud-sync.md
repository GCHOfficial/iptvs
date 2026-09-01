---
title: Cloud sync and pairing
description: Managing your sources from a browser, pairing a device with a code or QR, and end-to-end encryption.
---

Typing a provider password into a TV remote is miserable. Cloud sync exists so
you don't have to: set your sources up in a browser, then pair each device once
and it pulls them down.

It is **entirely optional**. The app works fully offline with sources added on
the device itself.

## Signing in

The panel uses a **magic link** — enter your email, get a link, click it. There
is no password to create or forget, and no login on the TV at all.

:::note
Sign-in emails are rate limited. If you ask for several in a row you will be told
to wait a few minutes; asking again immediately doesn't help, and neither does
trying a different address, because the limit covers the whole service rather
than your account.
:::

## Pairing a device

1. On the device, open **Cloud sync**. It shows an eight-character code and a QR.
2. In the panel, go to **Devices** and enter the code — or scan the QR with your
   phone, which opens the panel with the code already filled in.
3. Give the device a name. It suggests one ("Android TV", "Windows PC") so you
   can skip this.

Codes expire after ten minutes. Get a new one by reopening the screen.

## Pull and push

**Pull** brings the panel's sources down to the device. **Push** sends the
device's sources up.

Favorites are the exception: they sync **both ways, automatically**, as soon as
you star something. Everything else is deliberately manual, so a device can never
quietly overwrite work you did in the panel.

If the panel changed since your device last pulled, a push warns you before it
overwrites anything.

## Profiles

An account can hold several **profiles**, each a complete separate setup — its
own sources, its own metadata keys, its own favorites. Each device picks which
profile it syncs. See [Profiles and PINs](/guides/profiles/).

## End-to-end encryption

By default your provider credentials are stored server-side, isolated from the
rest of your data and only ever returned to devices you have paired.

You can go further and turn on **end-to-end encryption** in the panel's Security
tab. You choose a passphrase; your credentials are encrypted with a key only your
passphrase unlocks, and the server never sees either. Paired devices are then
each sent the key individually.

:::caution
**Nobody can recover the passphrase — not even us.** There is no reset, because
there is nothing on the server to reset it with. That is the point of the
feature. Use the panel's **Generate** button and save the phrase in a password
manager.
:::

A device that hasn't been given the key yet shows its sources as needing
attention rather than connecting with empty credentials. Send it the key from the
panel's Devices tab.

If you think a device has been lost or compromised, **rotate the key** in the
Security tab. That re-encrypts everything under a new key and every device has to
be sent the new one — which is exactly what locks the lost device out.
