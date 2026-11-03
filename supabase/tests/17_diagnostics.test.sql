-- "Send diagnostics": the anon-callable submit path and the developer-only
-- read path (20261103000000_diagnostics.sql).
--
-- This file carries more weight than most of the suite, because
-- `submit_diagnostics` is the **first write RPC in this schema that the `anon`
-- role may call** — an install with no session at all, holding nothing but the
-- public anon key. Everything that normally bounds a device write (a paired
-- session, an owner resolved through `current_device_owner()`, a per-subject
-- meter) is absent by design, so the bounds that replace it are the only thing
-- standing between a public key and unbounded storage on a free-tier project:
--
--   * a 256 KiB body cap,
--   * a GLOBAL 120/hour meter (there is no subject to meter per-subject),
--   * an absolute 2000-row / 64 MiB ceiling with a 72 h eviction floor,
--   * 30-day expiry, swept lazily and filtered on read,
--   * insert-only: no caller, including the table owner, may modify or delete a
--     live row.
--
-- And the read side: `support_readers` is empty by default, so "nobody can
-- read" is the default state, and the developer RPCs must refuse everyone else
-- — including a legitimately paired device, which is the caller most likely to
-- be confused for an authorised one.
--
-- The heavy fixtures (2000-row ceiling scenarios) are isolated with savepoints.
-- pgTAP's result counter is a sequence, and `nextval` is non-transactional, so
-- rolling back to a savepoint after an assertion does not rewind the plan.

begin;

select plan(39);

-- A helper for the two assertions that are about what an error message does
-- NOT say. `throws_like` can prove a message contains the limit; proving it
-- does not contain the body needs the text itself.
create or replace function pg_temp.submit_error(
  p_body text, p_app_version text, p_platform text,
  p_channel text, p_is_tv boolean, p_install_hint text)
returns text
language plpgsql
as $$
begin
  perform public.submit_diagnostics(
    p_body, p_app_version, p_platform, p_channel, p_is_tv, p_install_hint);
  return '(no error)';
exception when others then
  return sqlerrm;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. An install with NO session at all.
--
-- `set local role anon` plus an explicitly cleared `request.jwt.claims` is the
-- harness's faithful model of a request carrying only the publishable key: no
-- JWT, so `auth.uid()` is null and `auth.jwt()` is `{}`. Clearing the GUC is
-- required rather than tidy — see the same note in
-- 10_unpaired_and_revocation.test.sql.
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', '', true);
select count(*)::int as users_before from auth.users \gset

set local role anon;

select public.submit_diagnostics(
  'iptvs diagnostics exported 2026-11-03T10:00:00.000', '0.1.73',
  'android', 'githubDirect', true, 'abc123') as sub_code \gset

-- 1
select matches(
  -- psql substitutes :'sub_code' as an untyped literal, and matches() is
  -- polymorphic, so without the cast Postgres can't resolve the call.
  :'sub_code'::text,
  '^D-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$',
  'a session-less anon caller can submit, and gets a D- prefixed code from the unambiguous alphabet'
);

reset role;

-- 2. The whole point of granting `anon` rather than requiring a session: no
-- auth.users row is minted. An anonymous sign-in would be a permanent row
-- counting toward the project's MAU forever (docs/cloud-sync.md).
select is(
  (select count(*)::int from auth.users), :users_before,
  'submitting creates no auth.users row (no anonymous sign-in)'
);

-- 3. Server `now()`, 30 days out, client-supplied nothing.
select ok(
  (select d.expires_at > now() + interval '29 days'
      and d.expires_at < now() + interval '31 days'
     from public.diagnostics d where d.code = :'sub_code'),
  'the submitted row expires 30 days out, stamped by the server'
);

