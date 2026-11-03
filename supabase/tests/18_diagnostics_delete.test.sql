-- The developer delete: `support_delete_diagnostics`
-- (20261104000000_diagnostics_delete.sql).
--
-- `public.diagnostics` is insert-only, enforced by a BEFORE UPDATE OR DELETE
-- trigger that binds every role including the table owner. This RPC is the one
-- hole in it, and the point of this file is that it is a hole exactly one
-- caller fits through.
--
-- Two independent things have to hold, and neither one alone is enough:
--
--   * **No client role holds any table privilege**, so the only DELETE
--     statements that can reach the trigger at all are the ones inside a
--     SECURITY DEFINER function owned by the table owner. That is what makes
--     the transaction-local `iptvs.diagnostics_sweep` flag safe to extend: a
--     client may set it to anything it likes and still has nothing to delete
--     with.
--   * **The 'support' branch re-checks the caller's identity** with
--     `is_support_reader()`. SECURITY DEFINER switches the effective role, not
--     `request.jwt.claims`, so that question is answered about the *caller*
--     even inside the RPC — and a privileged hand at the dashboard, which has
--     no JWT at all, is refused by it. "The guard binds the table owner too"
--     survives the new mode, and that is asserted below rather than assumed.
--
-- The machine deletes the previous migration already owned — lazy expiry and
-- ceiling eviction — are re-checked at the end, because this file replaces the
-- function that implements all three.
--
-- The heavy ceiling fixture is isolated with a savepoint. pgTAP's result
-- counter is a sequence and `nextval` is non-transactional, so rolling back to
-- a savepoint after an assertion does not rewind the plan.

begin;

select plan(22);

-- ---------------------------------------------------------------------------
-- Identities: the developer, a real account that is not, and a legitimately
-- paired device (the caller most easily mistaken for an authorised one).
-- ---------------------------------------------------------------------------

set local role authenticated;

select test.login_user() as reader \gset
select test.login_user() as stranger \gset

select test.login_user() as owner_a \gset
select test.login_device() as device_a \gset
select code from public.request_pairing() \gset pairing_
select test.jwt(:'owner_a'::uuid, false);
select public.claim_pairing(:'pairing_code');

reset role;

insert into public.support_readers (uid) values (:'reader'::uuid);

-- Three live reports. The seeded codes contain `0`/`1`, which the generator's
-- alphabet deliberately omits, so they can never collide with a minted code.
insert into public.diagnostics (code, body) values ('D-DELET1', 'delete me');
insert into public.diagnostics (code, body) values ('D-NORM01', 'normalise me');
insert into public.diagnostics (code, body) values ('D-GUARD1', 'keep me');

-- ---------------------------------------------------------------------------
-- Who may NOT call it.
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', '', true);
set local role anon;

-- 1 — an install with no session at all: refused by the grant system, before
-- the function body can run.
select throws_like(
  $$ select public.support_delete_diagnostics('D-DELET1') $$,
  '%permission denied%',
  'anon holds no EXECUTE on support_delete_diagnostics'
);

reset role;
set local role authenticated;

-- 2 — a paired device has a session and may already read all of its owner's
-- cloud data; it reads and deletes nothing here.
select test.jwt(:'device_a'::uuid, true);
select throws_like(
  $$ select public.support_delete_diagnostics('D-DELET1') $$,
  'iptvs: not authorised',
  'a paired device cannot delete a submitted report'
);

-- 3 — a real, signed-in account that simply is not seeded in support_readers.
select test.jwt(:'stranger'::uuid, false);
select throws_like(
  $$ select public.support_delete_diagnostics('D-DELET1') $$,
  'iptvs: not authorised',
  'a real account that is not a support reader cannot delete a report'
);

reset role;

-- 4
select is(
  (select count(*)::int from public.diagnostics where code = 'D-DELET1'),
  1,
  'the refused deletes left the row exactly where it was'
);

-- ---------------------------------------------------------------------------
-- Who may.
-- ---------------------------------------------------------------------------

set local role authenticated;
select test.jwt(:'reader'::uuid, false);

-- 5
select is(
  public.support_delete_diagnostics('D-DELET1'),
  true,
  'a seeded support reader deletes a live report and is told a row went'
);

-- 6 — the read path agrees immediately; nothing is cached anywhere.
select is(
  public.support_get_diagnostics('D-DELET1'),
  null::text,
  'the deleted report is no longer readable'
);

reset role;

-- 7 — and it is really gone, not merely filtered out of the read.
select is(
  (select count(*)::int from public.diagnostics where code = 'D-DELET1'),
  0,
  'the row itself is gone, not merely hidden'
);

set local role authenticated;
select test.jwt(:'reader'::uuid, false);

-- 8 — an unknown code is the ordinary outcome of two tabs open on one inbox,
-- not an error.
select is(
  public.support_delete_diagnostics('D-DELET1'),
  false,
  'a second delete of the same code reports that nothing was deleted'
);

-- 9 — normalised exactly as `support_get_diagnostics` normalises it, so a code
-- read off a phone call finds the same row through both.
select is(
  public.support_delete_diagnostics('  d-norm01  '),
  true,
  'the code is upper-cased and trimmed before the lookup'
);

-- 10 — the flag does not outlive the statement it was set for. It is
-- transaction-local, and PostgREST runs a whole request in one transaction, so
-- a leaked `'support'` would arm every later DELETE in that request — including
-- the submit RPC's sweep, which re-sets the flag per statement precisely
-- because nobody should have to reason about what the last one left behind.
select is(
  current_setting('iptvs.diagnostics_sweep', true),
  ''::text,
  'the RPC clears the sweep flag behind itself'
);

