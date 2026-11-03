-- iptvs — a developer delete for submitted diagnostics, plus the trigger-
-- function grant sweep the advisor asked for.
--
-- Two unrelated things, deliberately in one file: both are privilege-surface
-- changes to the schema the previous migration left behind, and splitting them
-- would mean two migrations whose only difference is which half of the same
-- review they belong to.
--
-- ===========================================================================
-- 1. support_delete_diagnostics — the owner-approved developer delete
-- ===========================================================================
--
-- `20261103000000_diagnostics.sql` said a developer-initiated delete was NOT in
-- scope, and that adding one later would mean "adding a third sweep mode rather
-- than loosening anything". The owner has now approved one, and this is that
-- third mode — nothing in the guard is relaxed.
--
-- Why it exists: the inbox is a working queue. A report that has been read and
-- acted on is a user's provider address, source and profile names and viewing
-- history sitting on disk for up to 30 more days for no reason, and the only
-- way to clear one was to wait. Deleting the evidence once it has served its
-- purpose is *strictly* the safer direction for that data.
--
-- What it is NOT: a general DELETE privilege. The row is still unreachable by
-- every client role in every direction; this is one DEFINER RPC that deletes
-- exactly one row by primary key, for exactly the accounts seeded by hand into
-- `public.support_readers`.
--
-- Why a client cannot abuse the transaction-local flag
-- ----------------------------------------------------
-- The flag (`iptvs.diagnostics_sweep`) is a GUC, and `set_config` is callable
-- by anyone — so "can a client set it to 'support'?" is the wrong question. It
-- can. The answer is that the flag alone is worth nothing, for two independent
-- reasons:
--
--   * **No client role holds any table privilege on `public.diagnostics`** —
--     `20261103000000_diagnostics.sql` revokes ALL from `anon` and
--     `authenticated`, and RLS is on with zero policies behind that. A DELETE
--     from a client session is refused by the grant system *before* any trigger
--     runs, flag or no flag. The only DELETE statements that can reach this
--     trigger at all are the ones inside a `SECURITY DEFINER` function owned by
--     the table owner: the submit RPC's sweep/eviction, and this one.
--   * **The 'support' branch additionally re-checks the caller's identity**
--     with `public.is_support_reader()`. `SECURITY DEFINER` switches the
--     *effective role*, not `request.jwt.claims`, so inside this RPC that call
--     sees the same JWT PostgREST was given — i.e. the branch opens only for a
--     caller who is, at that instant, a seeded support reader. A privileged
--     hand at the dashboard has no JWT, so `auth.uid()` is null and the branch
--     stays shut for it too: "the guard binds the table owner" survives this
--     migration, and `18_diagnostics_delete.test.sql` pins exactly that.
--
--     (The honest bound on that last sentence, unchanged from before: a role
--     that can `drop trigger` was never held by this trigger. The guard is
--     there to make an *accidental* or *mistaken* delete impossible, and to
--     make a deliberate one a reviewable change rather than a stray statement.)
--
-- Not rate-limited, unlike `submit_diagnostics`. That RPC is metered because it
-- is callable by `anon` with no subject to bound; this one is callable only by
-- a row somebody put in `support_readers` from the dashboard, and the worst a
-- compromised developer account could do with a meter in place is the same
-- thing slightly more slowly. A limiter here would add a failure mode
-- ("couldn't delete, try later") without bounding anything, so neither this RPC
-- nor the two support *read* RPCs beside it carry one.
--
-- Expiry is deliberately NOT filtered. `support_get_diagnostics` hides an
-- expired body because serving it would break the 30-day promise; deleting a
-- row the lazy sweep has not reached yet only helps that promise along, so the
-- delete matches on the code alone. The code is normalised exactly as
-- `support_get_diagnostics` normalises it — `upper(btrim(coalesce(...)))` — so
-- a code read off a phone call in lower case finds the same row for both.
--
-- Returns a plain boolean: true if a row went, false if there was nothing to
-- delete. An unknown code is not an error — it is the ordinary outcome of two
-- browser tabs open on the same inbox, and the panel says "already gone".
--
-- No `DEFAULT` parameters, for the reason the previous migration spells out at
-- length (PostgREST resolves overloads by parameter-name set; a DEFAULT beside
-- a narrower overload is answered as `PGRST203`).
--
-- ===========================================================================
-- 2. The trigger-function grant sweep
-- ===========================================================================
--
-- See the second section below. Hygiene, not a fix: the Supabase advisor flags
-- `public` functions still executable by `anon`/`authenticated`, and
-- most of the trigger functions in this schema still are. Eight of the fourteen
-- carry no revoke at all; two were revoked `from public` only, which strips the
-- built-in PUBLIC grant and leaves the *direct* grants Supabase's default
-- privileges hand those two roles; four were already revoked from both.
--
-- Idempotent throughout, like every migration before it.