-- 4. `body_bytes` is recomputed server-side; it is the input to the storage
-- ceiling, so a client that under-reported it would be handing itself an
-- unbounded quota.
select is(
  (select d.body_bytes from public.diagnostics d where d.code = :'sub_code'),
  octet_length('iptvs diagnostics exported 2026-11-03T10:00:00.000'),
  'body_bytes is computed from the body, never taken from the caller'
);

-- ---------------------------------------------------------------------------
-- The table itself is unreachable from every client role, in both directions.
-- RLS with zero policies is the first layer; the table-level REVOKE is the one
-- these assertions actually hit.
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', '', true);
set local role anon;

-- 5
select throws_like(
  $$ select count(*) from public.diagnostics $$,
  '%permission denied%',
  'anon cannot SELECT diagnostics directly'
);
-- 6
select throws_like(
  $$ insert into public.diagnostics (code, body) values ('D-XXXXXX', 'x') $$,
  '%permission denied%',
  'anon cannot INSERT into diagnostics directly'
);
-- 7
select throws_like(
  $$ update public.diagnostics set body = 'x' $$,
  '%permission denied%',
  'anon cannot UPDATE diagnostics directly'
);
-- 8
select throws_like(
  $$ delete from public.diagnostics $$,
  '%permission denied%',
  'anon cannot DELETE from diagnostics directly'
);
-- 9
select throws_like(
  $$ select count(*) from public.support_readers $$,
  '%permission denied%',
  'anon cannot read support_readers (who may read is not public knowledge)'
);
-- 10 — the developer read RPCs are not granted to anon at all.
select throws_like(
  $$ select public.support_list_diagnostics(10) $$,
  '%permission denied%',
  'anon holds no EXECUTE on support_list_diagnostics'
);

-- ---------------------------------------------------------------------------
-- Size and metadata bounds. The message carries the LIMIT; it must never carry
-- the value, because here the value is a user's log.
--
-- Run as the session role rather than as `anon`, deliberately: `pg_temp`
-- belongs to the session that created it and a switched role has no USAGE on
-- it, so calling the helper below as `anon` would fail on a harness detail
-- rather than on anything under test. `submit_diagnostics` is SECURITY
-- DEFINER, so its validation path is identical whoever calls it — and that it
-- is callable by `anon` at all is already proved by test 1.
-- ---------------------------------------------------------------------------

reset role;

-- 11
select matches(
  pg_temp.submit_error(repeat('SECRETMARKER', 25000), '', '', '', false, ''),
  'max 262144 bytes',
  'an oversized body is refused, and the message names the limit'
);
-- 12
select unlike(
  pg_temp.submit_error(repeat('SECRETMARKER', 25000), '', '', '', false, ''),
  '%SECRETMARKER%',
  'the oversize rejection echoes none of the body back'
);
-- 13
select throws_like(
  format('select public.submit_diagnostics(%L, %L, %L, %L, %L, %L)',
         'x', repeat('v', 65), '', '', false, ''),
  '%max 64 characters%',
  'an over-long metadata field is refused, and the message names the limit'
);
-- 14 — these four strings are rendered in the developer's panel; an ANSI escape
-- or a bidi override in one would make a line read as something it is not.
select throws_like(
  format('select public.submit_diagnostics(%L, %L, %L, %L, %L, %L)',
         'x', '0.1' || chr(7), '', '', false, ''),
  '%control characters%',
  'a control character in a metadata field is refused'
);

-- ---------------------------------------------------------------------------
-- Insert-only, enforced by the BEFORE UPDATE OR DELETE trigger — which binds
-- the TABLE OWNER too, i.e. the dashboard. That is the real proof: RLS and
-- grants stop the clients, but only the trigger stops a privileged hand.
-- ---------------------------------------------------------------------------

insert into public.diagnostics (code, body) values ('D-IMMUT1', 'keep me');

-- 15
select throws_like(
  $$ update public.diagnostics set body = 'tampered' where code = 'D-IMMUT1' $$,
  '%cannot be modified%',
  'not even the table owner may modify a submitted row'
);
-- 16
select throws_like(
  $$ delete from public.diagnostics where code = 'D-IMMUT1' $$,
  '%cannot be deleted%',
  'not even the table owner may delete a live row'
);

