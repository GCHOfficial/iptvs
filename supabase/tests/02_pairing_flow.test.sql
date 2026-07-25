-- F3: pairing end-to-end (positive path) plus the three regressions closed by
-- tenant_isolation.sql — no direct anonymous INSERT, a TTL beyond the
-- 15-minute ceiling rejected, and a pre-claimed code rejected.

begin;

select plan(9);

-- ---------------------------------------------------------------------------
-- Positive path: a device requests a code, a real account claims it. Device
-- and account are the SAME Postgres role (`authenticated` — devices are
-- anonymous Supabase auth users, not the `anon` role); only the JWT differs.
-- ---------------------------------------------------------------------------

set local role authenticated;
select test.login_device() as device_id \gset
select code, expires_at from public.request_pairing() \gset pairing_

select cmp_ok(length(:'pairing_code'), '=', 8, 'request_pairing returns an 8-character code');
select ok(
  :'pairing_expires_at'::timestamptz between now() + interval '9 minutes' and now() + interval '11 minutes',
  'request_pairing sets a ~10 minute expiry'
);
select ok(
  not public.pairing_status(:'pairing_code'),
  'pairing_status is false before a real account claims the code'
);

select test.login_user() as owner_id \gset
select lives_ok(
  format('select public.claim_pairing(%L)', :'pairing_code'),
  'claim_pairing succeeds for an unclaimed, unexpired code'
);
select ok(
  (select owner from public.devices where device_uid = :'device_id'::uuid) = :'owner_id'::uuid,
  'claim_pairing links the device to the claiming account'
);

select test.jwt(:'device_id'::uuid, true);
select ok(
  public.pairing_status(:'pairing_code'),
  'pairing_status is true once the code has been claimed'
);

-- ---------------------------------------------------------------------------
-- F3 regression 1: pairings_insert was dropped — an anonymous (no-session)
-- caller has no direct write path left, only request_pairing().
-- ---------------------------------------------------------------------------

reset role;
set local role anon;
select throws_like(
  $$ insert into public.pairings (code, device_uid, expires_at)
     values ('ZZZZZZZZ', gen_random_uuid(), now() + interval '5 minutes') $$,
  '%row-level security%',
  'an anonymous session cannot INSERT a pairings row directly'
);

-- ---------------------------------------------------------------------------
-- F3 regressions 2 and 3: the pairings_validate trigger, exercised directly
-- as the unrestricted bootstrapping role so it is isolated from RLS (the
-- trigger must hold even for a caller RLS would otherwise let through, e.g.
-- a future SECURITY DEFINER writer).
-- ---------------------------------------------------------------------------

reset role;
select throws_like(
  $$ insert into public.pairings (code, device_uid, expires_at)
     values ('LONGTTL1', gen_random_uuid(), now() + interval '30 minutes') $$,
  'iptvs: pairing code lifetime too long',
  'pairings_validate rejects a code with a TTL beyond the 15 minute ceiling'
);

select throws_like(
  format(
    $$ insert into public.pairings (code, device_uid, claimed_by, expires_at)
       values ('PRECLAIM', gen_random_uuid(), %L, now() + interval '5 minutes') $$,
    :'owner_id'::uuid
  ),
  'iptvs: pairing code cannot be pre-claimed',
  'pairings_validate rejects an insert that pre-sets claimed_by'
);

select * from finish();

rollback;
