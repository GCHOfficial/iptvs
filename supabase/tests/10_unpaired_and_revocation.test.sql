-- The rest of supabase/README.md's security checklist not already covered by
-- the F1-F6 regression files: anonymous reads/writes are blocked before
-- pairing, the push/claim RPCs reject an unpaired or anonymous caller, an
-- expired or already-claimed code is rejected, and deleting a devices row
-- revokes that device's read access immediately.

begin;

select plan(9);

set local role authenticated;

select test.login_user() as owner_a \gset
select gen_random_uuid() as profile_a_id \gset
insert into public.profiles (id, owner, name)
  values (:'profile_a_id'::uuid, :'owner_a'::uuid, 'Default');
insert into public.sources (id, owner, profile_id, kind, label)
  values (gen_random_uuid(), :'owner_a'::uuid, :'profile_a_id'::uuid, 'm3u', 'A source');

-- Anonymous (no session at all) reads nothing and writes nothing, even
-- though rows exist.
reset role;
set local role anon;
select is(
  (select count(*) from public.sources)::int, 0,
  'an anonymous session reads zero rows from sources, even though rows exist'
);
select throws_like(
  $$ insert into public.sources (id, owner, kind, label)
     values (gen_random_uuid(), gen_random_uuid(), 'm3u', 'x') $$,
  '%row-level security%',
  'an anonymous session cannot INSERT into sources directly'
);

-- push_sources rejects a device that has never been paired (no owner to
-- resolve — holding the anon/publishable key alone grants nothing).
reset role;
set local role authenticated;
select test.login_device() as device_x \gset
select throws_like(
  format('select public.push_sources(%L::jsonb, %L::uuid)', '[]'::jsonb, gen_random_uuid()),
  'only a paired device can push sources',
  'push_sources rejects a device that has never been paired'
);

-- Pair device_x to owner_a; it can now read owner_a's sources.
select code from public.request_pairing() \gset pairing_x_
select test.jwt(:'owner_a'::uuid, false);
select public.claim_pairing(:'pairing_x_code');
select test.jwt(:'device_x'::uuid, true);
select is(
  (select count(*) from public.sources where owner = :'owner_a'::uuid)::int, 1,
  'a paired device can read its owner''s sources'
);

-- Deleting the devices row immediately revokes that read access.
select test.jwt(:'owner_a'::uuid, false);
delete from public.devices where device_uid = :'device_x'::uuid;
select test.jwt(:'device_x'::uuid, true);
select is(
  (select count(*) from public.sources where owner = :'owner_a'::uuid)::int, 0,
  'a revoked (unpaired) device can no longer read the former owner''s sources'
);

-- claim_pairing rejects an anonymous (device) claimer.
select test.login_device() as device_y \gset
select code from public.request_pairing() \gset pairing_y_
select test.jwt(:'device_y'::uuid, true);
select throws_like(
  format('select public.claim_pairing(%L)', :'pairing_y_code'),
  'only a signed-in account can claim a device',
  'claim_pairing rejects a caller whose own JWT is anonymous'
);

-- claim_pairing rejects an expired code. UPDATE can't manufacture one
-- (pairings_validate freezes expires_at), so insert one directly, already
-- expired, as the unrestricted bootstrapping role, then attempt the claim as
-- a fresh real-user JWT (the JWT claims from the previous block — an
-- anonymous device — persist across `reset role`, which only resets the SQL
-- role, so a real identity must be set explicitly here).
reset role;
insert into public.pairings (code, device_uid, expires_at)
  values ('EXPIRED1', gen_random_uuid(), now() - interval '1 minute');
select test.jwt(gen_random_uuid(), false);
select throws_like(
  $$ select public.claim_pairing('EXPIRED1') $$,
  'invalid or expired code',
  'claim_pairing rejects an expired code'
);

-- claim_pairing rejects an already-claimed code.
set local role authenticated;
select test.login_user() as owner_b \gset
select lives_ok(
  format('select public.claim_pairing(%L)', :'pairing_y_code'),
  'claim_pairing succeeds the first time for device_y''s code'
);
select test.login_user() as owner_c \gset
select throws_like(
  format('select public.claim_pairing(%L)', :'pairing_y_code'),
  'invalid or expired code',
  'claim_pairing rejects a code that has already been claimed'
);

select * from finish();

rollback;
