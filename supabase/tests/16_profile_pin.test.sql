-- profiles.pin + set_profile_pin: the optional 4-digit profile gate.
--
-- The server never sees a PIN — only an opaque verifier whose *shape* it
-- checks. So the properties that matter here are the boundary ones: a device
-- may set the PIN on its own account's profile and nothing else, a malformed
-- verifier is rejected rather than stored (a profile nobody can open is worse
-- than no gate), and the change advances the snapshot revision like any other
-- profile edit — it is deliberately not given the favorites exemption.

begin;

select plan(11);

set local role authenticated;

select test.login_user() as owner_a \gset
select gen_random_uuid() as profile_a_id \gset
insert into public.profiles (id, owner, name)
  values (:'profile_a_id'::uuid, :'owner_a'::uuid, 'Default');

-- A verifier of the real shape: pbkdf2-sha256$<iters>$<b64 salt>$<b64 hash>.
\set good 'pbkdf2-sha256$10000$MDEyMzQ1Njc4OWFiY2RlZg==$CmWBNvvnuYRzyW+Bx9SZCKhGjs+AZvSITxGzwYDngZM='

-- ── the panel's direct write path ──────────────────────────────────────────

select lives_ok(
  format('update public.profiles set pin = %L where id = %L::uuid',
         :'good', :'profile_a_id'::uuid),
  'the owner may set a well-formed pin directly (the panel path)'
);

select throws_ok(
  format('update public.profiles set pin = %L where id = %L::uuid',
         'hunter2', :'profile_a_id'::uuid),
  'P0001',
  'iptvs: profile pin is not a recognised verifier',
  'a raw PIN (or any non-verifier) is rejected, not stored'
);

-- Empty means open. Normalising here keeps every client''s "locked" test a
-- single `pin is not null`.
select lives_ok(
  format('update public.profiles set pin = %L where id = %L::uuid',
         '   ', :'profile_a_id'::uuid),
  'a blank pin is accepted'
);
select is(
  (select pin from public.profiles where id = :'profile_a_id'::uuid),
  null,
  'and is normalised to null rather than stored as an empty string'
);

-- ── the device write path ──────────────────────────────────────────────────

select test.login_device() as device_a \gset
select code from public.request_pairing() \gset pairing_
select test.jwt(:'owner_a'::uuid, false);
select public.claim_pairing(:'pairing_code');
select test.jwt(:'device_a'::uuid, true);

select lives_ok(
  format('select public.set_profile_pin(%L::uuid, %L)',
         :'profile_a_id'::uuid, :'good'),
  'a paired device may set the pin on its own account''s profile'
);
select is(
  (select pin from public.profiles where id = :'profile_a_id'::uuid),
  :'good',
  'and the verifier is stored verbatim'
);

select throws_ok(
  format('select public.set_profile_pin(%L::uuid, %L)',
         :'profile_a_id'::uuid, 'pbkdf2-sha256$10000$short$nope'),
  'P0001',
  'iptvs: profile pin is not a recognised verifier',
  'the device path is validated by the same trigger as the panel path'
);

select lives_ok(
  format('select public.set_profile_pin(%L::uuid, null)', :'profile_a_id'::uuid),
  'a device may clear the pin'
);
select is(
  (select pin from public.profiles where id = :'profile_a_id'::uuid),
  null,
  'and clearing stores null'
);

-- ── cross-tenant ───────────────────────────────────────────────────────────

select test.login_user() as owner_b \gset
select gen_random_uuid() as profile_b_id \gset
insert into public.profiles (id, owner, name)
  values (:'profile_b_id'::uuid, :'owner_b'::uuid, 'Other account');

select test.jwt(:'device_a'::uuid, true);
select throws_like(
  format('select public.set_profile_pin(%L::uuid, %L)',
         :'profile_b_id'::uuid, :'good'),
  'profile not found for this account',
  'a device cannot lock (or unlock) another account''s profile'
);

-- ── revision ───────────────────────────────────────────────────────────────
--
-- Not exempt, unlike favorites: a PIN change is a profile edit, and the
-- exemption exists only for the collection that pushes constantly.

select test.jwt(:'owner_a'::uuid, false);
select updated_at as rev_pin from public.profiles where id = :'profile_a_id'::uuid \gset
update public.profiles set pin = :'good' where id = :'profile_a_id'::uuid;
select ok(
  (select updated_at from public.profiles where id = :'profile_a_id'::uuid)
    > :'rev_pin'::timestamptz,
  'setting a pin advances the profile snapshot revision'
);

select * from finish();
rollback;
