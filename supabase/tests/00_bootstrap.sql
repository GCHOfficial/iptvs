-- iptvs cloud sync — pgTAP test bootstrap.
--
-- Recreates the minimal slice of Supabase's platform (auth surface + roles)
-- that supabase/migrations/*.sql actually touches, against a bare
-- `supabase/postgres:17.x` service container (no GoTrue, no full Supabase
-- stack, no `supabase/config.toml` — this repo doesn't have one). Everything
-- here is grep-justified against the migrations; nothing extra is added:
--
--   * `auth.users(id, is_anonymous)` — the FK target for every `owner`/
--     `claimed_by` column (cloud_sync_init.sql, profiles.sql,
--     secrets_store.sql, e2ee.sql), and `is_anonymous` is read directly by
--     account_deletion.sql / harden_cloud.sql's
--     `delete from auth.users ... where is_anonymous is true`.
--   * `auth.uid()` — read by nearly every RPC and RLS policy as the calling
--     session's identity.
--   * `auth.jwt()` — read once, by `is_real_user()`, for the `is_anonymous`
--     claim.
--   * Roles `anon` / `authenticated` / `service_role` — Supabase's three
--     PostgREST-facing roles. Every GRANT/REVOKE in the migrations targets
--     exactly these three (never bare `public` for anything sensitive), and
--     harden_cloud.sql / tenant_isolation.sql's REVOKEs are meaningless to
--     test unless the starting privilege set matches Supabase's real
--     default: `alter default privileges ... grant all on tables` to all
--     three, which is what a fresh Supabase project's dashboard-managed
--     bootstrap does before any app migration ever runs.
--   * `extensions` schema + `pgcrypto` — `gen_pairing_code()` calls
--     `extensions.gen_random_bytes(1)`, and cloud_sync_init.sql's own
--     `create extension if not exists pgcrypto` (no explicit schema) must
--     land on an already-installed extension as a no-op, matching a real
--     Supabase project where pgcrypto already lives in `extensions`.
--
-- Load order (see .github/workflows/db-tests.yml): this file, then every
-- supabase/migrations/*.sql in filename order, then pg_prove over
-- supabase/tests/*.test.sql. This file also installs pgTAP itself, since the
-- image ships the extension but nothing creates it automatically.

create extension if not exists pgtap;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Roles. NOLOGIN: nothing ever connects *as* anon/authenticated/service_role
-- (matching real Supabase, where PostgREST connects as a separate
-- `authenticator` role and switches with `SET LOCAL ROLE` per request). Tests
-- impersonate the same way — see test.jwt()/test.login_device() below and
-- `set local role ...;` in the test files themselves.
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    -- Real Supabase's service_role bypasses RLS outright; never shipped to a
    -- client, but recreated here so any migration that references it (none
    -- currently do directly) resolves.
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema extensions to anon, authenticated, service_role;

-- Matches a fresh Supabase project: every table/sequence/function created
-- from here on by this bootstrapping role (`postgres`, the same role that
-- applies the migrations in CI) is auto-granted to all three PostgREST
-- roles. Individual migrations then REVOKE down from this permissive
-- baseline — which is exactly the behavior under test (F5/F6, the pairing
-- RPCs, the push RPCs' `revoke ... from anon`).
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- auth schema: the minimal users table + auth.uid()/auth.jwt(), matching real
-- Supabase's signatures closely enough for every migration reference
-- (grepped above) to resolve and behave identically under RLS / SECURITY
-- DEFINER checks. Both read the PostgREST convention GUC
-- `request.jwt.claims`, which test.jwt() below sets with `SET LOCAL`
-- semantics (via set_config(..., true)) so it never escapes the enclosing
-- transaction — the mechanism that makes per-file `begin; ... rollback;`
-- wrapping enough to keep every test file independent.
-- ---------------------------------------------------------------------------

-- The supabase/postgres image ALREADY ships an `auth` schema, owned by GoTrue's
-- `supabase_auth_admin` role. That makes `create schema if not exists auth` a
-- silent no-op while every CREATE inside it fails with "permission denied for
-- schema auth" — which is exactly how this bootstrap failed on its first CI run.
-- Take ownership (this is a throwaway CI database) by briefly assuming the
-- owning role, which `postgres` is a member of in that image. If that ever stops
-- being true the script fails loudly here with both role names, rather than
-- 60 lines later with an opaque permission error.
do $$
declare
  schema_owner text;
  me           text := current_user;
begin
  select pg_get_userbyid(nspowner) into schema_owner
    from pg_namespace where nspname = 'auth';

  if schema_owner is null then
    execute 'create schema auth';
    raise notice 'bootstrap: created auth schema owned by %', me;
    return;
  end if;

  if schema_owner = me then
    raise notice 'bootstrap: auth schema already owned by %', me;
    return;
  end if;

  begin
    execute format('set local role %I', schema_owner);
    execute format('alter schema auth owner to %I', me);
    raise notice 'bootstrap: took ownership of auth from % (as %)', schema_owner, me;
  exception when insufficient_privilege then
    raise exception
      'bootstrap: auth schema is owned by % and % cannot assume that role; '
      'the base image changed its role layout', schema_owner, me;
  end;
end $$;

create table if not exists auth.users (
  id           uuid primary key default gen_random_uuid(),
  is_anonymous boolean not null default false
);

-- The image ALSO ships GoTrue's real `auth.users`, from a schema version
-- predating anonymous sign-ins — so the `create table if not exists` above is a
-- no-op and `is_anonymous` is simply absent. That column is not optional here:
-- `is_real_user()` reads it via the JWT, and account_deletion.sql deletes
-- `where is_anonymous is true`, so the whole device-vs-account distinction under
-- test depends on it. Add it if the table came from the image.
alter table auth.users add column if not exists is_anonymous boolean not null default false;

grant usage on schema auth to anon, authenticated, service_role;
grant select on auth.users to anon, authenticated, service_role;

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(
    (nullif(current_setting('request.jwt.claims', true), ''))::jsonb ->> 'sub',
    ''
  )::uuid
$$;

create or replace function auth.jwt()
returns jsonb
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb,
    '{}'::jsonb
  )
$$;

-- ---------------------------------------------------------------------------
-- Test-only impersonation helpers. Plain SQL, no GoTrue: a "real account"
-- session is `set local role authenticated;` + a JWT with is_anonymous=false;
-- a "device" session is the same role with is_anonymous=true (devices are
-- anonymous Supabase auth users by design — CLAUDE.md "Cloud sync +
-- profiles"). `anon` (no session at all) never gets a JWT and never calls
-- these helpers.
--
-- Deliberately NOT role-switching here: `SET ROLE`'s membership check means a
-- non-superuser session can `SET ROLE authenticated` but can never get back
-- to `postgres` that way, so role-switching stays an explicit, literal
-- `set local role authenticated;` / `reset role;` in the test files
-- themselves (the pattern documented in the task's DESIGN section) — these
-- helpers only ever seed auth.users and set the `request.jwt.claims` GUC.
-- Both are `SET LOCAL`-equivalent (see set_config's third argument), so
-- letting the test file's closing `rollback;` unwind them is sufficient
-- cleanup; no explicit "logout" call is required between identities.
-- ---------------------------------------------------------------------------

create schema if not exists test;

create or replace function test.jwt(p_sub uuid, p_is_anonymous boolean default false)
returns void
language plpgsql
as $$
begin
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', p_sub,
      'role', 'authenticated',
      'is_anonymous', p_is_anonymous
    )::text,
    true);
end;
$$;

-- Convenience: create the auth.users row (idempotent) and set the JWT in one
-- call. Returns the uuid so a test can `select test.login_user() as owner_a
-- \gset`. SECURITY DEFINER (unlike test.jwt() above): the calling test file
-- has already switched to `authenticated`/`anon` by this point, and only
-- `postgres` (this function's owner) holds INSERT on auth.users — matching
-- how a real Supabase project's auth schema is populated by a privileged
-- path the API roles never touch directly.
create or replace function test.login_user(p_id uuid default gen_random_uuid())
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into auth.users (id, is_anonymous) values (p_id, false)
    on conflict (id) do nothing;
  perform test.jwt(p_id, false);
  return p_id;
end;
$$;

create or replace function test.login_device(p_id uuid default gen_random_uuid())
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into auth.users (id, is_anonymous) values (p_id, true)
    on conflict (id) do nothing;
  perform test.jwt(p_id, true);
  return p_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- The helpers are called from inside `set local role authenticated` / `anon`
-- blocks, so those roles need USAGE on the schema and EXECUTE on the functions
-- — without this every test file dies on "permission denied for schema test"
-- at its first login call. The two login_* helpers are SECURITY DEFINER (only
-- the bootstrapping superuser may INSERT into auth.users), so granting EXECUTE
-- is what makes them usable, not a privilege escalation for the test roles:
-- they can only mint an auth.users row and a JWT claim inside this throwaway
-- CI database.
-- ---------------------------------------------------------------------------

grant usage on schema test to anon, authenticated, service_role;
grant execute on all functions in schema test to anon, authenticated, service_role;
