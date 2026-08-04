-- F4: device_uid is immutable (a squatted uuid would let an attacker inherit
-- another device's pairing via current_device_owner()), but re-pairing —
-- which repoints `owner`, not `device_uid` — must keep working. The positive
-- case is asserted explicitly: it is the regression that would otherwise
-- break every legitimate re-pair.

begin;

select plan(5);

set local role authenticated;
select test.login_device() as device_id \gset
select code from public.request_pairing() \gset pairing1_
select test.login_user() as owner_a \gset
select public.claim_pairing(:'pairing1_code');

-- F4 negative: even the owning account cannot repoint device_uid.
select test.jwt(:'owner_a'::uuid, false);

-- Name the device as account A, so the cross-account assertion at the end of
-- this file is about a real stored name rather than two empty strings.
update public.devices set label = 'Account A bedroom TV'
  where device_uid = :'device_id'::uuid;

select throws_like(
  format(
    'update public.devices set device_uid = %L where device_uid = %L',
    gen_random_uuid(), :'device_id'::uuid
  ),
  'iptvs: device identity is immutable',
  'an owner cannot repoint a device row at a different device_uid'
);

-- F4 positive (the regression to guard): re-pairing the SAME device to a
-- different account must still succeed — claim_pairing only ever repoints
-- `owner`, and devices_validate must not treat that as touching device_uid.
select test.jwt(:'device_id'::uuid, true);
select code from public.request_pairing() \gset pairing2_
select test.login_user() as owner_b \gset
select lives_ok(
  format('select public.claim_pairing(%L)', :'pairing2_code'),
  'claim_pairing still succeeds when re-pairing an already-paired device'
);

select ok(
  (select owner from public.devices where device_uid = :'device_id'::uuid) = :'owner_b'::uuid,
  'the device row''s owner is repointed to the new claiming account'
);
select ok(
  (select device_uid from public.devices where owner = :'owner_b'::uuid) = :'device_id'::uuid,
  'the device_uid itself is unchanged by re-pairing'
);

-- 20260804000000_pairing_suggested_label.sql: a re-pair moves the device to a
-- new account, so account A's chosen name must not follow it into account B's
-- device list. This code carried no suggestion, so B starts from empty.
select ok(
  (select label from public.devices where device_uid = :'device_id'::uuid) = '',
  'a cross-account re-pair does not carry the previous owner''s device name'
);

select * from finish();

rollback;
