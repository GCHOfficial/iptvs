-- Positive-path smoke for set_metadata_secret and delete_account — the last
-- two RPCs in the surface not already exercised elsewhere in the suite.
-- delete_account's cascade is also a useful sanity check on the composite FKs
-- from tenant_isolation.sql: `on delete cascade` on every one of them must
-- still let a real account's own data unwind cleanly. Also closes a
-- supabase/README.md checklist item: delete_account must reject an
-- anonymous (device) caller.

begin;

select plan(6);

set local role authenticated;

select test.login_user() as owner_a \gset
select gen_random_uuid() as profile_a_id \gset
insert into public.profiles (id, owner, name)
  values (:'profile_a_id'::uuid, :'owner_a'::uuid, 'Default');

select lives_ok(
  format(
    'select public.set_metadata_secret(%L::uuid, 0, %L::jsonb)',
    :'profile_a_id'::uuid, jsonb_build_object('tmdbApiKey', 'x')
  ),
  'set_metadata_secret succeeds for the owning account'
);
select ok(
  (public.get_secrets(:'profile_a_id'::uuid) -> 'metadata' ->> 'format')::int = 0,
  'get_secrets reflects the plaintext metadata secret just set'
);

select test.login_device() as device_x \gset
select throws_like(
  'select public.delete_account()',
  'only a signed-in account can delete itself',
  'delete_account rejects an anonymous (device) caller'
);

select test.jwt(:'owner_a'::uuid, false);
select lives_ok(
  'select public.delete_account()',
  'delete_account succeeds for a signed-in real account'
);
select ok(
  not exists (select 1 from auth.users where id = :'owner_a'::uuid),
  'delete_account removes the auth.users row'
);
select ok(
  not exists (select 1 from public.profiles where id = :'profile_a_id'::uuid),
  'delete_account cascades to the account''s profiles via the owner FK'
);

select * from finish();

rollback;
