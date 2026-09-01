---
title: TV remote controls
description: How the D-pad, OK and Back behave on Android TV and other remotes.
---

Every screen is fully navigable with a D-pad. Nothing needs a touchscreen or a
mouse.

## The channel list

| Key | What it does |
| --- | --- |
| **Up / Down** | Move the selection. Down wraps around at the bottom; Up never wraps — at the top it moves you out of the list instead. |
| **Right** | First to the channel's favorite star, then across to the next pane. |
| **Left** | Back off the star, then across to the category list. |
| **OK** | Start a preview. Press again to go fullscreen. |
| **Number keys** | Type a channel number to jump to it. |

Up deliberately never wraps. In an earlier design it did, and people got stuck
cycling the category list with no way out.

## Preview

Highlighting a channel does **not** start playing it — only pressing OK does.
That is on purpose: a preview opens a connection to your provider, and most
subscriptions allow only one at a time, so a preview that followed the cursor
would fight with itself as you scrolled.

Press OK again on the previewing channel and it goes fullscreen without
reconnecting, so there is no second stall and no second connection.

## Back

Back peels off exactly one thing per press, in a fixed order:

channel list → first channel → categories → first category → search → tabs → exit

It never changes your data or your filters. The last press asks for a second
Back to confirm before leaving the app.

## In the player

| Key | What it does |
| --- | --- |
| **OK** | Show or hide the controls |
| **Left / Right** | Seek (on-demand content only — live has no seek bar) |
| **Up / Down** | Move between controls |
| **Back** | Close the menu, then the info panel, then the controls, then exit |

The control row carries play/pause, aspect ratio, "Go to live" while you're
behind the live edge, and the favorite star.

## Aspect ratio

Cycles Fit → Fill → Stretch → 16:9 → 4:3.

**Fill** crops to fill the screen and keeps the picture's shape. **Stretch**
distorts it to fill and keeps every pixel. They are different, and Fill is
almost always the one you want.

The choice is remembered per source. On a television the default is Fill, which
on a 16:9 panel showing 16:9 content looks identical to Fit; on a desktop the
default is Fit, because a window is whatever shape you dragged it to.
