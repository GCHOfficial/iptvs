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
- **Tenant isolation** (`..._tenant_isolation.sql`) — makes that last sentence
  actually true. It was not: an owner-guarded `ON CONFLICT` *skips* a foreign row
  rather than rejecting it, so a crafted `push_sources` payload could carry another
  account's source id into the secret loop and plant a credential there. Adds
  composite `(id, owner)` keys + composite FKs so a cross-owner row is
  unrepresentable, raises instead of skipping on a foreign id, filters
  `source_secrets.owner` in `get_secrets`, drops the unvalidated direct
  `pairings` INSERT path, makes `devices.device_uid` immutable, throttles
  `claim_pairing`, and revokes table-level grants on the five RPC-only tables.
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
- **Snapshot revisions** (`..._profile_snapshot_revision.sql`) —
  `profiles.updated_at` is the revision for the complete profile snapshot.
  Triggers advance it for source and metadata inserts, updates, and deletes as
  well as direct profile/favorites edits, so the app's destructive-push warning
  detects panel changes anywhere in the snapshot.
- **Profile cap** (`..._profile_cap.sql`) — a `BEFORE INSERT` trigger
  (`enforce_profile_cap`) limits each account to **20** profiles. Enforced in the
  database so neither the panel nor a crafted client can exceed it; the panel also
  mirrors the limit (`MAX_PROFILES`) to disable its add button.
- **Diagnostics submission** (`..._diagnostics.sql`) — "Send diagnostics": an install uploads its
  exportable log and gets a `D-XXXXXX` code back for the user to read out. `submit_diagnostics` is
  the **only write RPC in this schema granted to `anon`** — a session-less install holding nothing
  but the publishable key — because requiring a session would mint a permanent `auth.users` row per
  submission and still not bound anything (sessions are free to mint). Consequently every limit is
  **global**, not per subject: 256 KiB per body, 120 submissions/hour, 2000 rows / 64 MiB, a 72 h
  eviction floor, 30-day expiry swept lazily. The table is **insert-only**, enforced by a
  `BEFORE UPDATE OR DELETE` trigger that binds the table owner too and re-checks each row's own
  eligibility rather than trusting the sweep's flag. Reads go through `support_list_diagnostics` /
  `support_get_diagnostics`, gated on a row in `support_readers` — **empty by default, so nobody can
  read anything**. There is deliberately **no developer delete RPC**. Read
  [docs/cloud-sync.md](../docs/cloud-sync.md) "Diagnostics submission" before changing any of it.
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
5. **Seed yourself as the diagnostics reader.** Submitted diagnostics are readable **only** by a
   `public.support_readers` row, and that table starts empty — so until this is done, nobody can
   read anything, including you. There is no RPC for it on purpose: a self-service "make me a
   reader" path would *be* the security boundary of the feature. Sign in to the panel once with the
   developer account, then run this in the dashboard SQL editor:
   ```sql
   insert into public.support_readers (uid)
   select id from auth.users where email = '<your panel sign-in email>'
   on conflict (uid) do nothing;
   ```
   Confirm with `select count(*) from public.support_readers;` — it must be exactly the accounts you
   intend. The panel's **Support** tab appears on its own once this row exists (it probes
   `support_list_diagnostics` and hides itself when that fails). To revoke, delete the row; access
   stops immediately and nothing is cached.
6. **Run the security advisor** after applying (`get_advisors` / dashboard Advisors):
   the only expected warnings are the intentional `SECURITY DEFINER` RPCs (the three
   pairing RPCs, `push_sources`/`push_metadata`/`push_favorites`, and `set_device_profile`,
   all callable by `authenticated`), the anonymous-access policies on the tables (devices
   read by design), and Supabase's own `rls_auto_enable`. The push RPCs are revoked from
   `anon` (they need a real session).
   - **One further expected warning, new and deliberate:** `submit_diagnostics` is
     `SECURITY DEFINER` **and granted `execute` to `anon`**. It is the only write RPC in this schema
     that is, and the advisor is right to point at it — see `..._diagnostics.sql`'s header for why a
     session would have been worse, and `01_baseline_invariants.test.sql`, which pins that grant in
     both directions (it exists here, and nowhere else). The three diagnostics tables also report
     `rls_enabled_no_policy`, like the original five RPC-only tables; that is the design.

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

**These were unchecked manual boxes for months, and two of them were false** (a
`push_sources` payload *could* reach another account's secret rows; an anonymous
session *did* have a direct INSERT on `pairings`). They are now the spec for the
pgTAP suite in `supabase/tests/` — prefer extending that over re-checking by hand.

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
- [ ] A `push_sources` payload naming another account's **source id** raises
      `iptvs: source id belongs to another account` (it used to skip silently).
- [ ] `get_secrets` never returns a `source_secrets` row owned by another account.
- [ ] `sources`/`metadata_configs` cannot be inserted pointing at another
      account's `profile_id` (composite FK violation).
- [ ] An anonymous session cannot INSERT into `pairings` directly, and
      `request_pairing` still works.
- [ ] `update devices set device_uid = …` raises `iptvs: device identity is
      immutable`, and `claim_pairing` still succeeds (it re-points `owner`).
- [ ] `anon`/`authenticated` hold **no** privileges on `source_secrets`,
      `metadata_secrets`, `profile_crypto`, `device_ck`, `push_rate`, and no
      TRUNCATE on the five client-facing tables.
- [ ] `pairings.suggested_label` — the one column an **anonymous** session can write
      that is displayed in **another account's** panel — is bounded (256, matching
      `devices_validate`), rejects control characters, and is frozen on UPDATE.
- [ ] A cross-account re-pair does not carry the previous owner's `devices.label`
      into the new owner's device list, and a same-owner re-pair with a blank panel
      name does not overwrite the name already stored.
- [ ] Every `SECURITY DEFINER` function pins `search_path = ''`.
- [ ] A session-less `anon` caller **can** `submit_diagnostics` and **cannot** select, insert,
      update or delete `diagnostics` — and the submit mints no `auth.users` row.
- [ ] `support_list_diagnostics`/`support_get_diagnostics` raise `iptvs: not authorised` for a real
      account with no `support_readers` row **and for a legitimately paired device**; a seeded
      reader reads the body verbatim and loses access the moment the row is deleted.
- [ ] A `diagnostics` row cannot be UPDATEd or DELETEd **by anyone, including the table owner**,
      except by the submit RPC's own expiry sweep (past `expires_at`) or ceiling eviction (past the
      72 h floor) — and setting the sweep flag by hand still cannot take an ineligible row.
- [ ] An oversized body is refused with the **limit** in the message and **none of the body**.
- [ ] The 121st submission in the hour is refused globally, and allowed again once the window rolls.
