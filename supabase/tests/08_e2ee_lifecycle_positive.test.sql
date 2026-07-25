-- Positive-path smoke for the Phase 3 (E2EE) RPC family: none of these are
-- touched by tenant_isolation.sql directly, but they sit on the same
-- profile_crypto/device_ck tables the migration's composite FKs reach
-- (profile_crypto_profile_owner_fkey) and the same table-privilege lockdown
-- (F5), so a "deny everything" regression anywhere in this surface would
-- otherwise pass every negative-only test silently.
--
-- No real cryptography happens here — the DB layer only validates JSON shape
-- and the ckv/revision bookkeeping, never plaintext, so dummy envelope
-- payloads exercise the same code paths a real wrapped key would.

begin;

select plan(14);

set local role authenticated;

select test.login_user() as owner_a \gset
select gen_random_uuid() as profile_a_id \gset
insert into public.profiles (id, owner, name)
  values (:'profile_a_id'::uuid, :'owner_a'::uuid, 'Default');

select test.login_device() as device_a \gset
select code from public.request_pairing() \gset pairing_
select test.jwt(:'owner_a'::uuid, false);
select public.claim_pairing(:'pairing_code');

select test.jwt(:'device_a'::uuid, true);
select lives_ok(
  $$ select public.set_device_public_key('test-pubkey-0000000000000000') $$,
  'set_device_public_key succeeds for a paired device'
);

select test.jwt(:'owner_a'::uuid, false);
select ok(
  (public.get_crypto_state(:'profile_a_id'::uuid) ->> 'enabled')::boolean = false,
  'get_crypto_state reports disabled before enable_e2ee'
);

select updated_at from public.profiles where id = :'profile_a_id'::uuid \gset rev_
select lives_ok(
  format(
    'select public.enable_e2ee(%L::uuid, %L::timestamptz, %L, 100000, %L::jsonb, %L::jsonb, null, %L::jsonb)',
    :'profile_a_id'::uuid, :'rev_updated_at'::timestamptz, 'test-salt',
    jsonb_build_object('iv', 'aaaa', 'ciphertext', 'bbbb'),
    '{}'::jsonb, '[]'::jsonb
  ),
  'enable_e2ee succeeds with no existing source/metadata secrets to migrate'
);
select ok(
  (public.get_crypto_state(:'profile_a_id'::uuid) ->> 'enabled')::boolean = true
    and (public.get_crypto_state(:'profile_a_id'::uuid) ->> 'ck_version')::int = 1,
  'get_crypto_state reports enabled, ck_version 1 after enable_e2ee'
);

select lives_ok(
  format(
    'select public.provision_device_ck(%L::uuid, %L::uuid, 1, %L::jsonb)',
    :'device_a'::uuid, :'profile_a_id'::uuid,
    jsonb_build_object('iv', 'cccc', 'ciphertext', 'dddd')
  ),
  'provision_device_ck succeeds for the owner''s own device and profile'
);

select test.jwt(:'device_a'::uuid, true);
select ok(
  (public.get_device_ck(:'profile_a_id'::uuid) ->> 'ck_version')::int = 1,
  'get_device_ck (as the device) returns the provisioned ck_version'
);

select test.jwt(:'owner_a'::uuid, false);
select ok(
  (public.get_profile_crypto(:'profile_a_id'::uuid) ->> 'enabled')::boolean = true,
  'get_profile_crypto (owner) returns the enabled KDF material'
);
select ok(
  jsonb_array_length(public.list_device_ck(:'profile_a_id'::uuid)) = 1
    and (public.list_device_ck(:'profile_a_id'::uuid) -> 0 ->> 'has_ck')::boolean = true,
  'list_device_ck shows the one provisioned device'
);

select lives_ok(
  format(
    'select public.rotate_passphrase(%L::uuid, %L, 100000, %L::jsonb, %L::jsonb)',
    :'profile_a_id'::uuid, 'test-salt-2',
    jsonb_build_object('iv', 'eeee', 'ciphertext', 'ffff'),
    jsonb_build_array(jsonb_build_object(
      'device_uid', :'device_a'::uuid,
      'wrapped_ck', jsonb_build_object('iv', 'gggg', 'ciphertext', 'hhhh')
    ))
  ),
  'rotate_passphrase succeeds and re-provisions the existing device'
);
select ok(
  (public.get_crypto_state(:'profile_a_id'::uuid) ->> 'ck_version')::int = 1,
  'rotate_passphrase does not change ck_version (CK itself is unchanged)'
);

select updated_at from public.profiles where id = :'profile_a_id'::uuid \gset rev_
select lives_ok(
  format(
    'select public.rotate_content_key(%L::uuid, %L::timestamptz, %L::jsonb, 2, %L::jsonb, null, %L::jsonb)',
    :'profile_a_id'::uuid, :'rev_updated_at'::timestamptz,
    jsonb_build_object('iv', 'iiii', 'ciphertext', 'jjjj'),
    '{}'::jsonb,
    jsonb_build_array(jsonb_build_object(
      'device_uid', :'device_a'::uuid,
      'wrapped_ck', jsonb_build_object('iv', 'kkkk', 'ciphertext', 'llll')
    ))
  ),
  'rotate_content_key succeeds and bumps ck_version by exactly 1'
);
select ok(
  (public.get_crypto_state(:'profile_a_id'::uuid) ->> 'ck_version')::int = 2,
  'get_crypto_state reflects the rotated ck_version'
);

select updated_at from public.profiles where id = :'profile_a_id'::uuid \gset rev_
select lives_ok(
  format(
    'select public.disable_e2ee(%L::uuid, %L::timestamptz, %L::jsonb, null)',
    :'profile_a_id'::uuid, :'rev_updated_at'::timestamptz, '{}'::jsonb
  ),
  'disable_e2ee succeeds and reverts the profile to plaintext'
);
select ok(
  (public.get_crypto_state(:'profile_a_id'::uuid) ->> 'enabled')::boolean = false,
  'get_crypto_state reports disabled after disable_e2ee'
);

select * from finish();

rollback;