-- The guard re-checks the ROW'S OWN eligibility rather than trusting the
-- transaction-local mode flag. This is what makes a bug in the sweep's WHERE
-- clause survivable: setting the flag by hand still cannot take a fresh row.
select set_config('iptvs.diagnostics_sweep', 'evict', true);
-- 17
select throws_like(
  $$ delete from public.diagnostics where code = 'D-IMMUT1' $$,
  '%cannot be deleted%',
  'the evict flag cannot delete a row inside the 72 h floor'
);
select set_config('iptvs.diagnostics_sweep', 'expire', true);
-- 18
select throws_like(
  $$ delete from public.diagnostics where code = 'D-IMMUT1' $$,
  '%cannot be deleted%',
  'the expire flag cannot delete a row that has not expired'
);
-- 19 — UPDATE is refused unconditionally, flag or no flag.
select throws_like(
  $$ update public.diagnostics set expires_at = now() where code = 'D-IMMUT1' $$,
  '%cannot be modified%',
  'no sweep mode permits an UPDATE'
);
select set_config('iptvs.diagnostics_sweep', '', true);

-- ---------------------------------------------------------------------------
-- The developer read path. `support_readers` empty = nobody reads anything.
-- ---------------------------------------------------------------------------

set local role authenticated;

-- A real, signed-in account that is simply not the developer.
select test.login_user() as stranger \gset

-- 20
select throws_like(
  $$ select public.support_list_diagnostics(10) $$,
  'iptvs: not authorised',
  'a real account that is not a support reader cannot list diagnostics'
);
-- 21
select throws_like(
  $$ select public.support_get_diagnostics('D-IMMUT1') $$,
  'iptvs: not authorised',
  'a real account that is not a support reader cannot read a body'
);

-- A legitimately PAIRED device — the caller most easily mistaken for an
-- authorised one, since it may already read all of its owner's cloud data.
select test.login_user() as owner_a \gset
select test.login_device() as device_a \gset
select code from public.request_pairing() \gset pairing_
select test.jwt(:'owner_a'::uuid, false);
select public.claim_pairing(:'pairing_code');
select test.jwt(:'device_a'::uuid, true);

-- 22
select throws_like(
  $$ select public.support_list_diagnostics(10) $$,
  'iptvs: not authorised',
  'a paired device reads nothing from the diagnostics inbox'
);
-- 23
select throws_like(
  $$ select public.support_get_diagnostics('D-IMMUT1') $$,
  'iptvs: not authorised',
  'a paired device cannot read a diagnostics body'
);

-- Now seed the stranger as the developer.
reset role;
insert into public.support_readers (uid) values (:'stranger'::uuid);

set local role authenticated;
select test.jwt(:'stranger'::uuid, false);

-- 24
select is(
  (select count(*)::int from public.support_list_diagnostics(100)
    where code = :'sub_code'),
  1,
  'a seeded support reader sees the submitted row in the inbox'
);
-- 25
select is(
  public.support_get_diagnostics(:'sub_code'),
  'iptvs diagnostics exported 2026-11-03T10:00:00.000',
  'a support reader reads the body back verbatim'
);
-- 26 — the code is normalised on the way in, so reading one off a phone call
-- in lower case still finds it.
select is(
  public.support_get_diagnostics(lower(:'sub_code')),
  'iptvs diagnostics exported 2026-11-03T10:00:00.000',
  'the lookup upper-cases and trims the code it is given'
);

-- Access is a row, so removing the row removes access. Nothing is cached, and
-- there is no self-service way back in.
reset role;
delete from public.support_readers where uid = :'stranger'::uuid;
set local role authenticated;
select test.jwt(:'stranger'::uuid, false);

