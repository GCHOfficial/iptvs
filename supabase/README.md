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
   the only expected warnings are the five intentional `SECURITY DEFINER` RPCs (three
   pairing + `push_sources`/`push_metadata`, all callable by `authenticated`), the
   anonymous-access policies on the tables (devices read by design), and Supabase's own
   `rls_auto_enable`. The push RPCs are revoked from `anon` (they need a real session).

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
- [ ] Account A cannot read or write account B's rows.
- [ ] `claim_pairing` rejects an anonymous claimer, an expired code, and an already-claimed code.
- [ ] Deleting a `devices` row immediately revokes that device's read access (and its push).