-- ---------------------------------------------------------------------------
-- 1a. The third sweep mode.
--
-- Body otherwise verbatim from `20261103000000_diagnostics.sql`; re-declared
-- here rather than edited there, the same way `touch_profile_snapshot_revision`
-- was re-declared in `20260821010000_profiles_favorites_revision.sql`. The
-- *function* keeps its OID across `create or replace`, and the trigger refers
-- to it by OID, so nothing needs re-creating and no window exists where the
-- table is unguarded.
--
--   'expire'  — the row is past `expires_at` (the 30-day expiry, implemented).
--   'evict'   — the row is older than the 72 h floor and the table is full.
--   'support' — a seeded support reader is deleting it through
--               `support_delete_diagnostics`.
--
-- The first two re-check the ROW's own eligibility, so a bug in the sweep's
-- WHERE clause still cannot take a fresh submission. The third has no row
-- property to re-check — deleting a live row is the entire point — so it
-- re-checks the CALLER instead, which is the strongest equivalent available and
-- is what keeps the dashboard bound (see the header).
-- ---------------------------------------------------------------------------

create or replace function public.diagnostics_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  mode text := coalesce(current_setting('iptvs.diagnostics_sweep', true), '');
begin
  if tg_op = 'UPDATE' then
    raise exception 'iptvs: diagnostics rows cannot be modified'
      using errcode = 'check_violation';
  end if;

  if mode = 'expire' and old.expires_at <= now() then
    return old;
  end if;
  if mode = 'evict' and old.created_at <= now() - interval '72 hours' then
    return old;
  end if;
  -- Deliberately re-asks the question `support_delete_diagnostics` already
  -- asked. The RPC's check is the one that produces a good error message; this
  -- one is the one that cannot be bypassed by reaching the DELETE some other
  -- way.
  if mode = 'support' and public.is_support_reader() then
    return old;
  end if;

  raise exception 'iptvs: diagnostics rows cannot be deleted'
    using errcode = 'check_violation';
end;
$$;

-- A no-op today (`create or replace` preserves the ACL, and
-- `20261103000000_diagnostics.sql` already revoked exactly this) — kept so the
-- revoke travels with the declaration if the function is ever dropped and
-- recreated rather than replaced.
revoke all on function public.diagnostics_immutable() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1b. The RPC.
-- ---------------------------------------------------------------------------