-- 27
select throws_like(
  $$ select public.support_list_diagnostics(10) $$,
  'iptvs: not authorised',
  'deleting the support_readers row revokes read access immediately'
);

-- ---------------------------------------------------------------------------
-- Expiry: filtered on read the instant it falls due, and swept lazily by the
-- next writer (there is no cron on this project).
-- ---------------------------------------------------------------------------

reset role;
insert into public.support_readers (uid) values (:'stranger'::uuid);
insert into public.diagnostics (code, body, expires_at)
  values ('D-EXPIRD', 'stale body', now() - interval '1 minute');

set local role authenticated;
select test.jwt(:'stranger'::uuid, false);

-- 28
select is(
  (select count(*)::int from public.support_list_diagnostics(500)
    where code = 'D-EXPIRD'),
  0,
  'an expired row is invisible to the reader before any sweep has run'
);
-- 29
select is(
  public.support_get_diagnostics('D-EXPIRD'),
  null::text,
  'an expired body is not served, even though the row is still on disk'
);

reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;
select public.submit_diagnostics('sweeper', '', '', '', false, '');
reset role;

-- 30
select is(
  (select count(*)::int from public.diagnostics where code = 'D-EXPIRD'),
  0,
  'a submit runs the bounded expiry sweep and removes the expired row'
);

-- ---------------------------------------------------------------------------
-- The GLOBAL hourly meter. Primed directly rather than by 120 real calls:
-- `diag_rate` carries no trigger, and the behaviour under test is the sliding
-- window, not the counting.
-- ---------------------------------------------------------------------------

savepoint rate_limit;

insert into public.diag_rate (bucket, window_start, count)
  values ('submit', now(), 120)
  on conflict (bucket) do update set window_start = now(), count = 120;

select set_config('request.jwt.claims', '', true);
set local role anon;
-- 31
select throws_like(
  $$ select public.submit_diagnostics('over the line', '', '', '', false, '') $$,
  '%too many diagnostics submissions%',
  'the 121st submission inside the window is refused'
);

reset role;
update public.diag_rate set window_start = now() - interval '2 hours'
  where bucket = 'submit';
select set_config('request.jwt.claims', '', true);
set local role anon;
-- 32
select lives_ok(
  $$ select public.submit_diagnostics('new window', '', '', '', false, '') $$,
  'the window rolls and submissions are allowed again'
);

rollback to savepoint rate_limit;

-- ---------------------------------------------------------------------------
-- The absolute ceiling, and the 72 h eviction floor that stops a burst of
-- submissions evicting the reports that burst is about.
-- ---------------------------------------------------------------------------

savepoint ceiling_fresh;

reset role;
-- Filled to exactly the ceiling, counting what earlier tests already left in
-- the table. Hard-coding 2000 here would overshoot it and make the fixture
-- quietly stop testing the boundary it is named after.
--
-- The seeded codes contain `0`/`1`, which are NOT in the generator's alphabet
-- (`ABCDEFGHJKMNPQRSTUVWXYZ23456789` deliberately omits the ambiguous pair), so
-- they can never collide with a code the RPC mints.
select 2000 - (select count(*) from public.diagnostics) as fill \gset
insert into public.diagnostics (code, body, created_at, expires_at)
  select 'D-' || to_char(i, 'FM000000'), 'x', now(), now() + interval '30 days'
    from generate_series(1, :fill) i;

select set_config('request.jwt.claims', '', true);
set local role anon;
-- 33
select throws_like(
  $$ select public.submit_diagnostics('no room', '', '', '', false, '') $$,
  '%temporarily unavailable%',
  'at the row ceiling with nothing past the 72 h floor, a submission is refused'
);

rollback to savepoint ceiling_fresh;

savepoint ceiling_evictable;

