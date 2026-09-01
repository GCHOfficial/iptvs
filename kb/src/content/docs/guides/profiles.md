---
title: Profiles and PINs
description: Separate setups on one device, and the optional 4-digit PIN that gates them.
---

A **profile** is a complete setup: its own sources, its own favorites, its own
watch history. One television, one profile each.

Profiles come in two kinds:

- **Local** profiles live only on that device.
- **Cloud** profiles come from your panel account and sync across every paired
  device.

## Switching

The profile picker appears at startup when a device has more than one profile.
Switching saves the profile you're leaving and restores the one you're entering,
so each keeps its own place.

If you only have one profile, the app boots straight into it and never shows the
picker.

## PINs

A profile can carry an optional **4-digit PIN**. On a shared television this
keeps the kids out of your setup and vice versa.

Enter it on an on-screen keypad — no text field, so it works with a remote's
arrow keys, and hardware number keys work too if your remote has them.

:::note
A PIN is a **household gate, not a security control**. Four digits is ten
thousand possibilities, and anyone with real access to the device has better
options than guessing. It stops the wrong person picking the wrong profile; it
does not protect credentials from someone determined. End-to-end encryption is
what protects those.
:::

Five wrong attempts starts a 30-second cooldown, and the cooldown belongs to the
profile — backing out of the dialog and reopening it doesn't clear it.

## Forgot a PIN?

On a **local** profile, delete it from the picker's manage mode. Deleting is
deliberately not behind the PIN: it reveals nothing, and it is the only way out
of a forgotten PIN on a device-only profile.

On a **cloud** profile, change or clear the PIN from the panel. The device picks
that up on its next pull.