create or replace function public.support_delete_diagnostics(p_code text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- Same normalisation as `support_get_diagnostics`, so the two agree on what
  -- "this code" means. Keep them identical if either ever changes.
  target  text := upper(btrim(coalesce(p_code, '')));
  deleted int  := 0;
begin
  if not public.is_support_reader() then
    raise exception 'iptvs: not authorised' using errcode = 'check_violation';
  end if;

  -- Transaction-local (`true`), so it cannot leak onto a pooled connection, and
  -- cleared immediately after the statement it exists for. If the DELETE
  -- raises, the GUC stack is unwound with the aborting (sub)transaction, so
  -- there is no path that leaves it set.
  perform set_config('iptvs.diagnostics_sweep', 'support', true);
  delete from public.diagnostics d where d.code = target;
  get diagnostics deleted = row_count;
  perform set_config('iptvs.diagnostics_sweep', '', true);

  return deleted > 0;
end;
$$;

-- Granted exactly like the two support read RPCs: `authenticated` may call it
-- (the identity check is inside, and lives in `support_readers`), `anon` may
-- not reach it at all.
revoke all on function public.support_delete_diagnostics(text) from public, anon;
grant execute on function public.support_delete_diagnostics(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Trigger functions: revoke EXECUTE from the client roles.
--
-- The finding: ten of the fourteen trigger functions in `public` are still
-- executable by `anon` and `authenticated` — eight were never revoked at all,
-- and two (`profiles_touch_updated_at` and `touch_profile_snapshot_revision`)
-- were revoked `from public` only, which strips the built-in PUBLIC grant but
-- leaves the *direct* grants
-- that a Supabase project's `alter default privileges ... grant all on
-- functions to anon, authenticated, service_role` hands every new function. The
-- advisor is right to point at it even though nothing is exploitable: a
-- function `returns trigger` cannot be called as an RPC at all (Postgres
-- answers "trigger functions can only be called as triggers"), and PostgREST
-- does not expose one. This is attack-surface hygiene, and the kind that is
-- only cheap to fix while it is small.
--
-- **Revoking EXECUTE does not stop any trigger from firing.** A trigger's
-- function is resolved and permission-checked when the trigger is *created*;
-- firing it goes through `ExecCallTriggerFunc`, which invokes a cached
-- `FmgrInfo` directly, and fmgr performs no privilege checks — SQL-level
-- EXECUTE is only consulted where a function is named in a parsed query. This
-- repo already relies on that in production: `sources_sync_secret_profile`,
-- `pairings_reap`, `diagnostics_validate` and `diagnostics_immutable` were
-- revoked from `anon, authenticated` in earlier migrations and their triggers
-- keep firing. It is also pinned empirically rather than by assertion —
-- `15_profiles_favorites_revision.test.sql` runs `set local role authenticated`
-- and then writes `public.sources`/`public.profiles` directly, firing
-- `sources_validate`, `profiles_touch_updated_at` and the SECURITY DEFINER
-- `touch_profile_snapshot_revision` as a role that, after this migration, holds
-- no EXECUTE on any of them.
--
-- The one the advisor named is `touch_profile_snapshot_revision`
-- (`SECURITY DEFINER`); the rest are swept with it because "all of them" is a
-- property `01_baseline_invariants.test.sql` can hold going forward, while "the
-- SECURITY DEFINER ones" is a list that drifts the moment someone adds a
-- trigger function. `service_role` is left alone: it bypasses RLS by design and
-- never ships to a client.
-- ---------------------------------------------------------------------------

revoke all on function public.touch_updated_at()                 from public, anon, authenticated;
revoke all on function public.profiles_touch_updated_at()        from public, anon, authenticated;
revoke all on function public.touch_profile_snapshot_revision()  from public, anon, authenticated;
revoke all on function public.enforce_profile_cap()              from public, anon, authenticated;
revoke all on function public.sources_validate()                 from public, anon, authenticated;
revoke all on function public.profiles_validate()                from public, anon, authenticated;
revoke all on function public.metadata_validate()                from public, anon, authenticated;
revoke all on function public.secrets_validate()                 from public, anon, authenticated;
revoke all on function public.pairings_validate()                from public, anon, authenticated;
revoke all on function public.devices_validate()                 from public, anon, authenticated;
revoke all on function public.sources_sync_secret_profile()      from public, anon, authenticated;
revoke all on function public.pairings_reap()                    from public, anon, authenticated;
revoke all on function public.diagnostics_validate()             from public, anon, authenticated;
