-- Device name at pairing time (20260804000000_pairing_suggested_label.sql):
-- the label precedence chain, the bounds on the device-supplied suggestion, and
-- the UPDATE freeze that keeps a suggestion from being swapped mid-pairing.
--
-- Precedence under test:
--   panel-supplied > existing devices.label (SAME owner only) > suggestion > ''

begin;

select plan(14);

-- ---------------------------------------------------------------------------
-- The suggestion travels on the pairing row and becomes the device's name when
-- the panel operator types nothing. Device and account are the same Postgres
-- role (`authenticated`); only the JWT differs.
-- ---------------------------------------------------------------------------

set local role authenticated;
select test.login_device() as dev1 \gset
select code from public.request_pairing('Android TV') \gset sugg_

select ok(
  (select suggested_label from public.pairings where code = :'sugg_code') = 'Android TV',
  'request_pairing stores the device-supplied suggestion on the pairing row'
);

select test.login_user() as owner1 \gset
select lives_ok(
  format('select public.claim_pairing(%L)', :'sugg_code'),
  'the legacy 1-arg claim_pairing still works (old panel tab, new backend)'
);
select ok(
  (select label from public.devices where device_uid = :'dev1'::uuid) = 'Android TV',
  'a claim with no panel name adopts the device suggestion'
);

-- ---------------------------------------------------------------------------
-- A name typed in the panel outranks the device's suggestion.
-- ---------------------------------------------------------------------------

select test.login_device() as dev2 \gset
select code from public.request_pairing('Android TV') \gset d2_

select test.jwt(:'owner1'::uuid, false);
select lives_ok(
  format('select public.claim_pairing(%L, %L)', :'d2_code', 'Living room'),
  'claim_pairing accepts a panel-supplied name'
);
select ok(
  (select label from public.devices where device_uid = :'dev2'::uuid) = 'Living room',
  'a panel-supplied name outranks the device suggestion'
);

-- ---------------------------------------------------------------------------
-- Re-pair to the SAME owner with the panel field left blank: the name the owner
-- already chose is PRESERVED, never overwritten by the device's suggestion.
-- This is the scalar form of merge_preserving_nonempty — a device-side value
-- must never blank or clobber a panel-set one.
-- ---------------------------------------------------------------------------

select test.jwt(:'dev2'::uuid, true);
select code from public.request_pairing('Android TV') \gset d2b_

select test.jwt(:'owner1'::uuid, false);
select lives_ok(
  format('select public.claim_pairing(%L, %L)', :'d2b_code', ''),
  'the same owner may re-pair a device'
);
select ok(
  (select label from public.devices where device_uid = :'dev2'::uuid) = 'Living room',
  'a same-owner re-pair with a blank panel name preserves the existing name'
);

-- ---------------------------------------------------------------------------
-- Re-pair to a DIFFERENT account: the new owner starts from the device's own
-- suggestion and never inherits the previous owner's chosen name.
-- ---------------------------------------------------------------------------

select test.jwt(:'dev2'::uuid, true);
select code from public.request_pairing('Android TV') \gset d2c_

select test.login_user() as owner2 \gset
select lives_ok(
  format('select public.claim_pairing(%L, %L)', :'d2c_code', ''),
  'a different account may claim a previously paired device'
);
select ok(
  (select label from public.devices where device_uid = :'dev2'::uuid) = 'Android TV',
  'a new owner never inherits the previous owner''s chosen device name'
);

-- ---------------------------------------------------------------------------
-- Bounds on the suggestion, exercised directly as the unrestricted
-- bootstrapping role so they are isolated from RLS — the trigger must hold even
-- for a caller RLS would let through (e.g. a future SECURITY DEFINER writer).
-- ---------------------------------------------------------------------------

reset role;
select throws_like(
  $$ insert into public.pairings (code, device_uid, expires_at, suggested_label)
     values ('LABELMAX', gen_random_uuid(), now() + interval '5 minutes', repeat('a', 257)) $$,
  'iptvs: pairing label invalid (max 256 chars)',
  'pairings_validate rejects a suggestion beyond the 256 character ceiling'
);

select throws_like(
  $$ insert into public.pairings (code, device_uid, expires_at, suggested_label)
     values ('CTRLCHAR', gen_random_uuid(), now() + interval '5 minutes', E'A\nB') $$,
  'iptvs: pairing label invalid',
  'pairings_validate rejects a suggestion containing control characters'
);

-- The freeze: a claimed code's suggestion can never be swapped out from under
-- the user after they have read the code off the device's screen.
select throws_like(
  format(
    $$ update public.pairings set suggested_label = 'Attacker' where code = %L $$,
    :'d2c_code'
  ),
  'iptvs: pairing row is immutable',
  'pairings_validate freezes suggested_label on UPDATE'
);

-- ---------------------------------------------------------------------------
-- A whitespace-only suggestion is treated as absent, not as an error: it must
-- never fail an otherwise valid pairing.
-- ---------------------------------------------------------------------------

set local role authenticated;
select test.login_device() as dev3 \gset
select code from public.request_pairing('   ') \gset d3_

select test.login_user() as owner3 \gset
select lives_ok(
  format('select public.claim_pairing(%L)', :'d3_code'),
  'a whitespace-only suggestion still pairs successfully'
);
select ok(
  (select label from public.devices where device_uid = :'dev3'::uuid) = '',
  'a whitespace-only suggestion yields an empty label, exactly as before'
);

select * from finish();

rollback;
