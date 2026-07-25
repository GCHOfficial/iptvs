-- Positive-path smoke for the device push RPCs not already exercised by the
-- F1/F2 regression files: set_device_profile, the legacy 1-arg push_sources,
-- both push_metadata overloads (2-arg and the secret-carrying 3-arg), and
-- push_favorites. A "deny everything" regression on any owner/profile guard
-- in these functions would pass the negative-only tests silently — this file
-- is what would catch it.

begin;

select plan(7);

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
  format('select public.set_device_profile(%L::uuid)', :'profile_a_id'::uuid),
  'set_device_profile succeeds for a profile the device''s owner owns'
);

select gen_random_uuid() as source_a_id \gset
select lives_ok(
  format(
    'select public.push_sources(%L::jsonb)',
    jsonb_build_array(jsonb_build_object(
      'id', :'source_a_id'::uuid,
      'kind', 'm3u',
      'label', 'legacy push',
      'fields', jsonb_build_object(),
      'settings', jsonb_build_object(),
      'position', 0
    ))
  ),
  'the legacy 1-arg push_sources delegates to the device''s active profile'
);
select ok(
  exists (
    select 1 from public.sources
     where id = :'source_a_id'::uuid and owner = :'owner_a'::uuid and profile_id = :'profile_a_id'::uuid
  ),
  'the legacy push landed the source under the device''s active profile'
);

select lives_ok(
  format(
    'select public.push_metadata(%L::jsonb, %L::uuid)',
    jsonb_build_object('language', 'en'), :'profile_a_id'::uuid
  ),
  'the 2-arg push_metadata succeeds for the device''s active profile'
);

select lives_ok(
  format(
    'select public.push_metadata(%L::jsonb, %L::uuid, %L::jsonb)',
    jsonb_build_object('language', 'en'), :'profile_a_id'::uuid,
    jsonb_build_object('format', 0, 'payload', jsonb_build_object('tmdbApiKey', 'x'))
  ),
  'the 3-arg push_metadata (with a plaintext secret) succeeds'
);

select lives_ok(
  format(
    'select public.push_favorites(%L::jsonb, %L::uuid)',
    jsonb_build_array(jsonb_build_object(
      'source_id', :'source_a_id'::uuid, 'kind', 'live', 'item_id', 'ch-1'
    )),
    :'profile_a_id'::uuid
  ),
  'push_favorites succeeds for the device''s active profile'
);
select ok(
  jsonb_array_length(
    (select favorites from public.profiles where id = :'profile_a_id'::uuid)
  ) = 1,
  'push_favorites landed exactly one favorite on the profile'
);

select * from finish();

rollback;
