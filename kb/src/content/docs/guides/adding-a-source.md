---
title: Adding a source
description: Connecting an Xtream panel, a MAG/Stalker portal, or an M3U playlist, and adding extra EPG guides.
---

A **source** is one IPTV provider. You can add as many as you like and switch
between them; each keeps its own channels, categories, guide and favorites.

## The three kinds

**Xtream** — the most common. Needs a host, a username and a password. The host
can be entered with or without `http://`, and with a port if your provider uses
one.

**Stalker / MAG portal** — needs the portal URL and the MAC address your provider
registered. The portal URL is usually the one ending in `/c/` or `/stalker_portal/c/`.

**M3U playlist** — a playlist URL, optionally an EPG (XMLTV) URL and a custom
User-Agent.

:::tip
If your M3U URL is really an Xtream panel — anything with `get.php?username=…&password=…`
in it — the app detects that and offers to upgrade the source to a proper Xtream
connection. Take it: you get categories, VOD, series and catch-up, none of which
a flat playlist can express. The upgrade keeps the same source, so favorites and
settings survive.
:::

## Extra EPG guides

If your provider's guide is thin or missing, you can add more XMLTV guides to a
source alongside its own.

A channel is claimed by the **first guide that has it**, and later guides only
fill in what the earlier ones missed. That is deliberate: two guides covering one
channel would make "what's on now" ambiguous and draw overlapping cells in the TV
guide.

Matching is by `tvg-id` first, then by channel name for anything the ids missed.
Stalker portals carry no `tvg-id` at all, so there matching is by name only.

A guide that fails to download is skipped — your provider's own guide being
broken is usually why you are adding another one in the first place.

## Hiding categories

Providers often ship hundreds of categories you will never watch. Open a source's
settings and switch off the ones you don't want; they disappear from the category
list on every screen. Favorites in a hidden category are still shown.

## Buffering

Each source has a **buffer** setting — Low, Normal or High. It changes how much
the player keeps in hand once a stream is running, not how long a channel takes
to start. Raise it if a provider is unstable; leave it on Normal otherwise.
