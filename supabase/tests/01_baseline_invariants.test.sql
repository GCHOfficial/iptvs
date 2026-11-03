-- Baseline security invariants, independent of any specific RPC.
--
-- Read-only against the schema produced by replaying every
-- supabase/migrations/*.sql — no seed data needed, so this file's
-- begin/rollback wrapper is only for consistency with the rest of the suite.

begin;

select plan(25);

-- ---------------------------------------------------------------------------
-- RLS is enabled on every table in `public` (deny-by-default is the whole
-- security model — see cloud_sync_init.sql's header comment).
-- ---------------------------------------------------------------------------

select ok(
  not exists (
    select 1
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'r'
       and not c.relrowsecurity
  ),
  'every table in public has row level security enabled'
);

-- ---------------------------------------------------------------------------
-- Every SECURITY DEFINER function in public pins search_path to the empty
-- string (harden_cloud.sql's advisor-clean sweep; every migration since has
-- kept new DEFINER functions on the same pin). A single catalog query over
-- pg_proc.proconfig, per the task brief: cheap, and it catches a regression
-- in any future migration that adds a DEFINER function without the pin.
-- ---------------------------------------------------------------------------

-- Two things this assertion learned the hard way, both worth keeping:
--
--   * `SET search_path = ''` is stored in pg_proc.proconfig as the text
--     `search_path=""` — WITH the quotes — not `search_path=`. Comparing
--     against the unquoted form made this fail for every function rather than
--     none, which looked like a catastrophic finding and was a test bug.
--   * `rls_auto_enable` is Supabase's OWN event-trigger function (it pins
--     `pg_catalog`, not `''`), present in the platform image rather than
--     created by any migration here. supabase/README.md already documents it
--     as an expected advisor warning, so it is excluded by name.
--
-- Reported as an array rather than a bare boolean so a future failure names the
-- offending function instead of just saying "no".
select is(
  (
    select coalesce(array_agg(p.proname::text order by p.proname), '{}'::text[])
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
       and p.proname <> 'rls_auto_enable'
       and not exists (
         select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) as cfg(setting)
          where cfg.setting in ('search_path=', 'search_path=""')
       )
  ),
  '{}'::text[],
  'every SECURITY DEFINER function in public pins search_path to empty'
);

-- ---------------------------------------------------------------------------
-- No trigger function in `public` is executable by a client role
-- (20261104000000_diagnostics_delete.sql's advisor sweep).
--
-- A function `returns trigger` cannot be called as an RPC — Postgres answers
-- "trigger functions can only be called as triggers" and PostgREST never
-- exposes one — so nothing here was exploitable. It is attack-surface hygiene,
-- and the reason it is an invariant rather than a one-off cleanup is that it is
-- the state a new function arrives in: Supabase's
-- `alter default privileges ... grant all on functions to anon, authenticated`
-- grants both roles *directly*, so the usual `revoke ... from public` (which
-- strips only the built-in PUBLIC grant) leaves them holding EXECUTE. Eight of
-- the fourteen carried no revoke at all and two carried that partial one. The
-- next trigger function added will inherit the same two grants unless someone
-- remembers; this assertion is that memory.
--
-- **Revoking EXECUTE does not stop a trigger firing.** The function is resolved
-- and permission-checked when the trigger is CREATEd; firing it goes through
-- `ExecCallTriggerFunc`, which invokes a cached `FmgrInfo` directly, and fmgr
-- does no privilege checking — SQL-level EXECUTE is only consulted where a
-- function is named in a parsed query. The suite proves that empirically too:
-- `15_profiles_favorites_revision.test.sql` writes `public.sources` and
-- `public.profiles` directly as `authenticated` and asserts on what
-- `sources_validate`, `profiles_touch_updated_at` and the SECURITY DEFINER
-- `touch_profile_snapshot_revision` did — as a role holding no EXECUTE on any
-- of them.
--
-- `rls_auto_enable` is excluded by name for continuity with the assertion
-- above; it is Supabase's own EVENT trigger function, so it returns
-- `event_trigger` rather than `trigger` and the type filter already skips it.
-- Reported as the array of offenders so a failure names them.
select is(
  (
    select coalesce(array_agg(distinct p.proname::text order by p.proname::text), '{}'::text[])
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      cross join unnest(array['anon', 'authenticated']) as r(name)
     where n.nspname = 'public'
       and p.prorettype = 'pg_catalog.trigger'::regtype
       and p.proname <> 'rls_auto_enable'
       and has_function_privilege(r.name::name, p.oid, 'EXECUTE')
  ),
  '{}'::text[],
  'no trigger function in public is executable by anon or authenticated'
);

-- ---------------------------------------------------------------------------
-- The six composite foreign keys from tenant_isolation.sql section 2 — the
-- structural fix for F1 (secret ownership) and F2 (profile_id squatting).
-- ---------------------------------------------------------------------------

select fk_ok(
  'public', 'sources', array['profile_id', 'owner'],
  'public', 'profiles', array['id', 'owner'],
  'sources(profile_id,owner) references profiles(id,owner)'
);
select fk_ok(
  'public', 'metadata_configs', array['profile_id', 'owner'],
  'public', 'profiles', array['id', 'owner'],
  'metadata_configs(profile_id,owner) references profiles(id,owner)'
);
select fk_ok(
  'public', 'source_secrets', array['source_id', 'owner'],
  'public', 'sources', array['id', 'owner'],
  'source_secrets(source_id,owner) references sources(id,owner)'
);
select fk_ok(
  'public', 'source_secrets', array['profile_id', 'owner'],
  'public', 'profiles', array['id', 'owner'],
  'source_secrets(profile_id,owner) references profiles(id,owner)'
);
select fk_ok(
  'public', 'metadata_secrets', array['profile_id', 'owner'],
  'public', 'profiles', array['id', 'owner'],
  'metadata_secrets(profile_id,owner) references profiles(id,owner)'
);
select fk_ok(
  'public', 'profile_crypto', array['profile_id', 'owner'],
  'public', 'profiles', array['id', 'owner'],
  'profile_crypto(profile_id,owner) references profiles(id,owner)'
);

-- ---------------------------------------------------------------------------
-- F3: pairings_insert was dropped and never replaced. Only select/delete
-- policies remain (both strictly self-scoped by device_uid = auth.uid()).
-- ---------------------------------------------------------------------------

select policies_are(
  'public', 'pairings',
  array['pairings_select', 'pairings_delete'],
  'pairings carries no direct-insert policy'
);

-- ---------------------------------------------------------------------------
-- F5: the five RPC-only tables are reachable by anon/authenticated through
-- nothing but table-level privilege — not even RLS is the boundary here,
-- since these tables have zero policies. table_privs_are() demonstrates the
-- idiomatic pgTAP check on one representative table; the aggregate query
-- below confirms it holds for all five, both roles, every privilege.
-- ---------------------------------------------------------------------------

select table_privs_are(
  'public', 'source_secrets', 'anon', array[]::text[],
  'anon holds no privileges on source_secrets'
);
select table_privs_are(
  'public', 'source_secrets', 'authenticated', array[]::text[],
  'authenticated holds no privileges on source_secrets'
);

select ok(
  not exists (
    select 1
      from unnest(array[
        'source_secrets', 'metadata_secrets', 'profile_crypto', 'device_ck', 'push_rate'
      ]) as t(name)
      cross join unnest(array['anon', 'authenticated']) as r(name)
      cross join unnest(array[
        'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'
      ]) as priv(name)
     where has_table_privilege(r.name, format('public.%I', t.name), priv.name)
  ),
  'anon/authenticated hold zero privileges on all five RPC-only secret tables'
);

-- The five client-facing tables keep their DML grants (the panel writes them
-- directly under RLS) but lose TRUNCATE/REFERENCES/TRIGGER — TRUNCATE in
-- particular, since it bypasses RLS entirely (a latent full-wipe primitive
-- on an RLS-protected table).
select ok(
  not exists (
    select 1
      from unnest(array[
        'sources', 'metadata_configs', 'devices', 'pairings', 'profiles'
      ]) as t(name)
      cross join unnest(array['anon', 'authenticated']) as r(name)
      cross join unnest(array['TRUNCATE', 'REFERENCES', 'TRIGGER']) as priv(name)
     where has_table_privilege(r.name, format('public.%I', t.name), priv.name)
  ),
  'anon/authenticated hold no TRUNCATE/REFERENCES/TRIGGER on the five client-facing tables'
);

-- ---------------------------------------------------------------------------
-- F6: gen_pairing_code() lost its default PUBLIC EXECUTE (it was exposed as
-- a callable PostgREST RPC with no client caller).
-- ---------------------------------------------------------------------------

select function_privs_are(
  'public', 'gen_pairing_code', array[]::text[], 'public', array[]::text[],
  'public holds no execute on gen_pairing_code'
);
select function_privs_are(
  'public', 'gen_pairing_code', array[]::text[], 'anon', array[]::text[],
  'anon holds no execute on gen_pairing_code'
);
select function_privs_are(
  'public', 'gen_pairing_code', array[]::text[], 'authenticated', array[]::text[],
  'authenticated holds no execute on gen_pairing_code'
);

-- ---------------------------------------------------------------------------
-- Diagnostics submission (20261103000000_diagnostics.sql). Three more RPC-only
-- tables, on the same deny-by-default footing as the original five: RLS on,
-- zero policies, zero table grants. They hold a user's exported log — provider
-- address, source and profile names, what they watched — so they get the
-- stricter of the two patterns in this schema, not the client-facing one.
-- ---------------------------------------------------------------------------

select table_privs_are(
  'public', 'diagnostics', 'anon', array[]::text[],
  'anon holds no privileges on diagnostics'
);
select table_privs_are(
  'public', 'diagnostics', 'authenticated', array[]::text[],
  'authenticated holds no privileges on diagnostics'
);

select ok(
  not exists (
    select 1
      from unnest(array['diagnostics', 'support_readers', 'diag_rate']) as t(name)
      cross join unnest(array['anon', 'authenticated']) as r(name)
      cross join unnest(array[
        'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'
      ]) as priv(name)
     where has_table_privilege(r.name, format('public.%I', t.name), priv.name)
  ),
  'anon/authenticated hold zero privileges on all three diagnostics tables'
);

select ok(
  not exists (
    select 1
      from pg_policies p
     where p.schemaname = 'public'
       and p.tablename in ('diagnostics', 'support_readers', 'diag_rate')
  ),
  'the three diagnostics tables carry no RLS policy at all'
);

-- THE deliberate departure, pinned in both directions. `submit_diagnostics` is
-- the only write RPC in this schema the `anon` role may call — an install with
-- no session, holding nothing but the publishable key (the alternative was
-- minting a permanent auth.users row per submission; see the migration header).
-- Asserting the grant *exists* keeps a future sweep from silently breaking
-- every unpaired install's support button; asserting it on nothing else is
-- what stops the exception spreading.
select function_privs_are(
  'public', 'submit_diagnostics',
  array['text', 'text', 'text', 'text', 'boolean', 'text'],
  'anon', array['EXECUTE'],
  'anon holds EXECUTE on submit_diagnostics (the one deliberate anon write path)'
);
select function_privs_are(
  'public', 'submit_diagnostics',
  array['text', 'text', 'text', 'text', 'boolean', 'text'],
  'authenticated', array['EXECUTE'],
  'authenticated holds EXECUTE on submit_diagnostics (a paired device has a session)'
);

-- The read side stays developer-only: `authenticated` may call it (the identity
-- check is inside), `anon` may not reach it at all.
select function_privs_are(
  'public', 'support_get_diagnostics', array['text'], 'anon', array[]::text[],
  'anon holds no execute on support_get_diagnostics'
);

-- The code generator is internal, exactly like gen_pairing_code.
select function_privs_are(
  'public', 'gen_diagnostics_code', array[]::text[], 'anon', array[]::text[],
  'anon holds no execute on gen_diagnostics_code'
);

select * from finish();

rollback;