-- ---------------------------------------------------------------------------
-- The hole is the RPC, and only the RPC.
-- ---------------------------------------------------------------------------

-- 11 — being allowed to delete THROUGH the RPC confers no table privilege.
select throws_like(
  $$ delete from public.diagnostics $$,
  '%permission denied%',
  'a support reader still holds no DELETE on the table itself'
);

-- 12 — the flag is a GUC and `set_config` is callable by anyone, so a client
-- can certainly set it. It buys nothing: the DELETE is refused by the grant
-- system before any trigger runs.
select set_config('iptvs.diagnostics_sweep', 'support', true);
select throws_like(
  $$ delete from public.diagnostics where code = 'D-GUARD1' $$,
  '%permission denied%',
  'a client setting the sweep flag by hand still has no table privilege to use it'
);
select set_config('iptvs.diagnostics_sweep', '', true);

reset role;

-- 13 — the table owner, with the flag set by hand and no JWT: the identity
-- re-check inside the trigger refuses it. This is what keeps "the insert-only
-- guard binds the dashboard too" true after the new mode. Clearing
-- `request.jwt.claims` is the faithful model of a dashboard SQL session, and
-- is load-bearing: the branch asks who the CALLER is, and an owner session
-- carrying a support reader's JWT would (correctly) be one.
select set_config('request.jwt.claims', '', true);
select set_config('iptvs.diagnostics_sweep', 'support', true);
select throws_like(
  $$ delete from public.diagnostics where code = 'D-GUARD1' $$,
  '%cannot be deleted%',
  'support mode still binds the table owner: no support-reader identity, no delete'
);
select set_config('iptvs.diagnostics_sweep', '', true);

-- 14
select is(
  (select count(*)::int from public.diagnostics where code = 'D-GUARD1'),
  1,
  'the row every refused delete aimed at is still there'
);

-- ---------------------------------------------------------------------------
-- The machine deletes still work. This migration replaces the function that
-- implements all three modes, so the two it did not add are re-proved here.
-- ---------------------------------------------------------------------------

insert into public.diagnostics (code, body, expires_at)
  values ('D-EXPIR1', 'stale body', now() - interval '1 minute');

select set_config('request.jwt.claims', '', true);
set local role anon;

-- 15
select lives_ok(
  $$ select public.submit_diagnostics('sweeper', '', '', '', false, '') $$,
  'a submission still succeeds with the third sweep mode in place'
);

reset role;

-- 16
select is(
  (select count(*)::int from public.diagnostics where code = 'D-EXPIR1'),
  0,
  'the bounded lazy expiry sweep still removes an expired row'
);

savepoint ceiling_evictable;

-- Old enough to evict but NOT expired, so only the ceiling logic can take it —
-- the same separation 17_diagnostics.test.sql's fixture relies on. Filled to
-- exactly the ceiling, counting what this file has already left in the table.
insert into public.diagnostics (code, body, created_at, expires_at)
  values ('D-OLDONE', 'x', now() - interval '100 hours', now() + interval '30 days');
select 2000 - (select count(*) from public.diagnostics) as fill \gset
insert into public.diagnostics (code, body, created_at, expires_at)
  select 'D-' || to_char(i, 'FM000000'), 'x', now(), now() + interval '30 days'
    from generate_series(1, :fill) i;

select set_config('request.jwt.claims', '', true);
set local role anon;

-- 17
select lives_ok(
  $$ select public.submit_diagnostics('evicts one', '', '', '', false, '') $$,
  'at the ceiling, a submission still evicts and succeeds'
);

reset role;

-- 18
select is(
  (select count(*)::int from public.diagnostics where code = 'D-OLDONE'),
  0,
  'the eviction mode still takes the row past the 72 h floor'
);

rollback to savepoint ceiling_evictable;

-- ---------------------------------------------------------------------------
-- Guard coverage, in the spirit of 12_rpc_guard_coverage and 17's tail: the
-- properties that make everything above true are structural, and a future edit
-- that quietly dropped one would leave every behavioural assertion passing.
--
-- Asserted as the list of *compliant* functions rather than an empty list of
-- offenders, so a vanished function fails the assertion instead of satisfying
-- it.
-- ---------------------------------------------------------------------------

-- 19
select is(
  (select coalesce(array_agg(p.proname::text order by p.proname), '{}'::text[])
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'support_delete_diagnostics'
      and p.prosecdef
      and exists (
        select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) as cfg(setting)
         where cfg.setting in ('search_path=', 'search_path=""'))),
  array['support_delete_diagnostics']::text[],
  'support_delete_diagnostics is SECURITY DEFINER with search_path pinned to empty'
);

-- 20 / 21 / 22 — granted exactly like the two support read RPCs beside it.
select function_privs_are(
  'public', 'support_delete_diagnostics', array['text'], 'anon', array[]::text[],
  'anon holds no execute on support_delete_diagnostics'
);
select function_privs_are(
  'public', 'support_delete_diagnostics', array['text'], 'authenticated',
  array['EXECUTE'],
  'authenticated holds execute on support_delete_diagnostics (the identity check is inside)'
);
select function_privs_are(
  'public', 'support_delete_diagnostics', array['text'], 'public', array[]::text[],
  'the PUBLIC pseudo-role holds no execute on support_delete_diagnostics'
);

select * from finish();

rollback;
