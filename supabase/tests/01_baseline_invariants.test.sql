-- Baseline security invariants, independent of any specific RPC.
--
-- Read-only against the schema produced by replaying every
-- supabase/migrations/*.sql — no seed data needed, so this file's
-- begin/rollback wrapper is only for consistency with the rest of the suite.

begin;

select plan(16);

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

select ok(
  not exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
       and not exists (
         select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) as cfg(setting)
          where cfg.setting = 'search_path='
       )
  ),
  'every SECURITY DEFINER function in public pins search_path to empty'
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

select * from finish();

rollback;
