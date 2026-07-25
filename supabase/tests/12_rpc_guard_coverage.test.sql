-- Coverage the earlier suite left implicit.
--
-- 10_unpaired_and_revocation.test.sql proves push_sources rejects an unpaired
-- anonymous caller, and the other three push/profile RPCs carry an identical
-- `o is null` guard — but "identical guard, therefore covered" is exactly the
-- reasoning that lets a future edit to one of them slip through. Each is
-- exercised here directly.
--
-- Same for the cross-account `p_profile_id` guard: every push RPC re-verifies
-- the profile belongs to the caller's account, and that predates
-- tenant_isolation.sql, so nothing else in the suite pins it.
--
-- Note the caller in the second half is a PAIRED DEVICE, not a signed-in
-- account: the push RPCs resolve their owner through `current_device_owner()`,
-- so a real account with no device row trips the "only a paired device" guard
-- first and never reaches the profile check. Testing the profile guard requires
-- a caller that gets past the owner guard.

begin;

select plan(8);

set local role authenticated;

-- Account A with a profile, plus account B with a profile it alone owns.
select test.login_user() as owner_a \gset
select gen_random_uuid() as profile_a \gset
insert into public.profiles (id, owner, name) values (:'profile_a'::uuid, :'owner_a'::uuid, 'A');

select test.login_user() as owner_b \gset
select gen_random_uuid() as profile_b \gset
insert into public.profiles (id, owner, name) values (:'profile_b'::uuid, :'owner_b'::uuid, 'B');

-- ---------------------------------------------------------------------------
-- An anonymous session that has never been paired resolves no owner, so every
-- device->cloud write path must refuse it. Holding the public anon key alone
-- grants nothing.
-- ---------------------------------------------------------------------------

select test.login_device() as unpaired \gset

select throws_like(
  format('select public.push_metadata(%L, %L)', '{}'::jsonb, :'profile_a'::uuid),
  'only a paired device can push metadata',
  'push_metadata rejects a device that has never been paired'
);

select throws_like(
  format('select public.push_favorites(%L, %L)', '[]'::jsonb, :'profile_a'::uuid),
  'only a paired device can push favorites',
  'push_favorites rejects a device that has never been paired'
);

select throws_like(
  format('select public.set_device_profile(%L)', :'profile_a'::uuid),
  'only a paired device can set its profile',
  'set_device_profile rejects a device that has never been paired'
);

select throws_like(
  format('select public.get_secrets(%L)', :'profile_a'::uuid),
  'iptvs: profile not found',
  'get_secrets rejects a device that has never been paired'
);

-- ---------------------------------------------------------------------------
-- Now a device legitimately paired to account A, passing account B's profile
-- id. The caller is real and its owner resolves; only the profile is foreign.
-- This is the guard that stops profile_id being a way around owner scoping.
-- ---------------------------------------------------------------------------

select test.login_device() as device_a \gset
select code from public.request_pairing() \gset pairing_
select test.jwt(:'owner_a'::uuid, false);
select public.claim_pairing(:'pairing_code');

-- Act as the now-paired device.
select test.jwt(:'device_a'::uuid, true);

select throws_like(
  format('select public.push_sources(%L, %L)', '[]'::jsonb, :'profile_b'::uuid),
  'profile not found for this account',
  'push_sources rejects a profile_id owned by another account'
);

select throws_like(
  format('select public.push_metadata(%L, %L)', '{}'::jsonb, :'profile_b'::uuid),
  'profile not found for this account',
  'push_metadata rejects a profile_id owned by another account'
);

select throws_like(
  format('select public.push_favorites(%L, %L)', '[]'::jsonb, :'profile_b'::uuid),
  'profile not found for this account',
  'push_favorites rejects a profile_id owned by another account'
);

-- Positive control: the identical call against the paired device's OWN
-- account's profile must still work, so a "reject everything" regression
-- cannot pass this file.
select lives_ok(
  format('select public.push_favorites(%L, %L)', '[]'::jsonb, :'profile_a'::uuid),
  'push_favorites still succeeds for the paired device''s own profile'
);

select * from finish();

rollback;
