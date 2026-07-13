# Cloud sync + profiles — full detail

A **web panel** lets users manage their source list with a real keyboard instead of a TV remote;
devices **pull** it down with no on-device login, and can optionally **push** their local list
back up (two-way). It's entirely optional — when the Supabase build config is absent the feature
hides itself and the app is unchanged. The compact rules live in CLAUDE.md; read this before
changing sync, pairing, profiles, or anything under `supabase/`.

## Backend

Supabase (the only free option bundling Postgres + Auth + RLS + a client SDK that's safe to call
directly from a static page). Schema + the entire security boundary live in
[`supabase/migrations/`](../supabase/migrations/) (timestamped `<version>_<name>.sql`, the first
is the schema + RLS) — read the first file's header before changing it. Five tables (`profiles`,
`sources`, `metadata_configs`, `devices`, `pairings`) with **deny-by-default RLS** (no policy = no
access) and `SECURITY DEFINER` RPCs: three pairing
(`request_pairing`/`pairing_status`/`claim_pairing`), the profile-scoped push
(`push_sources`/`push_metadata`/`push_favorites`, each `(payload, p_profile_id)`), and
`set_device_profile`. Migrations are applied to the live project and re-applying is idempotent;
the Supabase GitHub integration auto-applies new ones on push.

## Cloud profiles

An account holds multiple named `profiles`; each is a complete setup — its `sources` (which carry
a `profile_id` and a per-source `settings` jsonb for hidden categories), `metadata_configs`
(re-keyed to one row per profile), and the profile's `favorites` jsonb. A device's
`devices.active_profile_id` is which profile it syncs; the device picks it (panel only
creates/renames profiles). The `..._profiles.sql` migration backfills a `Default` profile per
existing owner, so a single-profile account is unchanged. Owner-scoping stays the security
boundary (`profile_id` is only an added filter); legacy 1-arg `push_*` delegate to the device's
active profile for older app builds.

## Open-source security model

The Supabase URL + **anon/publishable** key ship in the app and the panel (safe *by design* —
access is gated only by RLS). The `service_role` key must never appear in any client or this
repo. Devices authenticate as **anonymous** Supabase users with **no direct table writes** (every
write policy requires `is_real_user()`); they gain read access only after a real account claims
their pairing code (`claim_pairing`). The optional **push** is the one device→cloud write path
and goes through the `push_sources`/`push_metadata` `SECURITY DEFINER` RPCs, which are
owner-scoped via `current_device_owner()`: an *unpaired* anonymous caller has no owner and is
rejected, and a payload can't touch another account's rows (insert forces `owner = o`; the
upsert's `DO UPDATE` is guarded by `owner = o`). A paired device can already read all of its
owner's credentials, so writing that **same** owner's list adds no cross-account blast radius.
Pairing codes are short-lived + rate-limited. Push uses last-write-wins (it replaces the panel's
set).

## Pairing flow (code-based, works on every platform)

The device shows a code ([`cloud_sync_screen.dart`](../lib/screens/cloud_sync_screen.dart)); the
user enters it in the panel's Devices page; the device polls `pairing_status` until claimed, then
pulls. Once paired, the screen shows a **profile picker** (list the account's profiles, switch →
`set_device_profile` + re-pull) and offers **Pull now** / **Push to panel** (push confirms first,
since it overwrites that profile).

## Flutter side

[`cloud_config.dart`](../lib/data/cloud_config.dart) (build-time `--dart-define`
`SUPABASE_URL`/`SUPABASE_ANON_KEY`/`PANEL_URL`; `isConfigured` gates the whole feature),
[`cloud_sync.dart`](../lib/data/cloud_sync.dart) (`CloudSync`: anon session, pairing, profile
selection (`listProfiles`/`activeProfileId`/`setProfile`), and profile-scoped
`pullSources`/`pullMetadata`/`pullFavorites` + `pushSources`/`pushMetadata`/`pushFavorites`.
Sources/metadata write through `SourceStore`; favorites use `AppDatabase` and are mapped between
the credential-derived `Source.id` (local key) and the `SourceConfig` UUID (cloud key) via
`config.build().id`. Cloud-managed source ids are tracked in secure storage so a pull replaces
the managed set in panel order but leaves local-only sources alone). Source ids are UUIDs
(`newSourceId`/`isUuid` in [`source_config.dart`](../lib/sources/source_config.dart)) so they
round-trip through the `uuid`-typed cloud column; push rewrites any legacy non-UUID id first.
[`secure_local_storage.dart`](../lib/data/secure_local_storage.dart) persists the Supabase session
in the keychain, not plaintext prefs. Init is in `main.dart`, behind `isConfigured`. The pure
mapper `cloudRowToConfig` + the id helpers are unit-tested in `test/cloud_sync_test.dart`.

## Web panel

[`panel/`](../panel/) — a tiny Vite + `@supabase/supabase-js` SPA (no framework). **Magic-link
sign-in only** (no OAuth). Field shapes mirror `SourceConfig` per kind. Sources carry an integer
`position` and the list has **↑/↓ reorder** controls (positions self-heal to a clean `0..n-1` on
reorder; new sources append); devices show sources in that order. Branded with the app icon
(`panel/public/icon.png`, copied from `assets/icon/`). Deployed to **GitHub Pages** by
[`.github/workflows/pages.yml`](../.github/workflows/pages.yml) (`upload-pages-artifact@v5` +
`deploy-pages@v5`; Supabase values from repo Variables). Note: the Flutter web target lives in
`web/`; the panel deliberately lives in `panel/`.

## Profiles (device-side)

The app boots into `ProfilePickScreen` (`main.dart` `home:`, `bootMode: true`) — a "Who's
watching?" grid that combines **cloud profiles** (only when built with Supabase config *and*
paired) and **local profiles**, which need no cloud at all. At boot the screen decides for itself
whether to appear: `shouldShowPickerAtStartup(mode, profileCount)` with the persisted
`ProfilePickerStartup` mode (`auto` = only when >1 profile, `always`, `off`; cycled from a
`FocusableCard` row atop `sources_screen.dart`) — otherwise it silently short-circuits to
`HomeShell`, so a single-profile install boots exactly as before. Profiles are also reachable
from the channel-list AppBar avatar (`ProfileAvatarButton` → "Change profile") and a Profiles
action on the sources screen.

Isolation model (`lib/data/local_profile_store.dart`): every profile — local *and* cloud — owns a
`ProfileSnapshot` of the device state (source list + active source + metadata config + the
cloud-managed ids set from `CloudSync.managedSourceIds`). Switching away snapshots the current
state into its owner; switching to a local profile restores its snapshot verbatim (including an
empty list — and clears the managed-ids set so a later cloud "Pull now" can't merge cloud sources
into a local profile); switching to a cloud profile restores its snapshot first (its device-local
extra sources + managed ids), then does the normal `setProfile` + pull. This keeps `pullSources`'s
"preserve non-managed sources" semantic working on the right baseline and prevents cross-profile
source leaks. New local profiles are seeded with only the Demo source. Local profiles can be
deleted in the picker's manage mode; cloud profiles are managed in the web panel. JSON
round-trips, the startup decision, and the stable cloud-avatar colour hash are unit-tested in
`test/profile_store_test.dart`.
