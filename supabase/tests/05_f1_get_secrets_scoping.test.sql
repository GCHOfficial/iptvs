-- F1 read half: get_secrets() must never hand tenant A's secret to anyone but
-- tenant A (owner or a device paired to tenant A). Positive paths for both
-- accessors, a negative for an unrelated account, and a structural pin on the
-- `ss.owner = resolved_owner` predicate the migration added to the query
-- (belt-and-braces on top of the composite FK from section 2, which
-- 01_baseline_invariants.test.sql already proves cannot be violated).

begin;

select plan(5);

set local role authenticated;

select test.login_user() as owner_a \gset
select gen_random_uuid() as profile_a_id \gset
insert into public.profiles (id, owner, name)
  values (:'profile_a_id'::uuid, :'owner_a'::uuid, 'Default');
select gen_random_uuid() as source_a_id \gset
insert into public.sources (id, owner, profile_id, kind, label)
  values (:'source_a_id'::uuid, :'owner_a'::uuid, :'profile_a_id'::uuid, 'm3u', 'Tenant A source');

select lives_ok(
  format(
    'select public.set_source_secret(%L::uuid, %L::uuid, 0, %L::jsonb)',
    :'source_a_id'::uuid, :'profile_a_id'::uuid,
    jsonb_build_object('playlistUrl', 'http://example.invalid/list.m3u')
  ),
  'set_source_secret succeeds for the owning account'
);

select ok(
  (public.get_secrets(:'profile_a_id'::uuid) -> 'sources') ? :'source_a_id',
  'get_secrets (owner) returns the secret keyed by its source id'
);

-- A device paired to owner A can read the same secret (the RPC is
-- "owner-or-paired-device" scoped, not owner-only).
select test.login_device() as device_a \gset
select code from public.request_pairing() \gset pairing_
select test.jwt(:'owner_a'::uuid, false);
select public.claim_pairing(:'pairing_code');
select test.jwt(:'device_a'::uuid, true);
select ok(
  (public.get_secrets(:'profile_a_id'::uuid) -> 'sources') ? :'source_a_id',
  'get_secrets (paired device) returns the same secret'
);

-- F1 negative: an unrelated real account, neither owner nor paired device.
select test.login_user() as owner_b \gset
select throws_like(
  format('select public.get_secrets(%L::uuid)', :'profile_a_id'::uuid),
  'iptvs: profile not found',
  'get_secrets rejects a profile the caller neither owns nor is paired to'
);

-- Regression pin: the read-side fix was adding `ss.owner = resolved_owner`
-- to the source_secrets join in get_secrets — without it, a planted row
-- (impossible today only because of the section-2 composite FK) would still
-- have been handed back to the victim. Pin the predicate independently of
-- the FK so a future refactor that drops it is caught even if the FK stays.
select ok(
  pg_get_functiondef('public.get_secrets(uuid)'::regprocedure) like '%ss.owner = resolved_owner%',
  'get_secrets still filters source_secrets by ss.owner, not just the source''s owner'
);

select * from finish();

rollback;