reset role;
-- Old enough to evict, but NOT expired — so the sweep leaves it and only the
-- ceiling logic can take it. That separation is the point of the fixture, and
-- it is the only evictable row: everything else in the table, seeded or left
-- by an earlier test, was created inside the 72 h floor.
insert into public.diagnostics (code, body, created_at, expires_at)
  values ('D-OLDONE', 'x', now() - interval '100 hours', now() + interval '30 days');
select 2000 - (select count(*) from public.diagnostics) as fill \gset
insert into public.diagnostics (code, body, created_at, expires_at)
  select 'D-' || to_char(i, 'FM000000'), 'x', now(), now() + interval '30 days'
    from generate_series(1, :fill) i;

select set_config('request.jwt.claims', '', true);
set local role anon;
-- 34
select lives_ok(
  $$ select public.submit_diagnostics('evicts one', '', '', '', false, '') $$,
  'at the ceiling with one row past the 72 h floor, the submission succeeds'
);

reset role;
-- 35
select is(
  (select count(*)::int from public.diagnostics where code = 'D-OLDONE'),
  0,
  'the evicted row is the one past the 72 h floor'
);
-- 36
select is(
  (select count(*)::int from public.diagnostics), 2000,
  'the table is held at the ceiling, not pushed past it'
);

rollback to savepoint ceiling_evictable;

-- ---------------------------------------------------------------------------
-- Being allowed to READ submitted diagnostics confers no write of any kind.
--
-- The developer is the one caller with a legitimate reason to touch this table,
-- so they are the one caller whose write path is worth proving shut. Two
-- independent layers stop them and this exercises the outer one: `authenticated`
-- holds zero table privileges, so the request never even reaches the
-- insert-only trigger. (The trigger itself is proved by tests 15-19, which run
-- as the TABLE OWNER — the only identity that gets past the grants at all.)
-- ---------------------------------------------------------------------------

set local role authenticated;
select test.jwt(:'stranger'::uuid, false);

-- 37
select throws_like(
  $$ update public.diagnostics set body = 'tampered' $$,
  '%permission denied%',
  'a support reader cannot UPDATE diagnostics'
);
-- 38
select throws_like(
  $$ delete from public.diagnostics $$,
  '%permission denied%',
  'a support reader cannot DELETE diagnostics'
);

-- ---------------------------------------------------------------------------
-- Guard coverage, in the spirit of 12_rpc_guard_coverage: the properties that
-- make the above true are structural, and a future edit that quietly drops one
-- would leave every behavioural assertion above still passing.
--
--   * SECURITY DEFINER on `submit_diagnostics` is what lets a role with zero
--     table privileges insert at all; without it the RPC fails for everyone.
--   * SECURITY DEFINER on `is_support_reader` is what lets it read a table with
--     zero policies and zero grants; without it the read RPCs refuse the
--     developer too.
--   * `search_path = ''` is checked globally by 01_baseline_invariants; named
--     here so a failure says WHICH of these five regressed.
-- ---------------------------------------------------------------------------

reset role;

-- 39
--
-- Asserted as the list of *compliant* functions rather than as an empty list of
-- offenders: an "offenders is empty" query also passes when a function has
-- vanished from the schema entirely, which is the one regression most worth
-- catching here (a dropped `is_support_reader` would make the read RPCs refuse
-- the developer too).
select is(
  (select coalesce(array_agg(p.proname::text order by p.proname), '{}'::text[])
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'submit_diagnostics', 'check_diagnostics_rate', 'is_support_reader',
        'support_list_diagnostics', 'support_get_diagnostics')
      and p.prosecdef
      and exists (
        select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) as cfg(setting)
         where cfg.setting in ('search_path=', 'search_path=""'))),
  array[
    'check_diagnostics_rate', 'is_support_reader', 'submit_diagnostics',
    'support_get_diagnostics', 'support_list_diagnostics'
  ]::text[],
  'every diagnostics RPC is SECURITY DEFINER with search_path pinned to empty'
);

select * from finish();

rollback;
