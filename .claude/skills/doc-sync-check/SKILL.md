---
name: doc-sync-check
description: "Check whether a change touches an area covered by one of the docs/*.md detail docs (or CLAUDE.md itself) without updating that doc in the same diff. Use before considering work done, before committing, or when asked to review/finish a change — this enforces CLAUDE.md's 'Upkeep rule' that doc updates land in the same PR as the change that invalidates them."
---

# Doc-sync check

CLAUDE.md's Upkeep rule: "documentation updates land in the same commit/PR as the change that
invalidates them." This is easy to forget mid-task because the doc file usually isn't open in
context. Run this check before calling work done, not just when asked.

## How to run it

1. Get the diff: `git diff` (unstaged + staged) and `git status` for untracked files, or the
   specific file list you were given.
2. Map every changed file to a doc using the table below. A file can map to more than one doc.
3. For each doc a changed file maps to, check whether that doc file *also* appears in the diff.
4. If a mapped doc did not change, don't just flag it — actually read the relevant section of
   that doc and judge whether the code change **invalidates something it currently says** (a
   rule, a mechanism, a file/function name, a number). Cosmetic changes (renames that don't change
   behavior, comment-only edits, test-only changes with no new invariant) don't require a doc
   update even though the path matches — use judgment, don't cargo-cult the mapping.
5. Report findings as a short list: doc file → what needs updating → why (cite the stale
   sentence/section). If nothing needs updating, say so explicitly rather than staying silent.

## Path → doc ownership map

| Changed path | Doc to check |
|---|---|
| `lib/data/library_repository.dart`, `lib/data/app_database.dart` (schema/migration parts) | CLAUDE.md "Database migrations" + "Architecture" sections directly; also `docs/validation-baseline.md` if performance-relevant |
| `lib/screens/live_focus_coordinator.dart`, `lib/screens/epg_grid_screen.dart`, `lib/widgets/focusable_card.dart`, `lib/widgets/tv_text_field.dart`, Back-ladder code in `lib/screens/channel_list_screen.dart` | `docs/tv-navigation.md` |
| `lib/player/player_screen.dart`, `lib/player/player_overlay.dart`, `lib/screens/live_preview_controller.dart`, `android/app/src/main/kotlin/**/player/**`, `windows/runner/flutter_window.cpp`, `packages/iptvs_ios_player/**` (Swift) | `docs/player.md` |
| `packages/iptvs_ios_player/**`, anything iOS-native player/audio-session related | `docs/ios.md` (and `docs/player.md` "iOS" section) |
| `supabase/migrations/**`, `supabase/tests/**`, `lib/data/cloud_*.dart`, `lib/data/local_profile_store.dart`, `lib/screens/profile_pick_screen.dart` | `docs/cloud-sync.md` |
| `android/**` signing config, keystore, `docs/android-signing.md`-adjacent CI (`.github/workflows/build.yml`, `google-play.yml`) signing steps | `docs/android-signing.md` |
| `.github/workflows/release.yml`, `.github/workflows/google-play.yml`, `.github/workflows/microsoft-store.yml`, packaging/versioning code | `docs/store-publishing.md` |
| `lib/data/update_service.dart`, `lib/data/update_store.dart`, `lib/data/update_installer.dart`, `lib/screens/*update*`, `lib/widgets/release_notes_view.dart` | `docs/updates.md` |
| Large-ingestion workers (`decodeLiveChannelsBytes`, `decodeMediaItemsBytes`, `_ingestStalkerChannels`, `parseXmltvBatched`), migration fixture matrix | `docs/validation-baseline.md` |
| Any file whose change contradicts a stated invariant in the CLAUDE.md body itself (sealed locators, generation guards, redaction, HTTP timeouts, etc.) | CLAUDE.md directly, in the matching section |

## What "done" looks like

Either:
- No mapped doc needs a change (say why, briefly), or
- The relevant doc(s) are edited in the same diff/commit as the code change, addressing the
  specific stale claim you identified — not a generic "mention this file now exists" edit.

Don't create new doc sections speculatively. Only touch what the change actually invalidates.
