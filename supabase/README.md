# Supabase backend for iptvs cloud sync

This directory holds the database schema for the optional **cloud source panel** —
a web UI where you manage your IPTV source list once and devices pull it down with
no on-device login. See the repo `CLAUDE.md` and the design notes for the full picture.

## What's here

- `migrations/*.sql` — tables, row-level security, and the RPCs (filenames use
  Supabase's `<timestamp>_<name>` convention). The first migration is the entire
  security boundary; read its header comment before changing anything. The pairing
  RPCs link a device to an account; the `push_sources`/`push_metadata` RPCs
  (`..._two_way_push.sql`) are the only device→cloud write path — owner-scoped via
  `current_device_owner()`, so an unpaired anon caller is rejected and a payload
  can't reach another account's rows.
- **Profiles** (`..._profiles.sql`) — an account holds multiple named **profiles**,
  each its own source list + metadata config + per-source `settings` (hidden
  categories) + `favorites`. `sources`/`metadata_configs` gain a `profile_id`
  (`metadata_configs` is re-keyed to one row per profile); `devices` gain
  `active_profile_id` (which profile that device syncs). The push RPCs take a
  `p_profile_id` and verify it belongs to the caller's account; new
  `push_favorites` and `set_device_profile` RPCs follow the same owner-scoped
  pattern. The migration backfills a `Default` profile for every existing owner
  (idempotent), so a single-profile account is unchanged. Owner-scoping remains the
  security boundary — `profile_id` is only an added filter, and a paired device can
  already read all of its owner's data. The legacy 1-arg `push_sources`/
  `push_metadata` delegate to the device's `active_profile_id` so older app builds
  stay scoped to one profile.
- **Profile cap** (`..._profile_cap.sql`) — a `BEFORE INSERT` trigger
  (`enforce_profile_cap`) limits each account to **20** profiles. Enforced in the
  database so neither the panel nor a crafted client can exceed it; the panel also
  mirrors the limit (`MAX_PROFILES`) to disable its add button.
- **Account deletion** (`..._account_deletion.sql`) — the panel's
  `delete_account` RPC removes only the signed-in real account. Owner foreign
  keys cascade its cloud data, and the RPC also removes the anonymous auth
  identities of devices paired to that account.

## One-time setup

1. Create a free project at <https://supabase.com>.
2. Apply the migrations. With the Supabase **GitHub integration** connected to this
   repo, pushing `supabase/migrations/` applies new migrations automatically. Or use
   the CLI (`supabase link --project-ref <ref>` then `supabase db push`), or paste the
   SQL into the dashboard SQL editor.
3. **Auth → Providers / Sign In**: enable **Email** (magic link) and turn on
   **Anonymous sign-ins** (devices rely on them). The panel uses magic-link only.
4. **Auth → URL configuration**: add the GitHub Pages panel URL to the redirect allow-list.
5. **Run the security advisor** after applying (`get_advisors` / dashboard Advisors):
   the only expected warnings are the intentional `SECURITY DEFINER` RPCs (the three
   pairing RPCs, `push_sources`/`push_metadata`/`push_favorites`, and `set_device_profile`,
   all callable by `authenticated`), the anonymous-access policies on the tables (devices
   read by design), and Supabase's own `rls_auto_enable`. The push RPCs are revoked from
   `anon` (they need a real session).

> **Applying a migration out-of-band? Repair the version afterward.** When you apply a
> migration file through the **MCP `apply_migration` tool** or the **dashboard SQL editor**
> (rather than `supabase db push` / the GitHub integration), the remote ledger records it
> under a *freshly generated* version timestamp — not the file's `<version>_` prefix. The
> next `supabase db push` / "Supabase Preview" then fails with **"Remote migration versions
> not found in local migrations directory"** because the recorded version has no matching
> file. Fix it by aligning the ledger to the committed filename:
> ```sql
> update supabase_migrations.schema_migrations
>    set version = '<file_version>'   -- e.g. 20260630000000, the file's prefix
>  where name = '<migration_name>' and version = '<generated_version>';
> ```
> (Equivalent to `supabase migration repair --status applied <file_version>` when the CLI is
> linked.) The committed `supabase/migrations/*.sql` files are the source of truth; the remote
> ledger should match their version prefixes exactly.

## Wiring the clients

Both clients use the **anon/publishable** key — it is safe to commit because RLS
(in the migration) is deny-by-default. **Never** put the `service_role` key in the
app, the web panel, or this repo.

Prefer the modern **publishable key** (`sb_publishable_…`) over the legacy anon JWT.

- **Web panel** (`panel/`): set `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` (GitHub
  Actions reads these from repo **Variables** — they're public by design, not secrets).
- **Flutter app** (`lib/data/cloud_config.dart`): read at build time from `--dart-define`s.
  - **CI**: the build/release workflows pass them from the repo Variables automatically.
  - **Local dev**: copy `dart_define.example.json` → `dart_define.json` (gitignored) and run
    `flutter run -d <platform> --dart-define-from-file=dart_define.json`. Same flag works for
    `flutter build`. Without it, `CloudConfig.isConfigured` is false and the cloud UI stays hidden.

## Security checklist (do this before trusting it)

- [ ] Anonymous session reads **nothing** from `sources`/`metadata_configs` until paired.
- [ ] Anonymous session has **no direct** INSERT/UPDATE/DELETE on any table (writes need a real account).
- [ ] `push_sources`/`push_metadata` reject an **unpaired** anonymous caller (no owner).
- [ ] A `push_sources` payload can't create/modify/delete rows for another account (owner-scoped).
- [ ] `push_sources`/`push_metadata`/`push_favorites`/`set_device_profile` reject a
      `profile_id` the caller's account doesn't own.
- [ ] Account A cannot read or write account B's profiles, sources, or favorites.
- [ ] `claim_pairing` rejects an anonymous claimer, an expired code, and an already-claimed code.
- [ ] Deleting a `devices` row immediately revokes that device's read access (and its push).
- [ ] `delete_account` rejects anonymous devices, deletes only the caller, and
      removes all owner rows plus the caller's paired anonymous auth users.
