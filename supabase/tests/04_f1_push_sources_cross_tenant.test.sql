-- F1 write half: push_sources's per-payload id guard (tenant_isolation.sql
-- section 3(a)) plus the structural backstop — a direct INSERT into
-- source_secrets whose owner disagrees with its source's owner now violates
-- the new composite FK, so the F1 plant ("source_secrets(source_id = a
-- victim's source, owner = the attacker)") is unrepresentable even without
-- the RPC guard.

begin;

select plan(4);

set local role authenticated;

-- Tenant A: a real account with one source (no device involved on this side).
select test.login_user() as owner_a \gset
select gen_random_uuid() as profile_a_id \gset
insert into public.profiles (id, owner, name)
  values (:'profile_a_id'::uuid, :'owner_a'::uuid, 'Default');
select gen_random_uuid() as source_a_id \gset
insert into public.sources (id, owner, profile_id, kind, label)
  values (:'source_a_id'::uuid, :'owner_a'::uuid, :'profile_a_id'::uuid, 'm3u', 'Tenant A source');

-- Tenant B: a real account with a paired device and its own profile.
select test.login_device() as device_b \gset
select code from public.request_pairing() \gset pairing_
select test.login_user() as owner_b \gset
select public.claim_pairing(:'pairing_code');
select gen_random_uuid() as profile_b_id \gset
insert into public.profiles (id, owner, name)
  values (:'profile_b_id'::uuid, :'owner_b'::uuid, 'Default');

-- Act as tenant B's paired device for the rest of this file.
select test.jwt(:'device_b'::uuid, true);

-- Positive case: pushing the device's OWN new source (with a plaintext
-- secret — profile_crypto has no row for profile_b, so format 0 is required)
-- succeeds. Exercises the exact RPC the negative case below attacks.
select lives_ok(
  format(
    'select public.push_sources(%L::jsonb, %L::uuid)',
    jsonb_build_array(jsonb_build_object(
      'id', gen_random_uuid(),
      'kind', 'm3u',
      'label', 'tenant B own source',
      'fields', jsonb_build_object(),
      'secret', jsonb_build_object(
        'format', 0,
        'payload', jsonb_build_object('playlistUrl', 'http://example.invalid/list.m3u')
      )
    )),
    :'profile_b_id'::uuid
  ),
  'push_sources succeeds for the device''s own profile and its own new source id'
);

-- F1 negative: tenant B's device tries to push an element carrying tenant
-- A's source id (with a secret attached) under tenant B's own profile.
select throws_like(
  format(
    'select public.push_sources(%L::jsonb, %L::uuid)',
    jsonb_build_array(jsonb_build_object(
      'id', :'source_a_id'::uuid,
      'kind', 'm3u',
      'label', 'squatted id',
      'fields', jsonb_build_object(),
      'secret', jsonb_build_object(
        'format', 0,
        'payload', jsonb_build_object('playlistUrl', 'http://attacker.invalid/list.m3u')
      )
    )),
    :'profile_b_id'::uuid
  ),
  'iptvs: source id belongs to another account',
  'push_sources rejects a payload whose id belongs to another account, before any mutation'
);

-- Structural backstop: even a DIRECT insert (bypassing the RPC's guard
-- entirely) into source_secrets with a mismatched owner is now rejected by
-- the database itself.
reset role;
select throws_ok(
  format(
    'insert into public.source_secrets (source_id, owner, profile_id, format, payload) values (%L, %L, %L, 0, %L)',
    :'source_a_id'::uuid, :'owner_b'::uuid, :'profile_b_id'::uuid, '{}'::jsonb
  ),
  '23503',
  NULL,
  'a source_secrets row whose owner disagrees with its source''s owner violates the composite FK'
);

select ok(
  not exists (
    select 1 from public.source_secrets
     where source_id = :'source_a_id'::uuid and owner = :'owner_b'::uuid
  ),
  'no source_secrets row exists under the foreign owner after the rejected attempts'
);

select * from finish();

rollback;
