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

The control row carries play/pause, aspect ratio, and on live channels the
quick-list button, "Go to live" while you're behind the live edge, and the
favorite star.

## Changing channel in the player

On a live channel you don't have to leave fullscreen to change channel. While
the controls are **hidden**:

| Key | What it does |
| --- | --- |
| **Up / Down** | Next / previous channel. Both ends wrap around. |
| **Right** | Back to the previous channel — press again to swap back. |
| **Left** or **GUIDE** | Open the quick list (below). |
| **Number keys** | Type a channel number; it switches after a short pause, or straight away on OK. |
| **CH+ / CH−**, **Page Up / Page Down** | Next / previous channel, whether the controls are showing or not. |

A banner at the bottom shows where you've got to as you press, and the channel
only switches once you stop — holding Up to scan past twenty channels opens one
connection to your provider, not twenty. If a channel fails to start, you're
put back on the one you were watching.

The channels you move through are the ones you launched from: the category you
were in, your favorites in their usual order, or the guide's list. A channel
number you type is looked up in that same list, and "No channel N" means it
isn't in it.

The previous channel is remembered across sessions — watch one channel, go
back to the list, open another, and Right still takes you to the first.

With the controls **showing**, Up and Down go back to moving between the
controls, so press Back once to hide them before zapping.

## The quick list

Left (or **GUIDE**) opens a list over the picture, positioned on the channel
you're watching:

- **Channels** — each with what's on now. OK switches to it and closes the list.
- **Right** on a channel shows its schedule for today. If the channel has
  catch-up, OK on a past programme plays it.
- **Left** steps back up, to the list of categories. Picking a category also
  changes which channels Up and Down move through.
- **Back** closes the list from the top.

Nothing changes channel while the list is open except an explicit OK, so
browsing it is safe. With a mouse or a touchscreen, the list button in the
control row (just left of "Go to live") opens it.

## On a keyboard

The desktop apps follow the same rules: arrow keys stand in for the D-pad,
Enter for OK, and **Esc** for Back — it peels the same ladder, one press at a
time. A keyboard has no GUIDE key, so **G** opens and closes the quick list.

## Aspect ratio

Cycles Fit → Fill → Stretch → 16:9 → 4:3.

**Fill** crops to fill the screen and keeps the picture's shape. **Stretch**
distorts it to fill and keeps every pixel. They are different, and Fill is
almost always the one you want.

The choice is remembered per source. On a television the default is Fill, which
on a 16:9 panel showing 16:9 content looks identical to Fit; on a desktop the
default is Fit, because a window is whatever shape you dragged it to. On a phone
or tablet it follows how you're holding it: Fill in landscape, Fit in portrait,
where Fill would show only a sliver of the middle of the picture.
